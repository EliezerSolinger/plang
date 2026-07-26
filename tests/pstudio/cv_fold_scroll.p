# Folding from the GUTTER must not scroll the view. It used to call
# scroll_to_caret(), so clicking a fold arrow while the caret sat elsewhere
# (line 0 of a freshly opened file, say) threw the reader back to the top.
# Also checks the other half: folding the block the viewport STARTS on keeps
# that block's header as the first row instead of skipping past the block.
include <stdio.h>
include <stdlib.h>
include <string.h>
import "../../pstudio/codeview.ph"
import "../../selfhost/plang.ph"     # StrBuf, to build the source text

# 40 foldable blocks of 4 lines each: `def fN():` + 3 indented lines. Enough
# that the document still overflows the viewport with EVERY block collapsed —
# otherwise there is nothing to scroll and every anchor trivially lands on 0.
static def make_src() -> *char:
    b: StrBuf = {0}
    for i in range(40):
        b.printf("def f%d():\n", i)
        for j in range(3):
            b.printf("    line %d of %d\n", j, i)
    return b.data

# middle of the fold gutter (the second one: marks, fold, numbers)
static def fold_gutter_x(in cv: CodeView) -> i32:
    r: PgRect = cv.ui->rect_of(cv.id)
    cw: i32 = cv.ui->font.char_w()
    return r.x + cv.gutters[0].width_cp * cw + cw / 2

static def click_fold(ref ui: Ui, in cv: CodeView, row: i32):
    tr: PgRect = cv.text_rect()
    ev: PgEvent = {0}
    ev.kind = PGE_MOUSE_DOWN
    ev.button = 1
    ev.clicks = 1
    ev.x = fold_gutter_x(in cv)
    ev.y = tr.y + row * ui.font.line_h() + ui.font.line_h() / 2
    ui.input_event(&ev)
    ev.kind = PGE_MOUSE_UP
    ui.input_event(&ev)

def main() -> int:
    ui: Ui
    ui.init(pg_font_default(pg_font_default_size()))
    root: i32 = ui.box(-1, True)
    id: i32 = cv_create(ref ui, root)
    ui.layout(600, 300)
    cv: *CodeView = cv_of(ref ui, id)
    src: *char = make_src()
    cv->buf.load(src, strlen(src))
    cv->changed()
    vis: i32 = cv->visible_lines()
    printf("lines=%d visible_rows=%d\n", cv->buf.lines.len, vis)

    # the caret stays at the top of the file; the view is scrolled down
    cv->set_top(20)
    printf("top=%d caret=%d\n", cv->top, cv->buf.caret(0)->line)

    # fold a header that is on screen, a long way from the caret
    hdr: i32 = cv->line_at_row(4)
    while hdr % 4 != 0:                # land on a `def fN():` line
        hdr += 1
    row: i32 = cv->row_of_line(hdr)
    click_fold(ref ui, in *cv, row)
    printf("folded=%d top=%d (era 20) caret=%d\n", cv->buf.is_folded(hdr), cv->top,
           cv->buf.caret(0)->line)

    # unfolding from the gutter is just as quiet
    before: i32 = cv->top
    click_fold(ref ui, in *cv, cv->row_of_line(hdr))
    printf("unfold: top=%d (era %d) folded=%d\n", cv->top, before, cv->buf.is_folded(hdr))

    # `fold all` with the viewport INSIDE a block: the block's header takes the
    # top row — the one case where the anchor really has to walk backwards
    cv->set_top(cv->buf.to_visible(22))       # `    line 1 of 5`, an inner line
    inner: i32 = cv->top
    cv->fold_all()
    printf("fold_all: inner=%d -> top=%d hidden(inner)=%d caret=%d\n",
           inner, cv->top, cv->buf.is_hidden(inner), cv->buf.caret(0)->line)
    cv->unfold_all()
    printf("unfold_all: top=%d\n", cv->top)

    # the KEYBOARD command is caret-driven on purpose: it must bring the caret
    # into view (the fold header it lands on), unlike the gutter
    c: *Caret = cv->buf.caret(0)
    c->line = 40; c->col = 0; c->aline = 40; c->acol = 0
    cv->set_top(0)
    cv->toggle_fold_at_caret()
    printf("at_caret: top=%d caret=%d folded=%d\n", cv->top, cv->buf.caret(0)->line,
           cv->buf.is_folded(40))

    free(src)
    ui.deinit()
    printf("fold-scroll-ok\n")
    return 0
