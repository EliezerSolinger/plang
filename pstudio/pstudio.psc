"""Plang Studio — the IDE.

Everything `pcode` is, plus the ecosystem: the build inside the editor, the run,
the manifest. It requires a project (a `pack.json`, here or above), because
without one there is nothing for a build to build.

This file is the DRIVER of that half: it does the awaiting that `ide.psc` may not
do. The pattern is the shell's own — the editor asks and the driver serves — and
it is why `ide.psc` has no `await` in it at all.

The loop is four lines because the driver owns the turn:

    while sh.running:
        blink = await driver.step(dv, sh, blink)
        await serve_ide(dv, sh, ide)
        await driver.present(dv, sh)

The middle line is the whole difference between the two binaries.
"""
import "shim.ph"

import <pui> as pui
import shell as appm
import ide as idem
import driver
# the build engine is a LIBRARY, and the editor imports it. It is what makes the
# build run in the UI's event loop instead of in a separate process.
import <pforge/build.psc> as B
import <pforge/graph.psc> as G
import <pforge/manifest.psc> as MF
import config as cfg
import sys
import time
import os
import path

# ---------- the BUILD, in the same event loop (F6) ----------
#
# The engine is a LIBRARY (`packages/pforge`), not a process: the editor imports
# it and runs the build as a task in the same scheduler that handles the
# keyboard. The graph is a `dict` in memory — there is nothing to serialize, and
# no stream of text to parse on the other side (1.8).
#
# What the editor gains from that, and which a `pforge build` in a terminal does
# not give: the STATE. It knows which edge is running, how many are left, and
# what each one said — and it can draw that wherever it likes.

private def on_edge_start(sh: appm.Shell, ide: idem.Ide, id: int, what: str):
    ide.edge_started(id, what)
    ide.build_msg = what
    sh.dirty_ui = True


private def on_edge_end(sh: appm.Shell, ide: idem.Ide, id: int, st: int, out: str, ms: int):
    ide.build_done += 1
    if st != 0:
        # the FIRST failure is the one that matters for the status BAR: the ones
        # after it are almost always consequences, and a bar has one line. The
        # PANEL keeps all of them, which is the difference between the two.
        if len(ide.build_error) == 0:
            ide.build_error = out.strip()
            # ... and its POSITION, which is what turns a message into
            # navigation: the editor opens the file and puts the cursor there
            ide.mark_error(out)
    # the count is the BAR's now, so the message is free to say what happened
    ide.edge_ended(id, st, out, ms)
    sh.dirty_ui = True


private def where_is_pforge() -> str:
    for cand in ["build/bin/pforge", "pforge"]:
        if cand == "pforge" or path.isfile(cand):
            return cand
    return "pforge"


async def serve_manifest(sh: appm.Shell, ide: idem.Ide):
    """The two requests that touch `pack.json`.

    **The default target** is written here, with `lib_manifest`'s surgery — the
    same one `pforge add` uses, and that is why it lives there and not in either
    of the two: a manifest is a file somebody commits, and rewriting it from the
    structure would lose the formatting and reorder everything.

    **A dependency** is NOT written here: it is asked of `pforge`, which fetches
    it, checks the hash, checks the signature and locks it in `pack.lock`.
    Writing the line by hand would give a manifest that asks for what nobody
    resolved — and the editor pretending to be the package manager."""
    if len(ide.want_manifest_default) > 0:
        target = ide.want_manifest_default
        ide.want_manifest_default = ""
        man = path.join(sh.root_dir, "pack.json")
        if not path.isfile(man):
            ide.build_msg = "there is no pack.json in " + sh.root_dir
        else:
            try:
                await MF.write_field(man, "default", target)
                ide.build_msg = "default target: " + target
                # the file changed on DISK, and that is all that is needed:
                # whoever notices is `check_external`, which already runs in the
                # loop and already knows the hard rule (reload what is clean, ask
                # about what has local edits). A separate path for "I was the one
                # who wrote it" would be a second rule diverging from the first.
                sh.check_external()
            catch e:
                ide.build_msg = "I could not write pack.json: " + e.message
        sh.dirty_ui = True
    if len(ide.want_manifest_dep) > 0:
        request = ide.want_manifest_dep
        ide.want_manifest_dep = ""
        r = await os.run([where_is_pforge(), "add", request], cwd=sh.root_dir)
        if r.status() == 0:
            ide.build_msg = request + " went into the manifest and the lock"
            sh.check_external()
        else:
            # `pforge`'s message is better than any paraphrase: it says whether
            # the index does not have the version, whether the hash does not
            # match, or whether nobody signed
            ide.build_msg = r.output().strip().split("\n")[0]
        sh.dirty_ui = True


