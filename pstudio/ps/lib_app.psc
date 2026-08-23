"""O editor montado, em pscript: abas, árvore de arquivos, paleta de comandos,
busca e barra de estado (porte do `pstudio/app.p`, camada 5 do DESIGN).

O que NÃO está aqui, de propósito: a janela, o laço de eventos, o relógio, a
área de transferência e as caixas de confirmação. Tudo isso é DRIVER, e o driver
mora no `app.psc` (que fala com o `shim.p`). A ligação entre os dois é feita de
funções guardadas em campo — `clip_get`, `confirm_close`, `read_file` — que o
`app.psc` preenche na partida.

Por que assim: é a mesma razão do `Painter` no `pui` (o pacote) e do `load_text` no
`lib_cv`. Com o driver de fora, o editor INTEIRO — abas, árvore, paleta, busca,
atalhos — roda headless num teste, e o que sobra para o `app.psc` é uma página
que não tem lógica para errar.
"""
import <pui> as pui
import lib_cv as cvm
import lib_core as core
import os
import path


const BLINK_MS: int = 500        # o piscar do cursor (DESIGN.md)
const MAX_SCAN: int = 20000      # teto da varredura do projeto
const PAL_ROWS: int = 12         # linhas visíveis da paleta
const TREE_MIN_CP: int = 18      # largura mínima da árvore, em caracteres
const K_F2: int = 1073741883     # o F2 do SDL


