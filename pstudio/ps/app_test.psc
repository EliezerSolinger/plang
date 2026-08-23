"""THE WHOLE EDITOR in pscript, with no keyboard and no screen (the twin of
`tests/pstudio/app_flow.p`, retired along with the editor in P).

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
import lib_app as appm
import lib_cv as cvm
import lib_core as core
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
app = appm.new_app(u, D)
# the "driver": here it is synchronous and fake, which is exactly the point of
# it being injected (in the real editor it is `app.psc` that fills this in)
saved: dict<str, str> = {}
clip = ""
title = ""
cellw = 8
cellh = 17
app.read_file = lambda p: read_now(p)
app.write_file = lambda p, t: write_now(p, t)
app.mtime_of = lambda p: path.getmtime(p) if path.exists(p) else 0
app.clip_get = lambda: clip
app.clip_set = lambda s: set_clip(s)
app.confirm_close = lambda name: 1        # discard, without asking
app.confirm_reload = lambda name: True
app.set_title = lambda t: set_title(t)


def set_title(t: str):
    global title
    title = t


# the zoom "driver" in the test: a fake grid, but the effect is the real one —
# the cell changes and the toolkit redoes the whole layout
def fake_zoom(a: appm.App, step: int):
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


def read_now(p: str) -> str:
    if p in saved:
        return saved[p]
    return ""


def write_now(p: str, t: str) -> bool:
    saved[p] = t
    return True


# the test's `read_file` reads from the table; the project's files go into it
saved[D + "/hello.p"] = "def main() -> i32:\n    x: i32 = 42  # answer\n    return x\n"
saved[D + "/util.ph"] = "def helper(a: i32) -> i32\n"
saved[D + "/sub/notes.txt"] = "one note\nanother note\n"

u.layout(1100, 720)
print("tree=" + str(len(app.entries)) + " indexed_files=" + str(len(app.files)))

app.open_file(D + "/hello.p")
print("tabs=" + str(len(app.tabs)) + " cur=" + str(app.cur) + " title=" + app.tabs[0].title)
cv = app.tabs[0].cv
print("lines=" + str(cv.buf.nlines()) + " hl=" + ("1" if cv.hl.enabled else "0") +
      " gutter=" + str(cv.gutter_w()))

# type at the end of line 2
cv.buf.move_to(1, cv.buf.line_cp(1))
u.focus_set(cv.id)
app.feed(pui.Event(pui.EV_TEXT, 0, 0, ord("0"), 0, 0, 0, 0, 0))
print("typed=[" + cv.buf.line_text(1) + "] dirty=" + ("1" if cv.buf.dirty else "0"))
cv.buf.undo_step()
print("undo=[" + cv.buf.line_text(1) + "]")
cv.buf.redo_step()
print("redo=[" + cv.buf.line_text(1) + "]")

# a second caret
cv.buf.add_caret(2, 0)
print("carets=" + str(cv.buf.ncarets()))

# the file palette
app.palette_open(appm.PAL_FILES)
u.set_text(app.palinput, "notes")
app.palette_filter()
print("palette=" + ("1" if u.is_visible(app.palette) else "0") +
      " top=" + (app.palitems[0].label if len(app.palitems) > 0 else "<empty>"))
app.palette_accept()
print("tabs=" + str(len(app.tabs)) + " cur=" + app.tabs[app.cur].title +
      " hl_txt=" + ("1" if app.tabs[app.cur].cv.hl.enabled else "0"))

# the command palette
app.palette_open(appm.PAL_COMMANDS)
u.set_text(app.palinput, ">zoom in")
app.palette_filter()
print("cmds=" + str(len(app.palitems)) + " top=" + app.palitems[0].label)
app.palette_close()

# go to line
app.select_tab(0)
app.palette_open(appm.PAL_GOTO)
u.set_text(app.palinput, ":3")
app.palette_filter()
app.palette_accept()
print("goto=" + str(cv.buf.caret(0).line + 1))

# the search
app.find_open()
u.set_text(app.findinput, "42")
app.find_changed()
print("find1=" + str(cv.buf.caret(0).line) + ":" + str(cv.buf.caret(0).col))
u.set_text(app.findinput, "return")
app.find_changed()
print("find2=" + str(cv.buf.caret(0).line) + ":" + str(cv.buf.caret(0).col))
app.find_close()

# click a tab
tb = u.rect_of(app.tabbar)
u.input_event(pui.Event(pui.EV_MOUSE_DOWN, 0, 0, 0, tb.x + 4, tb.y + 4, 1, 1, 0))
u.input_event(pui.Event(pui.EV_MOUSE_UP, 0, 0, 0, tb.x + 4, tb.y + 4, 1, 1, 0))
print("clicked_tab=" + str(app.cur))

# the tree: expand the directory
for i in range(len(app.entries)):
    if app.entries[i].is_dir:
        app.tree_toggle(i)
        break
print("tree_expanded=" + str(len(app.entries)))

# folding, bookmark and commenting, through the commands
app.select_tab(0)
cv = app.tabs[0].cv
cv.buf.move_to(0, 0)
print("can_fold0=" + ("1" if cv.buf.can_fold(0) else "0"))
app.run_command(11)
print("fold: folded0=" + ("1" if cv.buf.is_folded(0) else "0") +
      " visible=" + str(cv.buf.visible_count()))
app.run_command(11)
print("unfold: folded0=" + ("1" if cv.buf.is_folded(0) else "0") +
      " visible=" + str(cv.buf.visible_count()))
cv.buf.move_to(1, 0)
app.run_command(20)
print("bookmark: mark=" + str(cv.buf.mark_of(1)))
app.run_command(14)
print("comment: 1=[" + cv.buf.line_text(1) + "]")
app.run_command(14)
print("uncomment: 1=[" + cv.buf.line_text(1) + "]")
app.run_command(17)
print("dup: lines=" + str(cv.buf.nlines()))

# auto pairs
cv.buf.move_to(1, cv.buf.line_cp(1))
app.feed(pui.Event(pui.EV_TEXT, 0, 0, ord("("), 0, 0, 0, 0, 0))
print("pair: 1=[" + cv.buf.line_text(1) + "] col=" + str(cv.buf.caret(0).col))
app.feed(pui.Event(pui.EV_TEXT, 0, 0, ord(")"), 0, 0, 0, 0, 0))
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
app.feed(pui.Event(pui.EV_KEY, ord("c"), 2, 0, 0, 0, 0, 0, 0))
print("clip=[" + clip + "]")

# ---- 115: what the editor's test in P measured and this one did not yet ----

# the zoom: the font cell changes, and the whole layout is redone
cell = 0
app.zoom_step = lambda step: fake_zoom(app, step)
app.run_command(5)                 # Zoom In
print("zoom: cell=" + str(u.cell_h))
app.run_command(7)                 # Zoom Reset
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
app.feed(pui.Event(pui.EV_TEXT, 0, 0, ord(" "), 0, 0, 0, 0, 0))
print("edit unfolds: folded0=" + ("1" if cv.buf.is_folded(0) else "0") +
      " hidden1=" + ("1" if cv.buf.is_hidden(1) else "0"))

# move a line, and the pair's backspace
cv.buf.move_to(2, 0)
before_line = cv.buf.line_text(2)
app.run_command(15)                # Move Line Up
print("moved: caret=" + str(cv.buf.caret(0).line) + " same=" + ("1" if cv.buf.line_text(1) == before_line else "0"))
cv.buf.move_to(1, cv.buf.line_cp(1))
app.feed(pui.Event(pui.EV_TEXT, 0, 0, ord("("), 0, 0, 0, 0, 0))
app.feed(pui.Event(pui.EV_KEY, pui.K_BACKSPACE, 0, 0, 0, 0, 0, 0, 0))
print("pair_bs: 1=[" + cv.buf.line_text(1) + "]")

# accept a candidate from the popup
cv.buf.move_to(0, 7)
cv.complete_open()
if cv.cmp_open:
    cv.complete_accept(app.now_ms)
print("accepted: 0=[" + cv.buf.line_text(0) + "] open=" + ("1" if cv.cmp_open else "0"))

# F2: sets the bookmark (ctrl+F2), walks between bookmarks (F2)
cv.buf.move_to(2, 0)
app.feed(pui.Event(pui.EV_KEY, appm.K_F2, 2, 0, 0, 0, 0, 0, 0))
print("f2 mark: " + str(cv.buf.mark_of(2)))
cv.buf.move_to(0, 0)
app.feed(pui.Event(pui.EV_KEY, appm.K_F2, 0, 0, 0, 0, 0, 0, 0))
print("f2 goto: caret=" + str(cv.buf.caret(0).line))

# the window title follows the tab
print("title=[" + title + "]")

# the status bar
app.update_status()
print("status=[" + u.text_of(app.status) + "]")

# ONE FRAME: the whole retained drawing, with a painter that counts
p = pui.Painter(count_rect, count_frame, nothing4, nothing0, count_glyph)
u.draw(p, 1100, 720)
print("draw: rects=" + str(rects) + " glyphs=" + str(glyphs))

# save and close
app.save_cur()
print("saved=" + ("1" if len(saved[D + "/hello.p"]) > 0 else "0") +
      " dirty=" + ("1" if cv.buf.dirty else "0"))
while len(app.tabs) > 0:
    app.close_tab(0)
print("tabs=" + str(len(app.tabs)))
print("app-ok")