async def serve_build(sh: appm.Shell, ide: idem.Ide):
    """The sh's build request, served here. It does not build: it ASKS."""
    await serve_manifest(sh, ide)
    if ide.want_stop_run:
        ide.want_stop_run = False
        if ide.run_pid > 0:
            os.kill(ide.run_pid)
            ide.build_msg = "stopped the program (pid " + str(ide.run_pid) + ")"
            ide.run_pid = 0
            sh.dirty_ui = True
    if ide.want_clean:
        ide.want_clean = False
        n = 0
        if path.isdir("build"):
            for name in sorted(os.listdir("build")):
                if name == "pkg":
                    continue          # what came from outside stays (pforge's broom)
                d = path.join("build", name)
                if path.isdir(d):
                    n += rmtree(d)
        ide.build_msg = "cleaned: " + str(n) + " file(s)"
        sh.dirty_ui = True
        return
    if not ide.want_build_on or ide.build_busy:
        return
    target = ide.want_build
    ide.want_build_on = False
    ide.build_busy = True
    ide.build_reset(target)
    ide.build_msg = "assembling the graph..."
    # up it comes, on the Build page. It is the one thing somebody who just
    # pressed Build wants to see, and asking them to open it first would mean
    # they only ever see it after the build they missed.
    ide.dock_open_at(idem.PAGE_BUILD)
    sh.dirty_ui = True
    g = await project_graph(sh, ide)
    if g == None:
        ide.build_busy = False
        sh.dirty_ui = True
        return
    # the targets, for the `!` palette: the editor does not know what a project builds
    alvos_v: list<str> = []
    for nd in g.nodes:
        if nd.gen >= 0:
            alvos_v.append(nd.p)
    ide.build_targets = sorted(alvos_v)
    rep = B.Rep(lambda t: set_total(sh, ide, t),
                lambda i, w: on_edge_start(sh, ide, i, w),
                lambda i, st, o, ms: on_edge_end(sh, ide, i, st, o, ms),
                lambda ok, f: set_done(sh, ide, ok, f),
                lambda m: set_error(sh, ide, m))
    tl: list<str> = [target] if len(target) > 0 else []
    ok = await B.build(g, "build/log/build.log", tl, B.Opts(os.nproc(), 1, False, False), rep)
    ide.build_busy = False
    # the PLAY: it built, now it runs. The previous program leaves first — it is
    # using the binary the build has just rewritten — and it leaves by SIGTERM,
    # which is a request: a `SIGKILL` does not let it close what it opened.
    if ide.want_run:
        ide.want_run = False
        if ide.run_pid > 0:
            os.kill(ide.run_pid)
            esperas = 0
            while os.alive(ide.run_pid) and esperas < 100:
                await sleep(0.05)
                esperas += 1
            ide.run_pid = 0
        if ok:
            prog = target if len(target) > 0 else first_executable(sh, ide)
            if len(prog) > 0 and path.isfile(prog):
                ide.run_pid = os.spawn([prog if prog.startswith("/") else path.join(os.getcwd(), prog)])
                ide.build_msg = "running " + path.basename(prog) + " (pid " + str(ide.run_pid) + ")"
            else:
                ide.build_msg = "it built, but I do not know what to run — use `Build Target…`"
    sh.dirty_ui = True


private def first_executable(sh: appm.Shell, ide: idem.Ide) -> str:
    """The target to run when nobody said which: the graph's first `build/bin/`.
    It is a guess, and that is why the message says how to choose another."""
    for t in ide.build_targets:
        if "/bin/" in t:
            return t
    return ""


private def set_total(sh: appm.Shell, ide: idem.Ide, t: int):
    ide.build_total = t
    ide.build_msg = str(t) + " edge(s) to build" if t > 0 else "nothing to do"
    ide.build_refresh()


