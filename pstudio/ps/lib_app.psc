"""O editor montado, em pscript: abas, árvore de arquivos, paleta de comandos,
busca e barra de estado (porte do `pstudio/app.p`, camada 5 do DESIGN).

O que NÃO está aqui, de propósito: a janela, o laço de eventos, o relógio, a
área de transferência e as caixas de confirmação. Tudo isso é DRIVER, e o driver
mora no `app.psc` (que fala com o `shim.p`). A ligação entre os dois é feita de
funções guardadas em campo — `clip_get`, `confirm_close`, `read_file` — que o
`app.psc` preenche na partida.

Por que assim: é a mesma razão do `Painter` no `lib_pui` e do `load_text` no
`lib_cv`. Com o driver de fora, o editor INTEIRO — abas, árvore, paleta, busca,
atalhos — roda headless num teste, e o que sobra para o `app.psc` é uma página
que não tem lógica para errar.
"""
import lib_pui as pui
import lib_cv as cvm
import lib_core as core
import os
import path


const BLINK_MS: int = 500        # o piscar do cursor (DESIGN.md)
const MAX_SCAN: int = 20000      # teto da varredura do projeto
const PAL_ROWS: int = 12         # linhas visíveis da paleta
const TREE_MIN_CP: int = 18      # largura mínima da árvore, em caracteres


enum PalMode:
    PAL_FILES         # busca difusa de arquivo (o padrão)
    PAL_COMMANDS      # o prefixo '>'
    PAL_GOTO          # o prefixo ':'


struct Tab:
    cv: cvm.CodeView
    title: str


struct TreeEntry:
    fullpath: str
    name: str
    depth: int
    is_dir: bool
    expanded: bool


struct PalItem:
    label: str
    payload: str
    score: int


# os nomes escondidos da árvore e do índice da paleta
def is_hidden(name: str) -> bool:
    if name.startswith("."):
        return True
    return name == "out" or name == "node_modules" or name == "__pycache__"


# difuso: casa como subsequência, com bônus para acerto seguido e para começo de
# palavra. -1 = não casa. O modelo do ctrl+p do Sublime, simplificado.
def fuzzy_score(hay: str, needle: str) -> int:
    if len(needle) == 0:
        return 1
    score = 0
    run = 0
    ni = 0
    low_h = hay.lower()
    low_n = needle.lower()
    for hi in range(len(low_h)):
        if ni >= len(low_n):
            break
        if low_h[hi:hi + 1] == low_n[ni:ni + 1]:
            run += 1
            score += 10 + run * 5
            if hi == 0:
                score += 15
            else:
                prev = low_h[hi - 1:hi]
                if prev == "/" or prev == "_" or prev == "-" or prev == ".":
                    score += 15
            ni += 1
        else:
            run = 0
    if ni < len(low_n):
        return -1
    return score - len(hay) // 4


# a paleta de comandos: nome e id, numa cadeia só (módulo importado não roda
# statement, e uma tabela de duas colunas cabe numa linha por comando)
const COMMANDS: str = "Save=0;Save All=1;Close Tab=2;Reload File=3;Toggle File Tree=4;Zoom In=5;Zoom Out=6;Zoom Reset=7;Find=8;Go To Line=9;Quit=10;Fold=11;Unfold=11;Fold All=12;Unfold All=13;Toggle Comment=14;Move Line Up=15;Move Line Down=16;Duplicate Line=17;Delete Line=18;Join Lines=19;Toggle Bookmark=20;Next Bookmark=21;Clear Bookmarks=22;Toggle Minimap=23"


