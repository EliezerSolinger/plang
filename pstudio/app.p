# app.p — o editor montado: abas, árvore, palette, busca, loop de eventos.
include <stdio.h>
include <stdlib.h>
include <string.h>
import "app.ph"
import "psys.ph"

implement Str
implement Vec<Tab>
implement Vec<TreeEntry>
implement Vec<PalItem>

MAX_SCAN: const i32 = 20000     # teto da varredura de arquivos do projeto
BLINK_MS: const i32 = 500       # piscar do caret (DESIGN.md)

# ---------- utilidades ----------

static def own(s: const *char) -> *char:
    r: *char = malloc(strlen(s) + 1)
    strcpy(r, s)
    return r

# nomes ignorados na árvore e no índice do palette (DESIGN.md: filtrada)
static def is_hidden(name: const *char) -> bool:
    if name[0] == '.':
        return True
    return name in {"out", "node_modules", "__pycache__"}

# fuzzy: subsequência com bônus para casamento consecutivo e início de palavra.
# -1 = não casa. Modelo do ctrl+p do Sublime, simplificado.
static def fuzzy_score(hay: const *char, needle: const *char) -> i32:
    if needle[0] == '\0':
        return 1
    score: i32 = 0
    run: i32 = 0
    hi: usize = 0
    ni: usize = 0
    while hay[hi] != '\0' and needle[ni] != '\0':
        h: char = hay[hi]
        n: char = needle[ni]
        if h >= 'A' and h <= 'Z':
            h = char(i32(h) + 32)
        if n >= 'A' and n <= 'Z':
            n = char(i32(n) + 32)
        if h == n:
            run += 1
            score += 10 + run * 5
            if hi == 0 or hay[hi - 1] in {'/', '_', '-', '.'}:
                score += 15
            ni += 1
        else:
            run = 0
        hi += 1
    if needle[ni] != '\0':
        return -1
    # caminhos curtos primeiro
    return score - i32(strlen(hay)) / 4

static def pal_free(items: *Vec<PalItem>):
    for i in range(items->len):
        free(items->data[i].label)
        free(items->data[i].payload)
    items->clear()

# comandos do palette (modo '>')
struct Command:
    name: const *char
    id: i32

commands: Command[] = {
    {"Save", 0}, {"Save All", 1}, {"Close Tab", 2}, {"Reload File", 3},
    {"Toggle File Tree", 4}, {"Zoom In", 5}, {"Zoom Out", 6}, {"Zoom Reset", 7},
    {"Find", 8}, {"Go To Line", 9}, {"Quit", 10}, {None, -1}}

# ---------- tab bar ----------

static def tabbar_min(ui: *Ui, id: i32, out_w: *i32, out_h: *i32):
    *out_w = 0
    *out_h = ui->font.line_h() + 8

static def tab_width(ui: *Ui, t: *Tab) -> i32:
    return ui->font.text_width(t->title) + ui->font.char_w() * 4

static def tabbar_build(ui: *Ui, id: i32):
    app: *App = ui->data_of(id)
    r: PgRect = ui->rect_of(id)
    th: *Theme = &ui->theme
    lh: i32 = ui->font.line_h()
    ui->cmd_rect(id, r, th->panel_lo)
    x: i32 = r.x
    for i in range(app->tabs.len):
        t: *Tab = &app->tabs.data[i]
        w: i32 = tab_width(ui, t)
        active: bool = i == app->cur
        ui->cmd_rect(id, pg_rect(x, r.y, w, r.h), th->panel if active else th->panel_lo)
        if active:
            ui->cmd_rect(id, pg_rect(x, r.y + r.h - 2, w, 2), th->accent)
        cv: *CodeView = cv_of(ref *ui, t->cv)
        ui->cmd_text(id, x + ui->font.char_w(), r.y + (r.h - lh) / 2, t->title,
                     th->text if active else th->text_dim)
        if cv->buf.dirty:
            ui->cmd_text(id, x + w - ui->font.char_w() * 2, r.y + (r.h - lh) / 2, "*", th->accent)
        ui->cmd_rect(id, pg_rect(x + w - 1, r.y, 1, r.h), th->border)
        x += w
    ui->cmd_rect(id, pg_rect(r.x, r.y + r.h - 1, r.w, 1), th->border)