private def set_done(sh: appm.Shell, ide: idem.Ide, ok: bool, fails: int):
    if ok:
        ide.build_msg = "build ok (" + str(ide.build_done) + " edge(s))"
    else:
        ide.build_msg = "build FAILED: " + (ide.build_error if len(ide.build_error) > 0 else str(fails) + " problem(s)")
        # and the panel STAYS: a build that broke is the one somebody has to
        # look at, and a dock that closed itself on the way out would be a dock
        # that hid the only thing it was opened for
        ide.dock_open_at(idem.PAGE_BUILD)
    ide.build_refresh()


private def set_error(sh: appm.Shell, ide: idem.Ide, msg: str):
    if len(ide.build_error) == 0:
        ide.build_error = msg


private async def project_graph(sh: appm.Shell, ide: idem.Ide) -> G.Graph?:
    """The graph of the project that is open.

    **The descriptor belongs to the PROJECT, and the editor does not know it** —
    nor should it: it opens any tree, and each one builds itself its own way.
    Whoever knows the descriptor is that project's `pforge`, so that is who gets
    asked: `pforge graph` returns the graph as JSON and the editor runs it with
    the ENGINE, which is a library (`packages/pforge`) and is in here.

    This is a serialization, and 1.8 would rather not have it. The trade is
    deliberate and in its favour: without it, the editor would have to embed the
    descriptor of every project it opens — which only works for ONE project,
    which would be this one. With it, the build runs in the editor's event loop
    (which is what F6 wants) for any tree that has a `pforge`. The cost is a JSON
    of a few megabytes, read once per build."""
    pp = ""
    for cand in ["build/bin/pforge", "pforge"]:
        if cand == "pforge" or path.isfile(cand):
            pp = cand
            break
    tmp = path.join("build", "t", "editor-graph.json")
    d = path.dirname(tmp)
    if len(d) > 0 and not path.isdir(d):
        os.makedirs(d)
    r = await os.run([pp, "graph"], stdout=tmp)
    if r.status() != 0:
        ide.build_msg = "I could not get the graph: " + r.output().strip()
        ide.build_error = ide.build_msg
        return None
    f = await open(tmp, "r")
    txt = await f.text()
    await f.close()
    try:
        return G.from_json(txt)
    catch e:
        ide.build_msg = "the graph would not be read: " + e.message
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



async def serve_ide(dv: driver.Driver, sh: appm.Shell, ide: idem.Ide):
    """What the IDE asked for and could not do itself. The middle line of the
    loop, and the only thing `pcode` does not have."""
    await serve_manifest(sh, ide)
    await serve_build(sh, ide)
    # the outline follows the buffer, and asks the index that already exists
    ide.outline_sync()
    if ide.want_conf_save:
        await save_config(sh, ide)
    if len(ide.build_msg) > 0:
        sh.u.set_text(sh.status, ide.build_msg)
        sh.dirty_ui = True


# ---------- F6: `.pstudio.json` ----------
#
# It is a project file, so reading and writing it is `await`, so it is here and
# not in `ide.psc`. The parsing is not: `config.parse` takes the TEXT, which is
# what lets every way a configuration file can be wrong be a string in a test
# instead of a file on a disk.

def conf_path(sh: appm.Shell) -> str:
    return path.join(sh.root_dir, ".pstudio.json")


async def load_config(sh: appm.Shell, ide: idem.Ide):
    """Read once, at startup, and never fatal.

    A file that refuses to load is a file that locks somebody out of their own
    editor at the worst possible moment. So every problem takes the default and
    says so in the status bar — and a file that is not there at all is not a
    problem, it is a project nobody has configured yet."""
    p = conf_path(sh)
    txt = ""
    if path.isfile(p):
        try:
            f = await open(p, "r")
            txt = await f.text()
            await f.close()
        catch e:
            sh.want_msg = ".pstudio.json: " + e.message + " — everything default"
            return
    names: list<str> = []
    for c in sh.commands:
        names.append(c.name)
    idem.apply_config(ide, cfg.parse(txt, names))


async def save_config(sh: appm.Shell, ide: idem.Ide):
    """Written back when a pane moved, and it is meant to be COMMITTED: the
    panes a team works with are a project decision, not a machine one."""
    ide.want_conf_save = False
    try:
        f = await open(conf_path(sh), "w")
        await f.write(cfg.to_text(idem.snapshot_config(ide)))
        await f.close()
    catch e:
        sh.want_msg = ".pstudio.json: could not write it (" + e.message + ")"


