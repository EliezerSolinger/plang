"""The IDE half: build, run, the manifest — and, later, the panels.

It **composes** the shell instead of living inside it, and the dependency runs
one way only: `ide.psc` knows `shell.psc`, and `shell.psc` has never heard of
`ide.psc`. That is what makes `pcode` possible, and it is what the whitelist gate
measures — `pcode` reads twenty-six files and this is not one of them.

The alternative was considered and refused (battery 124): an optional `ide` field
inside `Shell` would have been a much smaller change and would have proved
nothing, because the module would still be LINKED for the type to exist. That is
separation at run time; this is separation at link time, and only the second one
is a boundary.

The pattern for everything here is the shell's own: **the editor ASKS and the
driver serves.** Nothing in this file does I/O or waits — `pstudio.psc` reads the
requests in the event loop, does the awaiting, and writes back. The reason is the
editor's logic being synchronous on purpose: an `await` in the middle of a
keystroke would make every caller wait.
"""
import <pui> as pui
import shell as sh_mod
import icon_ids as ico
import complete as cmp
import config as cfg
import terminal as trm
import sys
import core
import path


struct BuildEdge:
    """One edge of the build graph, as it RAN.

    The engine already says all of this — `pforge` reports a start, an end, a
    status, what the command printed and how long it took. It was being thrown
    away and reduced to a `[41/86]` in the status bar, which is the one shape of
    it a person cannot click on."""
    id: int          # the engine's, so the end can find the start
    what: str        # what it said it was doing
    status: int      # 0 = ok, -1 = still running
    ms: int
    out: str         # what the command printed
    # ... and where its first error was, when it had one
    file: str
    line: int
    col: int


