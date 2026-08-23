"""pstudio, in pscript: the program.

This is the DRIVER, and nothing else: it opens the window, translates the shim's
event into the toolkit's event, reads and writes files, talks to the clipboard
and presents the frame. The editor's whole logic — buffer, cursors, undo,
folding, highlighting, completion, tabs, tree, palette, search — lives in the
`lib_*.psc` modules next door, and that is why it all runs in a headless test
(`--selftest`).

The boundary: `shim.p` is the hand that touches SDL (45.5 — a pointer does not
cross), and `hl.p` is the one that calls the compiler's lexer. Two pages of P;
the rest is pscript.

    pstudio [directory-or-file]
    pstudio --selftest file        # exercises the editor without a screen and exits
    pstudio --build [target]       # builds the project, without a screen (the
                                   #   engine is a library: it runs INSIDE the editor)
    pstudio --run <target>         # ... and launches the program (play, no screen)
    pstudio --shot out.ppm [dir]   # one frame as PPM (a server with no X)

**Why `import "shim.ph"` and not `include "shim.h"`:** the `include` door reads
the header with C, and there a `CStr` is a pointer — which does not cross (45.5).
The `import` door reads the `.ph` with P's front end (75.3), and through it come
the three things this file needs: `CStr`'s functions, the `SHIM_*` constants and
`bool` as a bool (through `include` it would arrive as an `int`, because that is
what the emitted header writes).

**The seam async charged for.** Reading and writing files in pscript is `await`
(76.2), and `lib_app` is synchronous on purpose — a completion index that waits
would force every caller to wait. So the app ASKS and the driver serves:
`want_open` is the read request (the driver reads and calls `open_file` again),
and writing goes into a queue the loop drains, with any failure going to the
status bar. It is the one place in the editor where the split costs anything, and
it is here — in the driver — instead of spread around.
"""
import "shim.ph"

import <pui> as pui
import lib_app as appm
# F6: the build engine is a LIBRARY, and the editor imports it. It is what makes
# the build run in the UI's event loop instead of in a separate process.
import <pbuild/lib_build.psc> as B
import <pbuild/lib_graph.psc> as G
import <pbuild/lib_manifest.psc> as MF
import sys
import time
import os
import path


cache: dict<str, str> = {}
pending: list<str> = []          # paths with a pending write (the text is in the cache)


async def read_file(p: str) -> str:
    try:
        with await open(p, "r") as f:
            return await f.text()
    catch e:
        return ""


async def flush_writes(app: appm.App):
    while len(pending) > 0:
        p = pending.pop()
        try:
            f = await open(p, "w")
            await f.write(cache[p])
            await f.close()
        catch e:
            app.want_msg = "could not write " + p


def read_cached(p: str) -> str:
    return cache[p] if p in cache else ""


def queue_write(p: str, text: str) -> bool:
    cache[p] = text
    pending.append(p)
    return True


# ---------- events: from the shim to the toolkit ----------

def ev_from_shim(kind: int) -> pui.Event:
    k = pui.EV_NONE
    if kind == SHIM_KEY:
        k = pui.EV_KEY
    elif kind == SHIM_TEXT:
        k = pui.EV_TEXT
    elif kind == SHIM_MOUSE_DOWN:
        k = pui.EV_MOUSE_DOWN
    elif kind == SHIM_MOUSE_UP:
        k = pui.EV_MOUSE_UP
    elif kind == SHIM_MOUSE_MOVE:
        k = pui.EV_MOUSE_MOVE
    elif kind == SHIM_WHEEL:
        k = pui.EV_WHEEL
    elif kind == SHIM_RESIZE:
        k = pui.EV_RESIZE
    elif kind == SHIM_QUIT:
        k = pui.EV_QUIT
    return pui.Event(k, shim_ev_key(), shim_ev_mods(), shim_ev_cp(),
                     shim_ev_x(), shim_ev_y(), shim_ev_button(),
                     shim_ev_clicks(), shim_ev_wheel())


