"""The driver: the window, the event loop, the clock, the clipboard and the disk.

Everything here is what a program that puts an editor on a screen must do, and
NOTHING here is an editor: the buffer, the tabs, the palette and the shortcuts are
`shell.psc`, and the build and the packages are `ide.psc`.

Both binaries use this file. `pcode.psc` is the editor alone; `pstudio.psc` is
that plus the IDE — and the loop is here rather than in either of them because
the two would otherwise carry the same fifty lines and drift apart.

**Why the loop is a STEP and not a loop.** The IDE's requests are served with
`await`, and pscript has no type for an `async` function value, so the driver
cannot take "what else to serve" as a callback. It could import `ide.psc` and
call it — and that is exactly what the whitelist gate exists to forbid. So the
driver offers one turn, and each `main` writes the three lines around it:

    while sh.running:
        blink = await driver.step(sh, blink)
        await ide_serve(ide)          # pstudio only
        await driver.present(sh)

The other half of the split, and it is the older one: **the editor asks and the
driver serves.** The editor's logic is synchronous on purpose (an `await` in the
middle of a keystroke would make every caller wait), so reading a file is a
REQUEST — `want_open` — that this file fulfils between two frames.
"""
import "shim.ph"

import <pui> as pui
import shell as appm
import highlight as hlm
import complete as cmp
import sys
import time
import os
import path


struct Driver:
    """What the driver remembers between turns.

    A module cannot hold state in pscript — an imported module is a set of
    definitions, not a program to run — and that turns out to be the right
    pressure: the cache, the queue of pending writes and the rescue counter
    belong to the driver, and here they are visible instead of being three
    globals nobody sees."""
    cache: dict<str, str>
    failed: dict<str, str>       # path -> why the read did not work
    pending: list<str>           # paths with a pending write (the text is in the cache)
    rescues: int


def new_driver() -> Driver:
    return Driver({}, {}, [], 0)


async def read_file(dv: Driver, p: str) -> str?:
    """`None` is a FAILURE; `""` is an empty file.

    They used to be the same value, and that is why an empty file never opened:
    the shell could not tell "I have nothing" from "there is nothing", so it asked
    for the file to be read again for ever, every 500 ms, without a message. The
    reason goes into `failed`, and the shell shows it in the status bar."""
    try:
        with await open(p, "r") as f:
            return await f.text()
    catch e:
        dv.failed[p] = e.message
        return None


async def flush_writes(dv: Driver, sh: appm.Shell):
    while len(dv.pending) > 0:
        p = dv.pending.pop()
        try:
            f = await open(p, "w")
            await f.write(dv.cache[p])
            await f.close()
        catch e:
            sh.want_msg = "could not write " + p


def read_cached(dv: Driver, p: str) -> appm.ReadOut:
    """The three states the shell needs: I have the text, I have a reason, or I
    have nothing yet. The cache is checked FIRST, so a path that failed once and
    then read fine is not held against it."""
    if p in dv.cache:
        return appm.ReadOut(True, dv.cache[p], "")
    if p in dv.failed:
        return appm.ReadOut(True, "", dv.failed[p])
    return appm.ReadOut(False, "", "")


def queue_write(dv: Driver, p: str, text: str) -> bool:
    dv.cache[p] = text
    dv.pending.append(p)
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
    """The editor's painter: six calls into the shim, and nothing else."""
    return pui.Painter(lambda x, y, w, h, c: shim_rect(x, y, w, h, c),
                       lambda x, y, w, h, c: shim_frame(x, y, w, h, c),
                       lambda x, y, w, h: shim_clip(x, y, w, h),
                       lambda: shim_clip_reset(),
                       lambda cp, x, y, c: shim_glyph(cp, x, y, c),
                       lambda ic, x, y, c: shim_icon(ic, x, y, c))


def now_ms() -> int:
    return int(time.monotonic() * 1000.0)


