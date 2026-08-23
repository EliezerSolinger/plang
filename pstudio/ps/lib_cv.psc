"""O widget de edição, em pscript (porte do `pstudio/codeview.p`).

Amarra as três camadas: o buffer (`lib_core`), o toolkit (`pui` (o pacote)), o realce e
o completamento (`lib_hl`, `lib_complete`, que falam com o lexer do compilador
pelo adaptador da 113). Segue o `TextEdit` do Godot onde importa: as barras de
rolagem são filhos INTERNOS que o widget posiciona, e as sarjetas são plugáveis.

Três diferenças do original, todas de LAYERING e todas para o mesmo fim — que a
lógica do editor rode sem driver, e portanto seja testável:

  * **a sarjeta é DADO, não função.** `enum GutKind` + `match`, que é a 28.5
    ("despacho é dado") aplicada onde ela cabe. As três que existem (marcas,
    dobra, números) são as três que o editor usa;
  * **a área de transferência não mora aqui.** `copy()` DEVOLVE o texto e
    `paste(texto)` RECEBE: quem fala com o sistema é o app, que é quem tem o
    driver. O modelo multi-cursor (N pedaços para N cursores) continua aqui;
  * **arquivo também não.** `load_text`/`text_to_save` em vez de ler e escrever:
    I/O no pscript é `await` (76.2), e quem espera é o laço de eventos.
"""
import lib_core as core
import <pui> as pui
import lib_hl as hlm
import lib_complete as cmp


const CV_TAB: int = 4              # tab suave (DESIGN.md)
# o popup de completamento. A caixa é ajustada aos candidatos NA ABERTURA e
# depois presa à área de texto, então nunca alcança o minimapa nem sai do
# widget; o que não cabe é elidido (`cmd_text_fit`), não pintado fora.
const CMP_MAX_ROWS: int = 10
const CMP_MIN_COLS: int = 16
const CMP_MAX_COLS: int = 72
const CMP_PAD: int = 3
const CMP_MIN_DETAIL: int = 8      # abaixo disto a assinatura sai em vez de virar "…"
# minimapa: uma fileira de pixels por linha, uma coluna por caractere (o Godot o
# desenha a partir do REALCE, não de glifos — nesta escala letra é ruído)
const MM_COLS: int = 90
const MM_ROW: int = 2


# as cores por classe de realce (tema escuro; o índice é HL_* do lib_hl)
# as cores por classe de realce (tema escuro; o índice é HL_* do lib_hl). Um
# `match` e não uma lista de módulo: módulo importado não roda statement.
def hl_color(cls: int) -> int:
    if cls == 1:
        return 0xFFC586C0      # palavra da linguagem (roxo)
    if cls == 2:
        return 0xFFCE9178      # cadeia (laranja)
    if cls == 3:
        return 0xFFB5CEA8      # número (verde claro)
    if cls == 4:
        return 0xFF6A9955      # comentário (verde)
    return 0xFFD4D4D4          # texto


# uma cor de realce na força do minimapa (translúcida, para as corridas lerem
# como textura)
def mm_tint(cls: int) -> int:
    return (hl_color(cls) & 0x00FFFFFF) | 0xB0000000


enum GutKind:
    GUT_NUMBERS       # o número da linha
    GUT_FOLD          # ▾ bloco aberto, ▸ recolhido
    GUT_MARKS         # ● ponto de parada, ◆ marcador


record Gutter:
    kind: GutKind
    width_cp: int     # largura em CARACTERES (fonte monoespaçada)


def is_word_ch(c: str) -> bool:
    return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_"


# os pares que um editor fecha por você; uma aspa é o próprio fechamento
def pair_close_of(open_ch: str) -> str:
    if open_ch == "(":
        return ")"
    if open_ch == "[":
        return "]"
    if open_ch == "{":
        return "}"
    if open_ch == "\"" or open_ch == "'":
        return open_ch
    return ""


def pair_is_close(ch: str) -> bool:
    return ch == ")" or ch == "]" or ch == "}" or ch == "\"" or ch == "'"


