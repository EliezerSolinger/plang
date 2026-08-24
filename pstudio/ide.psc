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
import core
import path


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

    # ---------- the build error, as a position ----------

    def mark_error(self, text: str) -> bool:
        """`file:line:column: error: message` — the format the compiler already
        uses, and that `pforge` copied on purpose for its own errors.

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
        self.want_build = ""
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
              "", 0, 0, 0, False, "", "")
    sh.add_commands(ide_commands(ide))
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
    ]