enum PalMode:
    PAL_FILES         # busca difusa de arquivo (o padrão)
    PAL_COMMANDS      # o prefixo '>'
    PAL_GOTO          # o prefixo ':'
    PAL_BUILD         # o prefixo '!': um alvo do grafo


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
const COMMANDS: str = "Save=0;Save All=1;Close Tab=2;Reload File=3;Toggle File Tree=4;Zoom In=5;Zoom Out=6;Zoom Reset=7;Find=8;Go To Line=9;Quit=10;Fold=11;Unfold=11;Fold All=12;Unfold All=13;Toggle Comment=14;Move Line Up=15;Move Line Down=16;Duplicate Line=17;Delete Line=18;Join Lines=19;Toggle Bookmark=20;Next Bookmark=21;Clear Bookmarks=22;Toggle Minimap=23;Build=24;Build Target...=25;Run=26;Clean=27;Stop Build=28;Go To Build Error=29"


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
    want_open: str     # 114: um arquivo que o app quer e o driver tem de LER
    want_msg: str      # uma mensagem para a barra de estado (falha de escrita)
    # F6: o BUILD. O app não constrói — ele PEDE, como pede a leitura de um
    # arquivo, e o driver atende no laço de eventos. A razão é a mesma da 114:
    # a lógica do editor é síncrona de propósito, e um `await` aqui obrigaria
    # todo chamador a esperar.
    #
    # `want_build` é o alvo ("" = o padrão do grafo), `want_run` diz se depois
    # de construir o programa deve correr, e `build_msg` é o que a barra de
    # estado mostra enquanto isso acontece.
    want_build: str
    want_build_on: bool
    want_run: bool
    want_clean: bool
    build_msg: str
    build_busy: bool
    build_stop: bool
    # os alvos que este projeto constrói, postos aqui pelo DRIVER a partir do
    # grafo: o editor não sabe o que um projeto constrói, e não devia saber
    build_targets: list<str>
    build_total: int
    build_feitas: int
    build_erro: str
    # F6: para onde o primeiro erro do build aponta. O editor ABRE o arquivo e
    # põe o cursor lá — que é o que "clicar no erro" faz, sem precisar do clique.
    build_pos_arq: str
    build_pos_lin: int
    build_pos_col: int
    # o programa que o `Run` lançou. Zero quando não há nenhum — e o número é o
    # PID, porque é isso que `os.spawn` devolve (ver a bateria do `os.spawn`).
    run_pid: int
    want_stop_run: bool

    # ---- o driver, injetado pelo `app.psc` ----
    read_file: (def(str) -> str)?        # "" quando não deu
    write_file: (def(str, str) -> bool)?
    mtime_of: (def(str) -> int)?
    clip_get: (def() -> str)?
    clip_set: def(str)?
    confirm_close: (def(str) -> int)?    # 0=salvar 1=descartar 2=cancelar
    confirm_reload: (def(str) -> bool)?
    set_title: def(str)?
    zoom_step: def(int)?        # 115: +1/-1/0(reset) — o driver troca a grade e
                                #   devolve a célula nova por `set_cell`

    # ---------- o driver, atrás de um método cada ----------
    # A prova de não-nulo é sobre LOCAL (43.1), então cada função do driver é
    # lida para uma variável e chamada DENTRO do ramo. Fazer isso uma vez por
    # função aqui deixa o resto do arquivo sem um `if` em cada uso.

    def do_read(self, p: str) -> str:
        f = self.read_file
        if f != None:
            return f(p)
        return ""

    def do_write(self, p: str, text: str) -> bool:
        f = self.write_file
        if f != None:
            return f(p, text)
        return False

    def do_mtime(self, p: str) -> int:
        f = self.mtime_of
        if f != None:
            return f(p)
        return 0

    def do_clip_get(self) -> str:
        f = self.clip_get
        if f != None:
            return f()
        return ""

    def do_clip_set(self, text: str):
        f = self.clip_set
        if f != None:
            f(text)

    def do_confirm_close(self, name: str) -> int:
        f = self.confirm_close
        if f != None:
            return f(name)
        return 1              # sem driver, descarta (é o que um teste quer)

    def do_confirm_reload(self, name: str) -> bool:
        f = self.confirm_reload
        if f != None:
            return f(name)
        return True

    def do_zoom(self, step: int):
        f = self.zoom_step
        if f != None:
            f(step)

    def do_title(self, t: str):
        f = self.set_title
        if f != None:
            f(t)

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
        text = self.do_read(p)
        # 114: LER é `await` no pscript (76.2), e este caminho é síncrono de
        # propósito (um índice que espera obriga todo chamador a esperar). Então
        # o app PEDE e o driver lê: `want_open` é o pedido, e o driver chama
        # `open_file` outra vez com o texto já em mão.
        if len(text) == 0 and path.isfile(p):
            self.want_open = p
            return
        if len(text) == 0 and not path.isfile(p):
            return
        cv = cvm.cv_create(self.u, self.cvhost)
        cv.load_text(p, text, self.do_mtime(p))
        self.tabs.append(Tab(cv, path.basename(p)))
        self.select_tab(len(self.tabs) - 1)

    def select_tab(self, i: int):
        if i < 0 or i >= len(self.tabs):
            return
        self.cur = i
        self.do_title("pstudio — " + self.tabs[i].title)
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
            r = self.do_confirm_close(self.tabs[i].title)
            if r == 2:
                return
            if r == 0 and not self.save_tab(i):
                return
        self.u.free_node(cv.id)
        self.tabs.remove_at(i)
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
        if not self.do_write(cv.path, cv.text_to_save()):
            return False
        cv.mark_saved(self.do_mtime(cv.path))
        return True

    def save_cur(self):
        ok = self.save_tab(self.cur)
        if not ok and self.cur >= 0:
            self.want_msg = "could not save " + self.tabs[self.cur].cv.path
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
                self.entries.remove_at(k)
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
        elif mode == PAL_BUILD:
            self.u.set_text(self.palinput, "!")
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
        elif q.startswith("!"):
            # F6: `!` escolhe um ALVO do grafo. O prefixo é a mesma ideia do
            # Sublime — quem já sabe o nome escreve-o, quem não sabe vê a lista.
            self.palmode = PAL_BUILD
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
            case PAL_BUILD:
                # os alvos vêm do GRAFO, que o driver pôs aqui: o editor não
                # sabe o que este projeto constrói, e não devia saber
                for t in self.build_targets:
                    sc3 = fuzzy_score(t, q)
                    if sc3 >= 0:
                        self.palitems.append(PalItem(t, t, sc3))
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
        if len(self.palitems) > 200:
            self.palitems = self.palitems[0:200]      # o resto não caberia na tela
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
            case PAL_BUILD:
                if self.build_busy:
                    self.build_msg = "build já a correr"
                else:
                    self.want_build = payload
                    self.want_build_on = True
                    self.want_run = False
                    self.build_msg = "a construir " + payload + "..."
                self.update_status()
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

    # ---------- o erro do build, como posição ----------

    def marcar_erro(self, texto: str) -> bool:
        """`arquivo:linha:coluna: error: mensagem` — o formato que o compilador
        já usa, e que o `ppack` copiou de propósito para os erros dele.

        Guardar a POSIÇÃO em vez de só o texto é o que separa uma barra de
        estado de uma IDE: com ela o editor abre o arquivo e põe o cursor lá.
        Uma linha que não tenha esta forma é ignorada — a saída de um `cc` tem
        muita coisa que não é diagnóstico."""
        for linha in texto.split("\n"):
            partes = linha.split(":")
            if len(partes) < 4:
                continue
            if not partes[1].isdigit() or not partes[2].isdigit():
                continue
            resto = ":".join(partes[3:len(partes)]).strip()
            if not resto.startswith("error") and not resto.startswith("warning"):
                continue
            if not resto.startswith("error"):
                continue           # o primeiro ERRO, não o primeiro aviso
            self.build_pos_arq = partes[0].strip()
            self.build_pos_lin = int(partes[1])
            self.build_pos_col = int(partes[2])
            return True
        return False

    def ir_para_erro(self) -> bool:
        """Abre o arquivo do primeiro erro e põe o cursor nele. Devolve se
        havia para onde ir."""
        if len(self.build_pos_arq) == 0:
            return False
        if not path.isfile(self.build_pos_arq):
            return False
        self.open_file(self.build_pos_arq)
        cv = self.cur_cv()
        if cv == None:
            return False
        cv.buf.move_to(self.build_pos_lin - 1, self.build_pos_col - 1)
        cv.scroll_to_caret()
        # e a linha fica MARCADA na sarjeta, para continuar a ver-se depois de o
        # cursor sair dali
        cv.buf.clear_marks(core.MARK_ERROR)
        cv.buf.toggle_mark(self.build_pos_lin - 1, core.MARK_ERROR)
        self.update_status()
        return True

    # ---------- comandos ----------

    def run_command(self, cmd: int):
        cv = self.cur_cv()
        now = self.now_ms
        if cmd == 0:
            self.save_cur()
        elif cmd == 1:
            for i in range(len(self.tabs)):
                if not self.save_tab(i):
                    self.want_msg = "could not save " + self.tabs[i].cv.path
            self.u.queue_redraw(self.tabbar)
        elif cmd == 2:
            self.close_tab(self.cur)
        elif cmd == 3:
            self.reload_cur()
        elif cmd == 4:
            self.u.set_visible(self.tree_pane, not self.u.is_visible(self.tree_pane))
        elif cmd == 5:
            self.do_zoom(1)
        elif cmd == 6:
            self.do_zoom(-1)
        elif cmd == 7:
            self.do_zoom(0)
        elif cmd == 10:
            self.try_quit()
        elif cmd == 24 or cmd == 26:
            # F6: play. O app PEDE; quem constrói é o driver, no mesmo laço de
            # eventos — o motor é uma biblioteca (`packages/pbuild`) e não um
            # processo, então o grafo é um `dict` e não um fluxo de texto.
            if self.build_busy:
                self.build_msg = "build já a correr"
            else:
                self.want_build = ""
                self.want_build_on = True
                self.want_run = cmd == 26
                self.build_msg = "a construir..."
                # o erro anterior sai da sarjeta: ele é de um build que já não é
                # este, e uma marca velha é pior do que nenhuma
                for t in self.tabs:
                    t.cv.buf.clear_marks(core.MARK_ERROR)
            self.update_status()
        elif cmd == 25:
            self.palette_open(PAL_BUILD)
        elif cmd == 27:
            self.want_clean = True
            self.build_msg = "a limpar..."
            self.update_status()
        elif cmd == 29:
            if not self.ir_para_erro():
                self.build_msg = "nenhum erro de build para onde ir"
                self.update_status()
        elif cmd == 28:
            # parar é um PEDIDO, não uma morte: o executor termina a aresta que
            # está a correr e não começa outra. Matar um `cc` a meio deixa um
            # `.o` truncado, que é exatamente o que o motor recusa depois.
            #
            # O PROGRAMA, esse, morre já: ele é do utilizador e não do build.
            self.build_stop = True
            self.want_stop_run = True
            self.build_msg = "a parar depois desta aresta..."
            self.update_status()
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
        if cv == None or len(cv.path) == 0:
            return
        keep = cv.top
        cv.load_text(cv.path, self.do_read(cv.path), self.do_mtime(cv.path))
        cv.top = keep
        self.dirty_ui = True

    def check_external(self):
        """Um arquivo mudou no disco: recarrega o que está limpo, pergunta o que
        tem edição local."""
        for i in range(len(self.tabs)):
            cv = self.tabs[i].cv
            if len(cv.path) == 0 or not path.exists(cv.path):
                continue
            m = self.do_mtime(cv.path)
            if m == cv.mtime:
                continue
            if not cv.buf.dirty:
                self.select_tab(i)
                self.reload_cur()
            else:
                if self.do_confirm_reload(self.tabs[i].title):
                    self.select_tab(i)
                    self.reload_cur()
                else:
                    cv.mtime = m      # escolheram manter: não pergunta de novo
        self.dirty_ui = True

    def try_quit(self):
        for i in range(len(self.tabs)):
            cv = self.tabs[i].cv
            if cv.buf.dirty:
                r = self.do_confirm_close(self.tabs[i].title)
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
        # 115: o F2 é atalho SEM ctrl (o ctrl+F2 põe/tira a marca, o shift+F2 vai
        # para trás) — é a navegação por marcadores do editor em P
        if ev.key == K_F2 and cv != None:
            if (ev.mods & 2) != 0:
                cv.toggle_bookmark()
            else:
                cv.goto_mark((ev.mods & 1) == 0)
            self.update_status()
            self.dirty_ui = True
            return True
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
                got = cv.copy()
                if len(got) > 0:
                    self.do_clip_set(got)
            elif k == ord("x"):
                got2 = cv.cut(now)
                if len(got2) > 0:
                    self.do_clip_set(got2)
            elif k == ord("v"):
                cv.paste(self.do_clip_get(), now)
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
              False, True, True, 0, "", "",
              "", False, False, False, "", False, False, [], 0, 0, "", "", 0, 0, 0, False,
              None, None, None, None, None, None, None, None, None)

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
