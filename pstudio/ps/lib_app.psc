"""The assembled editor, in pscript: tabs, file tree, command palette,
search and status bar (a port of `pstudio/app.p`, layer 5 of the DESIGN).

What is NOT here, on purpose: the window, the event loop, the clock, the
clipboard and the confirmation boxes. All of that is DRIVER, and the driver lives
in `app.psc` (which talks to `shim.p`). The link between the two is made of
functions kept in fields — `clip_get`, `confirm_close`, `read_file` — which
`app.psc` fills in at startup.

Why like this: it is the same reason as the `Painter` in `pui` (the package) and
`load_text` in `lib_cv`. With the driver outside, the WHOLE editor — tabs, tree,
palette, search, shortcuts — runs headless in a test, and what is left for
`app.psc` is a page with no logic to get wrong.
"""
import <pui> as pui
import lib_cv as cvm
import lib_core as core
import os
import path


const BLINK_MS: int = 500        # the cursor blink (DESIGN.md)
const MAX_SCAN: int = 20000      # ceiling on the project scan
const PAL_ROWS: int = 12         # visible palette rows
const TREE_MIN_CP: int = 18      # the tree's minimum width, in characters
const K_F2: int = 1073741883     # SDL's F2


enum PalMode:
    PAL_FILES         # fuzzy file search (the default)
    PAL_COMMANDS      # the '>' prefix
    PAL_GOTO          # the ':' prefix
    PAL_BUILD         # the '!' prefix: a graph target
    PAL_TEXT          # a TYPED line, for when it asks instead of offering


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


# the names hidden from the tree and from the palette's index
def is_hidden(name: str) -> bool:
    if name.startswith("."):
        return True
    return name == "out" or name == "node_modules" or name == "__pycache__"


# fuzzy: matches as a subsequence, with a bonus for consecutive hits and for a
# word start. -1 = no match. Sublime's ctrl+p model, simplified.
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


# the command palette: name and id, in a single string (an imported module does
# not run statements, and a two-column table fits one line per command)
const COMMANDS: str = "Save=0;Save All=1;Close Tab=2;Reload File=3;Toggle File Tree=4;Zoom In=5;Zoom Out=6;Zoom Reset=7;Find=8;Go To Line=9;Quit=10;Fold=11;Unfold=11;Fold All=12;Unfold All=13;Toggle Comment=14;Move Line Up=15;Move Line Down=16;Duplicate Line=17;Delete Line=18;Join Lines=19;Toggle Bookmark=20;Next Bookmark=21;Clear Bookmarks=22;Toggle Minimap=23;Build=24;Build Target...=25;Run=26;Clean=27;Stop Build=28;Go To Build Error=29;Manifest: Open pack.json=30;Manifest: Set Default Target...=31;Manifest: Add Dependency...=32"