struct App:
    u: pui.Ui
    root: int          # painel raiz (empilha o layout e a paleta)
    tabbar: int
    tree_pane: int     # caixa com o cabeçalho "FOLDERS" e as linhas
    tree: int          # as linhas (o retângulo dele É a área das linhas)
    split: int
    editors: int       # caixa vertical: [cvhost | barra de busca]
    cvhost: int
    findbar: int
    findinput: int
    status: int
    palette: int
    palinput: int

    tabs: list<Tab>
    cur: int           # aba ativa (-1 = nenhuma)
    tab_hover: int
    tab_hover_x: bool
    entries: list<TreeEntry>
    tree_top: int
    root_dir: str
    palmode: PalMode
    palitems: list<PalItem>
    palsel: int
    paltop: int
    files: list<PalItem>
    find_re: bool      # busca por regex (a consulta começa com '/')
    running: bool
    dirty_ui: bool     # um quadro precisa ser apresentado
    now_ms: int        # o relógio, que vem do driver

    # ---- o driver, injetado pelo `app.psc` ----
    read_file: (def(str) -> str)?        # "" quando não deu
    write_file: (def(str, str) -> bool)?
    mtime_of: (def(str) -> int)?
    clip_get: (def() -> str)?
    clip_set: def(str)?
    confirm_close: (def(str) -> int)?    # 0=salvar 1=descartar 2=cancelar
    confirm_reload: (def(str) -> bool)?
    set_title: def(str)?

    # ---------- abas ----------

    def cur_cv(self) -> cvm.CodeView?:
        if self.cur < 0 or self.cur >= len(self.tabs):
            return None
        return self.tabs[self.cur].cv

    def open_file(self, p: str):
        for i in range(len(self.tabs)):
            if self.tabs[i].cv.path == p:
                self.select_tab(i)          # já aberto: só ativa
                return
        rd = self.read_file
        if rd == None:
            return
        text = rd(p)
        if len(text) == 0 and not path.isfile(p):
            return
        cv = cvm.cv_create(self.u, self.cvhost)
        mt = self.mtime_of
        cv.load_text(p, text, mt(p) if mt != None else 0)
        self.tabs.append(Tab(cv, path.basename(p)))
        self.select_tab(len(self.tabs) - 1)

    def select_tab(self, i: int):
        if i < 0 or i >= len(self.tabs):
            return
        self.cur = i
        for k in range(len(self.tabs)):
            self.u.set_visible(self.tabs[k].cv.id, k == i)
        self.u.focus_set(self.tabs[i].cv.id)
        self.u.relayout()
        self.u.queue_redraw_tree(self.root)
        self.update_status()
        self.dirty_ui = True

    def close_tab(self, i: int):
        if i < 0 or i >= len(self.tabs):
            return
        cv = self.tabs[i].cv
        if cv.buf.dirty:
            ask = self.confirm_close
            r = ask(self.tabs[i].title) if ask != None else 1
            if r == 2:
                return
            if r == 0 and not self.save_tab(i):
                return
        self.u.free_node(cv.id)
        self.tabs.remove(self.tabs[i])
        self.tab_hover = -1
        self.tab_hover_x = False
        if len(self.tabs) == 0:
            self.cur = -1
            self.u.relayout()
        else:
            self.select_tab(i - 1 if i > 0 else 0)
        # a barra de abas e a árvore são RETIDAS e o retângulo delas não mudou:
        # sem sujá-las à mão, a aba fechada ficaria pintada na tela
        self.u.queue_redraw(self.tabbar)
        self.u.queue_redraw(self.tree)
        self.update_status()
        self.dirty_ui = True

    def save_tab(self, i: int) -> bool:
        if i < 0 or i >= len(self.tabs):
            return False
        cv = self.tabs[i].cv
        if len(cv.path) == 0:
            return False
        wr = self.write_file
        if wr == None or not wr(cv.path, cv.text_to_save()):
            return False
        mt = self.mtime_of
        cv.mark_saved(mt(cv.path) if mt != None else 0)
        return True

    def save_cur(self):
        self.save_tab(self.cur)
        self.u.queue_redraw(self.tabbar)
        self.dirty_ui = True

    def update_status(self):
        cv = self.cur_cv()
        if cv == None:
            self.u.set_text(self.status, "pstudio — ctrl+p to open a file")
        else:
            c = cv.buf.caret(0)
            s = (cv.path if len(cv.path) > 0 else "(untitled)") + ("*" if cv.buf.dirty else "") + "   "
            s += str(c.line + 1) + ":" + str(c.col + 1)
            if cv.buf.ncarets() > 1:
                s += " (" + str(cv.buf.ncarets()) + " carets)"
            s += "   " + ("CRLF" if cv.buf.crlf else "LF")
            s += "   " + str(cv.buf.nlines()) + " lines   " + str(self.u.cell_h) + "px"
            self.u.set_text(self.status, s)
        self.dirty_ui = True

    # ---------- a árvore ----------

    def dir_rows(self, dir: str, depth: int, at: int) -> int:
        """Insere as linhas de um diretório em `at`, diretório primeiro. Devolve
        onde a inserção parou."""
        names: list<str> = []
        if not path.isdir(dir):
            return at
        try:
            names = os.listdir(dir)
        catch e:
            return at
        dirs: list<str> = []
        files: list<str> = []
        for nm in names:
            if is_hidden(nm):
                continue
            if path.isdir(path.join(dir, nm)):
                dirs.append(nm)
            else:
                files.append(nm)
        pos = at
        for nm in dirs:
            self.entries.insert(pos, TreeEntry(path.join(dir, nm), nm, depth, True, False))
            pos += 1
        for nm in files:
            self.entries.insert(pos, TreeEntry(path.join(dir, nm), nm, depth, False, False))
            pos += 1
        return pos

    def scan_files(self, dir: str, depth: int) -> int:
        """O índice da paleta: uma varredura recursiva, com teto."""
        if depth > 8 or len(self.files) >= MAX_SCAN:
            return len(self.files)
        names: list<str> = []
        try:
            names = os.listdir(dir)
        catch e:
            return len(self.files)
        for nm in names:
            if is_hidden(nm):
                continue
            full = path.join(dir, nm)
            if path.isdir(full):
                self.scan_files(full, depth + 1)
            else:
                rel = full
                if full.startswith(self.root_dir):
                    rel = full[len(self.root_dir):len(full)]
                    if rel.startswith("/"):
                        rel = rel[1:len(rel)]
                self.files.append(PalItem(rel, full, 0))
                if len(self.files) >= MAX_SCAN:
                    break
        return len(self.files)

    def tree_scan(self):
        self.entries = []
        self.dir_rows(self.root_dir, 0, 0)
        self.tree_top = 0
        self.files = []
        self.scan_files(self.root_dir, 0)

    def tree_toggle(self, i: int):
        e = self.entries[i]
        if not e.is_dir:
            return
        if e.expanded:
            # tira os descendentes (as linhas mais fundas logo abaixo)
            j = i + 1
            while j < len(self.entries) and self.entries[j].depth > e.depth:
                j += 1
            k = j - 1
            while k > i:
                self.entries.remove(self.entries[k])
                k -= 1
            e.expanded = False
        else:
            self.dir_rows(e.fullpath, e.depth + 1, i + 1)
            e.expanded = True

    # ---------- a paleta ----------

    def palette_open(self, mode: PalMode):
        self.palmode = mode
        self.u.input_clear(self.palinput)
        if mode == PAL_COMMANDS:
            self.u.set_text(self.palinput, ">")
        elif mode == PAL_GOTO:
            self.u.set_text(self.palinput, ":")
        self.palsel = 0
        self.paltop = 0
        self.u.set_visible(self.palette, True)
        self.u.focus_set(self.palinput)
        self.palette_filter()
        self.dirty_ui = True

    def palette_close(self):
        self.u.set_visible(self.palette, False)
        self.palitems = []
        if self.cur >= 0:
            self.u.focus_set(self.tabs[self.cur].cv.id)
        self.dirty_ui = True

    def palette_filter(self):
        q = self.u.text_of(self.palinput)
        # o prefixo escolhe o modo (Sublime): '>' comandos, ':' ir para a linha
        if q.startswith(">"):
            self.palmode = PAL_COMMANDS
            q = q[1:len(q)]
        elif q.startswith(":"):
            self.palmode = PAL_GOTO
            q = q[1:len(q)]
        else:
            self.palmode = PAL_FILES
        self.palitems = []
        self.palsel = 0
        self.paltop = 0
        match self.palmode:
            case PAL_COMMANDS:
                for entry in COMMANDS.split(";"):
                    parts = entry.split("=")
                    sc = fuzzy_score(parts[0], q)
                    if sc >= 0:
                        self.palitems.append(PalItem(parts[0], parts[1], sc))
            case PAL_GOTO:
                self.palitems.append(PalItem("go to line " + (q if len(q) > 0 else "…"), q, 0))
            case _:
                for it in self.files:
                    sc2 = fuzzy_score(it.label, q)
                    if sc2 >= 0:
                        self.palitems.append(PalItem(it.label, it.payload, sc2))
        # maior pontuação primeiro (inserção: as listas são pequenas)
        for i in range(1, len(self.palitems)):
            t = self.palitems[i]
            k = i
            while k > 0 and self.palitems[k - 1].score < t.score:
                self.palitems[k] = self.palitems[k - 1]
                k -= 1
            self.palitems[k] = t
        while len(self.palitems) > 200:
            self.palitems.pop()
        self.u.relayout()
        self.u.queue_redraw(self.palette)
        self.dirty_ui = True

    def palette_accept(self):
        if len(self.palitems) == 0:
            self.palette_close()
            return
        it = self.palitems[self.palsel if self.palsel < len(self.palitems) else 0]
        mode = self.palmode
        payload = it.payload
        self.palette_close()
        match mode:
            case PAL_COMMANDS:
                self.run_command(int(payload))
            case PAL_GOTO:
                cv = self.cur_cv()
                if cv != None and len(payload) > 0:
                    cv.buf.move_to(int(payload) - 1, 0)
                    cv.scroll_to_caret()
                    self.update_status()
            case _:
                self.open_file(payload)

    # ---------- busca ----------

    def find_open(self):
        self.u.set_visible(self.findbar, True)
        cv = self.cur_cv()
        if cv != None and cv.buf.has_sel():
            sel = cv.buf.sel_text(0)
            if "\n" not in sel:
                self.u.set_text(self.findinput, sel)
        self.u.focus_set(self.findinput)
        self.u.relayout()
        self.dirty_ui = True

    def find_close(self):
        self.u.set_visible(self.findbar, False)
        if self.cur >= 0:
            self.u.focus_set(self.tabs[self.cur].cv.id)
        self.u.relayout()
        self.dirty_ui = True

    def find_changed(self):
        q = self.u.text_of(self.findinput)
        self.find_re = q.startswith("/")
        cv = self.cur_cv()
        if cv != None:
            cv.search(q[1:len(q)] if self.find_re else q, True, self.find_re, False)
        self.dirty_ui = True

    def find_step(self, forward: bool):
        cv = self.cur_cv()
        if cv == None:
            return
        q = self.u.text_of(self.findinput)
        cv.search(q[1:len(q)] if self.find_re else q, forward, self.find_re, True)
        self.update_status()
        self.dirty_ui = True

    # ---------- comandos ----------

    def run_command(self, cmd: int):
        cv = self.cur_cv()
        now = self.now_ms
        if cmd == 0:
            self.save_cur()
        elif cmd == 1:
            for i in range(len(self.tabs)):
                self.save_tab(i)
            self.u.queue_redraw(self.tabbar)
        elif cmd == 2:
            self.close_tab(self.cur)
        elif cmd == 3:
            self.reload_cur()
        elif cmd == 4:
            self.u.set_visible(self.tree_pane, not self.u.is_visible(self.tree_pane))
        elif cmd == 10:
            self.try_quit()
        elif cmd == 8:
            self.find_open()
        elif cmd == 9:
            self.palette_open(PAL_GOTO)
        elif cv != None:
            if cmd == 11:
                cv.toggle_fold_at_caret()
            elif cmd == 12:
                cv.fold_all()
            elif cmd == 13:
                cv.unfold_all()
            elif cmd == 14:
                cv.toggle_comment(now)
            elif cmd == 15:
                cv.move_lines(-1, now)
            elif cmd == 16:
                cv.move_lines(1, now)
            elif cmd == 17:
                cv.duplicate_lines(now)
            elif cmd == 18:
                cv.delete_lines(now)
            elif cmd == 19:
                cv.join_lines(now)
            elif cmd == 20:
                cv.toggle_bookmark()
            elif cmd == 21:
                cv.goto_mark(True)
            elif cmd == 22:
                cv.buf.clear_marks(core.MARK_BOOK)
                self.u.queue_redraw(cv.id)
            elif cmd == 23:
                cv.toggle_minimap()
        self.dirty_ui = True

    def reload_cur(self):
        cv = self.cur_cv()
        rd = self.read_file
        if cv == None or rd == None or len(cv.path) == 0:
            return
        keep = cv.top
        mt = self.mtime_of
        cv.load_text(cv.path, rd(cv.path), mt(cv.path) if mt != None else 0)
        cv.top = keep
        self.dirty_ui = True

    def check_external(self):
        """Um arquivo mudou no disco: recarrega o que está limpo, pergunta o que
        tem edição local."""
        mt = self.mtime_of
        if mt == None:
            return
        for i in range(len(self.tabs)):
            cv = self.tabs[i].cv
            if len(cv.path) == 0 or not path.exists(cv.path):
                continue
            m = mt(cv.path)
            if m == cv.mtime:
                continue
            if not cv.buf.dirty:
                self.select_tab(i)
                self.reload_cur()
            else:
                ask = self.confirm_reload
                if ask != None and ask(self.tabs[i].title):
                    self.select_tab(i)
                    self.reload_cur()
                else:
                    cv.mtime = m      # escolheram manter: não pergunta de novo
        self.dirty_ui = True

    def try_quit(self):
        for i in range(len(self.tabs)):
            cv = self.tabs[i].cv
            if cv.buf.dirty:
                ask = self.confirm_close
                r = ask(self.tabs[i].title) if ask != None else 1
                if r == 2:
                    return            # cancelado: continua editando
                if r == 0 and not self.save_tab(i):
                    return
        self.running = False

    def set_cell(self, cw: int, ch: int):
        """O driver mudou o zoom: a célula da fonte é do toolkit, então ela
        entra por aqui e o layout se refaz."""
        self.u.cell_w = cw
        self.u.cell_h = ch
        self.u.relayout()
        self.u.queue_redraw_tree(self.root)
        self.update_status()

    # ---------- atalhos globais ----------

    def key_shortcut(self, ev: pui.Event) -> bool:
        """True = consumido, e não chega à árvore de widgets."""
        pal_open = self.u.is_visible(self.palette)
        if pal_open and (ev.key == cvm.K_UP or ev.key == cvm.K_DOWN):
            n = len(self.palitems)
            if n > 0:
                self.palsel += 1 if ev.key == cvm.K_DOWN else -1
                if self.palsel < 0:
                    self.palsel = n - 1
                if self.palsel >= n:
                    self.palsel = 0
                if self.palsel < self.paltop:
                    self.paltop = self.palsel
                elif self.palsel >= self.paltop + PAL_ROWS:
                    self.paltop = self.palsel - PAL_ROWS + 1
                self.u.queue_redraw(self.palette)
                self.dirty_ui = True
            return True
        cv = self.cur_cv()
        if (ev.mods & 2) == 0:              # sem ctrl não é atalho global
            return False
        shift = (ev.mods & 1) != 0
        now = self.now_ms
        k = ev.key
        if k == ord("s"):
            self.run_command(1 if shift else 0)
        elif k == ord("p"):
            self.palette_open(PAL_FILES)
        elif k == ord("g"):
            self.palette_open(PAL_GOTO)
        elif k == ord("f"):
            self.find_open()
        elif k == ord("w"):
            self.close_tab(self.cur)
        elif k == ord("q"):
            self.try_quit()
        elif k == ord("b"):
            self.run_command(4)
        elif k == ord("="):
            self.run_command(5)
        elif k == ord("-"):
            self.run_command(6)
        elif k == ord("0"):
            self.run_command(7)
        elif k == pui.K_TAB:
            if len(self.tabs) > 0:
                self.select_tab((self.cur + (len(self.tabs) - 1 if shift else 1)) % len(self.tabs))
        elif cv != None:
            if k == ord("z"):
                if shift:
                    cv.buf.redo_step()
                else:
                    cv.buf.undo_step()
                cv.changed()
                cv.scroll_to_caret()
            elif k == ord("y"):
                cv.buf.redo_step()
                cv.changed()
                cv.scroll_to_caret()
            elif k == ord("a"):
                cv.buf.select_all()
                self.u.queue_redraw(cv.id)
            elif k == ord("c"):
                cs = self.clip_set
                got = cv.copy()
                if cs != None and len(got) > 0:
                    cs(got)
            elif k == ord("x"):
                cs2 = self.clip_set
                got2 = cv.cut(now)
                if cs2 != None and len(got2) > 0:
                    cs2(got2)
            elif k == ord("v"):
                cg = self.clip_get
                cv.paste(cg() if cg != None else "", now)
            elif k == ord("d"):
                if shift:
                    cv.duplicate_lines(now)
                else:
                    cv.buf.ctrl_d()
                    cv.scroll_to_caret()
                    self.u.queue_redraw(cv.id)
            elif k == ord("/"):
                cv.toggle_comment(now)
            elif k == ord("k"):
                cv.delete_lines(now)
            elif k == ord("j"):
                cv.join_lines(now)
            elif k == ord("["):
                if shift:
                    cv.fold_all()
                else:
                    cv.toggle_fold_at_caret()
            elif k == ord("]"):
                if shift:
                    cv.unfold_all()
                else:
                    cv.toggle_fold_at_caret()
            elif k == cvm.K_UP and shift:
                cv.move_lines(-1, now)
            elif k == cvm.K_DOWN and shift:
                cv.move_lines(1, now)
            else:
                return False
        else:
            return False
        self.update_status()
        self.dirty_ui = True
        return True

    # ---------- o quadro ----------

    def tick(self, now: int, blink_at: int) -> int:
        """O piscar do cursor. Devolve o instante do último piscar."""
        self.now_ms = now
        cv = self.cur_cv()
        if now - blink_at < BLINK_MS:
            return blink_at
        if cv != None and self.u.focus_get() == cv.id:
            cv.caret_on = not cv.caret_on
            self.u.queue_redraw(cv.id)
        return now

    def feed(self, ev: pui.Event) -> bool:
        """Um evento: atalho global primeiro, senão a árvore de widgets."""
        for t in self.tabs:
            t.cv.set_now(self.now_ms)
        if ev.kind == pui.EV_KEY:
            if self.key_shortcut(ev):
                return True
            got = self.u.input_event(ev)
            self.update_status()
            self.dirty_ui = True
            return got
        if self.u.input_event(ev):
            self.update_status()
            return True
        return False

    # ---------- os três widgets do app ----------

    def tab_at(self, r: pui.Rect, px: int, py: int) -> int:
        """A aba sob um ponto (-1 = nenhuma); marca em `tab_hover_x` se acertou
        o ×."""
        self.tab_hover_x = False
        if not pui.rect_has(r, px, py):
            return -1
        x = r.x
        for i in range(len(self.tabs)):
            w = tab_width(self.u, self.tabs[i])
            if px >= x and px < x + w:
                cx = tab_close_x(self.u, x, w)
                self.tab_hover_x = px >= cx and px < cx + self.u.cell_w
                return i
            x += w
        return -1

    def tabbar_build(self, id: int):
        u = self.u
        r = u.rect_of(id)
        th = u.theme
        u.cmd_rect(id, r, th.panel_lo)
        x = r.x
        for i in range(len(self.tabs)):
            t = self.tabs[i]
            w = tab_width(u, t)
            active = i == self.cur
            u.cmd_rect(id, pui.Rect(x, r.y, w, r.h), th.panel if active else th.panel_lo)
            if active:
                u.cmd_rect(id, pui.Rect(x, r.y + r.h - 2, w, 2), th.accent)
            u.cmd_text(id, x + u.cell_w, r.y + (r.h - u.cell_h) // 2, t.title,
                       th.text if active else th.text_dim)
            # marca de modificado / botão de fechar: um ponto quando sujo, um ×
            # quando o cursor está em cima (o modelo do Sublime)
            cx = tab_close_x(u, x, w)
            cy = r.y + (r.h - u.cell_h) // 2
            if self.tab_hover == i and self.tab_hover_x:
                u.cmd_rect(id, pui.Rect(cx, cy, u.cell_w, u.cell_h), th.panel_hi)
                u.cmd_text(id, cx, cy, "×", th.text)
            elif self.tab_hover == i:
                u.cmd_text(id, cx, cy, "×", th.text_dim)
            elif t.cv.buf.dirty:
                u.cmd_text(id, cx, cy, "*", th.accent)
            u.cmd_rect(id, pui.Rect(x + w - 1, r.y, 1, r.h), th.border)
            x += w
        u.cmd_rect(id, pui.Rect(r.x, r.y + r.h - 1, r.w, 1), th.border)

    def tabbar_input(self, id: int, ev: pui.Event) -> bool:
        r = self.u.rect_of(id)
        was_hover = self.tab_hover
        was_x = self.tab_hover_x
        hit = self.tab_at(r, ev.x, ev.y)
        if ev.kind == pui.EV_MOUSE_MOVE:
            # só suja quando o estado MUDA (senão todo movimento repinta)
            if hit != was_hover or self.tab_hover_x != was_x:
                self.tab_hover = hit
                self.u.queue_redraw(id)
            return hit >= 0
        if ev.kind != pui.EV_MOUSE_DOWN or hit < 0:
            return False
        if ev.button == 2 or self.tab_hover_x:
            self.close_tab(hit)        # botão do meio ou o × fecham a aba
        elif ev.button == 1:
            self.select_tab(hit)
        return True

    def tree_build(self, id: int):
        u = self.u
        r = u.rect_of(id)
        th = u.theme
        # sem fundo e sem cabeçalho aqui: o painel (uma caixa com bg) carrega os
        # dois, e o divisor do SPLIT é o separador — este widget é só as linhas
        cur_path = ""
        cv = self.cur_cv()
        if cv != None:
            cur_path = cv.path
        vis = r.h // u.cell_h
        for vi in range(vis + 1):
            i = self.tree_top + vi
            if i >= len(self.entries):
                break
            e = self.entries[i]
            y = r.y + vi * u.cell_h
            x = r.x + 4 + e.depth * u.cell_w * 2
            if e.is_dir:
                u.cmd_text(id, x, y, "v" if e.expanded else ">", th.text_dim)
                u.cmd_text(id, x + u.cell_w * 2, y, e.name, th.text)
            else:
                act = len(cur_path) > 0 and cur_path == e.fullpath
                if act:
                    u.cmd_rect(id, pui.Rect(r.x, y, r.w - 1, u.cell_h), th.sel)
                u.cmd_text(id, x + u.cell_w * 2, y, e.name, th.text if act else th.text_dim)

    def tree_input(self, id: int, ev: pui.Event) -> bool:
        r = self.u.rect_of(id)
        if ev.kind == pui.EV_WHEEL:
            t = self.tree_top - ev.wheel * 3
            mx = len(self.entries) - 1
            self.tree_top = 0 if t < 0 else (mx if t > mx else t)
            self.u.queue_redraw(id)
            return True
        if ev.kind != pui.EV_MOUSE_DOWN or ev.button != 1:
            return False
        i = self.tree_top + (ev.y - r.y) // self.u.cell_h
        if i < 0 or i >= len(self.entries):
            return True
        if self.entries[i].is_dir:
            self.tree_toggle(i)
        else:
            self.open_file(self.entries[i].fullpath)
        self.u.queue_redraw(id)
        return True

    def pal_layout(self, id: int, r: pui.Rect):
        u = self.u
        w = r.w * 3 // 5
        if w < u.cell_w * 40:
            w = u.cell_w * 40
        if w > r.w - 20:
            w = r.w - 20
        rows = len(self.palitems)
        if rows > PAL_ROWS:
            rows = PAL_ROWS
        h = u.cell_h + 12 + rows * u.cell_h + 8
        me = pui.Rect(r.x + (r.w - w) // 2, r.y + r.h // 8, w, h)
        u.set_rect(id, me)
        u.set_rect(self.palinput, pui.Rect(me.x + 6, me.y + 6, me.w - 12, u.cell_h + 6))

    def pal_build(self, id: int):
        u = self.u
        r = u.rect_of(id)
        th = u.theme
        u.cmd_rect(id, r, th.panel)
        u.cmd_frame(id, r, th.accent)
        y = r.y + u.cell_h + 14
        for vi in range(PAL_ROWS):
            i = self.paltop + vi
            if i >= len(self.palitems):
                break
            if y + u.cell_h > r.y + r.h:
                break
            if i == self.palsel:
                u.cmd_rect(id, pui.Rect(r.x + 2, y, r.w - 4, u.cell_h), th.sel)
            u.cmd_text_fit(id, r.x + 8, y, self.palitems[i].label, r.w - 16,
                           th.text if i == self.palsel else th.text_dim)
            y += u.cell_h

    def pal_input(self, id: int, ev: pui.Event) -> bool:
        if ev.kind == pui.EV_MOUSE_DOWN and ev.button == 1:
            r = self.u.rect_of(id)
            i = self.paltop + (ev.y - (r.y + self.u.cell_h + 14)) // self.u.cell_h
            if i >= 0 and i < len(self.palitems):
                self.palsel = i
                self.palette_accept()
            return True
        return False


# ---------- a montagem da árvore de widgets ----------
# É o `init` do `app.p`, e a forma é a mesma: um PAINEL na raiz (que empilha o
# layout e a paleta flutuante), a barra de abas DENTRO da coluna do editor (não
# atravessando o topo, para a árvore ocupar a altura inteira, como o Sublime), e
# a barra de busca como ÚLTIMO filho da coluna — que é o que a prende no rodapé.

def tab_width(u: pui.Ui, t: Tab) -> int:
    return u.text_w(t.title) + u.cell_w * 4


def tab_close_x(u: pui.Ui, x: int, w: int) -> int:
    return x + w - u.cell_w * 2


def new_app(u: pui.Ui, root_dir: str) -> App:
    app = App(u, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
              [], -1, -1, False, [], 0, root_dir, PAL_FILES, [], 0, 0, [],
              False, True, True, 0,
              None, None, None, None, None, None, None, None)

    app.root = u.panel(-1)
    col = u.box(app.root, True)
    app.split = u.split(col, False)
    u.set_expand(app.split, True, True)
    # o PAINEL da árvore é uma caixa com fundo: [ FOLDERS | linhas ]. O
    # cabeçalho é um label de verdade, então é o layout (e não deslocamento
    # escrito à mão) que decide onde as linhas começam.
    app.tree_pane = u.box(app.split, True)
    u.set_bg(app.tree_pane, u.theme.panel)
    head = u.label(app.tree_pane, "FOLDERS")
    u.set_pad(head, 6)
    u.set_min(head, 0, u.cell_h + 8)
    app.tree = u.custom(app.tree_pane, None)
    u.set_expand(app.tree, True, True)
    app.editors = u.box(app.split, True)
    u.set_expand(app.editors, True, True)
    u.split_set(app.split, 220)
    app.tabbar = u.custom(app.editors, None)
    app.cvhost = u.box(app.editors, True)
    u.set_expand(app.cvhost, True, True)

    app.findbar = u.box(app.editors, False)
    u.label(app.findbar, "find:")
    app.findinput = u.line_input(app.findbar)
    u.set_expand(app.findinput, True, False)
    u.on_changed(app.findinput, lambda wid, arg: app.find_changed())
    u.on_submit(app.findinput, lambda wid, arg: app.find_step(True))
    u.on_cancel(app.findinput, lambda wid, arg: app.find_close())
    u.set_visible(app.findbar, False)

    app.status = u.label(col, "")
    u.set_pad(app.status, 6)

    # a paleta: último filho da RAIZ, então desenha por cima e ganha o hit-test
    app.palette = u.custom(app.root, None)
    app.palinput = u.line_input(app.palette)
    u.on_changed(app.palinput, lambda wid, arg: app.palette_filter())
    u.on_submit(app.palinput, lambda wid, arg: app.palette_accept())
    u.on_cancel(app.palinput, lambda wid, arg: app.palette_close())
    u.set_visible(app.palette, False)

    # ---- a barra de abas ----
    u.set_custom(app.tabbar,
                 lambda u2, id: pui.Size(0, u2.cell_h + 8),
                 lambda u2, id: app.tabbar_build(id),
                 lambda u2, id, ev: app.tabbar_input(id, ev),
                 None)
    # ---- a árvore ----
    u.set_custom(app.tree,
                 lambda u2, id: pui.Size(u2.cell_w * TREE_MIN_CP, u2.cell_h),
                 lambda u2, id: app.tree_build(id),
                 lambda u2, id, ev: app.tree_input(id, ev),
                 None)
    # ---- a paleta ----
    u.set_custom(app.palette,
                 lambda u2, id: pui.Size(0, 0),
                 lambda u2, id: app.pal_build(id),
                 lambda u2, id, ev: app.pal_input(id, ev),
                 lambda u2, id, r: app.pal_layout(id, r))
    app.tree_scan()
    return app