def painter() -> pui.Painter:
    """The editor's painter: five calls into the shim, and nothing else."""
    return pui.Painter(lambda x, y, w, h, c: shim_rect(x, y, w, h, c),
                       lambda x, y, w, h, c: shim_frame(x, y, w, h, c),
                       lambda x, y, w, h: shim_clip(x, y, w, h),
                       lambda: shim_clip_reset(),
                       lambda cp, x, y, c: shim_glyph(cp, x, y, c))


def now_ms() -> int:
    return int(time.monotonic() * 1000.0)


def wire(app: appm.App):
    """Wires the app to the system. All the driver's functions, in one place."""
    app.read_file = lambda p: read_cached(p)
    app.write_file = lambda p, t: queue_write(p, t)
    app.mtime_of = lambda p: path.getmtime(p) if path.exists(p) else 0
    app.clip_get = lambda: shim_clip_get()
    app.clip_set = lambda s: shim_clip_set(s)
    app.confirm_close = lambda name: shim_confirm_close(name)
    app.confirm_reload = lambda name: shim_confirm_reload(name)
    app.set_title = lambda t: shim_title(t)
    app.zoom_step = lambda step: zoom(app, step)


def zoom(app: appm.App, step: int):
    """The zoom step is a real GRID (11..29px rasterized), not a multiplier —
    which is why the index is ABSOLUTE and the shim clamps it to the range. The
    toolkit receives the new cell and redoes the whole layout.

    `step == 0` goes back to the DEFAULT step — the same one the editor in P
    uses, and that is why the shim exposes it instead of the app guessing."""
    at = shim_zoom_at()
    want = shim_zoom_default() if step == 0 else at + step
    shim_zoom(want)
    app.set_cell(shim_cell_w(), shim_cell_h())
    app.dirty_ui = True


# ---------- the BUILD, in the same event loop (F6) ----------
#
# The engine is a LIBRARY (`packages/pbuild`), not a process: the editor imports
# it and runs the build as a task in the same scheduler that handles the
# keyboard. The graph is a `dict` in memory — there is nothing to serialize, and
# no stream of text to parse on the other side (1.8).
#
# What the editor gains from that, and which a `ppack build` in a terminal does
# not give: the STATE. It knows which edge is running, how many are left, and
# what each one said — and it can draw that wherever it likes.

private def on_edge_start(app: appm.App, id: int, what: str):
    app.build_done += 0
    app.build_msg = "[" + str(app.build_done) + "/" + str(app.build_total) + "] " + what
    app.dirty_ui = True


private def on_edge_end(app: appm.App, id: int, st: int, out: str, ms: int):
    app.build_done += 1
    if st != 0:
        # the FIRST failure is the one that matters: the ones after it are
        # almost always consequences, and the status bar has one line
        if len(app.build_error) == 0:
            app.build_error = out.strip()
            # ... and its POSITION, which is what turns a message into
            # navigation: the editor opens the file and puts the cursor there
            app.mark_error(out)
    app.build_msg = "[" + str(app.build_done) + "/" + str(app.build_total) + "]"
    app.dirty_ui = True


private def where_is_ppack() -> str:
    for cand in ["build/bin/ppack", "ppack"]:
        if cand == "ppack" or path.isfile(cand):
            return cand
    return "ppack"


