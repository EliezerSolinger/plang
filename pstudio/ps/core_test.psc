"""pstudio's editing buffer, ported to pscript — the trial by fire.

The same model the P version fixed (multi-caret, coalesced undo, folding,
marks), exercised headless: typing, selection, movement by word, undo/redo,
search and replace, whole-line commands, and the fold that hides lines without
deleting them.

What the port is really testing is whether the language holds a real program
together: a struct that owns lists of structs, records passed by value, string
slicing by codepoint, and about forty methods that mutate shared state.
"""

import lib_core as core


def show(b: core.Buffer) -> str:
    out = ""
    for i in range(b.nlines()):
        if i > 0:
            out += "|"
        out += b.line_text(i)
    return out


def carets(b: core.Buffer) -> str:
    out = ""
    for k in range(b.ncarets()):
        c = b.caret(k)
        if k > 0:
            out += " "
        out += str(c.line) + ":" + str(c.col)
    return out


b = core.new_buffer()
b.load("hello\nworld\n")
print("lines", b.nlines(), "text", show(b))

# typing coalesces into ONE undo group; a space breaks it
b.move_to(0, 5)
b.insert(",", 100)
b.insert(" there", 150)
print("typed", show(b), "carets", carets(b))
b.undo_step()
print("undo1", show(b))
b.undo_step()
print("undo2", show(b))
b.redo_step()
print("redo", show(b))

# selection and word movement
b.load("alpha beta gamma\nsecond line\n")
b.move_to(0, 0)
b.move_word(1, False)
print("word", carets(b))
b.move_word(1, True)
print("selected", "[" + b.sel_text(0) + "]")
b.insert("X", 200)
print("replaced", show(b))

# multi-caret: ctrl+d selects the word, then each next occurrence
b.load("cat dog cat dog cat\n")
b.move_to(0, 0)
b.ctrl_d()
b.ctrl_d()
b.ctrl_d()
print("ncarets", b.ncarets(), "at", carets(b))
b.insert("!", 300)
print("multi", show(b))

# search
b.load("one two three\nfour two six\n")
hit = b.find("two", 0, 0, True)
h = hit ?? core.Span(-1, -1, -1, -1)
print("found", h.l0, h.c0, h.l1, h.c1)
again = b.find("two", 0, h.c1, True)
h2 = again ?? core.Span(-1, -1, -1, -1)
print("next", h2.l0, h2.c0)
print("missing", b.find("nope", 0, 0, True) == None)
print("count", len(b.find_all("two")))

n = b.replace_all("two", "2", 400)
print("replaced", n, show(b))

# whole-line commands
b.load("a\nb\nc\n")
b.move_to(1, 0)
b.duplicate_lines(500)
print("dup", show(b))
b.move_to(0, 0)
b.indent(1, 600)
print("indent", show(b))
b.indent(-1, 700)
print("dedent", show(b))
b.move_to(0, 0)
b.toggle_comment("#", 800)
print("comment", show(b))
b.toggle_comment("#", 900)
print("uncomment", show(b))

# folding: hidden, not deleted
b.load("def f():\n    body\n    more\nafter\n")
print("can fold", b.can_fold(0), "end", b.fold_end(0))
b.fold(0)
print("folded", b.is_folded(0), b.is_hidden(1), b.is_hidden(2), b.is_hidden(3))
print("still there", show(b))
b.unfold(0)
print("unfolded", b.is_hidden(1))

# marks travel with the line
b.toggle_mark(2, core.MARK_BREAK)
print("mark", b.mark_of(2), b.mark_of(1))

# CRLF is detected on load and preserved on save
b.load("x\r\ny\r\n")
print("crlf", b.crlf, "lines", b.nlines())
print("roundtrip", len(b.text()))

# backspace joins lines, delete_fwd eats forward
b.load("ab\ncd\n")
b.move_to(1, 0)
b.backspace(1000)
print("join", show(b), carets(b))
b.move_to(0, 1)
b.delete_fwd(1100)
print("del", show(b))
b.undo_step()
print("undone", show(b))
