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
import codeview as cvm
import core
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
    # The two below are GENERIC: whoever opens them supplies the list (or none)
    # and what to do with the answer. They used to be `PAL_BUILD` and `PAL_TEXT`
    # — a graph target and a dependency name — which put "what a build target is"
    # inside a palette that has no business knowing.
    PAL_LIST          # a list SOMEBODY ELSE supplied ('!' picks it too)
    PAL_ASK           # no list: the item IS what is being typed


struct ReadOut:
    """The answer to "give me this file's text", with the three states it really
    has instead of the two a `str` can carry.

    They used to be two, and `""` meant all of them: an empty file, a file that
    could not be decoded, and a file the driver had not read yet. The shell could
    not tell "I have nothing" from "there is nothing", so it asked the driver to
    read it again, for ever, every 500 ms, with no message. `touch x.p` was enough
    to reproduce it. A `.png` fell down the same hole — and had it opened, saving
    would have truncated it."""
    have: bool       # the driver has an ANSWER — either the text or a reason
    text: str
    why: str         # "" = it worked; anything else is why it did not


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


struct Command:
    """A palette entry: a name, what it does, and when it is available.

    A TABLE, and not a `switch` over an `int`. Two debts died with the switch: a
    thirty-four entry string with fixed indices, where a command's name and its
    number lived apart and had to be kept in step by hand; and the cascade that
    read them.

    And one thing became possible that was not: the IDE adds its own commands to
    this list without the shell ever hearing about the IDE. That is the seam the
    whitelist gate measures — `pcode` links the shell and not `ide.psc`."""
    name: str
    run: def(Shell)
    when: (def(Shell) -> bool)?     # None = always available