async def serve_manifest(app: appm.App):
    """The two requests that touch `pack.json`.

    **The default target** is written here, with `lib_manifest`'s surgery — the
    same one `ppack add` uses, and that is why it lives there and not in either
    of the two: a manifest is a file somebody commits, and rewriting it from the
    structure would lose the formatting and reorder everything.

    **A dependency** is NOT written here: it is asked of `ppack`, which fetches
    it, checks the hash, checks the signature and locks it in `pack.lock`.
    Writing the line by hand would give a manifest that asks for what nobody
    resolved — and the editor pretending to be the package manager."""
    if len(app.want_manifest_default) > 0:
        target = app.want_manifest_default
        app.want_manifest_default = ""
        man = path.join(app.root_dir, "pack.json")
        if not path.isfile(man):
            app.build_msg = "there is no pack.json in " + app.root_dir
        else:
            try:
                await MF.write_field(man, "default", target)
                app.build_msg = "default target: " + target
                # the file changed on DISK, and that is all that is needed:
                # whoever notices is `check_external`, which already runs in the
                # loop and already knows the hard rule (reload what is clean, ask
                # about what has local edits). A separate path for "I was the one
                # who wrote it" would be a second rule diverging from the first.
                app.check_external()
            catch e:
                app.build_msg = "I could not write pack.json: " + e.message
        app.dirty_ui = True
    if len(app.want_manifest_dep) > 0:
        request = app.want_manifest_dep
        app.want_manifest_dep = ""
        r = await os.run([where_is_ppack(), "add", request], cwd=app.root_dir)
        if r.status() == 0:
            app.build_msg = request + " went into the manifest and the lock"
            app.check_external()
        else:
            # `ppack`'s message is better than any paraphrase: it says whether
            # the index does not have the version, whether the hash does not
            # match, or whether nobody signed
            app.build_msg = r.output().strip().split("\n")[0]
        app.dirty_ui = True


async def serve_build(app: appm.App):
    """The app's build request, served here. It does not build: it ASKS."""
    await serve_manifest(app)
    if app.want_stop_run:
        app.want_stop_run = False
        if app.run_pid > 0:
            os.kill(app.run_pid)
            app.build_msg = "stopped the program (pid " + str(app.run_pid) + ")"
            app.run_pid = 0
            app.dirty_ui = True
    if app.want_clean:
        app.want_clean = False
        n = 0
        if path.isdir("build"):
            for name in sorted(os.listdir("build")):
                if name == "pkg":
                    continue          # what came from outside stays (ppack's broom)
                d = path.join("build", name)
                if path.isdir(d):
                    n += rmtree(d)
        app.build_msg = "cleaned: " + str(n) + " file(s)"
        app.dirty_ui = True
        return
    if not app.want_build_on or app.build_busy:
        return
    target = app.want_build
    app.want_build_on = False
    app.build_busy = True
    app.build_error = ""
    app.build_done = 0
    app.build_total = 0
    app.build_msg = "assembling the graph..."
    app.dirty_ui = True
    g = await project_graph(app)
    if g == None:
        app.build_busy = False
        app.dirty_ui = True
        return
    # the targets, for the `!` palette: the editor does not know what a project builds
    alvos_v: list<str> = []
    for nd in g.nodes:
        if nd.gen >= 0:
            alvos_v.append(nd.p)
    app.build_targets = sorted(alvos_v)
    rep = B.Rep(lambda t: set_total(app, t),
                lambda i, w: on_edge_start(app, i, w),
                lambda i, st, o, ms: on_edge_end(app, i, st, o, ms),
                lambda ok, f: set_done(app, ok, f),
                lambda m: set_error(app, m))
    tl: list<str> = [target] if len(target) > 0 else []
    ok = await B.build(g, "build/log/build.log", tl, B.Opts(os.nproc(), 1, False, False), rep)
    app.build_busy = False
    # the PLAY: it built, now it runs. The previous program leaves first — it is
    # using the binary the build has just rewritten — and it leaves by SIGTERM,
    # which is a request: a `SIGKILL` does not let it close what it opened.
    if app.want_run:
        app.want_run = False
        if app.run_pid > 0:
            os.kill(app.run_pid)
            esperas = 0
            while os.alive(app.run_pid) and esperas < 100:
                await sleep(0.05)
                esperas += 1
            app.run_pid = 0
        if ok:
            prog = target if len(target) > 0 else first_executable(app)
            if len(prog) > 0 and path.isfile(prog):
                app.run_pid = os.spawn([prog if prog.startswith("/") else path.join(os.getcwd(), prog)])
                app.build_msg = "running " + path.basename(prog) + " (pid " + str(app.run_pid) + ")"
            else:
                app.build_msg = "it built, but I do not know what to run — use `Build Target…`"
    app.dirty_ui = True