struct CodeView:
    buf: core.Buffer
    hl: hlm.Hl
    index: cmp.Index
    path: str              # "" = buffer solto, sem arquivo
    u: pui.Ui              # o toolkit que o desenha
    id: int                # o id deste widget no pool
    vsb: int               # a barra vertical (filho interno)
    hsb: int               # a horizontal
    top: int               # primeira linha visível
    left: int              # primeira COLUNA DE TELA visível (tabs expandidos)
    gutters: list<Gutter>
    cmp_open: bool         # o popup está à mostra
    cmp_hits: list<int>
    cmp_sel: int
    cmp_top: int           # primeira linha mostrada no popup
    cmp_col: int           # coluna onde começa a palavra sendo completada
    cmp_owner: str         # struct cujos membros se listam (o caso `x.`); "" = nenhum
    minimap: bool
    minimap_drag: bool
    caret_on: bool         # fase do piscar (o app alterna no timeout)
    mouse_sel: bool        # arrastando uma seleção
    mtime: int             # o mtime do arquivo na última leitura
    clip: list<str>        # os pedaços do último copy (um por cursor)
    dirty_cb: bool         # algo mudou e o app ainda não olhou
    now_ms: int            # o relógio, posto pelo app a cada quadro — a entrada
                           #   vem do toolkit, que não sabe de tempo

    # ---------- o que o toolkit chama ----------

    def set_now(self, ms: int):
        self.now_ms = ms

    def layout(self, r: pui.Rect):
        """As barras internas (o layout do TextEdit do Godot): a vertical toma a
        borda direita inteira, a horizontal o rodapé menos essa largura."""
        hs = self.u.theme.handle + 2
        self.u.set_rect(self.vsb, pui.Rect(r.x + r.w - hs, r.y, hs, r.h - hs))
        self.u.set_rect(self.hsb, pui.Rect(r.x + self.gutter_w(), r.y + r.h - hs,
                                           r.w - hs - self.gutter_w(), hs))
        self.sync_bars()

    def on_vscroll(self, v: int):
        self.top = self.buf.from_visible(v)
        self.u.queue_redraw(self.id)

    def on_hscroll(self, v: int):
        self.left = v
        self.u.queue_redraw(self.id)

    # ---------- arquivo (sem I/O: quem espera é o app) ----------

    def load_text(self, path: str, data: str, mtime: int):
        self.buf.load(data)
        self.path = path
        self.mtime = mtime
        self.hl = hlm.new_hl(hlm.is_p_file(path))
        self.top = 0
        self.left = 0
        self.changed()

    def text_to_save(self) -> str:
        return self.buf.text()

    def mark_saved(self, mtime: int):
        self.buf.mark_saved()
        self.mtime = mtime
        self.dirty_cb = True

    def set_text(self, text: str):
        self.buf.load(text)
        self.changed()

    # ---------- geometria ----------

    def gutter_w(self) -> int:
        if len(self.gutters) == 0:
            return 0
        total = 0
        for g in self.gutters:
            total += g.width_cp * self.u.cell_w
        return total + self.u.cell_w   # um caractere de respiro antes do texto

    def minimap_rect(self) -> pui.Rect:
        r = self.u.rect_of(self.id)
        hs = self.u.theme.handle + 2
        if not self.minimap:
            return pui.Rect(r.x + r.w - hs, r.y, 0, 0)
        w = MM_COLS
        if w > r.w // 4:
            w = r.w // 4          # nunca come mais de um quarto da vista
        return pui.Rect(r.x + r.w - hs - w, r.y, w, r.h - hs)

    def text_rect(self) -> pui.Rect:
        r = self.u.rect_of(self.id)
        hs = self.u.theme.handle + 2
        g = self.gutter_w()
        mm = self.minimap_rect().w
        return pui.Rect(r.x + g, r.y, r.w - g - hs - mm, r.h - hs)

    def toggle_minimap(self):
        self.minimap = not self.minimap
        self.u.relayout()
        self.u.queue_redraw(self.id)

    def visible_lines(self) -> int:
        n = self.text_rect().h // self.u.cell_h
        return n if n > 0 else 1

    def add_gutter(self, kind: GutKind, width_cp: int):
        self.gutters.append(Gutter(kind, width_cp))

    # o texto e a cor de uma célula de sarjeta; "" = célula vazia
    def gutter_cell(self, kind: GutKind, line: int) -> str:
        match kind:
            case GUT_MARKS:
                m = self.buf.mark_of(line)
                # o ERRO ganha das outras: se o build falhou aqui, é isso que
                # quem olha precisa de ver primeiro
                if (m & core.MARK_ERROR) != 0:
                    return "✗"
                if (m & core.MARK_BREAK) != 0:
                    return "●"
                if (m & core.MARK_BOOK) != 0:
                    return "◆"
                return ""
            case GUT_FOLD:
                if self.buf.is_folded(line):
                    return "▸"
                if self.buf.can_fold(line):
                    return "▾"
                return ""
            case _:
                return str(line + 1)

    def gutter_color(self, kind: GutKind, line: int) -> int:
        match kind:
            case GUT_MARKS:
                return 0xFFE05252 if (self.buf.mark_of(line) & core.MARK_BREAK) != 0 else 0xFF4F9CF7
            case GUT_FOLD:
                return 0xFFD0A050 if self.buf.is_folded(line) else 0xFF6E7075
            case _:
                for k in range(self.buf.ncarets()):
                    if self.buf.caret(k).line == line:
                        return 0xFFB0B0B0
                return 0xFF6E7075

    def gutter_click(self, kind: GutKind, line: int) -> bool:
        match kind:
            case GUT_MARKS:
                self.buf.toggle_mark(line, core.MARK_BREAK)
                self.u.queue_redraw(self.id)
                return True
            case GUT_FOLD:
                if not self.buf.toggle_fold(line):
                    return False
                self.anchor_top()
                return True
            case _:
                return False

    # ---------- colunas de TELA (tabs expandidos) ----------

    def screen_col(self, line: int, col: int) -> int:
        s = self.buf.line_text(line)
        sc = 0
        n = 0
        for ch in s:
            if n >= col:
                break
            if ch == "\t":
                sc += CV_TAB - (sc % CV_TAB)
            else:
                sc += 1
            n += 1
        return sc

    def col_from_screen(self, line: int, scol: int) -> int:
        s = self.buf.line_text(line)
        sc = 0
        n = 0
        for ch in s:
            if sc >= scol:
                return n
            if ch == "\t":
                sc += CV_TAB - (sc % CV_TAB)
            else:
                sc += 1
            n += 1
        return n

    def line_at_row(self, row: int) -> int:
        return self.buf.next_visible(self.top, row)

    def row_of_line(self, line: int) -> int:
        if self.buf.is_hidden(line):
            return -1
        return self.buf.to_visible(line) - self.buf.to_visible(self.top)

    def pos_from_xy(self, x: int, y: int) -> core.Span:
        tr = self.text_rect()
        row = (y - tr.y) // self.u.cell_h
        if y < tr.y:
            row = -1
        l = self.line_at_row(row)      # a dobra é pulada pelo mapeamento
        sc = self.left + (x - tr.x + self.u.cell_w // 2) // self.u.cell_w
        if sc < 0:
            sc = 0
        c = self.col_from_screen(l, sc)
        return core.Span(l, c, l, c)

    def max_screen_cols(self) -> int:
        """A linha VISÍVEL mais larga: a barra horizontal acompanha o que está
        na tela, como o Godot faz — nunca varre o arquivo inteiro."""
        vis = self.visible_lines()
        mx = 1
        l = self.top
        for row in range(vis + 1):
            w = self.screen_col(l, self.buf.line_cp(l))
            if w > mx:
                mx = w
            nl = self.buf.next_visible(l, 1)
            if nl == l:
                break
            l = nl
        return mx

    def sync_bars(self):
        tr = self.text_rect()
        vis = self.visible_lines()
        cols = tr.w // self.u.cell_w
        if cols < 1:
            cols = 1
        # a barra vertical conta linhas VISÍVEIS (uma dobra encurta o documento)
        self.u.scroll_set(self.vsb, self.buf.visible_count(), vis, self.buf.to_visible(self.top))
        self.top = self.buf.from_visible(self.u.scroll_value(self.vsb))
        mx = self.max_screen_cols()
        self.u.scroll_set(self.hsb, mx + 1, cols, self.left)
        self.left = self.u.scroll_value(self.hsb)
        # a horizontal só aparece quando precisa (Sublime/Godot)
        self.u.set_visible(self.hsb, mx >= cols)

    # ---------- navegação ----------

    def set_top(self, line: int):
        """`line` é índice VISÍVEL aqui: a barra e a roda pensam em fileiras, e
        um documento dobrado tem menos fileiras do que linhas."""
        v = line
        mx = self.buf.visible_count() - 1
        if v > mx:
            v = mx
        if v < 0:
            v = 0
        n = self.buf.from_visible(v)
        if n != self.top:
            self.top = n
            self.sync_bars()
            self.u.queue_redraw(self.id)

    def set_left(self, col: int):
        n = col if col > 0 else 0
        if n != self.left:
            self.left = n
            self.sync_bars()
            self.u.queue_redraw(self.id)

    def anchor_top(self):
        """Uma dobra mudou o mapa: mantém a vista onde está. Dobrar pela SARJETA
        não deve rolar (Godot/Sublime) — o cursor pode estar em qualquer lugar, e
        correr atrás dele tira o leitor do bloco que ele acabou de dobrar."""
        self.top = self.buf.visible_at_or_before(self.top)
        self.changed()

    def scroll_to_caret(self):
        c = self.buf.caret(self.buf.ncarets() - 1)
        vis = self.visible_lines()
        top = self.top
        cv = self.buf.to_visible(c.line)
        tv = self.buf.to_visible(top)
        if cv < tv:
            top = c.line
        elif cv >= tv + vis:
            top = self.buf.from_visible(cv - vis + 1)
        tr = self.text_rect()
        cols = tr.w // self.u.cell_w
        if cols < 1:
            cols = 1
        sc = self.screen_col(c.line, c.col)
        left = self.left
        if sc < left:
            left = sc
        elif sc >= left + cols:
            left = sc - cols + 1
        self.top = top if top >= 0 else 0
        self.left = left if left >= 0 else 0
        self.sync_bars()
        self.u.queue_redraw(self.id)

    def changed(self):
        self.hl.update(self.buf)
        self.sync_bars()
        self.u.queue_redraw(self.id)
        self.dirty_cb = True

    # ---------- desenho ----------

    def build(self):
        r = self.u.rect_of(self.id)
        tr = self.text_rect()
        th = self.u.theme
        lh = self.u.cell_h
        cw = self.u.cell_w
        cols = tr.w // cw + 1
        vis = self.visible_lines()
        gw = self.gutter_w()

        self.u.cmd_rect(self.id, r, 0xFF1E1F22)
        if gw > 0:
            self.u.cmd_rect(self.id, pui.Rect(r.x, r.y, gw, r.h), 0xFF232527)

        self.hl.update(self.buf)

        # a linha atual (só com um cursor e sem seleção, como o Sublime)
        if self.buf.ncarets() == 1 and not self.buf.has_sel():
            crow = self.row_of_line(self.buf.caret(0).line)
            if crow >= 0 and crow < vis:
                self.u.cmd_rect(self.id, pui.Rect(tr.x, tr.y + crow * lh, tr.w, lh), 0xFF26282C)

        # as seleções (antes do texto: o replay é em ordem)
        for k in range(self.buf.ncarets()):
            sr = self.buf.sel_range(k)
            if sr.l0 == sr.l1 and sr.c0 == sr.c1:
                continue
            for ln in range(sr.l0, sr.l1 + 1):
                srow = self.row_of_line(ln)
                if srow < 0 or srow >= vis:
                    continue
                s0 = self.screen_col(ln, sr.c0) if ln == sr.l0 else 0
                s1 = self.screen_col(ln, sr.c1) if ln == sr.l1 else self.screen_col(ln, self.buf.line_cp(ln)) + 1
                x0 = tr.x + (s0 - self.left) * cw
                x1 = tr.x + (s1 - self.left) * cw
                if x1 <= tr.x or x0 >= tr.x + tr.w:
                    continue
                self.u.cmd_rect(self.id, pui.Rect(x0, tr.y + srow * lh, x1 - x0, lh), th.sel)

        # sarjetas e texto, andando pelas fileiras VISÍVEIS (dobra é pulada)
        ln = self.top
        for vi in range(vis + 1):
            if vi > 0:
                nl = self.buf.next_visible(ln, 1)
                if nl == ln:
                    break            # fim do documento
                ln = nl
            y = tr.y + vi * lh
            gx = r.x
            for g in self.gutters:
                cell = self.gutter_cell(g.kind, ln)
                if len(cell) > 0:
                    # alinhado à direita dentro da coluna, medido em CODEPOINTS:
                    # um marcador como ▾ é um glifo e três bytes
                    self.u.cmd_text(self.id, gx + (g.width_cp - len(cell)) * cw, y, cell,
                                    self.gutter_color(g.kind, ln))
                gx += g.width_cp * cw
            # guias de indentação: um fio de 1px em cada parada de tabulação
            # dentro do espaço à esquerda, para o aninhamento ser legível numa
            # linguagem de indentação
            ind = self.buf.indent_of(ln)
            if self.buf.is_blank(ln):
                # uma linha vazia empresta a menor dos vizinhos, para as guias
                # não quebrarem no meio de um bloco
                pv = self.buf.next_visible(ln, -1)
                nx = self.buf.next_visible(ln, 1)
                a = self.buf.indent_of(pv) if pv != ln else 0
                bq = self.buf.indent_of(nx) if nx != ln else 0
                ind = a if a < bq else bq
            gcol = CV_TAB
            while gcol < ind:
                gxx = tr.x + (gcol - self.left) * cw
                if gxx >= tr.x and gxx < tr.x + tr.w:
                    self.u.cmd_rect(self.id, pui.Rect(gxx, y, 1, lh), 0xFF31343A)
                gcol += CV_TAB
            s = self.buf.line_text(ln)
            sc = 0
            cpi = 0
            for ch in s:
                adv = 1
                if ch == "\t":
                    adv = CV_TAB - (sc % CV_TAB)
                if sc + adv > self.left and sc < self.left + cols and ch != "\t":
                    self.u.cmd_glyph(self.id, tr.x + (sc - self.left) * cw, y, ord(ch),
                                     hl_color(self.hl.class_at(ln, cpi)))
                sc += adv
                cpi += 1
                if sc > self.left + cols:
                    break
            # um bloco recolhido mostra a elipse do Sublime depois do cabeçalho
            if self.buf.is_folded(ln):
                ex = tr.x + (sc - self.left + 1) * cw
                self.u.cmd_rect(self.id, pui.Rect(ex - 2, y, cw + 4, lh), 0xFF3A3D41)
                self.u.cmd_glyph(self.id, ex, y, pui.CP_ELLIPSIS, th.text_dim)

        # ---- o popup de completamento, ancorado sob o cursor ----
        if self.cmp_open and len(self.cmp_hits) > 0 and self.row_of_line(self.buf.caret(0).line) >= 0:
            pr = self.cmp_rect()
            rows2 = self.cmp_rows()
            self.u.cmd_rect(self.id, pr, 0xFF2B2D30)
            self.u.cmd_frame(self.id, pr, th.accent)
            inner = pr.w - 2 * CMP_PAD
            for hi in range(rows2):
                idx2 = self.cmp_top + hi
                if idx2 >= len(self.cmp_hits):
                    break
                sm = self.index.sym(self.cmp_hits[idx2])
                ry = pr.y + CMP_PAD + hi * lh
                if idx2 == self.cmp_sel:
                    self.u.cmd_rect(self.id, pui.Rect(pr.x + 1, ry, pr.w - 2, lh), th.sel)
                # o NOME é o que se escolhe, então fica com o que precisa; a
                # assinatura pega o que sobrou e sai de cena quando não sobra o
                # bastante para dizer algo
                nw = self.u.cmd_text_fit(self.id, pr.x + CMP_PAD, ry, sm.name, inner,
                                         th.text if idx2 == self.cmp_sel else th.text_dim)
                if len(sm.detail) > 0:
                    dw = inner - nw - 2 * cw
                    if dw >= CMP_MIN_DETAIL * cw:
                        self.u.cmd_text_fit(self.id, pr.x + CMP_PAD + nw + 2 * cw, ry,
                                            sm.detail, dw, 0xFF6E7075)

        # ---- o minimapa: uma corrida da mesma classe vira um retângulo ----
        if self.minimap:
            mr = self.minimap_rect()
            self.u.cmd_rect(self.id, mr, 0xFF1A1B1E)
            rows = mr.h // MM_ROW
            total = self.buf.visible_count()
            first = self.mm_first(rows, vis, total)
            mln = self.buf.from_visible(first)
            for mrow in range(rows):
                if mrow > 0:
                    nl2 = self.buf.next_visible(mln, 1)
                    if nl2 == mln:
                        break
                    mln = nl2
                my = mr.y + mrow * MM_ROW
                mc = 0
                runc = 0
                runs = -1
                for chm in self.buf.line_text(mln):
                    if mc >= mr.w:
                        break
                    clsm = self.hl.class_at(mln, mc)
                    blank = chm == " " or chm == "\t"
                    if blank or clsm != runc:
                        if runs >= 0:
                            self.u.cmd_rect(self.id, pui.Rect(mr.x + runs, my, mc - runs, MM_ROW - 1),
                                            mm_tint(runc))
                            runs = -1
                        if not blank:
                            runc = clsm
                            runs = mc
                    mc += CV_TAB - (mc % CV_TAB) if chm == "\t" else 1
                if runs >= 0 and runs < mr.w:
                    e2 = mc if mc < mr.w else mr.w
                    self.u.cmd_rect(self.id, pui.Rect(mr.x + runs, my, e2 - runs, MM_ROW - 1),
                                    mm_tint(runc))
            # a janela da vista sobre a tira
            vy = mr.y + (self.buf.to_visible(self.top) - first) * MM_ROW
            self.u.cmd_rect(self.id, pui.Rect(mr.x, vy, mr.w, vis * MM_ROW), 0x18FFFFFF)
            self.u.cmd_frame(self.id, pui.Rect(mr.x, vy, mr.w, vis * MM_ROW), 0xFF3A3D41)

        # os cursores (por cima de tudo)
        if self.caret_on and self.u.focus_get() == self.id:
            for k in range(self.buf.ncarets()):
                c = self.buf.caret(k)
                krow = self.row_of_line(c.line)
                if krow < 0 or krow >= vis:
                    continue
                cx = tr.x + (self.screen_col(c.line, c.col) - self.left) * cw
                if cx < tr.x - 1 or cx > tr.x + tr.w:
                    continue
                self.u.cmd_rect(self.id, pui.Rect(cx, tr.y + krow * lh, 2, lh), 0xFFE8E8E8)

    def mm_first(self, rows: int, vis: int, total: int) -> int:
        """A primeira fileira que a tira mostra — a conta está aqui porque o
        desenho e o clique no minimapa precisam da MESMA."""
        if total <= rows:
            return 0
        topv = self.buf.to_visible(self.top)
        span = total - rows
        room = total - vis
        first = topv * span // (room if room > 0 else 1)
        return span if first > span else first

    def minimap_jump(self, y: int):
        """Centra a vista na linha que o pixel `y` do minimapa representa."""
        mr = self.minimap_rect()
        vis = self.visible_lines()
        rows = mr.h // MM_ROW
        first = self.mm_first(rows, vis, self.buf.visible_count())
        self.set_top(first + (y - mr.y) // MM_ROW - vis // 2)

    # ---------- área de transferência (o app fala com o sistema) ----------

    def copy(self) -> str:
        """Devolve o texto para o sistema (os pedaços juntados por \\n) e guarda
        os N pedaços para o paste multi-cursor. "" = não havia seleção."""
        if not self.buf.has_sel():
            return ""
        parts: list<str> = []
        for k in range(self.buf.ncarets()):
            parts.append(self.buf.sel_text(k))
        self.clip = parts
        return "\n".join(parts)

    def cut(self, now_ms: int) -> str:
        got = self.copy()
        if len(got) == 0:
            return ""
        self.buf.delete_sel(now_ms)
        self.changed()
        self.scroll_to_caret()
        return got

    def paste(self, sys_text: str, now_ms: int):
        # N pedaços para N cursores (Sublime): só enquanto o que veio do sistema
        # ainda é o que nós copiamos (senão o texto de fora ganha)
        if len(self.clip) == self.buf.ncarets() and len(self.clip) > 1 and sys_text == "\n".join(self.clip):
            self.buf.insert_each(self.clip, now_ms)
        elif len(sys_text) > 0:
            self.buf.insert(sys_text, now_ms)
        elif len(self.clip) == 1:
            self.buf.insert(self.clip[0], now_ms)
        self.changed()
        self.scroll_to_caret()

    # ---------- indentação ----------

    def sel_lines_range(self) -> core.Span:
        """As linhas que os cursores cobrem, e se ALGUM deles tem seleção de
        mais de uma linha (o que decide se o tab indenta o bloco)."""
        l0 = 0
        l1 = -1
        multi = 0
        for k in range(self.buf.ncarets()):
            sr = self.buf.sel_range(k)
            if sr.l0 != sr.l1:
                multi = 1
            if l1 < 0 or sr.l0 < l0:
                l0 = sr.l0
            if sr.l1 > l1:
                l1 = sr.l1
        return core.Span(l0, multi, l1, 0)

    def indent(self, now_ms: int):
        rg = self.sel_lines_range()
        if rg.c0 == 1:
            self.buf.indent(1, now_ms)
        else:
            c = self.buf.caret(0)
            pad = CV_TAB - (self.screen_col(c.line, c.col) % CV_TAB)
            self.buf.insert(" " * pad, now_ms)
        self.changed()
        self.scroll_to_caret()

    def unindent(self, now_ms: int):
        self.buf.indent(-1, now_ms)
        self.changed()
        self.scroll_to_caret()

    def newline(self, now_ms: int):
        """Auto-indentação: repete a indentação da linha, e desce um nível
        depois de um ':'."""
        c = self.buf.caret(self.buf.ncarets() - 1)
        s = self.buf.line_text(c.line)
        ind = len(s) - len(s.lstrip())
        head = s[0:c.col]
        deeper = head.rstrip().endswith(":")
        if ind > c.col:
            ind = c.col          # cursor dentro da indentação: não a duplica
        total = ind + (CV_TAB if deeper else 0)
        self.buf.insert("\n" + " " * total, now_ms)
        self.changed()
        self.scroll_to_caret()

    # ---------- pares automáticos ----------

    def char_after(self, c: core.Caret) -> str:
        s = self.buf.line_text(c.line)
        return s[c.col:c.col + 1] if c.col < len(s) else ""

    def char_before(self, c: core.Caret) -> str:
        if c.col == 0:
            return ""
        return self.buf.line_text(c.line)[c.col - 1:c.col]

    def auto_pair(self, ch: str, now_ms: int) -> bool:
        """True quando o caractere digitado foi tratado como par."""
        close = pair_close_of(ch)
        c = self.buf.caret(0)
        # digitar o fechamento onde ele já está: passa por cima
        if pair_is_close(ch) and self.buf.ncarets() == 1 and not self.buf.has_sel():
            if self.char_after(c) == ch:
                self.buf.move_h(1, False)
                return True
        if len(close) == 0:
            return False
        # envolve a seleção em vez de substituí-la
        if self.buf.has_sel():
            wrapped = False
            k = self.buf.ncarets() - 1
            while k >= 0:
                sr = self.buf.sel_range(k)
                if sr.l0 != sr.l1 or sr.c0 != sr.c1:
                    body = self.buf.sel_text(k)
                    self.buf.select_range(sr)
                    self.buf.replace_range(sr, ch + body + close, now_ms)
                    wrapped = True
                k -= 1
            return wrapped
        # uma aspa depois de palavra é apóstrofo, não par
        if (ch == "\"" or ch == "'") and is_word_ch(self.char_before(c)):
            return False
        after = self.char_after(c)
        if len(after) > 0 and not pair_is_close(after) and after != " " and after != "\t":
            return False          # só forma par numa fronteira
        self.buf.insert(ch + close, now_ms)
        self.buf.move_h(-1, False)
        return True

    def pair_backspace(self, now_ms: int) -> bool:
        """Backspace entre um par vazio tira os dois lados."""
        if self.buf.ncarets() != 1 or self.buf.has_sel():
            return False
        c = self.buf.caret(0)
        b = self.char_before(c)
        a = self.char_after(c)
        cl = pair_close_of(b)
        # `b` tem de ser ABERTURA cujo fechamento está logo depois do cursor;
        # com os dois lados ausentes, dois "" se comparariam iguais e a conta
        # comeria uma quebra de linha
        if len(cl) == 0 or len(a) == 0 or cl != a:
            return False
        self.buf.delete_fwd(now_ms)
        self.buf.backspace(now_ms)
        return True

    # ---------- completamento ----------

    def word_before(self) -> core.Span:
        """A palavra sendo digitada antes do cursor: devolve (coluna inicial) em
        `c0` e o texto vai por `word_text`."""
        c = self.buf.caret(0)
        s = self.buf.line_text(c.line)
        b = c.col
        while b > 0 and is_word_ch(s[b - 1:b]):
            b -= 1
        return core.Span(c.line, b, c.line, c.col)

    def word_text(self, r: core.Span) -> str:
        return self.buf.line_text(r.l0)[r.c0:r.c1]

    def owner_before(self, word_start: int) -> str:
        """A expressão cujos membros listar: o que está antes de um `.` ou `->`
        à esquerda da palavra. "" quando não há."""
        c = self.buf.caret(0)
        s = self.buf.line_text(c.line)
        b = word_start
        if b >= 1 and s[b - 1:b] == ".":
            b -= 1
        elif b >= 2 and s[b - 2:b] == "->":
            b -= 2
        else:
            return ""
        e = b
        while b > 0 and is_word_ch(s[b - 1:b]):
            b -= 1
        return "" if b == e else s[b:e]

    def cmp_rows(self) -> int:
        """Quantos candidatos o popup mostra. O desenho e as flechas perguntam
        AQUI — cada um carregava o seu `8`, e um popup encurtado por um painel
        baixo rolava contra fileiras que não estavam na tela."""
        n = len(self.cmp_hits)
        if n > CMP_MAX_ROWS:
            n = CMP_MAX_ROWS
        fits = self.text_rect().h // self.u.cell_h - 1
        if n > fits:
            n = fits
        return n if n > 1 else 1

    def cmp_rect(self) -> pui.Rect:
        """A caixa: tão larga quanto os candidatos à mostra pedem, depois presa
        à área de texto. Todo transbordo se decide aqui, uma vez."""
        tr = self.text_rect()
        cw = self.u.cell_w
        lh = self.u.cell_h
        rows = self.cmp_rows()
        w = CMP_MIN_COLS * cw
        for hi in range(rows):
            i = self.cmp_top + hi
            if i >= len(self.cmp_hits):
                break
            sm = self.index.sym(self.cmp_hits[i])
            cand = self.u.text_w(sm.name)
            if len(sm.detail) > 0:
                cand += 2 * cw + self.u.text_w(sm.detail)
            if cand > w:
                w = cand
        w += 2 * CMP_PAD
        if w > CMP_MAX_COLS * cw:
            w = CMP_MAX_COLS * cw
        if w > tr.w - cw:                  # painel estreito ganha de qualquer mínimo
            w = tr.w - cw
        h = rows * lh + 2 * CMP_PAD
        if h > tr.h:
            h = tr.h
        x = tr.x + (self.screen_col(self.buf.caret(0).line, self.cmp_col) - self.left) * cw
        if x + w > tr.x + tr.w:
            x = tr.x + tr.w - w
        if x < tr.x:
            x = tr.x
        row = self.row_of_line(self.buf.caret(0).line)
        y = tr.y + (row + 1) * lh
        if y + h > tr.y + tr.h:
            y = tr.y + row * lh - h        # vira para cima do cursor
        # nenhum dos dois lados cabe — painel baixo, ou cursor de que a vista
        # rolou embora. Fica DENTRO da área: cobrir texto é melhor que sair dela.
        if y + h > tr.y + tr.h:
            y = tr.y + tr.h - h
        if y < tr.y:
            y = tr.y
        return pui.Rect(x, y, w, h)

    def complete_close(self):
        if not self.cmp_open:
            return
        self.cmp_open = False
        self.cmp_owner = ""
        self.u.queue_redraw(self.id)

    def complete_open(self):
        if self.index.is_stale(self.buf):
            self.index.build(self.buf, [])
        self.cmp_open = True
        self.cmp_sel = 0
        self.cmp_top = 0
        self.complete_refresh()

    def enclosing_struct(self, line: int) -> str:
        """O struct em cujo corpo `line` está, pela indentação — é assim que
        `self.` resolve sem adivinhar (um índice do arquivo não conseguiria)."""
        l = line
        while l >= 0:
            s = self.buf.line_text(l)
            if s.startswith("struct "):
                rest = s[7:len(s)].lstrip()
                e = 0
                while e < len(rest) and is_word_ch(rest[e:e + 1]):
                    e += 1
                return rest[0:e] if e > 0 else ""
            l -= 1
        return ""

    def complete_refresh(self):
        if not self.cmp_open:
            return
        wr = self.word_before()
        w = self.word_text(wr)
        self.cmp_owner = self.owner_before(wr.c0)
        self.cmp_col = wr.c0
        owner = ""
        if len(self.cmp_owner) > 0:
            if self.cmp_owner == "self":
                owner = self.enclosing_struct(self.buf.caret(0).line)
            else:
                owner = self.index.owner_of(self.cmp_owner)
            if len(owner) == 0:
                self.complete_close()      # receptor desconhecido: nada honesto a oferecer
                return
        self.cmp_hits = self.index.query(w, owner)
        if len(self.cmp_hits) == 0:
            self.complete_close()
            return
        if self.cmp_sel >= len(self.cmp_hits):
            self.cmp_sel = len(self.cmp_hits) - 1
        self.u.queue_redraw(self.id)

    def complete_accept(self, now_ms: int) -> bool:
        if not self.cmp_open or len(self.cmp_hits) == 0:
            return False
        name = self.index.sym(self.cmp_hits[self.cmp_sel]).name
        c = self.buf.caret(0)
        self.buf.replace_range(core.Span(c.line, self.cmp_col, c.line, c.col), name, now_ms)
        self.complete_close()
        self.changed()
        self.scroll_to_caret()
        return True

    # ---------- dobra e comandos de linha ----------

    def toggle_fold_at_caret(self):
        l = self.buf.caret(0).line
        if not self.buf.can_fold(l) and not self.buf.is_folded(l):
            # não é cabeçalho: dobra o bloco que CONTÉM o cursor (Sublime)
            h = l - 1
            while h >= 0:
                if self.buf.can_fold(h) and self.buf.fold_end(h) >= l:
                    l = h
                    break
                h -= 1
        if self.buf.toggle_fold(l):
            self.changed()
            self.scroll_to_caret()

    def fold_all(self):
        self.buf.fold_all()
        self.anchor_top()

    def unfold_all(self):
        self.buf.unfold_all()
        self.anchor_top()

    def toggle_bookmark(self):
        self.buf.toggle_mark(self.buf.caret(0).line, core.MARK_BOOK)
        self.u.queue_redraw(self.id)

    def goto_mark(self, forward: bool):
        l = self.buf.next_mark(self.buf.caret(0).line, core.MARK_BOOK, forward)
        if l < 0:
            return
        self.buf.move_to(l, 0)
        self.scroll_to_caret()
        self.u.queue_redraw(self.id)

    def toggle_comment(self, now_ms: int):
        self.buf.toggle_comment("#", now_ms)
        self.changed()
        self.scroll_to_caret()

    def move_lines(self, dir: int, now_ms: int):
        self.buf.move_lines(dir, now_ms)
        self.changed()
        self.scroll_to_caret()

    def duplicate_lines(self, now_ms: int):
        self.buf.duplicate_lines(now_ms)
        self.changed()
        self.scroll_to_caret()

    def delete_lines(self, now_ms: int):
        self.buf.delete_lines(now_ms)
        self.changed()
        self.scroll_to_caret()

    def join_lines(self, now_ms: int):
        self.buf.join_lines(now_ms)
        self.changed()
        self.scroll_to_caret()

    # ---------- busca ----------

    def search(self, needle: str, forward: bool, use_re: bool, from_caret: bool) -> bool:
        if len(needle) == 0:
            return False
        c = self.buf.caret(0)
        sl = c.line
        sc = c.col
        if not from_caret:
            sl = 0
            sc = 0
        elif forward:
            sr = self.buf.sel_range(0)     # começa DEPOIS da seleção atual
            sl = sr.l1
            sc = sr.c1
        hit = self.buf.find_re(needle, sl, sc, forward) if use_re else self.buf.find(needle, sl, sc, True)
        if hit != None:
            # a prova de não-nulo vale DENTRO do ramo (43.1), e é aqui que os
            # campos do Span existem
            end = hit.c1 if use_re else hit.c0 + len(needle)
            self.buf.select_range(core.Span(hit.l0, hit.c0, hit.l0, end))
            self.scroll_to_caret()
            self.u.queue_redraw(self.id)
            return True
        return False

    # ---------- entrada ----------

    def handle_input(self, ev: pui.Event, now: int) -> bool:
        match ev.kind:
            case pui.EV_MOUSE_DOWN:
                if ev.button != 1:
                    return False
                self.u.focus_set(self.id)
                p = self.pos_from_xy(ev.x, ev.y)
                # o minimapa: clique ou arraste pula a vista (TextEdit do Godot)
                mmr = self.minimap_rect()
                if self.minimap and pui.rect_has(mmr, ev.x, ev.y):
                    self.minimap_drag = True
                    self.minimap_jump(ev.y)
                    return True
                # um clique nas sarjetas pertence à sarjeta daquela coluna
                r0 = self.u.rect_of(self.id)
                if ev.x < r0.x + self.gutter_w():
                    gx = r0.x
                    for g in self.gutters:
                        gw = g.width_cp * self.u.cell_w
                        if ev.x >= gx and ev.x < gx + gw:
                            if self.gutter_click(g.kind, p.l0):
                                return True
                        gx += gw
                    return True
                if ev.clicks >= 3:
                    self.buf.select_range(core.Span(p.l0, 0, p.l0, self.buf.line_cp(p.l0)))
                elif ev.clicks == 2:
                    self.buf.move_to(p.l0, p.c0)
                    self.buf.select_word_at(0)
                elif (ev.mods & 4) != 0:
                    self.buf.add_caret(p.l0, p.c0)     # cursor extra (alt+clique)
                elif (ev.mods & 1) != 0:
                    cr = self.buf.caret(0)
                    self.buf.select_range(core.Span(cr.aline, cr.acol, p.l0, p.c0))
                else:
                    self.buf.move_to(p.l0, p.c0)
                    self.mouse_sel = True
                self.caret_on = True
                self.u.queue_redraw(self.id)
                return True
            case pui.EV_MOUSE_MOVE:
                if self.minimap_drag:
                    self.minimap_jump(ev.y)
                    return True
                if not self.mouse_sel:
                    return False
                p2 = self.pos_from_xy(ev.x, ev.y)
                cr2 = self.buf.caret(0)
                self.buf.select_range(core.Span(cr2.aline, cr2.acol, p2.l0, p2.c0))
                tr = self.text_rect()
                if ev.y < tr.y:
                    self.set_top(self.buf.to_visible(self.top) - 1)
                elif ev.y > tr.y + tr.h:
                    self.set_top(self.buf.to_visible(self.top) + 1)
                self.u.queue_redraw(self.id)
                return True
            case pui.EV_MOUSE_UP:
                self.mouse_sel = False
                self.minimap_drag = False
                return True
            case pui.EV_WHEEL:
                if (ev.mods & 2) != 0:
                    return False   # ctrl+roda = zoom (é do app)
                self.set_top(self.buf.to_visible(self.top) - ev.wheel * 3)
                return True
            case pui.EV_TEXT:
                ch = chr(ev.cp)
                if self.cmp_open and not is_word_ch(ch):
                    self.complete_close()
                self.caret_on = True
                if self.auto_pair(ch, now):
                    self.changed()
                    self.scroll_to_caret()
                    return True
                self.buf.insert(ch, now)
                self.changed()
                self.scroll_to_caret()
                # `.`/`->` oferece membros; com o popup aberto, mantém a lista
                if self.cmp_open:
                    self.complete_refresh()
                elif ch == "." or ch == ">":
                    self.complete_open()
                return True
            case pui.EV_KEY:
                return self.handle_key(ev, now)
            case _:
                pass
        return False

    def handle_key(self, ev: pui.Event, now: int) -> bool:
        sel = (ev.mods & 1) != 0
        ctrl = (ev.mods & 2) != 0
        self.caret_on = True
        # ctrl+espaço pede candidatos; com o popup aberto, ele fica com as
        # flechas, o enter/tab e o escape
        if ctrl and ev.key == pui.K_SPACE:
            self.complete_open()
            return True
        if self.cmp_open:
            if ev.key == pui.K_ESCAPE:
                self.complete_close()
                return True
            if ev.key == pui.K_RETURN or ev.key == pui.K_TAB:
                if self.complete_accept(now):
                    return True
            if ev.key == K_UP or ev.key == K_DOWN:
                n2 = len(self.cmp_hits)
                self.cmp_sel += 1 if ev.key == K_DOWN else -1
                if self.cmp_sel < 0:
                    self.cmp_sel = n2 - 1
                if self.cmp_sel >= n2:
                    self.cmp_sel = 0
                rows3 = self.cmp_rows()      # o que está de fato na tela
                if self.cmp_sel < self.cmp_top:
                    self.cmp_top = self.cmp_sel
                elif self.cmp_sel >= self.cmp_top + rows3:
                    self.cmp_top = self.cmp_sel - rows3 + 1
                self.u.queue_redraw(self.id)
                return True
            if ev.key != pui.K_BACKSPACE and ev.key != pui.K_LEFT and ev.key != pui.K_RIGHT:
                self.complete_close()
        if ev.key == pui.K_LEFT:
            self.buf.move_word(-1, sel) if ctrl else self.buf.move_h(-1, sel)
        elif ev.key == pui.K_RIGHT:
            self.buf.move_word(1, sel) if ctrl else self.buf.move_h(1, sel)
        elif ev.key == K_UP:
            self.buf.move_v(-1, sel)
        elif ev.key == K_DOWN:
            self.buf.move_v(1, sel)
        elif ev.key == K_PAGEUP:
            self.buf.move_v(-self.visible_lines(), sel)
        elif ev.key == K_PAGEDOWN:
            self.buf.move_v(self.visible_lines(), sel)
        elif ev.key == pui.K_HOME:
            self.buf.move_to(0, 0) if ctrl else self.buf.home(sel)
        elif ev.key == pui.K_END:
            if ctrl:
                last = self.buf.nlines() - 1
                self.buf.move_to(last, self.buf.line_cp(last))
            else:
                self.buf.end(sel)
        elif ev.key == pui.K_BACKSPACE:
            if not self.pair_backspace(now):
                self.buf.backspace(now)
            self.changed()
            if self.cmp_open:
                self.complete_refresh()
        elif ev.key == pui.K_DELETE:
            self.buf.delete_fwd(now)
            self.changed()
        elif ev.key == pui.K_RETURN:
            self.newline(now)
        elif ev.key == pui.K_TAB:
            self.unindent(now) if sel else self.indent(now)
        elif ev.key == pui.K_ESCAPE:
            self.buf.collapse()
        else:
            return False
        self.scroll_to_caret()
        self.u.queue_redraw(self.id)
        return True


# as teclas que só o codeview usa (as outras vêm do pacote `pui`)
const K_UP: int = 1073741906
const K_DOWN: int = 1073741905
const K_PAGEUP: int = 1073741899
const K_PAGEDOWN: int = 1073741902


def cv_create(u: pui.Ui, parent: int) -> CodeView:
    """Cria o widget com as barras internas e as três sarjetas, e devolve o
    CodeView — o id dele está em `.id`."""
    cv = CodeView(core.new_buffer(), hlm.new_hl(True), cmp.new_index(), "",
                  u, -1, -1, -1, 0, 0, [], False, [], 0, 0, 0, "",
                  True, False, True, False, 0, [], False, 0)
    id = u.custom(parent, None)
    u.set_focusable(id, True)
    u.set_expand(id, True, True)
    cv.id = id
    cv.vsb = u.scrollbar(id, True)
    cv.hsb = u.scrollbar(id, False)
    u.on_scroll(cv.vsb, lambda wid, arg: cv.on_vscroll(arg))
    u.on_scroll(cv.hsb, lambda wid, arg: cv.on_hscroll(arg))
    u.set_custom(id,
                 lambda ui2, wid: pui.Size(cv.gutter_w() + u.cell_w * 8, u.cell_h * 3),
                 lambda ui2, wid: cv.build(),
                 lambda ui2, wid, ev: cv.handle_input(ev, cv.now_ms),
                 lambda ui2, wid, r: cv.layout(r))
    cv.add_gutter(GUT_MARKS, 2)        # ● / ◆ na ponta esquerda
    cv.add_gutter(GUT_FOLD, 2)         # depois ▾/▸, depois os números (ordem do Sublime)
    cv.add_gutter(GUT_NUMBERS, 5)
    return cv
