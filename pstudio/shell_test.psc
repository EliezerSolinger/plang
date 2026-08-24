"""THE EDITOR in pscript, with no keyboard and no screen (the twin of
`tests/pstudio/app_flow.p`, retired along with the editor in P).

After the cut it is `pcode`'s test: nothing here builds, tests or fetches a
package — it never did, which is what made the seam visible in the first place.

It builds a small project on disk — with `os`/`path`, 111's system layer — opens
files, types, uses the palette, the search, the tabs, the tree, folding,
commenting, the auto pairs and the completion popup, and checks the state at
every step. The drawing is exercised by a `Painter` that COUNTS commands instead
of painting pixels: with no driver, the code path is the same and what is
measured is that it runs all the way through.

What differs from the test in P, and why: there the "screenshot" is a map of the
framebuffer, which needs the rasterizer; here it is the count of the retained
commands, which is what exists on this side of the boundary.
"""
import <pui> as pui
import shell as appm
import codeview as cvm
import core
import os
import path


D: str = "projps"

rects = 0
texts = 0
glyphs = 0


def count_rect(x: int, y: int, w: int, h: int, c: int):
    global rects
    rects += 1


def count_frame(x: int, y: int, w: int, h: int, c: int):
    global rects
    rects += 1


def count_glyph(cp: int, x: int, y: int, c: int):
    global glyphs
    glyphs += 1


def nothing4(x: int, y: int, w: int, h: int):
    pass


def nothing0():
    pass


async def wr(p: str, text: str):
    f = await open(p, "w")
    await f.write(text)
    await f.close()


async def build_project():
    if path.isdir(D):
        for nm in os.listdir(D):
            full = path.join(D, nm)
            if path.isdir(full):
                for nm2 in os.listdir(full):
                    os.remove(path.join(full, nm2))
                os.rmdir(full)
            else:
                os.remove(full)
        os.rmdir(D)
    os.makedirs(D + "/sub")
    await wr(D + "/hello.p", "def main() -> i32:\n    x: i32 = 42  # answer\n    return x\n")
    await wr(D + "/util.ph", "def helper(a: i32) -> i32\n")
    await wr(D + "/sub/notes.txt", "one note\nanother note\n")


await build_project()

u = pui.new_ui(8, 17)
sh = appm.new_shell(u, D)
# the "driver": here it is synchronous and fake, which is exactly the point of
# it being injected (in the real editor it is `sh.psc` that fills this in)
saved: dict<str, str> = {}
clip = ""
title = ""
cellw = 8
cellh = 17
sh.read_file = lambda p: read_now(p)
sh.write_file = lambda p, t: write_now(p, t)
sh.mtime_of = lambda p: path.getmtime(p) if path.exists(p) else 0
sh.clip_get = lambda: clip
sh.clip_set = lambda s: set_clip(s)
sh.confirm_close = lambda name: 1        # discard, without asking
sh.confirm_reload = lambda name: True
sh.set_title = lambda t: set_title(t)


def set_title(t: str):
    global title
    title = t


# the zoom "driver" in the test: a fake grid, but the effect is the real one —
# the cell changes and the toolkit redoes the whole layout
def fake_zoom(a: appm.Shell, step: int):
    global cellw
    global cellh
    if step == 0:
        cellw = 8
        cellh = 17
    else:
        cellw += step * 2
        cellh += step * 3
    a.set_cell(cellw, cellh)


def set_clip(s: str):
    global clip
    clip = s


unreadable: dict<str, str> = {}


def read_now(p: str) -> appm.ReadOut:
    """The three states, as the driver gives them: have the text, have a reason,
    or have nothing yet (which is what makes the shell ask)."""
    if p in saved:
        return appm.ReadOut(True, saved[p], "")
    if p in unreadable:
        return appm.ReadOut(True, "", unreadable[p])
    return appm.ReadOut(False, "", "")


def write_now(p: str, t: str) -> bool:
    saved[p] = t
    return True


