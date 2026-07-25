# core, headless: multi-line buffer, multi-caret, coalesced undo, ctrl+d,
# smart backspace, search (text and regex) and highlighting via the real lexer.
include <stdio.h>
include <stdlib.h>
include <string.h>
import "../../pstudio/core.ph"

static def show(ref b: Buffer):
    for i in range(b.nlines()):
        printf("|%s\n", b.line_text(i))
    printf("carets:")
    for k in range(b.ncarets()):
        c: *Caret = b.caret(k)
        printf(" %d:%d", c->line, c->col)
        if c->aline != c->line or c->acol != c->col:
            printf("(a%d:%d)", c->aline, c->acol)
    printf("\n")

def main() -> int:
    b: Buffer
    b.init()
    b.load("def soma(a, b):\n    return a + b  # ok\n", 39)
    printf("nlines=%d crlf=%d\n", b.nlines(), b.crlf)

    # coalesced typing: "xy" in a single group (same timestamp)
    b.move_to(0, 3)
    b.insert("x", 1000)
    b.insert("y", 1050)
    show(ref b)
    b.undo_step()
    printf("undo1: |%s\n", b.line_text(0))

    # a pause longer than 700ms breaks the group
    b.insert("A", 2000)
    b.insert("B", 3000)
    b.undo_step()
    printf("undo2: |%s\n", b.line_text(0))
    b.redo_step()
    printf("redo:  |%s\n", b.line_text(0))
    b.undo_step(); b.undo_step()

    # ctrl+d: select the word, then the next occurrence
    b.move_to(1, 12)   # inside the first "a" of "return a + b"
    b.ctrl_d()
    t: *char = b.sel_text(0)
    printf("word=[%s]\n", t)
    free(t)
    b.ctrl_d()
    printf("ncarets=%d\n", b.ncarets())
    # edit at both carets at once
    b.insert("z", 5000)
    show(ref b)
    b.undo_step()

    # multi-caret paste (one piece per caret, Sublime style)
    parts: *char[2] = {"P", "Q"}
    b.insert_each(parts, 2, 5500)
    show(ref b)
    b.undo_step()
    b.collapse()

    # multi-line enter + join with backspace
    b.move_to(0, 15)
    b.insert("\n    pass", 6000)
    printf("split: nlines=%d |%s\n", b.nlines(), b.line_text(1))
    b.move_to(1, 0)
    b.backspace(7000)   # joins with the previous line
    printf("join:  nlines=%d\n", b.nlines())
    b.undo_step(); b.undo_step()

    # smart backspace: at a column multiple of 4 (spaces only) it goes back 4
    b.move_to(1, 4)
    b.backspace(8000)
    printf("smart: |%s\n", b.line_text(1))
    b.undo_step()

    # word-wise movement and smart home
    b.move_to(1, 11)
    b.move_word(-1, False)
    c0: *Caret = b.caret(0)
    printf("word_left=%d:%d\n", c0->line, c0->col)
    b.home(False)
    printf("home1=%d\n", b.caret(0)->col)
    b.home(False)
    printf("home2=%d\n", b.caret(0)->col)

    # a multi-line selection replaced
    b.select_range(0, 13, 1, 11)
    b.insert("!", 9000)
    show(ref b)
    b.undo_step()
    printf("restore: nlines=%d |%s\n", b.nlines(), b.line_text(1))

    # search: text and POSIX regex, forwards and backwards, wrapping
    fl: i32; fc: i32
    printf("find(a+b)=%d ", b.find("a + b", 0, 0, True, out fl, out fc))
    printf("%d:%d\n", fl, fc)
    printf("find_back(def)=%d ", b.find("def", 1, 5, False, out fl, out fc))
    printf("%d:%d\n", fl, fc)
    rc0: i32; rc1: i32
    printf("find_re(so.a)=%d ", b.find_re("so.a", 0, 0, True, out fl, out rc0, out rc1))
    printf("%d:%d-%d\n", fl, rc0, rc1)

    # highlighting: kw/num/str/comment; and BROKEN input must not crash it
    hl: Highlight
    hl.init(True)
    hl.update(ref b)
    printf("cls(0,0)=%d cls(0,4)=%d cmt=%d\n",
           hl.class_at(0, 0), hl.class_at(0, 4), hl.class_at(1, 18))
    b.load("x = \"aberta\ndef !@?\n\xff\xfe bad", 27)
    hl.update(ref b)
    printf("tolerant=%d\n", 1 if hl.lines.len == b.nlines() else 0)
    hl.deinit()

    # save preserves the content
    n: usize
    txt: *char = b.save_text(out n)
    printf("save=%zu bytes\n", n)
    free(txt)

    b.deinit()
    printf("core-ok\n")
    return 0
