# core, headless: the line-oriented commands (move/duplicate/delete/join,
# toggle comment) and code folding with its visible-line mapping.
include <stdio.h>
include <stdlib.h>
include <string.h>
import "../../pstudio/core.ph"

SRC: const *char = "def a(x: i32) -> i32:\n    if x > 0:\n        return x\n    return 0\n\ndef b():\n    pass\n"

static def show(ref b: Buffer):
    for i in range(b.nlines()):
        printf("%s%d|%s\n", "-" if b.is_hidden(i) else " ", i, b.line_text(i))

static def carets(ref b: Buffer):
    printf("carets:")
    for k in range(b.ncarets()):
        printf(" %d:%d", b.caret(k)->line, b.caret(k)->col)
    printf("\n")

def main() -> int:
    b: Buffer
    b.init()
    b.load(SRC, strlen(SRC))
    printf("lines=%d\n", b.nlines())

    # ---- move lines ----
    b.move_to(2, 4)                 # "        return x"
    b.move_lines(-1, 1000)
    printf("up:   1=[%s] 2=[%s] caret=%d\n", b.line_text(1), b.line_text(2), b.caret(0)->line)
    b.move_lines(1, 1100)
    printf("down: 1=[%s] 2=[%s] caret=%d\n", b.line_text(1), b.line_text(2), b.caret(0)->line)
    b.undo_step(); b.undo_step()
    printf("undo: 1=[%s] 2=[%s]\n", b.line_text(1), b.line_text(2))

    # a block selection moves as one, and the last line cannot go down
    b.select_range(1, 0, 3, 0)      # lines 1..2
    b.move_lines(1, 1200)
    printf("block: 1=[%s] 2=[%s] 3=[%s]\n", b.line_text(1), b.line_text(2), b.line_text(3))
    b.undo_step()
    b.move_to(b.nlines() - 1, 0)
    b.move_lines(1, 1300)           # no-op at the end of the file
    printf("edge: lines=%d\n", b.nlines())

    # ---- duplicate / delete / join ----
    b.move_to(5, 2)
    b.duplicate_lines(1400)
    printf("dup: 5=[%s] 6=[%s] caret=%d:%d\n", b.line_text(5), b.line_text(6),
           b.caret(0)->line, b.caret(0)->col)
    b.delete_lines(1500)
    printf("del: 5=[%s] lines=%d caret=%d\n", b.line_text(5), b.nlines(), b.caret(0)->line)
    b.undo_step(); b.undo_step()
    b.move_to(1, 0)
    b.join_lines(1600)
    printf("join: 1=[%s] lines=%d\n", b.line_text(1), b.nlines())
    b.undo_step()

    # ---- multi-caret: two blocks at once ----
    b.move_to(1, 0)
    b.add_caret(5, 0)
    b.duplicate_lines(1700)
    printf("multi: 1=[%s] 2=[%s] 6=[%s] 7=[%s]\n",
           b.line_text(1), b.line_text(2), b.line_text(6), b.line_text(7))
    carets(ref b)
    b.undo_step()
    b.collapse()

    # ---- toggle comment ----
    b.select_range(1, 0, 3, 0)      # lines 1..2, indents 4 and 8
    b.toggle_comment("#", 1800)
    printf("cmt:  1=[%s] 2=[%s]\n", b.line_text(1), b.line_text(2))
    b.toggle_comment("#", 1900)     # every line commented -> removes
    printf("uncmt: 1=[%s] 2=[%s]\n", b.line_text(1), b.line_text(2))
    b.undo_step(); b.undo_step()
    printf("after_undo: 1=[%s]\n", b.line_text(1))
    b.collapse()

    # ---- folding ----
    printf("can_fold: 0=%d 1=%d 2=%d 4=%d\n",
           b.can_fold(0), b.can_fold(1), b.can_fold(2), b.can_fold(4))
    printf("fold_end: 0=%d 1=%d 5=%d\n", b.fold_end(0), b.fold_end(1), b.fold_end(5))
    b.fold(1)                        # the inner `if` block
    printf("inner folded: %d hidden2=%d visible=%d\n",
           b.is_folded(1), b.is_hidden(2), b.visible_count())
    b.fold(0)                        # now the outer `def`
    show(ref b)
    printf("visible=%d\n", b.visible_count())
    # mapping: rows <-> lines
    printf("map: to_vis(5)=%d from_vis(1)=%d next(0,+1)=%d next(5,-1)=%d\n",
           b.to_visible(5), b.from_visible(1), b.next_visible(0, 1), b.next_visible(5, -1))
    # vertical movement skips the collapsed block
    b.move_to(0, 0)
    b.move_v(1, False)
    printf("down_over_fold=%d\n", b.caret(0)->line)
    # unfolding the outer keeps the inner collapsed (Godot leaves it dangling)
    b.unfold(0)
    printf("outer open: folded1=%d hidden2=%d hidden3=%d visible=%d\n",
           b.is_folded(1), b.is_hidden(2), b.is_hidden(3), b.visible_count())
    b.unfold(1)
    printf("all open: visible=%d\n", b.visible_count())

    # a caret inside the block is pulled onto the header
    b.move_to(2, 8)
    b.fold(1)
    printf("caret pulled: %d:%d\n", b.caret(0)->line, b.caret(0)->col)

    # editing the header releases the fold (the invariant)
    b.move_to(1, b.line_cp(1))
    b.insert("  ", 2000)
    printf("edit released: folded1=%d hidden2=%d visible=%d\n",
           b.is_folded(1), b.is_hidden(2), b.visible_count())
    b.undo_step()

    # fold_all folds the outermost blocks only (level 1)
    b.fold_all()
    printf("fold_all: visible=%d folded0=%d folded5=%d\n",
           b.visible_count(), b.is_folded(0), b.is_folded(5))
    b.unfold_all()
    printf("unfold_all: visible=%d\n", b.visible_count())

    b.deinit()
    printf("core-lines-ok\n")
    return 0