def wire(dv: Driver, sh: appm.Shell):
    """Wires the sh to the system. All the driver's functions, in one place."""
    sh.read_file = lambda p: read_cached(dv, p)
    sh.write_file = lambda p, t: queue_write(dv, p, t)
    sh.mtime_of = lambda p: path.getmtime(p) if path.exists(p) else 0
    sh.clip_get = lambda: shim_clip_get()
    sh.clip_set = lambda s: shim_clip_set(s)
    sh.confirm_close = lambda name: shim_confirm_close(name)
    sh.confirm_reload = lambda name: shim_confirm_reload(name)
    sh.set_title = lambda t: shim_title(t)
    sh.zoom_step = lambda step: zoom(sh, step)


def zoom(sh: appm.Shell, step: int):
    """The zoom step is a real GRID (11..29px rasterized), not a multiplier —
    which is why the index is ABSOLUTE and the shim clamps it to the range. The
    toolkit receives the new cell and redoes the whole layout.

    `step == 0` goes back to the DEFAULT step — the same one the editor in P
    uses, and that is why the shim exposes it instead of the sh guessing."""
    at = shim_zoom_at()
    want = shim_zoom_default() if step == 0 else at + step
    shim_zoom(want)
    sh.set_cell(shim_cell_w(), shim_cell_h(), shim_icon_px())
    sh.dirty_ui = True



const SEARCH_MAX: int = 500       # hits; past this the list stops being a list


async def serve_search(dv: Driver, sh: appm.Shell):
    """Reads the project's files and finds the needle in them.

    It VARRE every time. There is no index to invalidate and nothing to keep in
    memory, and for a source tree it is milliseconds — this repository is about
    58 000 lines. The cap exists because five hundred hits is already more than
    anybody reads, and a list of fifty thousand is not a list."""
    needle = sh.want_search
    sh.want_search = ""
    hits: list<appm.PalItem> = []
    for it in sh.files:
        if len(hits) >= SEARCH_MAX:
            break
        p = it.payload
        t = ""
        if p in dv.cache:
            t = dv.cache[p]
        else:
            got = await read_file(dv, p)
            if got == None:
                continue                    # binary, unreadable: not an error here
            t = got
            dv.cache[p] = t
        if needle not in t:
            continue                        # one native scan rejects most files
        ln = 0
        for line in t.split("\n"):
            ln += 1
            col = line.find(needle)
            if col < 0:
                continue
            where = it.label + ":" + str(ln)
            hits.append(appm.PalItem(where + ": " + line.strip(),
                                     p + ":" + str(ln) + ":" + str(col + 1), 0))
            if len(hits) >= SEARCH_MAX:
                break
    sh.search_ready(needle, hits)
    sh.dirty_ui = True


async def serve_index(dv: Driver, sh: appm.Shell):
    """Reads the project's SOURCES, once, when somebody first asks a question
    that needs them.

    Nothing is read at startup, which is what makes the editor open instantly on
    any folder. The first go-to-definition pays for it, and after that the answer
    is in memory."""
    sh.want_index = False
    srcs: list<cmp.Source> = []
    for it in sh.files:
        p = it.payload
        if hlm.lang_of(p) == hlm.LANG_NONE:
            continue                      # only what a compiler here can read
        t = ""
        if p in dv.cache:
            t = dv.cache[p]
        else:
            got = await read_file(dv, p)
            if got == None:
                continue
            t = got
            dv.cache[p] = t
        srcs.append(cmp.Source(p, t))
    sh.index_ready(srcs)
    sh.dirty_ui = True


