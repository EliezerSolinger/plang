"""The terminal, without a terminal.

Everything a program can say to a screen is a byte, so every one of these cases
is a string in this file — which is what lets the whole VT be measured without a
pseudo-terminal, a window or a child process. `os.spawn_pty` has its own test
(`tests/pscript/run/pty.psc`); this one is about what happens to the GRID.

The cases were chosen from what actually breaks terminals: the deferred wrap
(the reason a program that fills a line exactly does not leave a blank one), the
scrolling region (the reason `less` does not eat your history), the alternate
screen (the reason your prompt comes back), and UTF-8 arriving split across two
reads (the reason an accent turns into two question marks).
"""
import <pui> as pui
import <pui/theme.psc> as th
import terminal as trm


rects = 0
glyphs = 0


def cnt_rect(x: int, y: int, w: int, h: int, c: int):
    global rects
    rects += 1


def cnt_glyph(cp: int, x: int, y: int, c: int):
    global glyphs
    glyphs += 1


def nothing4(x: int, y: int, w: int, h: int):
    pass


def nothing0():
    pass


def esc(s: str) -> str:
    out = ""
    for ch in s:
        n = ord(ch)
        if n < 32 or n == 127:
            out += "\\" + str(n)
        else:
            out += ch
    return out


def feed(t: trm.Term, s: str):
    t.feed_text(s)


def row_text(t: trm.Term, y: int) -> str:
    out = ""
    for c in t.visible(y):
        out += chr(c.ch if c.ch > 0 else 32)
    while len(out) > 0 and out.endswith(" "):
        out = out[:len(out) - 1]
    return out


def dump(t: trm.Term, what: str):
    print(what + ":")
    for y in range(t.rows):
        print("  |" + row_text(t, y) + "|")
    print("  cursor=" + str(t.cx) + "," + str(t.cy) +
          " region=" + str(t.top) + ".." + str(t.bot) +
          " back=" + str(t.back_len) + " view=" + str(t.view))


# ---- plain text, and the DEFERRED wrap ----
t = trm.new_term(10, 4)
feed(t, "hello")
dump(t, "text")
# exactly to the end of the row: the cursor sits ON the last column and the line
# has NOT broken — which is why a program that fills a line does not leave a
# blank one behind it
feed(t, "12345")
print("exactly one line: cursor=" + str(t.cx) + "," + str(t.cy) +
      " wrap_next=" + str(t.wrap_next))
feed(t, "X")
dump(t, "and then one more")

# ---- the controls ----
t = trm.new_term(12, 3)
feed(t, "abc\rZ")
print("CR: [" + row_text(t, 0) + "]")
feed(t, "\r\n\tqq")
print("LF+TAB: [" + row_text(t, 1) + "]")
feed(t, "\b\bW")
print("BS: [" + row_text(t, 1) + "]")

# ---- moving ----
t = trm.new_term(10, 4)
feed(t, "\x1b[2;3Hxy")
print("CUP: [" + row_text(t, 1) + "] cursor=" + str(t.cx) + "," + str(t.cy))
feed(t, "\x1b[2A\x1b[4CZ")
print("CUU+CUF: [" + row_text(t, 0) + "]")
feed(t, "\x1b[10;99H")
print("clamped to " + str(t.cx) + "," + str(t.cy))

# ---- erasing ----
t = trm.new_term(8, 3)
feed(t, "aaaaaaaa\r\nbbbbbbbb\r\ncccccccc")
feed(t, "\x1b[2;4H\x1b[K")
print("EL 0: [" + row_text(t, 1) + "]")
feed(t, "\x1b[2;4H\x1b[1K")
print("EL 1: [" + row_text(t, 1) + "]")
feed(t, "\x1b[1;1H\x1b[J")
print("ED 0 leaves: [" + row_text(t, 0) + "][" + row_text(t, 2) + "]")

# ---- inserting and deleting ----
t = trm.new_term(8, 3)
feed(t, "abcdefgh\x1b[1;3H\x1b[2P")
print("DCH: [" + row_text(t, 0) + "]")
feed(t, "\x1b[1;3H\x1b[2@")
print("ICH: [" + row_text(t, 0) + "]")
t = trm.new_term(6, 4)
feed(t, "one\r\ntwo\r\nsix\x1b[2;1H\x1b[L")
print("IL: [" + row_text(t, 1) + "][" + row_text(t, 2) + "]")
feed(t, "\x1b[2;1H\x1b[M")
print("DL: [" + row_text(t, 1) + "][" + row_text(t, 2) + "]")