struct App:
    u: pui.Ui
    root: int          # the root panel (stacks the layout and the palette)
    tabbar: int
    tree_pane: int     # box with the "FOLDERS" header and the rows
    tree: int          # the rows (its rectangle IS the row area)
    split: int
    editors: int       # vertical box: [cvhost | search bar]
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
    find_re: bool      # regex search (the query starts with '/')
    running: bool
    dirty_ui: bool     # a frame needs presenting
    now_ms: int        # the clock, which comes from the driver
    want_open: str     # 114: a file the app wants and the driver has to READ
    want_msg: str      # a message for the status bar (a write failure)
    # F6: the BUILD. The app does not build — it ASKS, the way it asks for a
    # file to be read, and the driver serves it in the event loop. The reason is
    # the same as 114's: the editor's logic is synchronous on purpose, and an
    # `await` here would force every caller to wait.
    #
    # `want_build` is the target ("" = the graph's default), `want_run` says
    # whether the program should run after building, and `build_msg` is what the
    # status bar shows while that happens.
    want_build: str
    want_build_on: bool
    want_run: bool
    want_clean: bool
    build_msg: str
    build_busy: bool
    build_stop: bool
    # the targets this project builds, put here by the DRIVER from the graph:
    # the editor does not know what a project builds, and should not know
    build_targets: list<str>
    build_total: int
    build_done: int
    build_error: str
    # F6: where the build's first error points. The editor OPENS the file and
    # puts the cursor there — which is what "clicking the error" does, without the click.
    build_pos_file: str
    build_pos_line: int
    build_pos_col: int
    # the program `Run` launched. Zero when there is none — and the number is
    # the PID, because that is what `os.spawn` returns (see the `os.spawn` battery).
    run_pid: int
    want_stop_run: bool
    # F6: the MANIFEST. The editor does not invent a form — it already is a text
    # editor, and `pack.json` is text. What the palette adds is what is tedious
    # to write by hand and easy to write wrong: the default target (which has to
    # be a target THAT EXISTS, and the graph knows which ones do) and a
    # dependency (which has to be resolved, checked and locked, and `ppack` is
    # the one that knows how).
    #
    # Like everything else here, the app ASKS and the driver serves.
    want_manifest_default: str      # "" = nothing to ask for
    want_manifest_dep: str          # "name@version"
    pal_text_for: int               # the command waiting for what gets typed
    pal_prompt: str                 # ... and what is asked of whoever types
    # when the target palette is for CHOOSING and not for building
    pal_build_default: bool

    # ---- the driver, injected by `app.psc` ----
    read_file: (def(str) -> str)?        # "" when it did not work
    write_file: (def(str, str) -> bool)?
    mtime_of: (def(str) -> int)?
    clip_get: (def() -> str)?
    clip_set: def(str)?
    confirm_close: (def(str) -> int)?    # 0=save 1=discard 2=cancel
    confirm_reload: (def(str) -> bool)?
    set_title: def(str)?
    zoom_step: def(int)?        # 115: +1/-1/0(reset) — the driver swaps the grid
                                #   and returns the new cell through `set_cell`

    # ---------- the driver, one method each behind it ----------
    # The non-null proof is about LOCALS (43.1), so each driver function is read
    # into a variable and called INSIDE the branch. Doing that once per function
    # here leaves the rest of the file without an `if` at every use.

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
        return 1              # with no driver, discard (which is what a test wants)

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
                self.select_tab(i)          # already open: just activate it
                return
        text = self.do_read(p)
        # 114: READING is `await` in pscript (76.2), and this path is synchronous
        # on purpose (an index that waits forces every caller to wait). So the
        # app ASKS and the driver reads: `want_open` is the request, and the
        # driver calls `open_file` again with the text already in hand.
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
        # the tab bar and the tree are RETAINED and their rectangle did not
        # change: without dirtying them by hand, the closed tab would stay painted
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

    # ---------- the tree ----------

    def dir_rows(self, dir: str, depth: int, at: int) -> int:
        """Inserts a directory's rows at `at`, directories first. Returns where
        the insertion stopped."""
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
        """The palette's index: a recursive scan, with a ceiling."""
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
            # removes the descendants (the deeper rows right below)
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

    # ---------- the palette ----------

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

    def ask(self, prompt: str, for_cmd: int):
        """Opens the palette ASKING, instead of offering.

        The editor has no dialog boxes, and that is not a gap: it has an input
        line that already serves to look for a file, a command and a line number
        — and asking is the fourth thing you do with it. A modal window with one
        field and two buttons would be a new mechanism for what already exists,
        and would force a decision about where it sits, how big it is and what
        happens when the window shrinks."""
        self.pal_prompt = prompt
        self.pal_text_for = for_cmd
        self.palette_open(PAL_TEXT)

    def text_accepted(self, for_cmd: int, txt: str):
        """What was typed, handed to whoever asked."""
        if for_cmd == 32:
            if "@" not in txt:
                self.build_msg = "a dependency is `name@version` — v1 has no resolver"
                self.update_status()
                return
            self.want_manifest_dep = txt
            self.build_msg = "a acrescentar " + txt + "..."
            self.update_status()

    def palette_close(self):
        self.u.set_visible(self.palette, False)
        self.palitems = []
        if self.cur >= 0:
            self.u.focus_set(self.tabs[self.cur].cv.id)
        self.dirty_ui = True

    def palette_filter(self):
        q = self.u.text_of(self.palinput)
        if self.palmode == PAL_TEXT:
            # asking: what gets typed is an ANSWER, and a `>` in the middle of
            # it is a character and not a mode
            self.palitems = []
            self.palsel = 0
            self.paltop = 0
            rot0 = self.pal_prompt + ": " + (q if len(q) > 0 else "…")
            self.palitems.append(PalItem(rot0, q, 0))
            return
        # the prefix picks the mode (Sublime): '>' commands, ':' go to line
        if q.startswith(">"):
            self.palmode = PAL_COMMANDS
            q = q[1:len(q)]
        elif q.startswith(":"):
            self.palmode = PAL_GOTO
            q = q[1:len(q)]
        elif q.startswith("!"):
            # F6: `!` picks a graph TARGET. The prefix is Sublime's idea —
            # whoever knows the name types it, whoever does not sees the list.
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
            case PAL_TEXT:
                # there is no list: the item IS what is being typed. It exists
                # so the palette can ASK, and not only offer.
                rot = self.pal_prompt + ": " + (q if len(q) > 0 else "…")
                self.palitems.append(PalItem(rot, q, 0))
            case PAL_BUILD:
                # the targets come from the GRAPH, which the driver put here:
                # the editor does not know what this project builds, and should not
                for t in self.build_targets:
                    sc3 = fuzzy_score(t, q)
                    if sc3 >= 0:
                        self.palitems.append(PalItem(t, t, sc3))
            case _:
                for it in self.files:
                    sc2 = fuzzy_score(it.label, q)
                    if sc2 >= 0:
                        self.palitems.append(PalItem(it.label, it.payload, sc2))
        # highest score first (insertion: the lists are small)
        for i in range(1, len(self.palitems)):
            t = self.palitems[i]
            k = i
            while k > 0 and self.palitems[k - 1].score < t.score:
                self.palitems[k] = self.palitems[k - 1]
                k -= 1
            self.palitems[k] = t
        if len(self.palitems) > 200:
            self.palitems = self.palitems[0:200]      # the rest would not fit on screen
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
            case PAL_TEXT:
                if len(payload) > 0:
                    self.text_accepted(self.pal_text_for, payload)
            case PAL_BUILD:
                if self.pal_build_default:
                    # choosing the project's DEFAULT target: what gets asked of
                    # the driver is a write to the manifest, not a build
                    self.pal_build_default = False
                    self.want_manifest_default = payload
                    self.build_msg = "writing the default target..."
                    self.update_status()
                elif self.build_busy:
                    self.build_msg = "a build is already running"
                else:
                    self.want_build = payload
                    self.want_build_on = True
                    self.want_run = False
                    self.build_msg = "building " + payload + "..."
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

    # ---------- the build error, as a position ----------

    def mark_error(self, text: str) -> bool:
        """`file:line:column: error: message` — the format the compiler already
        uses, and that `ppack` copied on purpose for its own errors.

        Keeping the POSITION instead of only the text is what separates a status
        bar from an IDE: with it the editor opens the file and puts the cursor
        there. A line that does not have this shape is ignored — a `cc`'s output
        has plenty that is not a diagnostic."""
        for line in text.split("\n"):
            parts = line.split(":")
            if len(parts) < 4:
                continue
            if not parts[1].isdigit() or not parts[2].isdigit():
                continue
            rest = ":".join(parts[3:len(parts)]).strip()
            if not rest.startswith("error") and not rest.startswith("warning"):
                continue
            if not rest.startswith("error"):
                continue           # the first ERROR, not the first warning
            self.build_pos_file = parts[0].strip()
            self.build_pos_line = int(parts[1])
            self.build_pos_col = int(parts[2])
            return True
        return False

    def goto_error(self) -> bool:
        """Opens the first error's file and puts the cursor in it. Returns
        whether there was anywhere to go."""
        if len(self.build_pos_file) == 0:
            return False
        if not path.isfile(self.build_pos_file):
            return False
        self.open_file(self.build_pos_file)
        cv = self.cur_cv()
        if cv == None:
            return False
        cv.buf.move_to(self.build_pos_line - 1, self.build_pos_col - 1)
        cv.scroll_to_caret()
        # and the line stays MARKED in the gutter, so it can still be seen after
        # cursor sair dali
        cv.buf.clear_marks(core.MARK_ERROR)
        cv.buf.toggle_mark(self.build_pos_line - 1, core.MARK_ERROR)
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
            # F6: play. The app ASKS; whoever builds is the driver, in the same
            # event loop — the engine is a library (`packages/pbuild`) and not a
            # process, so the graph is a `dict` and not a stream of text.
            if self.build_busy:
                self.build_msg = "a build is already running"
            else:
                self.want_build = ""
                self.want_build_on = True
                self.want_run = cmd == 26
                self.build_msg = "building..."
                # the previous error leaves the gutter: it belongs to a build
                # that is no longer this one, and a stale mark is worse than none
                for t in self.tabs:
                    t.cv.buf.clear_marks(core.MARK_ERROR)
            self.update_status()
        elif cmd == 25:
            self.pal_build_default = False
            self.palette_open(PAL_BUILD)
        elif cmd == 30:
            # F6, the manifest "panel": OPEN the file. A text editor offering a
            # form to edit text would be one more layer between the person and
            # the file they are going to commit — and `pack.json` is small,
            # declarative and made to be read.
            self.open_file(path.join(self.root_dir, "pack.json"))
        elif cmd == 31:
            # what a form would do better than the text: guarantee the default
            # target EXISTS. The list comes from the graph, the same as `!`'s.
            if len(self.build_targets) == 0:
                self.build_msg = "I do not know this project's targets (the graph has not arrived yet)"
                self.update_status()
            else:
                self.pal_build_default = True
                self.palette_open(PAL_BUILD)
        elif cmd == 32:
            # and the other one: a dependency is not a line you write, it is one
            # you RESOLVE — `ppack` fetches, checks the hash, checks the signature
            # and locks it. Here only the name is asked for.
            self.ask("dependency (name@version)", 32)
        elif cmd == 27:
            self.want_clean = True
            self.build_msg = "a limpar..."
            self.update_status()
        elif cmd == 29:
            if not self.goto_error():
                self.build_msg = "no build error to go to"
                self.update_status()
        elif cmd == 28:
            # stopping is a REQUEST, not a killing: the executor finishes the
            # edge that is running and does not start another. Killing a `cc`
            # halfway leaves a truncated `.o`, which is exactly what the engine
            # refuses afterwards.
            #
            # The PROGRAM, that one dies now: it is the user's and not the build's.
            self.build_stop = True
            self.want_stop_run = True
            self.build_msg = "stopping after this edge..."
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
        """A file changed on disk: reloads what is clean, asks about what has
        local edits."""
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
                    cv.mtime = m      # they chose to keep it: do not ask again
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
        """The driver changed the zoom: the font cell belongs to the toolkit, so
        it comes in here and the layout is redone."""
        self.u.cell_w = cw
        self.u.cell_h = ch
        self.u.relayout()
        self.u.queue_redraw_tree(self.root)
        self.update_status()

    # ---------- atalhos globais ----------

    def key_shortcut(self, ev: pui.Event) -> bool:
        """True = consumed, and it does not reach the widget tree."""
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
        # 115: F2 is a shortcut WITHOUT ctrl (ctrl+F2 sets/clears the mark,
        # shift+F2 goes backwards) — it is the editor in P's bookmark navigation
        if ev.key == K_F2 and cv != None:
            if (ev.mods & 2) != 0:
                cv.toggle_bookmark()
            else:
                cv.goto_mark((ev.mods & 1) == 0)
            self.update_status()
            self.dirty_ui = True
            return True
        if (ev.mods & 2) == 0:              # without ctrl it is not a global shortcut
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
        """The cursor blink. Returns the instant of the last blink."""
        self.now_ms = now
        cv = self.cur_cv()
        if now - blink_at < BLINK_MS:
            return blink_at
        if cv != None and self.u.focus_get() == cv.id:
            cv.caret_on = not cv.caret_on
            self.u.queue_redraw(cv.id)
        return now

    def feed(self, ev: pui.Event) -> bool:
        """One event: the global shortcut first, otherwise the widget tree."""
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

    # ---------- the app's three widgets ----------

    def tab_at(self, r: pui.Rect, px: int, py: int) -> int:
        """The tab under a point (-1 = none); marks `tab_hover_x` if it hit the
        ×."""
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
            # modified mark / close button: a dot when dirty, an × when the
            # cursor is over it (Sublime's model)
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
            # only dirties when the state CHANGES (otherwise every move repaints)
            if hit != was_hover or self.tab_hover_x != was_x:
                self.tab_hover = hit
                self.u.queue_redraw(id)
            return hit >= 0
        if ev.kind != pui.EV_MOUSE_DOWN or hit < 0:
            return False
        if ev.button == 2 or self.tab_hover_x:
            self.close_tab(hit)        # the middle button or the × close the tab
        elif ev.button == 1:
            self.select_tab(hit)
        return True

    def tree_build(self, id: int):
        u = self.u
        r = u.rect_of(id)
        th = u.theme
        # no background and no header here: the panel (a box with a bg) carries
        # both, and the SPLIT's divider is the separator — this widget is only rows
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


