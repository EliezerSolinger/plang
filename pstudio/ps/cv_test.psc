"""The ported codeview, headless: folding from the gutter, the view's anchor,
folding from the keyboard — the same thing `tests/pstudio/cv_fold_scroll.p`
measured in the editor in P (retired along with it).

The printed lines are the SAME, because the arithmetic is the same: 40 blocks of
4 lines, the view scrolled far from the caret, and the rule that folding from the
GUTTER does not scroll (Godot/Sublime) while folding from the KEYBOARD brings the
caret into view.

With no window: the toolkit gets the font cell (8 x 17) as a parameter, and the
codeview talks to no driver at all — not for files (the text comes in through
`load_text`) and not for the clipboard (it is the app that talks to the system).
"""
import <pui> as pui
import lib_cv as cvm


def make_src() -> str:
    parts: list<str> = []
    for i in range(40):
        parts.append("def f" + str(i) + "():")
        for j in range(3):
            parts.append("    line " + str(j) + " of " + str(i))
    return "\n".join(parts) + "\n"


u = pui.new_ui(8, 17)
root = u.box(-1, True)
cv = cvm.cv_create(u, root)
u.layout(600, 300)
cv.load_text("demo.p", make_src(), 0)

vis = cv.visible_lines()
print("lines=" + str(cv.buf.nlines()) + " visible_rows=" + str(vis))


# the middle of the fold gutter (the second one: marks, folding, numbers)
def fold_gutter_x() -> int:
    r = u.rect_of(cv.id)
    return r.x + cv.gutters[0].width_cp * u.cell_w + u.cell_w // 2


def click_fold(row: int):
    tr = cv.text_rect()
    y = tr.y + row * u.cell_h + u.cell_h // 2
    u.input_event(pui.Event(pui.EV_MOUSE_DOWN, 0, 0, 0, fold_gutter_x(), y, 1, 1, 0))
    u.input_event(pui.Event(pui.EV_MOUSE_UP, 0, 0, 0, fold_gutter_x(), y, 1, 1, 0))


# the caret stays at the top of the file; the view is scrolled down
cv.set_top(20)
print("top=" + str(cv.top) + " caret=" + str(cv.buf.caret(0).line))

# fold a header that is on screen, far from the caret
hdr = cv.line_at_row(4)
while hdr % 4 != 0:
    hdr += 1
click_fold(cv.row_of_line(hdr))
print("folded=" + ("1" if cv.buf.is_folded(hdr) else "0") + " top=" + str(cv.top) + " (was 20) caret=" + str(cv.buf.caret(0).line))

# unfolding from the gutter is just as quiet
before = cv.top
click_fold(cv.row_of_line(hdr))
print("unfold: top=" + str(cv.top) + " (was " + str(before) + ") folded=" + ("1" if cv.buf.is_folded(hdr) else "0"))

# `fold all` with the view INSIDE a block: its header takes the first row — the
# case where the anchor really has to walk backwards
cv.set_top(cv.buf.to_visible(22))
inner = cv.top
cv.fold_all()
print("fold_all: inner=" + str(inner) + " -> top=" + str(cv.top) + " hidden(inner)=" + ("1" if cv.buf.is_hidden(inner) else "0") + " caret=" + str(cv.buf.caret(0).line))
cv.unfold_all()
print("unfold_all: top=" + str(cv.top))

# the KEYBOARD command is caret-driven on purpose: it has to bring the caret
# into view (the header it lands on), unlike the gutter
cv.buf.move_to(40, 0)
cv.set_top(0)
cv.toggle_fold_at_caret()
print("at_caret: top=" + str(cv.top) + " caret=" + str(cv.buf.caret(0).line) + " folded=" + ("1" if cv.buf.is_folded(40) else "0"))

# ---- highlighting and completion, through the lexer adapter (113) ----
cv.load_text("demo.p", "def sum(a: i32, b: i32) -> i32:\n    x: i32 = 42 + b   # math\n    return x\n", 0)
# 1=word of the language, 0=plain text, 3=number, 4=comment (lib_hl)
print("hl: kw=" + str(cv.hl.class_at(0, 0)) + " ident=" + str(cv.hl.class_at(0, 4)) +
      " num=" + str(cv.hl.class_at(1, 13)) + " comment=" + str(cv.hl.class_at(1, 22)) +
      " outside=" + str(cv.hl.class_at(1, 19)))
cv.index.build(cv.buf, [])
hits = cv.index.query("su", "")
print("cmp: " + (cv.index.sym(hits[0]).name if len(hits) > 0 else "<none>") +
      " detail=[" + (cv.index.sym(hits[0]).detail if len(hits) > 0 else "") + "]")
own = cv.index.owner_of("x")
print("owner_of(x)=" + own)
print("fold-scroll-ok")