private def first_executable(app: appm.App) -> str:
    """The target to run when nobody said which: the graph's first `build/bin/`.
    It is a guess, and that is why the message says how to choose another."""
    for t in app.build_targets:
        if "/bin/" in t:
            return t
    return ""


private def set_total(app: appm.App, t: int):
    app.build_total = t
    app.build_msg = str(t) + " edge(s) to build" if t > 0 else "nothing to do"


private def set_done(app: appm.App, ok: bool, fails: int):
    if ok:
        app.build_msg = "build ok (" + str(app.build_done) + " edge(s))"
    else:
        app.build_msg = "build FAILED: " + (app.build_error if len(app.build_error) > 0 else str(fails) + " problem(s)")


private def set_error(app: appm.App, msg: str):
    if len(app.build_error) == 0:
        app.build_error = msg


private async def project_graph(app: appm.App) -> G.Graph?:
    """The graph of the project that is open.

    **The descriptor belongs to the PROJECT, and the editor does not know it** —
    nor should it: it opens any tree, and each one builds itself its own way.
    Whoever knows the descriptor is that project's `ppack`, so that is who gets
    asked: `ppack graph` returns the graph as JSON and the editor runs it with
    the ENGINE, which is a library (`packages/pbuild`) and is in here.

    This is a serialization, and 1.8 would rather not have it. The trade is
    deliberate and in its favour: without it, the editor would have to embed the
    descriptor of every project it opens — which only works for ONE project,
    which would be this one. With it, the build runs in the editor's event loop
    (which is what F6 wants) for any tree that has a `ppack`. The cost is a JSON
    of a few megabytes, read once per build."""
    pp = ""
    for cand in ["build/bin/ppack", "ppack"]:
        if cand == "ppack" or path.isfile(cand):
            pp = cand
            break
    tmp = path.join("build", "t", "editor-graph.json")
    d = path.dirname(tmp)
    if len(d) > 0 and not path.isdir(d):
        os.makedirs(d)
    r = await os.run([pp, "graph"], stdout=tmp)
    if r.status() != 0:
        app.build_msg = "I could not get the graph: " + r.output().strip()
        app.build_error = app.build_msg
        return None
    f = await open(tmp, "r")
    txt = await f.text()
    await f.close()
    try:
        return G.from_json(txt)
    catch e:
        app.build_msg = "the graph would not be read: " + e.message
        return None


private def rmtree(d: str) -> int:
    n = 0
    for name in os.listdir(d):
        p = path.join(d, name)
        if path.isdir(p):
            n += rmtree(p)
        else:
            os.remove(p)
            n += 1
    os.rmdir(d)
    return n


async def serve_requests(app: appm.App):
    """Serves what the app asked for and could not do: read a file, write one,
    the failure message — and, since F6, the BUILD."""
    if len(app.want_open) > 0:
        p = app.want_open
        app.want_open = ""
        cache[p] = await read_file(p)
        app.open_file(p)
    await flush_writes(app)
    await serve_build(app)
    if len(app.build_msg) > 0:
        app.u.set_text(app.status, app.build_msg)
        app.dirty_ui = True
    if len(app.want_msg) > 0:
        app.u.set_text(app.status, app.want_msg)
        app.want_msg = ""
        app.dirty_ui = True


async def open_arg(app: appm.App, arg: str):
    if path.isfile(arg):
        cache[arg] = await read_file(arg)
        app.open_file(arg)


# ---------- the loop ----------