struct Ide:
    """The twenty-one fields that used to live inside the editor's own struct.

    They are forty per cent of what `App` had, and none of them means anything to
    somebody who is only editing text."""
    sh: sh_mod.Shell

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
    # where the build's first error points. The editor OPENS the file and puts
    # the cursor there — which is what "clicking the error" does, without the click.
    build_pos_file: str
    build_pos_line: int
    build_pos_col: int
    # the program `Run` launched. Zero when there is none — and the number is the
    # PID, because that is what `os.spawn` returns.
    run_pid: int
    want_stop_run: bool
    # the MANIFEST. The editor does not invent a form — it already is a text
    # editor, and `pack.json` is text. What the palette adds is what is tedious to
    # write by hand and easy to write wrong: the default target (which has to be a
    # target THAT EXISTS, and the graph knows which ones do) and a dependency
    # (which has to be resolved, checked and locked, and `pforge` knows how).
    want_manifest_default: str      # "" = nothing to ask for
    want_manifest_dep: str          # "name@version"

    # ---------- F6: the shell ----------
    # The three slots the editor left empty, filled. `pcode` has the same three
    # and leaves them shut, which is what the whitelist gate measures.
    outline: int          # the WK_LIST inside `sh.side`
    outline_syms: list<cmp.CSym>   # what it is showing, in file order
    outline_ver: int      # the buffer version it came from
    outline_path: str     # ... and which file, so a tab change rebuilds it
    dock_tabs: int        # the strip at the top of the bottom dock
    dock_body: int        # what is under it
    dock_page: int        # which panel is up
    dock_labels: list<int>  # one label per page: F9 and F10 replace two of them
    # F7: the Build panel. The engine's report, kept instead of collapsed.
    build_edges: list<BuildEdge>
    build_bar: int        # a WK_PROGRESS, because a LENGTH is seen and a number is read
    build_list: int       # the edges, one row each, the failing ones clickable
    tb_target: int        # the toolbar button that says which target `Build` builds
    # F8: the terminal. The GRID is the editor's — it is a parser and a screen,
    # and neither of those needs to wait for anything. What has to wait is the
    # pseudo-terminal on the other end, so that belongs to the driver and what
    # is here is three requests.
    term: trm.Term
    term_node: int
    term_live: bool
    want_term_cmd: list<str>   # [] = nothing to start
    want_term_in: str          # what the keyboard typed, on its way to the child
    want_term_stop: bool
    # `.pstudio.json`, read once by the driver and written back when a pane moves
    conf: cfg.Config
    want_conf_save: bool

    # ---------- F6: the panes ----------

    def toggle_outline(self):
        u = self.sh.u
        u.set_visible(self.sh.side, not u.is_visible(self.sh.side))
        self.conf.outline_open = u.is_visible(self.sh.side)
        self.want_conf_save = True
        self.sh.dirty_ui = True

    def toggle_dock(self):
        u = self.sh.u
        u.set_visible(self.sh.dock, not u.is_visible(self.sh.dock))
        self.conf.dock_open = u.is_visible(self.sh.dock)
        self.want_conf_save = True
        self.sh.dirty_ui = True

    def toggle_toolbar(self):
        u = self.sh.u
        u.set_visible(self.sh.topbar, not u.is_visible(self.sh.topbar))
        self.sh.dirty_ui = True

    def dock_refresh(self):
        names = dock_pages()
        icons = dock_icons()
        items: list<pui.TabItem> = []
        for i in range(len(names)):
            items.append(pui.TabItem(names[i], icons[i], False, False))
        self.sh.u.tabs_set(self.dock_tabs, items)
        self.sh.u.tabs_set_sel(self.dock_tabs, self.dock_page)

    def dock_show(self, i: int):
        """One page visible at a time. The pages are SIBLINGS and not a stack
        widget, because a stack would be a fourth container that does what
        `set_visible` already does."""
        if i < 0 or i >= len(self.dock_labels):
            return
        self.dock_page = i
        for k in range(len(self.dock_labels)):
            self.sh.u.set_visible(self.dock_labels[k], k == i)
        self.sh.u.tabs_set_sel(self.dock_tabs, i)
        self.sh.dirty_ui = True

    def dock_open_at(self, i: int):
        """Bring a page up, opening the dock if it was shut. It is what a build
        does when it starts, and what a failing test does when it lands."""
        if not self.sh.u.is_visible(self.sh.dock):
            self.sh.u.set_visible(self.sh.dock, True)
            self.conf.dock_open = True
        self.dock_show(i)

    # ---------- F8: the terminal ----------

    def open_terminal(self):
        """A shell, in the dock. `Run` uses the same door with another command —
        which is the point of `Run` running in a terminal at all: a program with
        a real TTY behaves the way it behaves in a shell, and one without it
        does not."""
        self.dock_open_at(PAGE_TERMINAL)
        self.sh.u.focus_set(self.term_node)
        if not self.term_live:
            sh_env = os_env_shell()
            self.want_term_cmd = [sh_env]
        self.sh.dirty_ui = True

    def run_in_terminal(self, cmd: list<str>):
        self.dock_open_at(PAGE_TERMINAL)
        self.sh.u.focus_set(self.term_node)
        self.want_term_cmd = cmd
        self.sh.dirty_ui = True

    def stop_terminal(self):
        self.want_term_stop = True
        self.sh.dirty_ui = True

    def term_input(self, ev: pui.Event) -> bool:
        """The keyboard, as the bytes a program on the other end expects.

        This is the half of a terminal nobody remembers until an arrow key
        prints `^[[A` into somebody's shell."""
        if ev.kind == pui.EV_WHEEL:
            self.term.scroll_view(ev.wheel * 3)
            self.sh.dirty_ui = True
            return True
        if ev.kind == pui.EV_MOUSE_DOWN:
            self.sh.u.focus_set(self.term_node)
            return True
        if ev.kind == pui.EV_TEXT:
            self.want_term_in += trm.key_bytes(0, ev.mods, ev.cp)
            return True
        if ev.kind == pui.EV_KEY:
            if not self.term_live:
                return False
            b = trm.key_bytes(ev.key, ev.mods, 0)
            if len(b) == 0:
                return False
            # anything typed brings the view back to the bottom: a shell that
            # answered a key somewhere above what is on screen is a shell nobody
            # can follow
            self.term.scroll_view(-self.term.view)
            self.want_term_in += b
            return True
        return False

    # ---------- F7: the Build panel ----------

    def build_reset(self, target: str):
        self.build_edges = []
        self.build_error = ""
        self.build_pos_file = ""
        self.build_done = 0
        self.build_total = 0
        self.set_target_label()
        self.build_refresh()

    def edge_started(self, id: int, what: str):
        self.build_edges.append(BuildEdge(id, what, -1, 0, "", "", 0, 0))
        self.build_refresh()

    def edge_ended(self, id: int, status: int, out: str, ms: int):
        for i in range(len(self.build_edges) - 1, -1, -1):
            e = self.build_edges[i]
            if e.id != id or e.status != -1:
                continue
            e.status = status
            e.ms = ms
            e.out = out.strip()
            if status != 0:
                p = first_position(out)
                if len(p) == 3:
                    e.file = p[0]
                    e.line = int(p[1])
                    e.col = int(p[2])
            break
        self.build_refresh()

    def build_refresh(self):
        if self.build_bar < 0:
            return
        u = self.sh.u
        cap = self.build_msg
        if self.build_total > 0:
            cap = "[" + str(self.build_done) + "/" + str(self.build_total) + "] " + cap
        elif len(cap) == 0 and len(self.build_edges) == 0:
            # an empty grey strip says nothing; the other three pages say they
            # are empty out loud, and this one should too
            cap = "(nothing built yet — press Build)"
        u.progress_set(self.build_bar, self.build_done, self.build_total, cap)
        rows: list<pui.ListRow> = []
        for e in self.build_edges:
            tone = pui.TONE_DIM
            icon = ico.ICO_CIRCLE_DOT
            detail = ""
            if e.status == 0:
                tone = pui.TONE_NORMAL
                icon = ico.ICO_CHECK
                detail = str(e.ms) + " ms"
            elif e.status > 0:
                tone = pui.TONE_BAD
                icon = ico.ICO_X
                detail = "failed"
            rows.append(pui.ListRow(e.what, detail, 0, "", icon, tone, False))
            # what a failing command PRINTED, under it and indented. It is the
            # only thing anybody wants from a build that broke, and putting it
            # anywhere else means a second place to look.
            if e.status > 0 and len(e.out) > 0:
                for ln in e.out.split("\n"):
                    if len(ln.strip()) == 0:
                        continue
                    rows.append(pui.ListRow(ln, "", 1, "", pui.ICON_NONE,
                                            pui.TONE_WARN, False))
        u.list_set(self.build_list, rows)
        self.sh.dirty_ui = True

    def build_row_picked(self, row: int):
        """A row of the panel, clicked. The ones with a position go there."""
        i = 0
        for e in self.build_edges:
            if i == row:
                if len(e.file) > 0:
                    self.sh.goto_hit(e.file + ":" + str(e.line) + ":" + str(e.col))
                return
            i += 1
            if e.status > 0 and len(e.out) > 0:
                for ln in e.out.split("\n"):
                    if len(ln.strip()) == 0:
                        continue
                    if i == row:
                        # a line of output: it may carry its own position, and
                        # that is more precise than the edge's first error
                        p = first_position(ln)
                        if len(p) == 3:
                            self.sh.goto_hit(p[0] + ":" + p[1] + ":" + p[2])
                        elif len(e.file) > 0:
                            self.sh.goto_hit(e.file + ":" + str(e.line) + ":" + str(e.col))
                        return
                    i += 1

    def set_target_label(self):
        if self.tb_target < 0:
            return
        t = self.want_build
        if len(t) == 0:
            t = "(default)"
        else:
            cut = t.rfind("/")
            if cut >= 0:
                t = t[cut + 1:]
        self.sh.u.set_text(self.tb_target, t)

    # ---------- F6: the outline ----------

    def outline_sync(self):
        """Rebuilt when the buffer changed, and not before.

        It is fed by the COMPLETION index, which already scans the buffer and
        recovers every declaration on each relex. An outline is that list ordered
        by position instead of by relevance: no new analysis, and it works on a
        file that was never saved."""
        cv = self.sh.cur_cv()
        if cv == None:
            if len(self.outline_syms) > 0:
                self.outline_syms = []
                self.outline_ver = -1
                self.outline_path = ""
                self.sh.u.list_set(self.outline, [])
            return
        if cv.path == self.outline_path and cv.buf.version == self.outline_ver:
            return
        if cv.index.is_stale(cv.buf):
            cv.index.build(cv.buf, cv.sources)
        self.outline_path = cv.path
        self.outline_ver = cv.buf.version
        self.outline_syms = cv.index.outline()
        rows: list<pui.ListRow> = []
        for sy in self.outline_syms:
            rows.append(pui.ListRow(sy.name, str(sy.line), 1 if sy.kind == cmp.SYM_MEMBER else 0,
                                    "", outline_icon(sy.kind), pui.TONE_NORMAL, False))
        self.sh.u.list_set(self.outline, rows)

    def outline_picked(self, i: int):
        if i < 0 or i >= len(self.outline_syms):
            return
        cv = self.sh.cur_cv()
        if cv == None:
            return
        cv.buf.move_to(self.outline_syms[i].line - 1, 0)
        cv.scroll_to_caret()
        self.sh.update_status()
        self.sh.dirty_ui = True

    # ---------- the build error, as a position ----------

    def mark_error(self, text: str) -> bool:
        """`file:line:column: error: message` — the format the compiler already
        uses, and that `pforge` copied on purpose for its own errors.

        Keeping the POSITION instead of only the text is what separates a status
        bar from an IDE: with it the editor opens the file and puts the cursor
        there. A line that does not have this shape is ignored — a `cc`'s output
        has plenty that is not a diagnostic."""
        p = first_position(text)
        if len(p) != 3:
            return False
        self.build_pos_file = p[0]
        self.build_pos_line = int(p[1])
        self.build_pos_col = int(p[2])
        return True

    def goto_error(self) -> bool:
        """Opens the first error's file and puts the cursor in it. Returns
        whether there was anywhere to go."""
        if len(self.build_pos_file) == 0:
            return False
        if not path.isfile(self.build_pos_file):
            return False
        self.sh.open_file(self.build_pos_file)
        cv = self.sh.cur_cv()
        if cv == None:
            return False
        cv.buf.move_to(self.build_pos_line - 1, self.build_pos_col - 1)
        cv.scroll_to_caret()
        # and the line stays MARKED in the gutter, so it can still be seen once
        # the cursor has moved away
        cv.buf.clear_marks(core.MARK_ERROR)
        cv.buf.toggle_mark(self.build_pos_line - 1, core.MARK_ERROR)
        return True

    # ---------- what the commands do ----------

    def start_build(self, run_after: bool):
        """Play. The app ASKS; whoever builds is the driver, in the same event
        loop — the engine is a library (`packages/pforge`) and not a process, so
        the graph is a `dict` and not a stream of text."""
        if self.build_busy:
            self.build_msg = "a build is already running"
            return
        self.want_build_on = True
        self.want_run = run_after
        self.build_msg = "building..."
        # the previous error leaves the gutter: it belongs to a build that is no
        # longer this one, and a stale mark is worse than none
        for t in self.sh.tabs:
            t.cv.buf.clear_marks(core.MARK_ERROR)

    def build_named(self, target: str):
        if self.build_busy:
            self.build_msg = "a build is already running"
            return
        self.want_build = target
        self.want_build_on = True
        self.want_run = False
        self.set_target_label()
        self.build_msg = "building " + target + "..."

    def targets_as_items(self) -> list<sh_mod.PalItem>:
        out: list<sh_mod.PalItem> = []
        for t in self.build_targets:
            out.append(sh_mod.PalItem(t, t, 0))
        return out

    def ask_target(self):
        """`!` picks a graph TARGET. The list comes from the graph, which the
        driver put here — the editor does not know what this project builds."""
        self.sh.palette_choose("target", self.targets_as_items(),
                               lambda t: self.build_named(t))

    def ask_default_target(self):
        """What a form would do better than the text: guarantee the default
        target EXISTS. The list is the same one `!` offers."""
        if len(self.build_targets) == 0:
            self.build_msg = "I do not know this project's targets (the graph has not arrived yet)"
            return
        self.sh.palette_choose("default target", self.targets_as_items(),
                               lambda t: self.set_default_target(t))

    def set_default_target(self, target: str):
        self.want_manifest_default = target
        self.build_msg = "writing the default target..."

    def ask_dependency(self):
        """A dependency is not a line you write, it is one you RESOLVE — `pforge`
        fetches it, checks the hash, checks the signature and locks it. Here only
        the name is asked for."""
        self.sh.palette_ask("dependency (name@version)", lambda t: self.add_dependency(t))

    def add_dependency(self, spec: str):
        if "@" not in spec:
            self.build_msg = "a dependency is `name@version` — v1 has no resolver"
            return
        self.want_manifest_dep = spec
        self.build_msg = "adding " + spec + "..."

    def open_manifest(self):
        """The manifest "panel": OPEN the file. A text editor offering a form to
        edit text would be one more layer between the person and the file they
        are going to commit — and `pack.json` is small, declarative and made to
        be read."""
        self.sh.open_file(path.join(self.sh.root_dir, "pack.json"))

    def clean(self):
        self.want_clean = True
        self.build_msg = "cleaning..."

    def stop(self):
        """Stopping is a REQUEST, not a killing: the executor finishes the edge
        that is running and does not start another. Killing a `cc` halfway leaves
        a truncated `.o`, which is exactly what the engine refuses afterwards.

        The PROGRAM, that one dies now: it is the user's, not the build's."""
        self.build_stop = True
        self.want_stop_run = True
        self.build_msg = "stopping after this edge..."

    def go_to_error(self):
        if not self.goto_error():
            self.build_msg = "no build error to go to"