static def tabbar_input(ui: *Ui, id: i32, ev: *PgEvent) -> bool:
    if ev->kind != PGE_MOUSE_DOWN:
        return False
    app: *App = ui->data_of(id)
    r: PgRect = ui->rect_of(id)
    x: i32 = r.x
    for i in range(app->tabs.len):
        w: i32 = tab_width(ui, &app->tabs.data[i])
        if ev->x >= x and ev->x < x + w:
            # último caractere da aba = fechar (ou botão do meio)
            if ev->button == 2 or ev->x > x + w - ui->font.char_w() * 2:
                app->close_tab(i)
            else:
                app->select_tab(i)
            return True
        x += w
    return True

# ---------- árvore de arquivos ----------

static def tree_min(ui: *Ui, id: i32, out_w: *i32, out_h: *i32):
    *out_w = ui->font.char_w() * 18
    *out_h = 0

static def tree_build(ui: *Ui, id: i32):
    app: *App = ui->data_of(id)
    r: PgRect = ui->rect_of(id)
    th: *Theme = &ui->theme
    lh: i32 = ui->font.line_h()
    cw: i32 = ui->font.char_w()
    ui->cmd_rect(id, r, th->panel)
    ui->cmd_rect(id, pg_rect(r.x + r.w - 1, r.y, 1, r.h), th->border)
    vis: i32 = r.h / lh
    for vi in range(vis + 1):
        i: i32 = app->tree_top + vi
        if i >= app->entries.len:
            break
        e: *TreeEntry = &app->entries.data[i]
        y: i32 = r.y + vi * lh
        x: i32 = r.x + 4 + e->depth * cw * 2
        if e->is_dir:
            ui->cmd_text(id, x, y, "v" if e->expanded else ">", th->text_dim)
            ui->cmd_text(id, x + cw * 2, y, e->name, th->text)
        else:
            act: bool = False
            if app->cur >= 0:
                cv: *CodeView = cv_of(ref *ui, app->tabs.data[app->cur].cv)
                act = cv->path != None and strcmp(cv->path, e->path) == 0
            if act:
                ui->cmd_rect(id, pg_rect(r.x, y, r.w - 1, lh), th->sel)
            ui->cmd_text(id, x + cw * 2, y, e->name, th->text if act else th->text_dim)

static def tree_input(ui: *Ui, id: i32, ev: *PgEvent) -> bool:
    app: *App = ui->data_of(id)
    r: PgRect = ui->rect_of(id)
    lh: i32 = ui->font.line_h()
    if ev->kind == PGE_WHEEL:
        t: i32 = app->tree_top - ev->wheel_y * 3
        mx: i32 = app->entries.len - 1
        app->tree_top = 0 if t < 0 else (mx if t > mx else t)
        ui->queue_redraw(id)
        return True
    if ev->kind != PGE_MOUSE_DOWN or ev->button != 1:
        return False
    i: i32 = app->tree_top + (ev->y - r.y) / lh
    if i < 0 or i >= app->entries.len:
        return True
    if app->entries.data[i].is_dir:
        app->tree_toggle(i)
    else:
        app->open_file(app->entries.data[i].path)
    ui->queue_redraw(id)
    return True

# ---------- command palette ----------

static def pal_min(ui: *Ui, id: i32, out_w: *i32, out_h: *i32):
    *out_w = 0
    *out_h = 0

static def pal_layout(ui: *Ui, id: i32, r: PgRect):
    app: *App = ui->data_of(id)
    lh: i32 = ui->font.line_h()
    w: i32 = r.w * 3 / 5
    if w < ui->font.char_w() * 40:
        w = ui->font.char_w() * 40
    if w > r.w - 20:
        w = r.w - 20
    rows: i32 = app->palitems.len
    if rows > 12:
        rows = 12
    h: i32 = lh + 12 + rows * lh + 8
    me: PgRect = pg_rect(r.x + (r.w - w) / 2, r.y + r.h / 8, w, h)
    ui->set_rect(id, me)
    ui->set_rect(app->palinput, pg_rect(me.x + 6, me.y + 6, me.w - 12, lh + 6))