async def run(app: appm.App) -> int:
    blink = now_ms()
    while app.running:
        # ONE blocking event (the timeout makes the cursor blink), then DRAIN
        # the queue: the `present` is per FRAME, not per event. With vsync each
        # present holds ~16ms, and one per movement event leaves the drag behind
        # the cursor (measured in the editor in P: 200 movements = 182ms that
        # way, 1ms this way)
        kind = shim_wait(appm.BLINK_MS)
        app.now_ms = now_ms()
        if kind == SHIM_TIMEOUT or kind == SHIM_NONE:
            blink = app.tick(app.now_ms, blink)
        elif kind == SHIM_FOCUS:
            app.check_external()
        elif kind == SHIM_QUIT:
            app.try_quit()
        elif kind == SHIM_RESIZE:
            app.u.layout(shim_width(), shim_height())
            app.u.queue_redraw_tree(app.root)
            app.dirty_ui = True
        else:
            app.feed(ev_from_shim(kind))
        while app.running:
            k2 = shim_poll()
            if k2 == SHIM_NONE:
                break
            app.now_ms = now_ms()
            if k2 == SHIM_QUIT:
                app.try_quit()
            elif k2 == SHIM_RESIZE:
                app.u.layout(shim_width(), shim_height())
                app.u.queue_redraw_tree(app.root)
                app.dirty_ui = True
            elif k2 == SHIM_FOCUS:
                app.check_external()
            else:
                app.feed(ev_from_shim(k2))
        await serve_requests(app)
        if app.dirty_ui or app.u.needs_draw:
            shim_clear(app.u.theme.bg)
            app.u.draw(painter(), shim_width(), shim_height())
            shim_present()
            app.dirty_ui = False
    return 0


# ---------- the self-test: the whole editor, without a screen ----------

async def selftest(arg: str) -> int:
    u = pui.new_ui(8, 17)
    app = appm.new_app(u, path.dirname(arg) if len(path.dirname(arg)) > 0 else ".")
    wire(app)
    app.read_file = lambda p: read_cached(p)
    u.layout(900, 500)
    await open_arg(app, arg)
    print("tabs", len(app.tabs))
    cv = app.cur_cv()
    if cv == None:
        print("no file")
        return 1
    print("lines", cv.buf.nlines())
    app.now_ms = now_ms()
    app.feed(pui.Event(pui.EV_TEXT, 0, 0, ord("X"), 0, 0, 0, 0, 0))
    print("typed", cv.buf.line_text(0))
    cv.buf.undo_step()
    print("undone", cv.buf.line_text(0))
    app.palette_open(appm.PAL_COMMANDS)
    u.set_text(app.palinput, ">fold all")
    app.palette_filter()
    print("palette", len(app.palitems), app.palitems[0].label if len(app.palitems) > 0 else "-")
    app.palette_accept()
    print("folded", cv.buf.visible_count())
    # F6: the build through the palette. What gets measured here is the REQUEST
    # — the driver serves it in `serve_requests`, and a whole build in a
    # self-test would take minutes.
    app.palette_open(appm.PAL_COMMANDS)
    u.set_text(app.palinput, ">build")
    app.palette_filter()
    print("build cmd", app.palitems[0].label if len(app.palitems) > 0 else "-")
    app.palette_accept()
    print("asked for a build", app.want_build_on, "target", "(default)" if len(app.want_build) == 0 else app.want_build)
    app.want_build_on = False       # a self-test does not build the repository
    app.build_targets = ["build/bin/plangc_s2", "build/bin/ppack"]
    app.palette_open(appm.PAL_BUILD)
    u.set_text(app.palinput, "!ppack")
    app.palette_filter()
    print("targets", len(app.palitems), app.palitems[0].label if len(app.palitems) > 0 else "-")
    app.palette_accept()
    print("asked for target", app.want_build)
    app.want_build_on = False
    # F6: the build error as a POSITION. It is what turns a message into
    # navigation — and the format is the one the compiler and ppack already use.
    found = app.mark_error(arg + ":2:3: error: invented for the test\ncc: some warning\n")
    print("error positioned", found, app.build_pos_line, app.build_pos_col)
    print("went to the error", app.goto_error())
    cvm2 = app.cur_cv()
    if cvm2 != None:
        print("error mark", cvm2.buf.mark_of(app.build_pos_line - 1))
    cvx = app.cur_cv()
    if cvx != None:
        print("caret at", cvx.buf.caret(0).line + 1)
    # F6, the manifest through the palette. The three things measured here are
    # the three the "panel" is: opening the file (an editor edits text), choosing
    # the default target from a LIST that came from the graph (which is what a
    # form would do better than the text: guarantee the target exists), and
    # ASKING for the name of a dependency — which you do not write, you resolve.
    app.palette_open(appm.PAL_COMMANDS)
    u.set_text(app.palinput, ">manifest set")
    app.palette_filter()
    print("manifest cmd", app.palitems[0].label if len(app.palitems) > 0 else "-")
    app.palette_accept()
    print("choosing the default target", app.pal_build_default, len(app.palitems))
    u.set_text(app.palinput, "!ppack")
    app.palette_filter()
    app.palette_accept()
    print("asked for the default target", app.want_manifest_default, "and did not build", app.want_build_on)
    app.want_manifest_default = ""
    app.palette_open(appm.PAL_COMMANDS)
    u.set_text(app.palinput, ">manifest add")
    app.palette_filter()
    app.palette_accept()
    print("asking", app.pal_prompt, app.pal_text_for)
    # what gets typed is an ANSWER: a `>` in the middle of it is a character, not a mode
    u.set_text(app.palinput, ">nothing")
    app.palette_filter()
    print("typed", app.palitems[0].payload if len(app.palitems) > 0 else "-")
    app.palette_accept()
    print("refused without a version", app.build_msg)
    app.palette_open(appm.PAL_COMMANDS)
    u.set_text(app.palinput, ">manifest add")
    app.palette_filter()
    app.palette_accept()
    u.set_text(app.palinput, "tar@0.1.0")
    app.palette_filter()
    app.palette_accept()
    print("asked for the dependency", app.want_manifest_dep)
    app.want_manifest_dep = ""
    n = app.u.build_all()
    print("drawn", "yes" if n > 20 else "no")
    await serve_requests(app)
    print("selftest ok")
    return 0