# the test's `read_file` reads from the table; the project's files go into it
saved[D + "/hello.p"] = "def main() -> i32:\n    x: i32 = 42  # answer\n    return x\n"
saved[D + "/util.ph"] = "def helper(a: i32) -> i32\n"
saved[D + "/sub/notes.txt"] = "one note\nanother note\n"

# F0: the three answers a read can give. An EMPTY file used to never open — `""`
# was the sentinel for "empty" and for "I could not read it" at the same time, so
# the shell asked the driver to read it again, for ever, every 500 ms, with no
# message. And a file that cannot be decoded must get NO tab: an empty tab over a
# `.png` truncates it on the next save.
saved[D + "/empty.p"] = ""
unreadable[D + "/photo.png"] = "these bytes are not valid UTF-8"

u.layout(1100, 720)
print("tree=" + str(len(sh.entries)) + " indexed_files=" + str(len(sh.files)))

sh.open_file(D + "/hello.p")
print("tabs=" + str(len(sh.tabs)) + " cur=" + str(sh.cur) + " title=" + sh.tabs[0].title)
cv = sh.tabs[0].cv
print("lines=" + str(cv.buf.nlines()) + " hl=" + ("1" if cv.hl.enabled else "0") +
      " gutter=" + str(cv.gutter_w()))

# type at the end of line 2
cv.buf.move_to(1, cv.buf.line_cp(1))
u.focus_set(cv.id)
sh.feed(pui.Event(pui.EV_TEXT, 0, 0, ord("0"), 0, 0, 0, 0, 0))
print("typed=[" + cv.buf.line_text(1) + "] dirty=" + ("1" if cv.buf.dirty else "0"))
cv.buf.undo_step()
print("undo=[" + cv.buf.line_text(1) + "]")
cv.buf.redo_step()
print("redo=[" + cv.buf.line_text(1) + "]")

# a second caret
cv.buf.add_caret(2, 0)
print("carets=" + str(cv.buf.ncarets()))

# the file palette
sh.palette_open(appm.PAL_FILES)
u.set_text(sh.palinput, "notes")
sh.palette_filter()
print("palette=" + ("1" if u.is_visible(sh.palette) else "0") +
      " top=" + (sh.palitems[0].label if len(sh.palitems) > 0 else "<empty>"))
sh.palette_accept()
print("tabs=" + str(len(sh.tabs)) + " cur=" + sh.tabs[sh.cur].title +
      " hl_txt=" + ("1" if sh.tabs[sh.cur].cv.hl.enabled else "0"))

# the command palette
sh.palette_open(appm.PAL_COMMANDS)
u.set_text(sh.palinput, ">zoom in")
sh.palette_filter()
print("cmds=" + str(len(sh.palitems)) + " top=" + sh.palitems[0].label)
sh.palette_close()

# go to line
sh.select_tab(0)
sh.palette_open(appm.PAL_GOTO)
u.set_text(sh.palinput, ":3")
sh.palette_filter()
sh.palette_accept()
print("goto=" + str(cv.buf.caret(0).line + 1))

# the search
sh.find_open()
u.set_text(sh.findinput, "42")
sh.find_changed()
print("find1=" + str(cv.buf.caret(0).line) + ":" + str(cv.buf.caret(0).col))
u.set_text(sh.findinput, "return")
sh.find_changed()
print("find2=" + str(cv.buf.caret(0).line) + ":" + str(cv.buf.caret(0).col))
sh.find_close()

# click a tab
tb = u.rect_of(sh.tabbar)
u.input_event(pui.Event(pui.EV_MOUSE_DOWN, 0, 0, 0, tb.x + 4, tb.y + 4, 1, 1, 0))
u.input_event(pui.Event(pui.EV_MOUSE_UP, 0, 0, 0, tb.x + 4, tb.y + 4, 1, 1, 0))
print("clicked_tab=" + str(sh.cur))

# the tree: expand the directory
for i in range(len(sh.entries)):
    if sh.entries[i].is_dir:
        sh.tree_toggle(i)
        break