static def pal_build(ui: *Ui, id: i32):
    app: *App = ui->data_of(id)
    r: PgRect = ui->rect_of(id)
    th: *Theme = &ui->theme
    lh: i32 = ui->font.line_h()
    ui->cmd_rect(id, r, th->panel)
    ui->cmd_frame(id, r, th->accent)
    y: i32 = r.y + lh + 14
    for vi in range(12):
        i: i32 = app->paltop + vi
        if i >= app->palitems.len:
            break
        if y + lh > r.y + r.h:
            break
        if i == app->palsel:
            ui->cmd_rect(id, pg_rect(r.x + 2, y, r.w - 4, lh), th->sel)
        ui->cmd_text(id, r.x + 8, y, app->palitems.data[i].label,
                     th->text if i == app->palsel else th->text_dim)
        y += lh

static def pal_input(ui: *Ui, id: i32, ev: *PgEvent) -> bool:
    app: *App = ui->data_of(id)
    if ev->kind == PGE_MOUSE_DOWN and ev->button == 1:
        r: PgRect = ui->rect_of(id)
        lh: i32 = ui->font.line_h()
        i: i32 = app->paltop + (ev->y - (r.y + lh + 14)) / lh
        if i >= 0 and i < app->palitems.len:
            app->palsel = i
            app->palette_accept()
        return True
    return False

# ---------- sinais ----------

static def on_pal_changed(ctx: *void, id: i32, arg: i64):
    app: *App = ctx
    app->palette_filter()

static def on_pal_submit(ctx: *void, id: i32, arg: i64):
    app: *App = ctx
    app->palette_accept()

static def on_pal_cancel(ctx: *void, id: i32, arg: i64):
    app: *App = ctx
    app->palette_close()

static def on_find_changed(ctx: *void, id: i32, arg: i64):
    app: *App = ctx
    q: const *char = app->ui.text_of(app->findinput)
    app->find_re = q[0] == '/'
    cv: *CodeView = app->cur_cv()
    if cv == None:
        return
    cv->search(q + 1 if app->find_re else q, True, app->find_re, False)
    app->dirty_ui = True

static def on_find_submit(ctx: *void, id: i32, arg: i64):
    app: *App = ctx
    app->find_step(True)

static def on_find_cancel(ctx: *void, id: i32, arg: i64):
    app: *App = ctx
    app->find_close()

static def on_cv_changed(ctx: *void, cv: *CodeView):
    app: *App = ctx
    app->update_status()
    app->ui.queue_redraw(app->tabbar)
    app->dirty_ui = True