async def mode_run(target: str) -> int:
    """`pstudio --run <target>` — the PLAY, without a screen: it builds and
    launches the program, then kills it. It exists for the same reason as
    `--build`: without it, "play builds and runs" is a claim you can only check
    by looking at the window."""
    u = pui.new_ui(8, 17)
    app = appm.new_app(u, ".")
    app.want_build = target
    app.want_build_on = True
    app.want_run = True
    await serve_build(app)
    print(app.build_msg)
    alive = app.run_pid > 0 and os.alive(app.run_pid)
    print("launched", alive)
    if app.run_pid > 0:
        app.want_stop_run = True
        await serve_build(app)
        n = 0
        while os.alive(app.run_pid) and n < 60:
            await sleep(0.05)
            n += 1
    return 0 if alive else 1


async def mode_manifest(arg: str) -> int:
    """`pstudio --manifest <dir>` — the panel's other half, without a screen.

    What the palette does is ASK; what gets proven here is the serving: that the
    default target is written into `pack.json` without ruining the rest of the
    file, and that a dependency is not written by hand at all — it is asked of
    `ppack`, which resolves it, checks it and locks it."""
    u = pui.new_ui(8, 17)
    app = appm.new_app(u, arg)
    app.want_manifest_default = "build/bin/ppack"
    await serve_manifest(app)
    print(app.build_msg)
    f = await open(path.join(arg, "pack.json"), "r")
    txt = await f.text()
    await f.close()
    print("in the manifest", "\"default\": \"build/bin/ppack\"" in txt)
    # and again, with another target: the existing key is REPLACED where it
    # stands, and not repeated — a JSON object with the same key twice is
    # resolved differently by every reader
    app.want_manifest_default = "build/bin/pstudio"
    await serve_manifest(app)
    f2 = await open(path.join(arg, "pack.json"), "r")
    txt2 = await f2.text()
    await f2.close()
    n = 0
    i = 0
    while True:
        k = txt2.find("\"default\"", i)
        if k < 0:
            break
        n += 1
        i = k + 1
    print("only once", n, "and it is the new one", "\"default\": \"build/bin/pstudio\"" in txt2)
    # a dependency that does not exist: the editor writes NOTHING, and what
    # appears is `ppack`'s message — which knows how to say why
    app.want_manifest_dep = "doesnotexist@9.9.9"
    await serve_manifest(app)
    print("refused", len(app.build_msg) > 0)
    f3 = await open(path.join(arg, "pack.json"), "r")
    txt3 = await f3.text()
    await f3.close()
    print("and it wrote nothing", "doesnotexist" not in txt3)
    return 0