# ---- the scrolling region, and what does NOT become history ----
t = trm.new_term(6, 5)
feed(t, "l1\r\nl2\r\nl3\r\nl4\r\nl5")
print("history so far=" + str(t.back_len))
feed(t, "\r\n")
print("one line scrolled: back=" + str(t.back_len) + " top row=[" + row_text(t, 0) + "]")
feed(t, "\x1b[2;4r")
feed(t, "\x1b[4;1H\r\n\r\n\r\n")
print("inside a region: back stays " + str(t.back_len))
dump(t, "region scrolled")

# ---- the scrollback, and looking back into it ----
t = trm.new_term(6, 3)
for i in range(10):
    feed(t, "row" + str(i) + "\r\n")
print("back=" + str(t.back_len))
t.scroll_view(4)
print("view 4 top=[" + row_text(t, 0) + "]")
t.scroll_view(1000)
print("clamped view=" + str(t.view) + " top=[" + row_text(t, 0) + "]")
t.scroll_view(-1000)
print("back to live=" + str(t.view))

# ---- colour and attributes ----
t = trm.new_term(20, 2)
feed(t, "\x1b[31mred\x1b[1;32mbold-green\x1b[0mplain")
c0 = t.at(0, 0)
c3 = t.at(3, 0)
c13 = t.at(13, 0)
print("fg red=" + str(c0.fg) + " green=" + str(c3.fg) + " bold=" + str(c3.attr) +
      " reset fg=" + str(c13.fg) + " attr=" + str(c13.attr))
feed(t, "\x1b[7mR\x1b[27m")
print("reverse attr=" + str(t.at(18, 0).attr))
t = trm.new_term(8, 1)
feed(t, "\x1b[38;5;196mA\x1b[48;2;0;0;255mB")
print("256=" + str(t.at(0, 0).fg) + " truecolour blue rounded to " + str(t.at(1, 0).bg))

# ---- the alternate screen ----
t = trm.new_term(8, 2)
feed(t, "before")
feed(t, "\x1b[?1049h")
print("alt is empty: [" + row_text(t, 0) + "]")
feed(t, "inside")
feed(t, "\x1b[?1049l")
print("and the main one came back: [" + row_text(t, 0) + "]")

# ---- UTF-8 split across two reads ----
t = trm.new_term(8, 1)
t.feed_bytes([0xC3])
t.feed_bytes([0xA9, 0x21])
print("split codepoint: [" + row_text(t, 0) + "] len=" + str(len(row_text(t, 0))))

# ---- the title, which is the only OSC anybody sets ----
t = trm.new_term(8, 1)
feed(t, "\x1b]0;a title\x07x")
print("title=[" + t.title + "] and the x survived: [" + row_text(t, 0) + "]")

# ---- resize keeps the BOTTOM, because that is where the prompt is ----
t = trm.new_term(8, 4)
feed(t, "one\r\ntwo\r\nthree\r\nfour")
t.resize(8, 2)
print("shrunk: [" + row_text(t, 0) + "][" + row_text(t, 1) + "]")
t.resize(8, 4)
print("grown back: [" + row_text(t, 2) + "][" + row_text(t, 3) + "]")

# ---- and what one frame COSTS ----
#
# The whole reason this widget draws immediately instead of retaining: an 80x24
# grid is 1 920 cells. Runs of identical background collapse into one rectangle
# each, so ordinary output costs a couple of dozen and not two thousand.
t = trm.new_term(80, 24)
for y in range(24):
    feed(t, "the quick brown fox jumps over the lazy dog, and again it does\r\n")
p = pui.Painter(cnt_rect, cnt_rect, nothing4, nothing0, cnt_glyph, cnt_glyph)
tm = th.theme_dark()
trm.draw(t, p, pui.Rect(0, 0, 80 * 8, 24 * 17), 8, 17, tm, True, True)
print("plain screen: rects=" + str(rects) + " glyphs=" + str(glyphs))
rects = 0
glyphs = 0
feed(t, "\x1b[41m")
for y in range(24):
    feed(t, "coloured background all the way across this line here      \r\n")
trm.draw(t, p, pui.Rect(0, 0, 80 * 8, 24 * 17), 8, 17, tm, True, True)
print("one background per line: rects=" + str(rects))

# ---- the keyboard, as the bytes a program expects ----
print("up=[" + esc(trm.key_bytes(pui.K_UP, 0, 0)) + "]" +
      " ctrl+c=[" + esc(trm.key_bytes(0, 2, ord("c"))) + "]" +
      " enter=[" + esc(trm.key_bytes(pui.K_RETURN, 0, 0)) + "]" +
      " bs=[" + esc(trm.key_bytes(pui.K_BACKSPACE, 0, 0)) + "]" +
      " alt+x=[" + esc(trm.key_bytes(0, 4, ord("x"))) + "]" +
      " plain=[" + esc(trm.key_bytes(0, 0, ord("q"))) + "]")

print("terminal-ok")