struct App:
    static def scan_dir(ref self: App, dir: const *char, depth: i32, ref count: i32)
    static def build_tree(ref self: App, dir: const *char, depth: i32, at: i32) -> i32
    static def check_external(ref self: App)
    static def try_quit(ref self: App)
    static def run_command(ref self: App, cmd: i32)

    # ---------- construção ----------

    def init(out self: App, dir: const *char, w: i32 = 1100, h: i32 = 720) -> bool:
        memset(&self, 0, sizeof(App))
        self.zoom = 1
        self.cur = -1
        self.tabs.init()
        self.entries.init()
        self.palitems.init()
        self.files.init()
        self.root_dir = own(dir)
        if not self.win.open("Plang Studio", w, h):
            return False
        self.ui.init(pg_font_default(self.zoom))

        # raiz = PANEL (empilha): [ coluna do editor | palette flutuante ]
        self.root = self.ui.panel(-1)
        col: i32 = self.ui.box(self.root, True)
        self.tabbar = self.ui.custom(col, &self, tabbar_min, tabbar_build,
                                     tabbar_input, None, None)
        self.split = self.ui.split(col, False)
        self.ui.set_expand(self.split, True, True)
        self.tree = self.ui.custom(self.split, &self, tree_min, tree_build,
                                   tree_input, None, None)
        self.editors = self.ui.box(self.split, True)
        self.ui.set_expand(self.editors, True, True)
        self.ui.split_set(self.split, 220)
        self.cvhost = self.ui.box(self.editors, True)
        self.ui.set_expand(self.cvhost, True, True)

        # barra de busca: último filho da coluna = FIXA no rodapé (Sublime)
        self.findbar = self.ui.box(self.editors, False)
        self.ui.label(self.findbar, "buscar:")
        self.findinput = self.ui.line_input(self.findbar)
        self.ui.set_expand(self.findinput, True, False)
        self.ui.on_changed(self.findinput, on_find_changed, &self)
        self.ui.on_submit(self.findinput, on_find_submit, &self)
        self.ui.on_cancel(self.findinput, on_find_cancel, &self)
        self.ui.set_visible(self.findbar, False)

        self.status = self.ui.label(col, " ")

        # palette (último filho da raiz: desenha por cima e ganha o hit-test)
        self.palette = self.ui.custom(self.root, &self, pal_min, pal_build,
                                      pal_input, pal_layout, None)
        self.palinput = self.ui.line_input(self.palette)
        self.ui.on_changed(self.palinput, on_pal_changed, &self)
        self.ui.on_submit(self.palinput, on_pal_submit, &self)
        self.ui.on_cancel(self.palinput, on_pal_cancel, &self)
        self.ui.set_visible(self.palette, False)

        self.tree_scan()
        self.ui.layout(self.win.fb.w, self.win.fb.h)
        self.running = True
        self.dirty_ui = True
        return True

    def deinit(ref self: App):
        for i in range(self.tabs.len):
            free(self.tabs.data[i].title)
        self.tabs.deinit()
        for i in range(self.entries.len):
            free(self.entries.data[i].path)
            free(self.entries.data[i].name)
        self.entries.deinit()
        pal_free(&self.palitems)
        self.palitems.deinit()
        pal_free(&self.files)
        self.files.deinit()
        free(self.root_dir)
        cv_clip_clear()
        self.ui.deinit()
        self.win.close()

    # ---------- abas ----------

    def cur_cv(ref self: App) -> *CodeView:
        if self.cur < 0 or self.cur >= self.tabs.len:
            return None
        return cv_of(ref self.ui, self.tabs.data[self.cur].cv)

    def open_file(ref self: App, path: const *char):
        # já aberto? só ativa
        for i in range(self.tabs.len):
            cv: *CodeView = cv_of(ref self.ui, self.tabs.data[i].cv)
            if cv->path != None and strcmp(cv->path, path) == 0:
                self.select_tab(i)
                return
        id: i32 = cv_create(ref self.ui, self.cvhost)
        cv: *CodeView = cv_of(ref self.ui, id)
        cv->on_change = on_cv_changed
        cv->on_change_ctx = &self
        if not cv->load_file(path):
            self.ui.free_node(id)
            return
        t: Tab = {id, own(ps_path_basename(path))}
        self.tabs.push(t)
        self.select_tab(self.tabs.len - 1)

    def select_tab(ref self: App, i: i32):
        if i < 0 or i >= self.tabs.len:
            return
        self.cur = i
        for k in range(self.tabs.len):
            self.ui.set_visible(self.tabs.data[k].cv, k == i)
        self.ui.focus_set(self.tabs.data[i].cv)
        self.ui.relayout()
        self.ui.queue_redraw_tree(self.root)
        self.update_status()
        self.dirty_ui = True

    def close_tab(ref self: App, i: i32):
        if i < 0 or i >= self.tabs.len:
            return
        cv: *CodeView = cv_of(ref self.ui, self.tabs.data[i].cv)
        if cv->buf.dirty:
            r: i32 = self.win.confirm_close(self.tabs.data[i].title)
            if r == 2:
                return
            if r == 0 and not cv->save_file():
                return
        self.ui.free_node(self.tabs.data[i].cv)
        free(self.tabs.data[i].title)
        self.tabs.remove_at(i)
        if self.tabs.is_empty():
            self.cur = -1
            self.ui.relayout()
        else:
            self.select_tab(i - 1 if i > 0 else 0)
        self.update_status()
        self.dirty_ui = True

    def save_cur(ref self: App):
        cv: *CodeView = self.cur_cv()
        if cv != None:
            cv->save_file()
        self.ui.queue_redraw(self.tabbar)
        self.dirty_ui = True

    def update_status(ref self: App):
        s: Str
        s.init()
        cv: *CodeView = self.cur_cv()
        if cv == None:
            s.append(" pstudio — ctrl+p abre um arquivo")
        else:
            c: *Caret = cv->buf.caret(0)
            s.appendf(" %s%s   ", cv->path if cv->path != None else "(sem nome)",
                      "*" if cv->buf.dirty else "")
            s.appendf("%d:%d", c->line + 1, c->col + 1)
            if cv->buf.ncarets() > 1:
                s.appendf(" (%d carets)", cv->buf.ncarets())
            s.appendf("   %s   %d linhas   %dx",
                      "CRLF" if cv->buf.crlf else "LF", cv->buf.nlines(), self.zoom)
        self.ui.set_text(self.status, s.cstr())
        s.deinit()
        self.dirty_ui = True

    # ---------- árvore ----------

    # (re)constrói a lista plana: dirs primeiro, filtrada, com expansão
    static def build_tree(ref self: App, dir: const *char, depth: i32, at: i32) -> i32:
        v: Vfs = vfs_local()
        n: i32
        es: *PsDirEntry = vfs_list_dir(in v, dir, out n)
        if es == None:
            return at
        pos: i32 = at
        for i in range(n):
            if is_hidden(es[i].name):
                continue
            full: *char = ps_path_join(dir, es[i].name)
            e: TreeEntry = {full, own(es[i].name), depth, es[i].is_dir, False}
            self.entries.insert_at(pos, e)
            pos += 1
        ps_entries_free(es, n)
        return pos

    def tree_scan(ref self: App):
        for i in range(self.entries.len):
            free(self.entries.data[i].path)
            free(self.entries.data[i].name)
        self.entries.clear()
        self.build_tree(self.root_dir, 0, 0)
        self.tree_top = 0
        # índice de arquivos para o palette (varredura recursiva, uma vez)
        pal_free(&self.files)
        count: i32 = 0
        self.scan_dir(self.root_dir, 0, ref count)

    def tree_toggle(ref self: App, i: i32):
        e: *TreeEntry = &self.entries.data[i]
        if not e->is_dir:
            return
        if e->expanded:
            # remove os descendentes (profundidade maior) logo abaixo
            d: i32 = e->depth
            j: i32 = i + 1
            while j < self.entries.len and self.entries.data[j].depth > d:
                free(self.entries.data[j].path)
                free(self.entries.data[j].name)
                j += 1
            if j > i + 1:
                self.entries.remove_range(i + 1, j - i - 1)
            self.entries.data[i].expanded = False
        else:
            self.build_tree(e->path, e->depth + 1, i + 1)
            self.entries.data[i].expanded = True

    static def scan_dir(ref self: App, dir: const *char, depth: i32, ref count: i32):
        if depth > 8 or count >= MAX_SCAN:
            return
        v: Vfs = vfs_local()
        n: i32
        es: *PsDirEntry = vfs_list_dir(in v, dir, out n)
        if es == None:
            return
        for i in range(n):
            if is_hidden(es[i].name):
                continue
            full: *char = ps_path_join(dir, es[i].name)
            if es[i].is_dir:
                self.scan_dir(full, depth + 1, ref count)
                free(full)
            else:
                rel: const *char = full
                rl: usize = strlen(self.root_dir)
                if strncmp(full, self.root_dir, rl) == 0:
                    rel = full + rl
                    if rel[0] == '/':
                        rel += 1
                it: PalItem = {own(rel), full, 0}
                self.files.push(it)
                count += 1
                if count >= MAX_SCAN:
                    break
        ps_entries_free(es, n)

    # ---------- palette ----------

    def palette_open(ref self: App, mode: PalMode):
        self.palmode = mode
        self.ui.input_clear(self.palinput)
        if mode == PAL_COMMANDS:
            self.ui.set_text(self.palinput, ">")
        elif mode == PAL_GOTO:
            self.ui.set_text(self.palinput, ":")
        self.palsel = 0
        self.paltop = 0
        self.ui.set_visible(self.palette, True)
        self.ui.focus_set(self.palinput)
        self.palette_filter()
        self.dirty_ui = True

    def palette_close(ref self: App):
        self.ui.set_visible(self.palette, False)
        pal_free(&self.palitems)
        if self.cur >= 0:
            self.ui.focus_set(self.tabs.data[self.cur].cv)
        self.dirty_ui = True

    def palette_filter(ref self: App):
        q: const *char = self.ui.text_of(self.palinput)
        # o prefixo escolhe o modo (Sublime): '>' comandos, ':' ir para linha
        if q[0] == '>':
            self.palmode = PAL_COMMANDS
            q += 1
        elif q[0] == ':':
            self.palmode = PAL_GOTO
            q += 1
        else:
            self.palmode = PAL_FILES
        pal_free(&self.palitems)
        self.palsel = 0
        self.paltop = 0
        match self.palmode:
            case PAL_COMMANDS:
                j: i32 = 0
                while commands[j].name != None:
                    sc: i32 = fuzzy_score(commands[j].name, q)
                    if sc >= 0:
                        it: PalItem = {own(commands[j].name), None, sc}
                        it.payload = malloc(8)
                        snprintf(it.payload, 8, "%d", commands[j].id)
                        self.palitems.push(it)
                    j += 1
            case PAL_GOTO:
                lab: char[64]
                snprintf(lab, sizeof(lab), "ir para a linha %s", q if q[0] != '\0' else "…")
                it2: PalItem = {own(lab), own(q), 0}
                self.palitems.push(it2)
            case _:
                for i in range(self.files.len):
                    sc2: i32 = fuzzy_score(self.files.data[i].label, q)
                    if sc2 >= 0:
                        it3: PalItem = {own(self.files.data[i].label),
                                        own(self.files.data[i].payload), sc2}
                        self.palitems.push(it3)
                # maior score primeiro (insertion sort: listas pequenas)
                for i in range(1, self.palitems.len):
                    t: PalItem = self.palitems.data[i]
                    k: i32 = i
                    while k > 0 and self.palitems.data[k - 1].score < t.score:
                        self.palitems.data[k] = self.palitems.data[k - 1]
                        k -= 1
                    self.palitems.data[k] = t
                if self.palitems.len > 200:
                    for i in range(200, self.palitems.len):
                        free(self.palitems.data[i].label)
                        free(self.palitems.data[i].payload)
                    self.palitems.len = 200
        self.ui.relayout()
        self.ui.queue_redraw(self.palette)
        self.dirty_ui = True

    def palette_accept(ref self: App):
        if self.palitems.is_empty():
            self.palette_close()
            return
        it: *PalItem = &self.palitems.data[self.palsel if self.palsel < self.palitems.len else 0]
        mode: PalMode = self.palmode
        payload: *char = own(it->payload if it->payload != None else "")
        self.palette_close()
        match mode:
            case PAL_COMMANDS:
                self.run_command(atoi(payload))
            case PAL_GOTO:
                cv: *CodeView = self.cur_cv()
                if cv != None and payload[0] != '\0':
                    cv->buf.move_to(atoi(payload) - 1, 0)
                    cv->scroll_to_caret()
                    self.update_status()
            case _:
                self.open_file(payload)
        free(payload)

    # ---------- busca ----------

    def find_open(ref self: App):
        self.ui.set_visible(self.findbar, True)
        cv: *CodeView = self.cur_cv()
        if cv != None and cv->buf.has_sel():
            sel: *char = cv->buf.sel_text(0)
            if sel != None and strchr(sel, '\n') == None:
                self.ui.set_text(self.findinput, sel)
            free(sel)
        self.ui.focus_set(self.findinput)
        self.ui.relayout()
        self.dirty_ui = True

    def find_close(ref self: App):
        self.ui.set_visible(self.findbar, False)
        if self.cur >= 0:
            self.ui.focus_set(self.tabs.data[self.cur].cv)
        self.ui.relayout()
        self.dirty_ui = True

    def find_step(ref self: App, forward: bool):
        cv: *CodeView = self.cur_cv()
        if cv == None:
            return
        q: const *char = self.ui.text_of(self.findinput)
        cv->search(q + 1 if self.find_re else q, forward, self.find_re, True)
        self.update_status()
        self.dirty_ui = True

    # ---------- comandos / atalhos ----------

    def set_zoom(ref self: App, z: i32):
        nz: i32 = 1 if z < 1 else (3 if z > 3 else z)
        if nz == self.zoom:
            return
        self.zoom = nz
        self.ui.font = pg_font_default(nz)
        self.ui.relayout()
        self.ui.queue_redraw_tree(self.root)
        self.update_status()

    static def run_command(ref self: App, cmd: i32):
        cv: *CodeView = self.cur_cv()
        match cmd:
            case 0:
                self.save_cur()
            case 1:
                for i in range(self.tabs.len):
                    cv_of(ref self.ui, self.tabs.data[i].cv)->save_file()
                self.ui.queue_redraw(self.tabbar)
            case 2:
                self.close_tab(self.cur)
            case 3:
                if cv != None:
                    cv->reload()
            case 4:
                self.ui.set_visible(self.tree, not self.ui.is_visible(self.tree))
            case 5:
                self.set_zoom(self.zoom + 1)
            case 6:
                self.set_zoom(self.zoom - 1)
            case 7:
                self.set_zoom(1)
            case 8:
                self.find_open()
            case 9:
                self.palette_open(PAL_GOTO)
            case 10:
                self.try_quit()
            case _:
                pass
        self.dirty_ui = True

    # atalhos globais (Sublime). True = consumido, não desce para a árvore de UI
    def key_shortcut(ref self: App, ev: *PgEvent) -> bool:
        pal_open: bool = self.ui.is_visible(self.palette)
        # navegação da palette: as setas não são do input de texto
        if pal_open and ev->key in {PGK_UP, PGK_DOWN}:
            n: i32 = self.palitems.len
            if n > 0:
                self.palsel += 1 if ev->key == PGK_DOWN else -1
                if self.palsel < 0:
                    self.palsel = n - 1
                if self.palsel >= n:
                    self.palsel = 0
                if self.palsel < self.paltop:
                    self.paltop = self.palsel
                elif self.palsel >= self.paltop + 12:
                    self.paltop = self.palsel - 11
                self.ui.queue_redraw(self.palette)
                self.dirty_ui = True
            return True
        if (ev->mods & PGM_CTRL) == 0:
            return False
        shift: bool = (ev->mods & PGM_SHIFT) != 0
        cv: *CodeView = self.cur_cv()
        now: i64 = ps_millis()
        match ev->key:
            case i32('s'):
                if shift:
                    self.run_command(1)
                else:
                    self.save_cur()
            case i32('p'):
                self.palette_open(PAL_FILES)
            case i32('g'):
                self.palette_open(PAL_GOTO)
            case i32('f'):
                self.find_open()
            case i32('w'):
                self.close_tab(self.cur)
            case i32('q'):
                self.try_quit()
            case i32('b'):
                self.run_command(4)
            case i32('z'):
                if cv != None:
                    if shift:
                        cv->buf.redo_step()
                    else:
                        cv->buf.undo_step()
                    cv->changed()
                    cv->scroll_to_caret()
            case i32('y'):
                if cv != None:
                    cv->buf.redo_step()
                    cv->changed()
                    cv->scroll_to_caret()
            case i32('a'):
                if cv != None:
                    cv->buf.select_all()
                    self.ui.queue_redraw(cv->id)
            case i32('c'):
                if cv != None:
                    cv->copy()
            case i32('x'):
                if cv != None:
                    cv->cut(now)
            case i32('v'):
                if cv != None:
                    cv->paste(now)
            case i32('d'):
                if cv != None:
                    cv->buf.ctrl_d()
                    cv->scroll_to_caret()
                    self.ui.queue_redraw(cv->id)
            case i32('='), i32('+'):
                self.set_zoom(self.zoom + 1)
            case i32('-'):
                self.set_zoom(self.zoom - 1)
            case i32('0'):
                self.set_zoom(1)
            case PGK_TAB:
                if not self.tabs.is_empty():
                    self.select_tab((self.cur + (self.tabs.len - 1 if shift else 1)) % self.tabs.len)
            case _:
                return False
        self.update_status()
        self.dirty_ui = True
        return True

    # ---------- mudança externa / saída ----------

    static def check_external(ref self: App):
        v: Vfs = vfs_local()
        for i in range(self.tabs.len):
            cv: *CodeView = cv_of(ref self.ui, self.tabs.data[i].cv)
            if cv->path == None:
                continue
            st: PsStat
            if not vfs_stat(in v, cv->path, out st) or not st.exists:
                continue
            if st.mtime == cv->mtime:
                continue
            # mtime mudou: sem edições locais recarrega; com edições, pergunta
            if not cv->buf.dirty:
                cv->reload()
            elif self.win.confirm_reload(self.tabs.data[i].title):
                cv->reload()
            else:
                cv->mtime = st.mtime   # decidiu manter: não pergunta de novo
        self.dirty_ui = True

    static def try_quit(ref self: App):
        i: i32 = 0
        while i < self.tabs.len:
            cv: *CodeView = cv_of(ref self.ui, self.tabs.data[i].cv)
            if cv->buf.dirty:
                r: i32 = self.win.confirm_close(self.tabs.data[i].title)
                if r == 2:
                    return          # cancelou: continua editando
                if r == 0 and not cv->save_file():
                    return
            i += 1
        self.running = False

    def screenshot(ref self: App, path: const *char) -> bool:
        self.ui.draw(ref self.win.fb)
        f: *FILE = fopen(path, "wb")
        if f == None:
            return False
        fb: *PgFb = &self.win.fb
        fprintf(f, "P6\n%d %d\n255\n", fb->w, fb->h)
        row: *u8 = malloc(usize(fb->w) * 3)
        for y in range(fb->h):
            for x in range(fb->w):
                px: u32 = fb->px[usize(y) * usize(fb->w) + usize(x)]
                row[usize(x) * 3 + 0] = u8((px >> 16) & 0xFF)
                row[usize(x) * 3 + 1] = u8((px >> 8) & 0xFF)
                row[usize(x) * 3 + 2] = u8(px & 0xFF)
            fwrite(row, 1, usize(fb->w) * 3, f)
        free(row)
        fclose(f)
        return True

    # ---------- loop ----------

    static def handle_event(ref self: App, ev: *PgEvent, ref blink: i64):
        match ev->kind:
            case PGE_QUIT:
                self.try_quit()
            case PGE_RESIZE:
                self.ui.layout(ev->x, ev->y)
                self.ui.queue_redraw_tree(self.root)
            case PGE_TIMEOUT:
                now: i64 = ps_millis()
                if now - blink >= i64(BLINK_MS):
                    blink = now
                    cv: *CodeView = self.cur_cv()
                    if cv != None and self.ui.focus_get() == cv->id:
                        cv->caret_on = not cv->caret_on
                        self.ui.queue_redraw(cv->id)
            case PGE_FOCUS_GAINED:
                self.check_external()
            case PGE_KEY:
                # teclado é de baixa frequência: força o repaint (uma tecla
                # sempre mexe em algo visível, e não há fila para acumular)
                if not self.key_shortcut(ev):
                    self.ui.input_event(ev)
                    self.update_status()
                self.dirty_ui = True
            case _:
                # mouse/roda: NÃO força repaint. Quem realmente sujou algo
                # levantou ui.needs_draw — mover o mouse sem efeito visual não
                # deve custar um frame inteiro de rasterização.
                if self.ui.input_event(ev):
                    self.update_status()

    def run(ref self: App) -> i32:
        blink: i64 = ps_millis()
        while self.running:
            ev: PgEvent
            # UM evento bloqueante (timeout = piscar do caret) e depois DRENA
            # a fila: o present é por FRAME, não por evento. Com vsync cada
            # present segura ~16ms; um por evento de movimento deixa o arraste
            # atrás do cursor porque a fila do SDL cresce mais rápido do que a
            # gente consome (medido: 200 motions = 182ms assim, 1ms drenando).
            if not self.win.wait_event(out ev, BLINK_MS):
                break
            self.handle_event(&ev, ref blink)
            while self.running and self.win.poll_event(out ev):
                self.handle_event(&ev, ref blink)
            if self.dirty_ui or self.ui.needs_draw:
                self.ui.draw(ref self.win.fb)
                self.win.present()
                self.dirty_ui = False
        return 0