def new_ide(sh: sh_mod.Shell) -> Ide:
    """Builds the IDE over an editor, and registers its nine commands.

    Two lines, and they are the whole seam: `pcode.psc` does not have them."""
    ide = Ide(sh, "", False, False, False, "", False, False, [], 0, 0, "",
              "", 0, 0, 0, False, "", "",
              -1, [], -1, "", -1, -1, 0, [], [], -1, -1, -1,
              trm.new_term(80, 24), -1, False, [], "", False,
              cfg.default_config(), False)
    sh.add_commands(ide_commands(ide))
    build_shell(ide)
    return ide


def ide_commands(ide: Ide) -> list<sh_mod.Command>:
    """The nine the IDE adds. They close over `ide`, which is how the shell runs
    them while knowing nothing about it."""
    return [
        sh_mod.Command("Build",     lambda s: ide.start_build(False), None),
        sh_mod.Command("Run",       lambda s: ide.start_build(True), None),
        sh_mod.Command("Build Target...", lambda s: ide.ask_target(), None),
        sh_mod.Command("Clean",     lambda s: ide.clean(), None),
        sh_mod.Command("Stop Build", lambda s: ide.stop(), None),
        sh_mod.Command("Go To Build Error", lambda s: ide.go_to_error(), None),
        sh_mod.Command("Manifest: Open pack.json", lambda s: ide.open_manifest(), None),
        sh_mod.Command("Manifest: Set Default Target...", lambda s: ide.ask_default_target(), None),
        sh_mod.Command("Manifest: Add Dependency...", lambda s: ide.ask_dependency(), None),
        sh_mod.Command("Toggle Outline", lambda s: ide.toggle_outline(), None),
        sh_mod.Command("Toggle Panel", lambda s: ide.toggle_dock(), None),
        sh_mod.Command("Toggle Toolbar", lambda s: ide.toggle_toolbar(), None),
        sh_mod.Command("Terminal", lambda s: ide.open_terminal(), None),
        sh_mod.Command("Terminal: Stop", lambda s: ide.stop_terminal(), None),
    ]