# ---------- the self-test: the whole editor, without a screen ----------

async def selftest(arg: str) -> int:
    u = pui.new_ui(8, 17)
    dv = driver.new_driver()
    sh = appm.new_shell(u, path.dirname(arg) if len(path.dirname(arg)) > 0 else ".")
    ide = idem.new_ide(sh)
    driver.wire(dv, sh)
    u.layout(900, 500)
    await driver.open_arg(dv, sh, arg)
    print("tabs", len(sh.tabs))
    cv = sh.cur_cv()
    if cv == None:
        print("no file")
        return 1
    print("lines", cv.buf.nlines())
    sh.now_ms = driver.now_ms()
    sh.feed(pui.Event(pui.EV_TEXT, 0, 0, ord("X"), 0, 0, 0, 0, 0))
    print("typed", cv.buf.line_text(0))
    cv.buf.undo_step()
    print("undone", cv.buf.line_text(0))
    sh.palette_open(appm.PAL_COMMANDS)
    u.set_text(sh.palinput, ">fold all")
    sh.palette_filter()
    print("palette", len(sh.palitems), sh.palitems[0].label if len(sh.palitems) > 0 else "-")
    sh.palette_accept()
    print("folded", cv.buf.visible_count())
    # F6: the build through the palette. What gets measured here is the REQUEST
    # — the driver serves it in `serve_requests`, and a whole build in a
    # self-test would take minutes.
    sh.palette_open(appm.PAL_COMMANDS)
    u.set_text(sh.palinput, ">build")
    sh.palette_filter()
    print("build cmd", sh.palitems[0].label if len(sh.palitems) > 0 else "-")
    sh.palette_accept()
    print("asked for a build", ide.want_build_on, "target", "(default)" if len(ide.want_build) == 0 else ide.want_build)
    ide.want_build_on = False       # a self-test does not build the repository
    ide.build_targets = ["build/bin/plangc_s2", "build/bin/pforge"]
    ide.ask_target()
    u.set_text(sh.palinput, "!pforge")
    sh.palette_filter()
    print("targets", len(sh.palitems), sh.palitems[0].label if len(sh.palitems) > 0 else "-")
    sh.palette_accept()
    print("asked for target", ide.want_build)
    ide.want_build_on = False
    # F6: the build error as a POSITION. It is what turns a message into
    # navigation — and the format is the one the compiler and pforge already use.
    found = ide.mark_error(arg + ":2:3: error: invented for the test\ncc: some warning\n")
    print("error positioned", found, ide.build_pos_line, ide.build_pos_col)
    print("went to the error", ide.goto_error())
    cvm2 = sh.cur_cv()
    if cvm2 != None:
        print("error mark", cvm2.buf.mark_of(ide.build_pos_line - 1))
    cvx = sh.cur_cv()
    if cvx != None:
        print("caret at", cvx.buf.caret(0).line + 1)
    # F6, the manifest through the palette. The three things measured here are
    # the three the "panel" is: opening the file (an editor edits text), choosing
    # the default target from a LIST that came from the graph (which is what a
    # form would do better than the text: guarantee the target exists), and
    # ASKING for the name of a dependency — which you do not write, you resolve.
    sh.palette_open(appm.PAL_COMMANDS)
    u.set_text(sh.palinput, ">manifest set")
    sh.palette_filter()
    print("manifest cmd", sh.palitems[0].label if len(sh.palitems) > 0 else "-")
    sh.palette_accept()
    print("choosing the default target", sh.palmode == appm.PAL_LIST, len(sh.palitems))
    u.set_text(sh.palinput, "!pforge")
    sh.palette_filter()
    sh.palette_accept()
    print("asked for the default target", ide.want_manifest_default, "and did not build", ide.want_build_on)
    ide.want_manifest_default = ""
    sh.palette_open(appm.PAL_COMMANDS)
    u.set_text(sh.palinput, ">manifest add")
    sh.palette_filter()
    sh.palette_accept()
    print("asking", sh.pal_prompt, sh.palmode == appm.PAL_ASK)
    # what gets typed is an ANSWER: a `>` in the middle of it is a character, not a mode
    u.set_text(sh.palinput, ">nothing")
    sh.palette_filter()
    print("typed", sh.palitems[0].payload if len(sh.palitems) > 0 else "-")
    sh.palette_accept()
    print("refused without a version", ide.build_msg)
    sh.palette_open(appm.PAL_COMMANDS)
    u.set_text(sh.palinput, ">manifest add")
    sh.palette_filter()
    sh.palette_accept()
    u.set_text(sh.palinput, "tar@0.1.0")
    sh.palette_filter()
    sh.palette_accept()
    print("asked for the dependency", ide.want_manifest_dep)
    ide.want_manifest_dep = ""
    n = sh.u.build_all()
    print("drawn", "yes" if n > 20 else "no")
    await driver.serve_shell(dv, sh)
    print("selftest ok")
    return 0