struct Shell:
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
    commands: list<Command>
    # PAL_LIST / PAL_ASK: what was supplied, what is being asked, and who wants
    # the answer. Three fields, and none of them knows what a build is.
    pal_items: list<PalItem>
    pal_prompt: str
    pal_answer: (def(str))?
    find_re: bool      # regex search (the query starts with '/')
    running: bool
    dirty_ui: bool     # a frame needs presenting
    now_ms: int        # the clock, which comes from the driver
    want_open: str     # 114: a file the app wants and the driver has to READ
    want_reload: list<str>   # ... and the ones whose cached text is STALE
    want_msg: str      # a message for the status bar (a write failure)
    # ---- the driver, injected by `app.psc` ----
    read_file: (def(str) -> ReadOut)?
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

    def do_read(self, p: str) -> ReadOut:
        f = self.read_file
        if f != None:
            return f(p)
        return ReadOut(False, "", "")

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
        r = self.do_read(p)
        # 114: READING is `await` in pscript (76.2), and this path is synchronous
        # on purpose (an index that waits forces every caller to wait). So the
        # app ASKS and the driver reads: `want_open` is the request, and the
        # driver calls `open_file` again with the answer already in hand.
        if not r.have:
            if path.isfile(p):
                self.want_open = p
            return
        if len(r.why) > 0:
            # a file that cannot be read gets NO tab. An empty tab over a `.png`
            # would truncate it on the next save, which is the worst thing an
            # editor can do to a file it did not understand.
            self.want_msg = p + ": " + r.why
            return
        cv = cvm.cv_create(self.u, self.cvhost)
        cv.load_text(p, r.text, self.do_mtime(p))
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
        elif mode == PAL_LIST:
            self.u.set_text(self.palinput, "!")
        self.palsel = 0
        self.paltop = 0
        self.u.set_visible(self.palette, True)
        self.u.focus_set(self.palinput)
        self.palette_filter()
        self.dirty_ui = True

    def palette_ask(self, prompt: str, answer: def(str)):
        """Opens the palette ASKING, instead of offering, and calls back with
        what was typed.

        The editor has no dialog boxes, and that is not a gap: it has an input
        line that already serves to look for a file, a command and a line number
        — and asking is the fourth thing you do with it. A modal window with one
        field and two buttons would be a new mechanism for what already exists,
        and would force a decision about where it sits, how big it is and what
        happens when the window shrinks.

        The callback is what makes this usable by somebody the shell does not
        know: the IDE asks for a dependency here without the shell learning what
        a dependency is."""
        self.pal_prompt = prompt
        self.pal_answer = answer
        self.palette_open(PAL_ASK)

    def palette_choose(self, prompt: str, items: list<PalItem>, answer: def(str)):
        """The same, over a list SOMEBODY ELSE supplied."""
        self.pal_prompt = prompt
        self.pal_items = items
        self.pal_answer = answer
        self.palette_open(PAL_LIST)

    def palette_close(self):
        self.u.set_visible(self.palette, False)
        self.palitems = []
        if self.cur >= 0:
            self.u.focus_set(self.tabs[self.cur].cv.id)
        self.dirty_ui = True

    def palette_filter(self):
        q = self.u.text_of(self.palinput)
        if self.palmode == PAL_ASK:
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
            # `!` picks from the SUPPLIED list. The prefix is Sublime's idea —
            # whoever knows the name types it, whoever does not sees the list.
            self.palmode = PAL_LIST
            q = q[1:len(q)]
        else:
            self.palmode = PAL_FILES
        self.palitems = []
        self.palsel = 0
        self.paltop = 0
        match self.palmode:
            case PAL_COMMANDS:
                # the TABLE is the list, and the payload is the NAME: no second
                # place where a command's number and its label have to agree
                for c in self.commands:
                    w = c.when
                    if w != None and not w(self):
                        continue
                    sc = fuzzy_score(c.name, q)
                    if sc >= 0:
                        self.palitems.append(PalItem(c.name, c.name, sc))
            case PAL_GOTO:
                self.palitems.append(PalItem("go to line " + (q if len(q) > 0 else "…"), q, 0))
            case PAL_ASK:
                # there is no list: the item IS what is being typed. It exists
                # so the palette can ASK, and not only offer.
                rot = self.pal_prompt + ": " + (q if len(q) > 0 else "…")
                self.palitems.append(PalItem(rot, q, 0))
            case PAL_LIST:
                # the items were SUPPLIED. The editor does not know what they
                # are — for the IDE they are graph targets, and it stays that way
                for it3 in self.pal_items:
                    sc3 = fuzzy_score(it3.label, q)
                    if sc3 >= 0:
                        self.palitems.append(PalItem(it3.label, it3.payload, sc3))
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
                self.run_named(payload)
            case PAL_ASK:
                a = self.pal_answer
                if len(payload) > 0 and a != None:
                    a(payload)
            case PAL_LIST:
                a2 = self.pal_answer
                if a2 != None:
                    a2(payload)
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

    # ---------- commands ----------

    def add_commands(self, cs: list<Command>):
        """How the IDE extends the editor, and the only direction that exists:
        `ide.psc` knows `shell.psc`, and `shell.psc` has never heard of it."""
        for c in cs:
            self.commands.append(c)

    def run_named(self, name: str) -> bool:
        """Runs a command by NAME. False when there is none, or when its `when`
        says it is not available right now."""
        for c in self.commands:
            if c.name != name:
                continue
            w = c.when
            if w != None and not w(self):
                return False
            f = c.run
            f(self)
            self.dirty_ui = True
            return True
        return False

    # ---------- what the editor's own commands do ----------
    #
    # Small methods rather than bodies inside the table: a lambda that is one
    # call reads as the name of the thing, and the table stays a table.

    def on_cv(self, f: def(cvm.CodeView)):
        """Runs `f` on the current editing widget, when there is one."""
        cv = self.cur_cv()
        if cv != None:
            f(cv)

    def save_all(self):
        for i in range(len(self.tabs)):
            if not self.save_tab(i):
                self.want_msg = "could not save " + self.tabs[i].cv.path
        self.u.queue_redraw(self.tabbar)

    def clear_bookmarks(self, cv: cvm.CodeView):
        cv.buf.clear_marks(core.MARK_BOOK)
        self.u.queue_redraw(cv.id)

    def toggle_tree(self):
        self.u.set_visible(self.tree_pane, not self.u.is_visible(self.tree_pane))

    def request_reload(self, p: str):
        """Asks the driver to read `p` FROM DISK again.

        It does not read here (reading is `await`, 76.2) and it must not use what
        the driver already has: the cache holds what was read when the file was
        OPENED, and a reload exists precisely because the disk stopped matching
        that. Reading the cache made "Reload File" and the external-change reload
        both return the OLD text.

        A LIST and not one field: `check_external` walks every tab, and several
        files can have changed at once — a `git checkout` changes all of them."""
        if len(p) > 0 and p not in self.want_reload:
            self.want_reload.append(p)

    def reload_cur(self):
        cv = self.cur_cv()
        if cv != None:
            self.request_reload(cv.path)

    def reload_now(self, p: str, text: str):
        """The driver came back with fresh text for `p` (see `reload_cur`).

        It finds the tab by PATH and not by "the current one": between asking and
        being served there is a turn of the event loop, and the answer belongs to
        the file that was asked for."""
        for i in range(len(self.tabs)):
            cv = self.tabs[i].cv
            if cv.path == p:
                keep = cv.top
                cv.load_text(p, text, self.do_mtime(p))
                cv.top = keep
                self.dirty_ui = True
                return

    def check_external(self):
        """A file changed on disk: reloads what is clean, asks about what has
        local edits.

        It no longer SWITCHES to the tab it is reloading. That used to happen
        because the reload worked on "the current tab", and being yanked to
        another file because something touched it in the background is not what
        anybody asked for."""
        for i in range(len(self.tabs)):
            cv = self.tabs[i].cv
            if len(cv.path) == 0 or not path.exists(cv.path):
                continue
            m = self.do_mtime(cv.path)
            if m == cv.mtime:
                continue
            if not cv.buf.dirty:
                self.request_reload(cv.path)
            else:
                if self.do_confirm_reload(self.tabs[i].title):
                    self.request_reload(cv.path)
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
            self.run_named("Save All" if shift else "Save")
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
            self.toggle_tree()
        elif k == ord("="):
            self.do_zoom(1)
        elif k == ord("-"):
            self.do_zoom(-1)
        elif k == ord("0"):
            self.do_zoom(0)
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