print("tree_expanded=" + str(len(sh.entries)))

# folding, bookmark and commenting, through the commands
sh.select_tab(0)
cv = sh.tabs[0].cv
cv.buf.move_to(0, 0)
print("can_fold0=" + ("1" if cv.buf.can_fold(0) else "0"))
sh.run_named("Fold")
print("fold: folded0=" + ("1" if cv.buf.is_folded(0) else "0") +
      " visible=" + str(cv.buf.visible_count()))
sh.run_named("Fold")
print("unfold: folded0=" + ("1" if cv.buf.is_folded(0) else "0") +
      " visible=" + str(cv.buf.visible_count()))
cv.buf.move_to(1, 0)
sh.run_named("Toggle Bookmark")
print("bookmark: mark=" + str(cv.buf.mark_of(1)))
sh.run_named("Toggle Comment")
print("comment: 1=[" + cv.buf.line_text(1) + "]")
sh.run_named("Toggle Comment")
print("uncomment: 1=[" + cv.buf.line_text(1) + "]")
sh.run_named("Duplicate Line")
print("dup: lines=" + str(cv.buf.nlines()))

# auto pairs
cv.buf.move_to(1, cv.buf.line_cp(1))
sh.feed(pui.Event(pui.EV_TEXT, 0, 0, ord("("), 0, 0, 0, 0, 0))
print("pair: 1=[" + cv.buf.line_text(1) + "] col=" + str(cv.buf.caret(0).col))
sh.feed(pui.Event(pui.EV_TEXT, 0, 0, ord(")"), 0, 0, 0, 0, 0))
print("skip: 1=[" + cv.buf.line_text(1) + "] col=" + str(cv.buf.caret(0).col))

# the completion popup
cv.buf.move_to(0, 7)
cv.complete_open()
print("popup: open=" + ("1" if cv.cmp_open else "0") + " hits=" + str(len(cv.cmp_hits)))
if cv.cmp_open and len(cv.cmp_hits) > 0:
    print("first=" + cv.index.sym(cv.cmp_hits[0]).name)
cv.complete_close()

# the clipboard, through the shortcut (ctrl+c and ctrl+v)
cv.buf.select_range(core.Span(2, 0, 2, cv.buf.line_cp(2)))
sh.feed(pui.Event(pui.EV_KEY, ord("c"), 2, 0, 0, 0, 0, 0, 0))
print("clip=[" + clip + "]")

# ---- 115: what the editor's test in P measured and this one did not yet ----

# the zoom: the font cell changes, and the whole layout is redone
cell = 0
sh.zoom_step = lambda step: fake_zoom(sh, step)
sh.run_named("Zoom In")
print("zoom: cell=" + str(u.cell_h))
sh.run_named("Zoom Reset")
print("zoom reset: cell=" + str(u.cell_h))

# the click on the GUTTER, by pixel: the mark one sets and clears the breakpoint
gx = u.rect_of(cv.id).x + 2
gy = cv.text_rect().y + 2
u.input_event(pui.Event(pui.EV_MOUSE_DOWN, 0, 0, 0, gx, gy, 1, 1, 0))
print("gutter mark: " + str(cv.buf.mark_of(cv.line_at_row(0))))
u.input_event(pui.Event(pui.EV_MOUSE_DOWN, 0, 0, 0, gx, gy, 1, 1, 0))
print("gutter unmark: " + str(cv.buf.mark_of(cv.line_at_row(0))))

# the click on the FOLD gutter (the second column)
fx = u.rect_of(cv.id).x + cv.gutters[0].width_cp * u.cell_w + 2
u.input_event(pui.Event(pui.EV_MOUSE_DOWN, 0, 0, 0, fx, gy, 1, 1, 0))
print("gutter fold: folded0=" + ("1" if cv.buf.is_folded(0) else "0") +
      " visible=" + str(cv.buf.visible_count()))

