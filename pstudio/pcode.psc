"""PCode — the editor, and nothing else.

Tabs, a file tree, a fuzzy palette, multi-caret editing, coalesced undo,
incremental search, folding, a minimap, and highlighting that uses the compiler's
own lexer. It opens any folder, it needs no project, and it remembers nothing
between runs — zero I/O at startup is half of what makes it fast.

**It is also the proof.** `pstudio` is this plus `ide.psc`, and the two share
every layer below. A whitelist gate asks the compiler which files this program
reads (`plangc --deps`) and fails if anything that is not on the list appears —
so "the layers are separable" stops being a claim and becomes a number.

That is why there is no build here, no test panel, no package tree and no
diagnostics. Not because they would not be useful, but because a proof with an
exception is not a proof.
"""
import "shim.ph"

import <pui> as pui
import shell as appm
import driver
import sys
import path


async def selftest(arg: str) -> int:
    """The whole editor, without a screen: opens a file, types, undoes, uses the
    palette, folds, draws a frame. It is the same shape as `pstudio`'s, minus
    everything `pstudio` has that this does not."""
    dv = driver.new_driver()
    u = pui.new_ui(8, 17)
    sh = appm.new_shell(u, path.dirname(arg) if len(path.dirname(arg)) > 0 else ".")
    driver.wire(dv, sh)
    u.layout(900, 500)
    await driver.open_arg(dv, sh, arg)
    print("tabs", len(sh.tabs))
    cv = sh.cur_cv()
    if cv == None:
        print("no file")
        return 1
    print("lines", cv.buf.nlines())
    u.focus_set(cv.id)
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

    # the command TABLE is the palette's only source, so a command that is not
    # in it is not offered — and the IDE's are not in this binary
    sh.palette_open(appm.PAL_COMMANDS)
    u.set_text(sh.palinput, ">build")
    sh.palette_filter()
    print("no build command", len(sh.palitems))
    sh.palette_close()
    print("commands", len(sh.commands))

    n = u.build_all()
    print("drawn", "yes" if n > 20 else "no")
    print("selftest ok")
    return 0


async def main_run() -> int:
    args = sys.argv
    if len(args) > 1 and args[1] == "--selftest":
        return await selftest(args[2] if len(args) > 2 else "")
    a = driver.parse_args("pcode", args, 1)
    if not a.ok:
        return 2
    dv = driver.new_driver()
    sh = await driver.open_window(dv, a, a.dir)
    if sh == None:
        return 1
    if len(a.shot) > 0:
        return driver.take_shot(sh, a.shot)
    blink = driver.now_ms()
    while sh.running:
        blink = await driver.step(dv, sh, blink)
        await driver.present(dv, sh)
    shim_close()
    return 0


sys.exit(await main_run())