def new_shell(u: pui.Ui, root_dir: str) -> Shell:
    sh = Shell(u, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
              [], -1, -1, False, [], 0, root_dir, PAL_FILES, [], 0, 0, [], [],
              [], "", None,
              False, True, True, 0, "", [], "",
              None, None, None, None, None, None, None, None, None)

    sh.root = u.panel(-1)
    col = u.box(sh.root, True)
    sh.split = u.split(col, False)
    u.set_expand(sh.split, True, True)
    # the tree's PANEL is a box with a background: [ FOLDERS | rows ]. The
    # header is a real label, so it is the layout (and not a hand-written offset)
    # that decides where the rows begin.
    sh.tree_pane = u.box(sh.split, True)
    u.set_bg(sh.tree_pane, u.theme.panel)
    head = u.label(sh.tree_pane, "FOLDERS")
    u.set_pad(head, 6)
    u.set_min(head, 0, u.cell_h + 8)
    sh.tree = u.custom(sh.tree_pane, None)
    u.set_expand(sh.tree, True, True)
    sh.editors = u.box(sh.split, True)
    u.set_expand(sh.editors, True, True)
    u.split_set(sh.split, 220)
    sh.tabbar = u.custom(sh.editors, None)
    sh.cvhost = u.box(sh.editors, True)
    u.set_expand(sh.cvhost, True, True)

    sh.findbar = u.box(sh.editors, False)
    u.label(sh.findbar, "find:")
    sh.findinput = u.line_input(sh.findbar)
    u.set_expand(sh.findinput, True, False)
    u.on_changed(sh.findinput, lambda wid, arg: sh.find_changed())
    u.on_submit(sh.findinput, lambda wid, arg: sh.find_step(True))
    u.on_cancel(sh.findinput, lambda wid, arg: sh.find_close())
    u.set_visible(sh.findbar, False)

    sh.status = u.label(col, "")
    u.set_pad(sh.status, 6)

    # the palette: the ROOT's last child, so it draws on top and wins the hit-test
    sh.palette = u.custom(sh.root, None)
    sh.palinput = u.line_input(sh.palette)
    u.on_changed(sh.palinput, lambda wid, arg: sh.palette_filter())
    u.on_submit(sh.palinput, lambda wid, arg: sh.palette_accept())
    u.on_cancel(sh.palinput, lambda wid, arg: sh.palette_close())
    u.set_visible(sh.palette, False)

    # ---- the tab bar ----
    u.set_custom(sh.tabbar,
                 lambda u2, id: pui.Size(0, u2.cell_h + 8),
                 lambda u2, id: sh.tabbar_build(id),
                 lambda u2, id, ev: sh.tabbar_input(id, ev),
                 None)
    # ---- the tree ----
    u.set_custom(sh.tree,
                 lambda u2, id: pui.Size(u2.cell_w * TREE_MIN_CP, u2.cell_h),
                 lambda u2, id: sh.tree_build(id),
                 lambda u2, id, ev: sh.tree_input(id, ev),
                 None)
    # ---- the palette ----
    u.set_custom(sh.palette,
                 lambda u2, id: pui.Size(0, 0),
                 lambda u2, id: sh.pal_build(id),
                 lambda u2, id, ev: sh.pal_input(id, ev),
                 lambda u2, id, r: sh.pal_layout(id, r))
    sh.add_commands(editor_commands())
    sh.tree_scan()
    return sh


