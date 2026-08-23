"""pui in pscript, headless: the tree, the layout's two phases, the hit-test, the
button's signal, the scrollbar, the one-line input and the freelist.

It is the twin of `tests/pstudio/pui_layout.p`, which did the same with the pui in
P (retired along with the editor in P) — and the point of the test is that **the
eight rectangle lines are identical**: the ported Godot arithmetic cannot have
slipped on a rounding. The font cell (8 x 17) is passed in from outside, which is
how the toolkit in pscript needs no window to be measured.

Two lines DIFFER on purpose, and why:
  * `changes=5` (in P, 3): the shim's text event carries ONE codepoint, not a
    string, so `abc` is three events. That is the scalar boundary (45.5), not a
    difference in behaviour.
  * `draw_cmds` instead of `draw_lit`: with no framebuffer there is no pixel to
    count, and what is counted is what the retained drawing produced — which is
    the most direct measure of the same code path.
"""
import <pui> as ui


clicks = 0
changes = 0
submits = 0

u = ui.new_ui(8, 17)


def bump_click():
    global clicks
    clicks += 1


def bump_change():
    global changes
    changes += 1


def bump_submit():
    global submits
    submits += 1


def show(id: int):
    r = u.rect_of(id)
    print("[" + str(id) + "] " + str(r.x) + "," + str(r.y) + " " + str(r.w) + "x" + str(r.h))


def key(k: int):
    u.input_event(ui.Event(ui.EV_KEY, k, 0, 0, 0, 0, 0, 0, 0))


def typed(s: str):
    for ch in s:
        u.input_event(ui.Event(ui.EV_TEXT, 0, 0, ord(ch), 0, 0, 0, 0, 0))


def mouse(kind: ui.EvKind, x: int, y: int, button: int) -> bool:
    return u.input_event(ui.Event(kind, 0, 0, 0, x, y, button, 1, 0))


# root: vbox [ label | hbox [ button A | button B(expands) ] | split ]
root = u.box(-1, True)
lbl = u.label(root, "title")
row = u.box(root, False)
ba = u.button(row, "A")
bb = u.button(row, "B")
u.set_expand(bb, True, False)
sp = u.split(root, False)
u.set_expand(sp, True, True)
left = u.panel(sp)
u.set_min(left, 40, 0)
right = u.panel(sp)
u.set_min(right, 40, 0)
u.split_set(sp, 80)

u.layout(240, 120)
show(root)
show(lbl)
show(row)
show(ba)
show(bb)
show(sp)
show(left)
show(right)

# a synthetic click on button A: press and release inside its rectangle
u.on_click(ba, lambda id, arg: bump_click())
r = u.rect_of(ba)
c1 = mouse(ui.EV_MOUSE_DOWN, r.x + 2, r.y + 2, 1)
c2 = mouse(ui.EV_MOUSE_UP, r.x + 2, r.y + 2, 1)
print("click: handled=" + ("1" if c1 else "0") + ("1" if c2 else "0") + " fired=" + str(clicks) + " focus_on_button=" + ("1" if u.focus_get() == ba else "0"))
print("hit_split_handle=" + ("1" if u.hit(80 + 2, 60) == sp else "0"))

# the scrollbar: set, clamp, read
sb = u.scrollbar(root, True)
u.scroll_set(sb, 1000, 100, 5000)      # clamps to 900
print("scroll=" + str(u.scroll_value(sb)))

# the one-line input: type, move, delete, submit
inp = u.line_input(root)
u.on_changed(inp, lambda id, arg: bump_change())
u.on_submit(inp, lambda id, arg: bump_submit())
u.focus_set(inp)
typed("ábc")
typed("!")
key(ui.K_LEFT)
key(ui.K_BACKSPACE)
print("input=[" + u.text_of(inp) + "] changes=" + str(changes))
key(ui.K_RETURN)
print("submits=" + str(submits))

# the retained drawing: relayout and build everything, counting the commands
u.layout(240, 120)
print("draw_cmds=" + ("1" if u.build_all() > 10 else "0"))

# hiding a widget takes it out of the layout and out of the hit-test
u.set_visible(row, False)
print("hidden_hit=" + ("1" if u.hit(u.rect_of(ba).x + 1, u.rect_of(ba).y + 1) != ba else "0"))
u.set_visible(row, True)

# freelist: free the row and create another node — it reuses an id from the subtree
u.free_node(row)
n2 = u.label(root, "new")
print("reuse=" + ("1" if n2 == row or n2 == ba or n2 == bb else "0"))
print("pui-ok")