# ---------- F6: the shell ----------
#
# The layout, in the words that chose it: a toolbar on top, the tree on the left,
# the editor in the middle, the outline on the right, a dock of tabs at the
# bottom. The panes are EMPTY on purpose — the point of building them now is to
# find out early whether a two-way `SPLIT` nested twice is enough for four zones,
# and what it costs for one of them to collapse and come back.
#
# It turned out to cost one defect: a split drew its divider even when only one
# child was visible, so a collapsed pane left a line across the middle of its
# neighbour with nothing to drag. That is in `pui` now, where it belongs.

# what the bottom dock offers. Build is real since F7; Tests and Packages are
# still labels, and F9 and F10 replace them.
const PAGE_BUILD: int = 0
const PAGE_PROBLEMS: int = 1
const PAGE_TERMINAL: int = 4


def dock_pages() -> list<str>:
    return ["Build", "Problems", "Tests", "Packages", "Terminal"]


def dock_icons() -> list<int>:
    return [ico.ICO_HAMMER, ico.ICO_TRIANGLE_ALERT, ico.ICO_FLASK_CONICAL,
            ico.ICO_PACKAGE, ico.ICO_TERMINAL]


private def tool(ide: Ide, icon: int, command: str) -> int:
    """One toolbar button. It runs a COMMAND by name and nothing else.

    That is what the F2 table bought: a button is a picture plus a string, the
    palette offers the same string, and `.pstudio.json` can bind a key to it.
    Three ways in, one implementation."""
    u = ide.sh.u
    b = u.button(ide.sh.topbar, "")
    u.set_icon(b, icon)
    u.on_click(b, lambda id, arg: ide.sh.run_named(command))
    return b