def has_cv(s: Shell) -> bool:
    """The guard for everything that works on a buffer. It used to be an
    `elif cv != None:` wrapped around half of a `switch`; here it is a field of
    each command, and the palette can grey out what is unavailable."""
    return s.cur_cv() != None


def editor_commands() -> list<Command>:
    """The twenty-five the EDITOR has.

    Everything here works on a buffer, a tab or the tree. Nothing here knows what
    a build, a target or a package is — that is `ide.psc`, and it adds its own to
    this list at startup."""
    return [
        Command("Save",             lambda s: s.save_cur(), None),
        Command("Save All",         lambda s: s.save_all(), None),
        Command("Close Tab",        lambda s: s.close_tab(s.cur), None),
        Command("Reload File",      lambda s: s.reload_cur(), None),
        Command("Toggle File Tree", lambda s: s.toggle_tree(), None),
        Command("Zoom In",          lambda s: s.do_zoom(1), None),
        Command("Zoom Out",         lambda s: s.do_zoom(-1), None),
        Command("Zoom Reset",       lambda s: s.do_zoom(0), None),
        Command("Find",             lambda s: s.find_open(), None),
        Command("Go To Line",       lambda s: s.palette_open(PAL_GOTO), None),
        Command("Quit",             lambda s: s.try_quit(), None),
        # `Fold` and `Unfold` are the same toggle under two names: whoever wants
        # to unfold looks for "unfold", and a palette that only knew "fold"
        # would answer nothing
        Command("Fold",             lambda s: s.on_cv(lambda c: c.toggle_fold_at_caret()), has_cv),
        Command("Unfold",           lambda s: s.on_cv(lambda c: c.toggle_fold_at_caret()), has_cv),
        Command("Fold All",         lambda s: s.on_cv(lambda c: c.fold_all()), has_cv),
        Command("Unfold All",       lambda s: s.on_cv(lambda c: c.unfold_all()), has_cv),
        Command("Toggle Comment",   lambda s: s.on_cv(lambda c: c.toggle_comment(s.now_ms)), has_cv),
        Command("Move Line Up",     lambda s: s.on_cv(lambda c: c.move_lines(-1, s.now_ms)), has_cv),
        Command("Move Line Down",   lambda s: s.on_cv(lambda c: c.move_lines(1, s.now_ms)), has_cv),
        Command("Duplicate Line",   lambda s: s.on_cv(lambda c: c.duplicate_lines(s.now_ms)), has_cv),
        Command("Delete Line",      lambda s: s.on_cv(lambda c: c.delete_lines(s.now_ms)), has_cv),
        Command("Join Lines",       lambda s: s.on_cv(lambda c: c.join_lines(s.now_ms)), has_cv),
        Command("Toggle Bookmark",  lambda s: s.on_cv(lambda c: c.toggle_bookmark()), has_cv),
        Command("Next Bookmark",    lambda s: s.on_cv(lambda c: c.goto_mark(True)), has_cv),
        Command("Clear Bookmarks",  lambda s: s.on_cv(lambda c: s.clear_bookmarks(c)), has_cv),
        Command("Toggle Minimap",   lambda s: s.on_cv(lambda c: c.toggle_minimap()), has_cv),
    ]