async def mode_run(target: str) -> int:
    """`pstudio --run <target>` — the PLAY, without a screen: it builds and
    launches the program, then kills it. It exists for the same reason as
    `--build`: without it, "play builds and runs" is a claim you can only check
    by looking at the window."""
    u = pui.new_ui(8, 17)
    sh = appm.new_shell(u, ".")
    ide = idem.new_ide(sh)
    ide.want_build = target
    ide.want_build_on = True
    ide.want_run = True
    await serve_build(sh, ide)
    print(ide.build_msg)
    alive = ide.run_pid > 0 and os.alive(ide.run_pid)
    print("launched", alive)
    if ide.run_pid > 0:
        ide.want_stop_run = True
        await serve_build(sh, ide)
        n = 0
        while os.alive(ide.run_pid) and n < 60:
            await sleep(0.05)
            n += 1
    return 0 if alive else 1


async def mode_manifest(arg: str) -> int:
    """`pstudio --manifest <dir>` — the panel's other half, without a screen.

    What the palette does is ASK; what gets proven here is the serving: that the
    default target is written into `pack.json` without ruining the rest of the
    file, and that a dependency is not written by hand at all — it is asked of
    `pforge`, which resolves it, checks it and locks it."""
    u = pui.new_ui(8, 17)
    sh = appm.new_shell(u, arg)
    ide = idem.new_ide(sh)
    ide.want_manifest_default = "build/bin/pforge"
    await serve_manifest(sh, ide)
    print(ide.build_msg)
    f = await open(path.join(arg, "pack.json"), "r")
    txt = await f.text()
    await f.close()
    print("in the manifest", "\"default\": \"build/bin/pforge\"" in txt)
    # and again, with another target: the existing key is REPLACED where it
    # stands, and not repeated — a JSON object with the same key twice is
    # resolved differently by every reader
    ide.want_manifest_default = "build/bin/pstudio"
    await serve_manifest(sh, ide)
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
    # appears is `pforge`'s message — which knows how to say why
    ide.want_manifest_dep = "doesnotexist@9.9.9"
    await serve_manifest(sh, ide)
    print("refused", len(ide.build_msg) > 0)
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
    sh = appm.new_shell(u, ".")
    ide = idem.new_ide(sh)
    ide.want_build = target
    ide.want_build_on = True
    await serve_build(sh, ide)
    print(ide.build_msg)
    for t in ide.build_targets[0:0]:
        print(t)
    print("targets in the graph:", len(ide.build_targets))
    # the exit status is the BUILD's, not the editor's: whoever calls this from
    # a script wants to know whether it built
    return 1 if len(ide.build_error) > 0 or ide.build_msg.startswith("build FAILED") else 0

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
    a = driver.parse_args("pstudio", args, 1)
    if not a.ok:
        return 2
    dv = driver.new_driver()
    sh = await driver.open_window(dv, a, a.dir)
    if sh == None:
        return 1
    ide = idem.new_ide(sh)
    # AFTER the first layout, because what the file remembers is a pane's width
    # and the widget has to have a rectangle for that to mean anything
    await load_config(sh, ide)
    # the outline is filled by the loop's middle line, and a screenshot never
    # reaches the loop — so a picture of the IDE would show an empty pane that
    # fills in half a frame later, which is a picture of a bug that is not there
    ide.outline_sync()
    if len(a.shot) > 0:
        return driver.take_shot(sh, a.shot)
    blink = driver.now_ms()
    while sh.running:
        blink = await driver.step(dv, sh, blink)
        await serve_ide(dv, sh, ide)
        await driver.present(dv, sh)
    shim_close()
    return 0


sys.exit(await main_run())
