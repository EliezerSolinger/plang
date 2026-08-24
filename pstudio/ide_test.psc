"""The IDE half, headless, with a driver of make-believe.

`shell_test.psc` measures the editor and never touches a build — which is what
made the seam visible in the first place. This measures the other side: the
request is placed, a fake driver answers, the state moves, and the error becomes
navigation.

Nothing here compiles anything. That is the point of the split the IDE is built
on: `ide.psc` places REQUESTS and does no `await`, so a test can serve them in
three lines instead of waiting for `cc`.
"""
import <pui> as pui
import shell as sh_mod
import ide as idem
import core
import os
import path


D: str = "projide"


async def wr(p: str, text: str):
    f = await open(p, "w")
    await f.write(text)
    await f.close()


async def build_project():
    if not path.isdir(D):
        os.makedirs(D)
    await wr(D + "/main.p", "def main() -> i32:\n    x: i32 = 1\n    return x\n")


await build_project()

files: dict<str, str> = {D + "/main.p": "def main() -> i32:\n    x: i32 = 1\n    return x\n"}

u = pui.new_ui(8, 17)
sh = sh_mod.new_shell(u, D)
sh.read_file = lambda p: sh_mod.ReadOut(True, files[p], "") if p in files else sh_mod.ReadOut(False, "", "")
sh.mtime_of = lambda p: 1
u.layout(1000, 700)

# ---- the seam itself: the shell has 28 commands, and the IDE adds 12 ----
print("editor commands=" + str(len(sh.commands)))
ide = idem.new_ide(sh)
print("with the IDE=" + str(len(sh.commands)))

# a command the editor does NOT have, offered only because the IDE registered it
sh.palette_open(sh_mod.PAL_COMMANDS)
u.set_text(sh.palinput, ">build")
sh.palette_filter()
print("build offered=" + str(len(sh.palitems) > 0) +
      " first=" + (sh.palitems[0].label if len(sh.palitems) > 0 else "-"))
sh.palette_accept()
print("asked=" + str(ide.want_build_on) + " target=[" + ide.want_build + "]" +
      " run=" + str(ide.want_run))
ide.want_build_on = False

# ---- Run is Build plus one flag, and it goes through the same request ----
sh.run_named("Run")
print("run asked=" + str(ide.want_build_on) + " and runs=" + str(ide.want_run))
ide.want_build_on = False
ide.want_run = False

# ---- a second build while one is running is refused, not queued ----
ide.build_busy = True
sh.run_named("Build")
print("busy=[" + ide.build_msg + "] asked=" + str(ide.want_build_on))
ide.build_busy = False

# ---- the target list comes from the GRAPH, which the driver puts here ----
ide.build_targets = ["build/bin/plangc_s2", "build/bin/pforge", "build/bin/pcode"]
sh.run_named("Build Target...")
u.set_text(sh.palinput, "!pcode")
sh.palette_filter()
print("targets offered=" + str(len(sh.palitems)) +
      " top=" + (sh.palitems[0].label if len(sh.palitems) > 0 else "-"))
sh.palette_accept()
print("target asked=[" + ide.want_build + "]")
ide.want_build_on = False

# ---- the error as a POSITION, and the navigation it buys ----
found = ide.mark_error(D + "/main.p:2:5: error: invented for the test\ncc: a warning\n")
print("positioned=" + str(found) + " " + str(ide.build_pos_line) + ":" + str(ide.build_pos_col))
print("went=" + str(ide.goto_error()))
cv = sh.cur_cv()
if cv != None:
    print("caret=" + str(cv.buf.caret(0).line + 1) + ":" + str(cv.buf.caret(0).col + 1) +
          " mark=" + str(cv.buf.mark_of(ide.build_pos_line - 1)))

# a line that is not a diagnostic is ignored — a `cc`'s output is full of them
ide.build_pos_file = ""
print("noise ignored=" + str(not ide.mark_error("cc: warning: something\nmake: *** [x] Error 1\n")))

# ---- the manifest: ASKING, and refusing what does not resolve ----
sh.run_named("Manifest: Add Dependency...")
print("asking=[" + sh.pal_prompt + "]")
u.set_text(sh.palinput, "semversion")
sh.palette_filter()
sh.palette_accept()
print("refused=[" + ide.build_msg + "] dep=[" + ide.want_manifest_dep + "]")
sh.run_named("Manifest: Add Dependency...")
u.set_text(sh.palinput, "tar@0.1.0")
sh.palette_filter()
sh.palette_accept()
print("accepted dep=[" + ide.want_manifest_dep + "]")

# ---- the default target has to be one that EXISTS, so the list is the graph's ----
sh.run_named("Manifest: Set Default Target...")
u.set_text(sh.palinput, "!pforge")
sh.palette_filter()
sh.palette_accept()
print("default=[" + ide.want_manifest_default + "] and did not build=" +
      str(not ide.want_build_on))

# ---- stopping is a REQUEST for the build and a killing for the program ----
sh.run_named("Stop Build")
print("stop=" + str(ide.build_stop) + " kill=" + str(ide.want_stop_run))

sh.run_named("Clean")
print("clean=" + str(ide.want_clean) + " msg=[" + ide.build_msg + "]")

# ---- F6: the three slots the editor left empty ----
#
# `pcode` builds the same three and leaves them shut; everything below is what
# `ide.psc` put in them, and none of it exists in the other binary.
print("toolbar=" + str(u.is_visible(sh.topbar)) +
      " outline=" + str(u.is_visible(sh.side)) +
      " dock=" + str(u.is_visible(sh.dock)))
sh.run_named("Toggle Outline")
print("outline shut=" + str(not u.is_visible(sh.side)))
sh.run_named("Toggle Outline")

# the outline comes from the COMPLETION index, so it works on a file nobody
# saved: open one, type into it, and ask again
sh.open_file(D + "/main.p")
ide.outline_sync()
rows = u.list_rows(ide.outline)
print("outline rows=" + str(len(rows)) +
      " first=[" + (rows[0].text if len(rows) > 0 else "-") + "]" +
      " at=" + (rows[0].detail if len(rows) > 0 else "-"))
ide.outline_picked(0)
cv2 = sh.cur_cv()
if cv2 != None:
    print("jumped to line=" + str(cv2.buf.caret(0).line + 1))
    # a declaration typed just now, never written to disk
    cv2.buf.move_to(cv2.buf.nlines() - 1, 0)
    cv2.buf.insert("def second() -> i32:\n    return 2\n", 1000)
    ide.outline_sync()
    rows2 = u.list_rows(ide.outline)
    print("after typing=" + str(len(rows2)) +
          " last=[" + (rows2[len(rows2) - 1].text if len(rows2) > 0 else "-") + "]")

# ---- the dock: four pages, one of them up ----
ide.dock_show(2)
print("dock page=" + str(ide.dock_page) + " of " + str(len(idem.dock_pages())))
ide.toggle_dock()
print("dock shut=" + str(not u.is_visible(sh.dock)))
ide.dock_open_at(0)
print("and a build reopens it=" + str(u.is_visible(sh.dock)) +
      " at page=" + str(ide.dock_page))

# ---- and what the panes look like, as `.pstudio.json` would remember them ----
u.layout(1000, 700)
c = idem.snapshot_config(ide)
print("remembered: tree=" + str(c.tree_w) + " outline_open=" + str(c.outline_open) +
      " dock_open=" + str(c.dock_open) + " target=[" + c.target + "]")

print("ide-ok")