async def mode_build(target: str) -> int:
    """`pstudio --build [target]` — the build INSIDE the editor, without a screen.

    It exists to prove (and to measure) what F6 promises: the engine is a library
    the editor imports, and the build runs in the same scheduler that handles the
    keyboard. Without this, "the build runs in the editor" would be a claim you
    could only check by looking at a window.

    What it does is exactly what the palette does: it places the request, and
    lets the driver serve it."""
    u = pui.new_ui(8, 17)
    app = appm.new_app(u, ".")
    app.want_build = target
    app.want_build_on = True
    await serve_build(app)
    print(app.build_msg)
    for t in app.build_targets[0:0]:
        print(t)
    print("targets in the graph:", len(app.build_targets))
    # the exit status is the BUILD's, not the editor's: whoever calls this from
    # a script wants to know whether it built
    return 1 if len(app.build_error) > 0 or app.build_msg.startswith("build FAILED") else 0


# ---------- the entry point ----------

async def main_run() -> int:
    args = sys.argv
    if len(args) > 1 and args[1] == "--selftest":
        return await selftest(args[2] if len(args) > 2 else "")
    if len(args) > 1 and args[1] == "--build":
        return await mode_build(args[2] if len(args) > 2 else "")
    if len(args) > 1 and args[1] == "--manifest":
        return await mode_manifest(args[2] if len(args) > 2 else ".")
    if len(args) > 1 and args[1] == "--run":
        return await mode_run(args[2] if len(args) > 2 else "")
    # 115: the same command line as the editor in P — several files in tabs,
    # `--size WxH`, `--shot img.ppm`, and a diagnostic for what does not exist
    shot = ""
    files: list<str> = []
    dir = ""
    win_w = 1100
    win_h = 720
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--shot" and i + 1 < len(args):
            shot = args[i + 1]
            i += 2
            continue
        if a == "--size" and i + 1 < len(args):
            wh = args[i + 1].split("x")
            if len(wh) == 2:
                win_w = int(wh[0])
                win_h = int(wh[1])
            i += 2
            continue
        if a.startswith("--"):
            print("pstudio: unknown option '" + a + "'")
            return 2
        if path.isdir(a):
            if len(dir) == 0:
                dir = path.normpath(a)
        elif path.isfile(a):
            files.append(a)
            if len(dir) == 0:
                dir = path.dirname(a)
        else:
            print("pstudio: '" + a + "' does not exist")
        i += 1
    if len(dir) == 0:
        dir = "."
    if not shim_open(win_w, win_h):
        print("could not open a window (SDL). Is DISPLAY set?")
        return 1
    u = pui.new_ui(shim_cell_w(), shim_cell_h())
    app = appm.new_app(u, dir)
    wire(app)
    u.layout(shim_width(), shim_height())
    for fp in files:
        await open_arg(app, fp)
    app.update_status()
    if len(shot) > 0:
        shim_clear(u.theme.bg)
        u.draw(painter(), shim_width(), shim_height())
        shim_present()
        ok = shim_shot(shot)
        shim_close()
        print("shot", "ok" if ok else "failed")
        return 0 if ok else 1
    rc = await run(app)
    shim_close()
    return rc


sys.exit(await main_run())