def build_shell(ide: Ide):
    u = ide.sh.u
    sh = ide.sh

    # ---- the toolbar ----
    u.set_visible(sh.topbar, True)
    u.set_bg(sh.topbar, u.theme.panel)
    tool(ide, ico.ICO_HAMMER, "Build")
    # ... and which target it builds. It opens the palette's target list rather
    # than a dropdown of its own: the palette already picks from a list supplied
    # by somebody else, it filters as you type, and a second list-picking widget
    # would be the thing F5 spent a phase removing.
    ide.tb_target = u.button(sh.topbar, "")
    u.set_icon(ide.tb_target, ico.ICO_CHEVRON_DOWN)
    u.on_click(ide.tb_target, lambda id, arg: sh.run_named("Build Target..."))
    tool(ide, ico.ICO_PLAY, "Run")
    tool(ide, ico.ICO_SQUARE, "Stop Build")
    tool(ide, ico.ICO_TRASH_2, "Clean")
    tool(ide, ico.ICO_SEARCH, "Find in Project")
    tool(ide, ico.ICO_LIST_TREE, "Toggle Outline")
    tool(ide, ico.ICO_PANEL_BOTTOM, "Toggle Panel")
    tool(ide, ico.ICO_SUN, "Toggle Theme")

    # ---- the outline, on the right ----
    head = u.label(sh.side, "OUTLINE")
    u.set_pad(head, 6)
    u.set_min(head, 0, u.cell_h + 8)
    ide.outline = u.list(sh.side)
    u.set_expand(ide.outline, True, True)
    u.on_submit(ide.outline, lambda id, row: ide.outline_picked(row))
    u.set_visible(sh.side, True)
    u.split_set(sh.rsplit, 700)

    # ---- the dock, at the bottom ----
    u.set_visible(sh.dock, True)
    ide.dock_tabs = u.tabs(sh.dock)
    u.on_submit(ide.dock_tabs, lambda id, i: ide.dock_show(i))
    ide.dock_body = u.box(sh.dock, True)
    u.set_expand(ide.dock_body, True, True)
    names = dock_pages()
    for i in range(len(names)):
        if i == PAGE_TERMINAL:
            # The one widget that draws itself DURING the draw. An 80x24 grid
            # with a background per cell is 1 920 rectangles plus 1 920 glyphs,
            # and retaining that list between frames would cost more than the
            # text it shows. It is still the painter it is handed — see
            # `set_paint`.
            tn = u.custom(ide.dock_body, None)
            u.set_expand(tn, True, True)
            u.set_focusable(tn, True)
            u.set_custom(tn,
                         lambda u2, id: pui.Size(u2.cell_w * 20, u2.cell_h * 4),
                         None,
                         lambda u2, id, ev: ide.term_input(ev),
                         None)
            u.set_paint(tn, lambda u2, id, r, pt: trm.draw(
                ide.term, pt, r, u2.cell_w, u2.cell_h, u2.theme,
                u2.focus_get() == id, True))
            ide.term_node = tn
            ide.dock_labels.append(tn)
        elif i == PAGE_BUILD:
            # the Build page is REAL since F7; the others still say "empty".
            # Whatever a page is made of, ONE node per page goes in the list, so
            # `dock_show` hides one thing each and never learns what they are.
            page = u.box(ide.dock_body, True)
            u.set_expand(page, True, True)
            ide.build_bar = u.progress(page)
            u.set_expand(ide.build_bar, True, False)
            ide.build_list = u.list(page)
            u.set_expand(ide.build_list, True, True)
            u.on_submit(ide.build_list, lambda id, row: ide.build_row_picked(row))
            ide.dock_labels.append(page)
        else:
            lb = u.label(ide.dock_body, "(" + names[i] + " is empty)")
            u.set_pad(lb, 8)
            # wide but not tall: a panel's content starts at the TOP of it, and
            # a label that expanded vertically floated in the middle of the dock
            u.set_expand(lb, True, False)
            ide.dock_labels.append(lb)
    ide.build_refresh()
    ide.dock_refresh()
    ide.dock_show(0)
    u.split_set(sh.vsplit, 420)
    apply_config(ide, ide.conf)