async def serve_shell(dv: Driver, sh: appm.Shell):
    """What the EDITOR asked for: read a file, write one, say something.

    The IDE's requests are not here, and could not be: this file does not import
    `ide.psc`, and that is the property `pcode` is built to have."""
    if len(sh.want_open) > 0:
        p = sh.want_open
        sh.want_open = ""
        t = await read_file(dv, p)
        if t != None:
            dv.cache[p] = t
        sh.open_file(p)
    while len(sh.want_reload) > 0:
        # a reload does NOT go through the cache: the cache is what was read when
        # the file was opened, and a reload exists because the disk stopped
        # matching that
        p2 = sh.want_reload.pop()
        t2 = await read_file(dv, p2)
        if t2 != None:
            dv.cache[p2] = t2
            sh.reload_now(p2, t2)
        else:
            sh.want_msg = p2 + ": " + (dv.failed[p2] if p2 in dv.failed else "could not read it")
    if len(sh.want_search) > 0:
        await serve_search(dv, sh)
    if sh.want_index:
        await serve_index(dv, sh)
    await flush_writes(dv, sh)
    if len(sh.want_msg) > 0:
        sh.u.set_text(sh.status, sh.want_msg)
        sh.want_msg = ""
        sh.dirty_ui = True


async def open_arg(dv: Driver, sh: appm.Shell, arg: str):
    if path.isfile(arg):
        t = await read_file(dv, arg)
        if t != None:
            dv.cache[arg] = t
        sh.open_file(arg)      # `failed` already carries the reason if it did not



# ---------- the loop survives a defect (F0) ----------
#
# pscript RAISES on integer overflow and on an index out of range, so a slip in
# column arithmetic used to kill the process and take with it everything that had
# not been saved. The loop had no `try` at all.
#
# Now a defect is a lost EVENT instead of lost work: what is modified goes to a
# draft, the reason goes to a log and to the status bar, and the loop carries on.

const CRASH_DIR: str = "build/pstudio"



private def flat_name(p: str) -> str:
    """`a/b/c.psc` -> `a%b%c.psc`. Two files called `main.psc` in different folders
    are two drafts, not one overwriting the other."""
    return p.replace("/", "%")


private async def rescue(dv: Driver, sh: appm.Shell, doing: str, why: str):
    """Keeps the work, records the reason, and lets the loop go on.

    Nothing in here may raise: it runs precisely when something already did."""
    dv.rescues += 1
    kept = 0
    if dv.rescues == 1:
        # only the FIRST time: if the state is broken, the second draft is not
        # better than the first, and a defect that repeats every frame must not
        # write a file every frame
        for i in range(len(sh.tabs)):
            cv = sh.tabs[i].cv
            if not cv.buf.dirty or len(cv.path) == 0:
                continue
            try:
                d = path.join(CRASH_DIR, "draft")
                if not path.isdir(d):
                    os.makedirs(d)
                f = await open(path.join(d, flat_name(cv.path)), "w")
                await f.write(cv.buf.text())
                await f.close()
                kept += 1
            catch e:
                pass
    if dv.rescues <= 20:
        try:
            if not path.isdir(CRASH_DIR):
                os.makedirs(CRASH_DIR)
            lg = await open(path.join(CRASH_DIR, "crash.log"), "a")
            await lg.write("while " + doing + ": " + why + "\n")
            await lg.close()
        catch e2:
            pass
    sh.want_msg = "internal error while " + doing + ": " + why
    if kept > 0:
        sh.want_msg += " — " + str(kept) + " draft(s) in " + path.join(CRASH_DIR, "draft")
    sh.dirty_ui = True



# ---------- one turn of the loop ----------