# ---------- assembling the widget tree ----------
# It is `app.p`'s `init`, and the shape is the same: a PANEL at the root (which
# stacks the layout and the floating palette), the tab bar INSIDE the editor's
# column (not crossing the top, so the tree takes the full height, as in
# Sublime), and the search bar as the column's LAST child — which is what pins it
# to the footer.

def tab_width(u: pui.Ui, t: Tab) -> int:
    return u.text_w(t.title) + u.cell_w * 4


def tab_close_x(u: pui.Ui, x: int, w: int) -> int:
    return x + w - u.cell_w * 2


def new_app(u: pui.Ui, root_dir: str) -> App:
    app = App(u, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
              [], -1, -1, False, [], 0, root_dir, PAL_FILES, [], 0, 0, [],
              False, True, True, 0, "", "",
              "", False, False, False, "", False, False, [], 0, 0, "", "", 0, 0, 0, False,
              "", "", 0, "", False,
              None, None, None, None, None, None, None, None, None)

    app.root = u.panel(-1)
    col = u.box(app.root, True)
    app.split = u.split(col, False)
    u.set_expand(app.split, True, True)
    # the tree's PANEL is a box with a background: [ FOLDERS | rows ]. The
    # header is a real label, so it is the layout (and not a hand-written offset)
    # that decides where the rows begin.
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

    # the palette: the ROOT's last child, so it draws on top and wins the hit-test
    app.palette = u.custom(app.root, None)
    app.palinput = u.line_input(app.palette)
    u.on_changed(app.palinput, lambda wid, arg: app.palette_filter())
    u.on_submit(app.palinput, lambda wid, arg: app.palette_accept())
    u.on_cancel(app.palinput, lambda wid, arg: app.palette_close())
    u.set_visible(app.palette, False)

    # ---- the tab bar ----
    u.set_custom(app.tabbar,
                 lambda u2, id: pui.Size(0, u2.cell_h + 8),
                 lambda u2, id: app.tabbar_build(id),
                 lambda u2, id, ev: app.tabbar_input(id, ev),
                 None)
    # ---- the tree ----
    u.set_custom(app.tree,
                 lambda u2, id: pui.Size(u2.cell_w * TREE_MIN_CP, u2.cell_h),
                 lambda u2, id: app.tree_build(id),
                 lambda u2, id, ev: app.tree_input(id, ev),
                 None)
    # ---- the palette ----
    u.set_custom(app.palette,
                 lambda u2, id: pui.Size(0, 0),
                 lambda u2, id: app.pal_build(id),
                 lambda u2, id, ev: app.pal_input(id, ev),
                 lambda u2, id, r: app.pal_layout(id, r))
    app.tree_scan()
    return app