def first_position(text: str) -> list<str>:
    """`file:line:column: error: ...` -> [file, line, column], or [].

    The format the compiler already uses, and the one `pforge` copied on purpose
    for its own errors. It is a free function because two things want it now —
    the status bar's first error and a row of the Build panel — and neither of
    them owns it."""
    for line in text.split("\n"):
        parts = line.split(":")
        if len(parts) < 4:
            continue
        if not parts[1].isdigit() or not parts[2].isdigit():
            continue
        rest = ":".join(parts[3:len(parts)]).strip()
        if not rest.startswith("error"):
            continue           # the first ERROR, not the first warning
        return [parts[0].strip(), parts[1], parts[2]]
    return []


def outline_icon(kind: cmp.SymKind) -> int:
    match kind:
        case cmp.SYM_TYPE:
            return ico.ICO_BOX
        case cmp.SYM_FUNC:
            return ico.ICO_BRACES
        case cmp.SYM_MEMBER:
            return ico.ICO_VARIABLE
        case _:
            # a keyword and a loose word never reach here: `Index.outline`
            # filters them out, because neither is a declaration
            return pui.ICON_NONE


def apply_config(ide: Ide, c: cfg.Config):
    """`.pstudio.json` onto the widgets that already exist.

    It runs AFTER the shell is built, never instead of it: a configuration that
    could prevent a pane from existing would be a configuration that can lock
    somebody out of their editor, and the whole file was written on the promise
    that it cannot."""
    u = ide.sh.u
    ide.conf = c
    u.split_set(ide.sh.split, c.tree_w)
    u.set_visible(ide.sh.tree_pane, c.tree_open)
    u.set_visible(ide.sh.side, c.outline_open)
    u.set_visible(ide.sh.dock, c.dock_open)
    # the two offsets are measured from the LEFT and from the TOP, and what the
    # file remembers is the pane's own width and height — which is the thing a
    # person resized, and the only one that survives another window size
    r = u.rect_of(ide.sh.rsplit)
    if r.w > c.outline_w:
        u.split_set(ide.sh.rsplit, r.w - c.outline_w)
    rv = u.rect_of(ide.sh.vsplit)
    if rv.h > c.dock_h:
        u.split_set(ide.sh.vsplit, rv.h - c.dock_h)
    if len(c.target) > 0:
        ide.want_build = c.target
    ide.set_target_label()
    ide.sh.u.relayout()
    ide.sh.dirty_ui = True
    # the status bar has ONE line, and a file with six mistakes in it has six
    # notes: the first is shown and the rest are counted, because a bar that
    # flickered through all of them would show the last one, which is never the
    # one that matters
    if len(c.notes) > 0:
        extra = "" if len(c.notes) == 1 else "  (+" + str(len(c.notes) - 1) + " more)"
        ide.sh.want_msg = c.notes[0] + extra


def snapshot_config(ide: Ide) -> cfg.Config:
    """What the panes are RIGHT NOW, so the driver can write it back.

    The widths and not the offsets, for the same reason `apply_config` reads
    them that way: an offset is where a divider is on this screen, and a width is
    what somebody chose."""
    u = ide.sh.u
    c = ide.conf
    c.tree_w = u.split_offset(ide.sh.split)
    r = u.rect_of(ide.sh.rsplit)
    c.outline_w = r.w - u.split_offset(ide.sh.rsplit)
    rv = u.rect_of(ide.sh.vsplit)
    c.dock_h = rv.h - u.split_offset(ide.sh.vsplit)
    c.tree_open = u.is_visible(ide.sh.tree_pane)
    c.outline_open = u.is_visible(ide.sh.side)
    c.dock_open = u.is_visible(ide.sh.dock)
    c.target = ide.want_build
    return c


def os_env_shell() -> str:
    """The user's shell, or the one every system has.

    `SHELL` and not a guess: somebody who chose `fish` typed that choice
    somewhere, and starting `bash` for them would be this program having an
    opinion about it."""
    v = sys.env.get("SHELL", "")
    return v if len(v) > 0 else "/bin/sh"