async def step(dv: Driver, sh: appm.Shell, blink: int) -> int:
    """Waits for ONE event, drains what follows it, and serves the editor's own
    requests. Returns the new blink stamp.

    The blocking wait with a timeout is what makes the caret blink without the
    program spinning: an idle editor uses no CPU at all. And the queue is DRAINED
    after it because `present` is per FRAME and not per event — with vsync each
    present holds about 16 ms, and one per movement event leaves a drag behind
    the cursor (measured in the editor in P: 200 movements were 182 ms that way
    and 1 ms this way)."""
    kind = shim_wait(sh.wait_ms if sh.wait_ms > 0 else appm.BLINK_MS)
    sh.now_ms = now_ms()
    try:
        if kind == SHIM_TIMEOUT or kind == SHIM_NONE:
            blink = sh.tick(sh.now_ms, blink)
        elif kind == SHIM_FOCUS:
            sh.check_external()
        elif kind == SHIM_QUIT:
            sh.try_quit()
        elif kind == SHIM_RESIZE:
            sh.u.layout(shim_width(), shim_height())
            sh.u.queue_redraw_tree(sh.root)
            sh.dirty_ui = True
        else:
            sh.feed(ev_from_shim(kind))
        while sh.running:
            k2 = shim_poll()
            if k2 == SHIM_NONE:
                break
            sh.now_ms = now_ms()
            if k2 == SHIM_QUIT:
                sh.try_quit()
            elif k2 == SHIM_RESIZE:
                sh.u.layout(shim_width(), shim_height())
                sh.u.queue_redraw_tree(sh.root)
                sh.dirty_ui = True
            elif k2 == SHIM_FOCUS:
                sh.check_external()
            else:
                sh.feed(ev_from_shim(k2))
    catch e:
        await rescue(dv, sh, "handling an event", e.message)
    try:
        await serve_shell(dv, sh)
    catch e2:
        await rescue(dv, sh, "serving a request", e2.message)
    return blink


async def present(dv: Driver, sh: appm.Shell):
    """One frame, when something changed."""
    try:
        if sh.dirty_ui or sh.u.needs_draw:
            shim_clear(sh.u.theme.bg)
            sh.u.draw(painter(), shim_width(), shim_height())
            shim_present()
            sh.dirty_ui = False
    catch e:
        sh.dirty_ui = False        # do not redraw the same failure for ever
        await rescue(dv, sh, "drawing", e.message)


# ---------- the command line the two binaries share ----------

struct Args:
    """What both `pcode` and `pstudio` accept. Each of them handles its own
    modes (`--build`, `--manifest`) before getting here."""
    files: list<str>
    dir: str
    shot: str
    win_w: int
    win_h: int
    ok: bool


def parse_args(who: str, args: list<str>, first: int) -> Args:
    """Several files open in tabs; a directory becomes the tree's root.

    `--shot` writes one frame as PPM, which is how the editor is looked at on a
    machine with no X."""
    a = Args([], "", "", 1100, 720, True)
    i = first
    while i < len(args):
        x = args[i]
        if x == "--shot" and i + 1 < len(args):
            a.shot = args[i + 1]
            i += 2
            continue
        if x == "--size" and i + 1 < len(args):
            wh = args[i + 1].split("x")
            if len(wh) == 2:
                a.win_w = int(wh[0])
                a.win_h = int(wh[1])
            i += 2
            continue
        if x.startswith("--"):
            print(who + ": unknown option '" + x + "'")
            a.ok = False
            return a
        if path.isdir(x):
            if len(a.dir) == 0:
                a.dir = path.normpath(x)
        elif path.isfile(x):
            a.files.append(x)
            if len(a.dir) == 0:
                a.dir = path.dirname(x)
        else:
            print(who + ": '" + x + "' does not exist")
        i += 1
    if len(a.dir) == 0:
        a.dir = "."
    return a


async def open_window(dv: Driver, a: Args, dir: str) -> appm.Shell?:
    """Opens the window and builds the editor in it. `None` when there is no
    screen to open one on."""
    if not shim_open(a.win_w, a.win_h):
        print("could not open a window (SDL). Is DISPLAY set?")
        return None
    u = pui.new_ui(shim_cell_w(), shim_cell_h())
    u.icon_px = shim_icon_px()
    sh = appm.new_shell(u, dir)
    wire(dv, sh)
    u.layout(shim_width(), shim_height())
    for fp in a.files:
        await open_arg(dv, sh, fp)
    sh.update_status()
    return sh


def take_shot(sh: appm.Shell, file: str) -> int:
    """One frame to a file, and out. It is the whole `--shot` mode."""
    shim_clear(sh.u.theme.bg)
    sh.u.draw(painter(), shim_width(), shim_height())
    shim_present()
    ok = shim_shot(file)
    shim_close()
    print("shot", "ok" if ok else "failed")
    return 0 if ok else 1