# 115: an EDIT inside the collapsed block releases it — the missing invariant
cv.buf.move_to(0, cv.buf.line_cp(0))
sh.feed(pui.Event(pui.EV_TEXT, 0, 0, ord(" "), 0, 0, 0, 0, 0))
print("edit unfolds: folded0=" + ("1" if cv.buf.is_folded(0) else "0") +
      " hidden1=" + ("1" if cv.buf.is_hidden(1) else "0"))

# move a line, and the pair's backspace
cv.buf.move_to(2, 0)
before_line = cv.buf.line_text(2)
sh.run_named("Move Line Up")
print("moved: caret=" + str(cv.buf.caret(0).line) + " same=" + ("1" if cv.buf.line_text(1) == before_line else "0"))
cv.buf.move_to(1, cv.buf.line_cp(1))
sh.feed(pui.Event(pui.EV_TEXT, 0, 0, ord("("), 0, 0, 0, 0, 0))
sh.feed(pui.Event(pui.EV_KEY, pui.K_BACKSPACE, 0, 0, 0, 0, 0, 0, 0))
print("pair_bs: 1=[" + cv.buf.line_text(1) + "]")

# accept a candidate from the popup
cv.buf.move_to(0, 7)
cv.complete_open()
if cv.cmp_open:
    cv.complete_accept(sh.now_ms)
print("accepted: 0=[" + cv.buf.line_text(0) + "] open=" + ("1" if cv.cmp_open else "0"))

# F2: sets the bookmark (ctrl+F2), walks between bookmarks (F2)
cv.buf.move_to(2, 0)
sh.feed(pui.Event(pui.EV_KEY, appm.K_F2, 2, 0, 0, 0, 0, 0, 0))
print("f2 mark: " + str(cv.buf.mark_of(2)))
cv.buf.move_to(0, 0)
sh.feed(pui.Event(pui.EV_KEY, appm.K_F2, 0, 0, 0, 0, 0, 0, 0))
print("f2 goto: caret=" + str(cv.buf.caret(0).line))

# the window title follows the tab
print("title=[" + title + "]")

# the status bar
sh.update_status()
print("status=[" + u.text_of(sh.status) + "]")

# ONE FRAME: the whole retained drawing, with a painter that counts
p = pui.Painter(count_rect, count_frame, nothing4, nothing0, count_glyph)
u.draw(p, 1100, 720)
print("draw: rects=" + str(rects) + " glyphs=" + str(glyphs))

# F0: the empty file opens (one line), and the unreadable one does not open at all
sh.open_file(D + "/empty.p")
ntabs = len(sh.tabs)
print("empty opens=" + ("1" if sh.tabs[ntabs - 1].cv.path == D + "/empty.p" else "0") +
      " lines=" + str(sh.tabs[ntabs - 1].cv.buf.nlines()))
sh.open_file(D + "/photo.png")
print("unreadable stays out=" + ("1" if len(sh.tabs) == ntabs else "0") +
      " said=[" + sh.want_msg + "]")
sh.want_msg = ""
sh.close_tab(ntabs - 1)
sh.select_tab(0)          # back to hello.p, which is what the save below checks

# F0: a reload does NOT read the cache. The fake driver's table is the "disk":
# change it, ask, and the buffer has to follow. Reading the cache made both
# "Reload File" and the external-change reload hand back the OLD text.
saved[D + "/hello.p"] = "def main() -> i32:\n    return 7\n"
sh.reload_cur()
print("reload asked=" + str(len(sh.want_reload)) + " for=" +
      (path.basename(sh.want_reload[0]) if len(sh.want_reload) > 0 else "-"))
sh.reload_now(D + "/hello.p", saved[D + "/hello.p"])
print("reloaded=[" + sh.tabs[0].cv.buf.line_text(1) + "]")

# save and close
sh.save_cur()
print("saved=" + ("1" if len(saved[D + "/hello.p"]) > 0 else "0") +
      " dirty=" + ("1" if cv.buf.dirty else "0"))
while len(sh.tabs) > 0:
    sh.close_tab(0)
print("tabs=" + str(len(sh.tabs)))
print("pcode-ok")
