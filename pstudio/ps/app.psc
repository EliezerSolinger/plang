"""pstudio, in pscript: the window, the keys and the painting.

The whole editor above the driver is here and in `core.psc` — the buffer, the
selection, the undo, the layout, the key bindings and the drawing order. What
is NOT here is anything with a pointer in it: the window, the events and the
pixels live in `shim.p`, on the P side of the boundary (45.5), and what
crosses between the two is what a number can say.

That split is the whole experiment. If a garbage-collected language with
checked indexing can hold a real editor together while the hand that touches
SDL2 stays a page of P, then the two languages are doing exactly what they
were separated to do.
"""

include "shim.h"

import sys

import lib_core as core


# ---------- colours (0xAARRGGBB) ----------
const BG: int = 0xFF1E1E1E
const BG_GUTTER: int = 0xFF252526
const BG_STATUS: int = 0xFF007ACC
const FG: int = 0xFFD4D4D4
const FG_DIM: int = 0xFF858585
const FG_STATUS: int = 0xFFFFFFFF
const SEL: int = 0xFF264F78
const CARET: int = 0xFFAEAFAD
const CUR_LINE: int = 0xFF2A2D2E
const FG_FOLD: int = 0xFFC586C0

# The event kinds come from shim.h itself now (72.4): a `static const` scalar
# crosses the boundary as the number it is, so there is no second copy here to
# fall out of step with the first.

const MOD_SHIFT: int = 1
const MOD_CTRL: int = 2
const MOD_ALT: int = 4

const K_RETURN: int = 13
const K_ESCAPE: int = 27
const K_BACKSPACE: int = 8
const K_TAB: int = 9
const K_DELETE: int = 127
const K_RIGHT: int = 1073741903
const K_LEFT: int = 1073741904
const K_DOWN: int = 1073741905
const K_UP: int = 1073741906
const K_PAGEUP: int = 1073741899
const K_PAGEDOWN: int = 1073741902
const K_END: int = 1073741901
const K_HOME: int = 1073741898


struct Editor:
    buf: core.Buffer
    path: str
    top: int                 # first VISIBLE line (folds skipped)
    left: int                # horizontal scroll, in columns
    message: str
    msg_until: int
    running: bool
    find_mode: bool
    find_text: str

    # ---------- geometry ----------

    def gutter_w(self) -> int:
        digits = 1
        n = self.buf.nlines()
        while n >= 10:
            digits += 1
            n = n // 10
        return (digits + 3) * shim_cell_w()

    def rows(self) -> int:
        return (shim_height() - shim_cell_h()) // shim_cell_h()

    def cols(self) -> int:
        return (shim_width() - self.gutter_w()) // shim_cell_w()

    # the line a screen row shows, skipping what is folded away
    def line_at_row(self, row: int) -> int:
        l = self.top
        seen = 0
        while l < self.buf.nlines():
            if not self.buf.is_hidden(l):
                if seen == row:
                    return l
                seen += 1
            l += 1
        return -1

    def row_of_line(self, line: int) -> int:
        row = 0
        l = self.top
        while l < line and l < self.buf.nlines():
            if not self.buf.is_hidden(l):
                row += 1
            l += 1
        return row

    def scroll_to_caret(self):
        c = self.buf.caret(self.buf.ncarets() - 1)
        if c.line < self.top:
            self.top = c.line
        r = self.row_of_line(c.line)
        if r >= self.rows():
            over = r - self.rows() + 1
            l = self.top
            while over > 0 and l < self.buf.nlines():
                if not self.buf.is_hidden(l):
                    over -= 1
                l += 1
            self.top = l
        if c.col < self.left:
            self.left = c.col
        if c.col >= self.left + self.cols():
            self.left = c.col - self.cols() + 1

    # ---------- painting ----------

    def draw_text(self, s: str, x: int, y: int, color: int) -> int:
        at = x
        for ch in s:
            at += shim_glyph(ord(ch), at, y, color)
        return at

    def draw(self):
        cw = shim_cell_w()
        ch = shim_cell_h()
        gw = self.gutter_w()
        shim_clear(BG)
        shim_rect(0, 0, gw, shim_height() - ch, BG_GUTTER)

        cur_line = self.buf.caret(self.buf.ncarets() - 1).line
        for row in range(self.rows()):
            l = self.line_at_row(row)
            if l < 0:
                break
            y = row * ch
            if l == cur_line:
                shim_rect(gw, y, shim_width() - gw, ch, CUR_LINE)
            # the line number, right-aligned in the gutter
            num = str(l + 1)
            nx = gw - (len(num) + 2) * cw
            self.draw_text(num, nx, y, FG_STATUS if l == cur_line else FG_DIM)
            if self.buf.is_folded(l):
                self.draw_text("▸", gw - cw, y, FG_FOLD)

            # the selection, then the text over it
            for k in range(self.buf.ncarets()):
                r = self.buf.sel_range(k)
                if r.l0 == r.l1 and r.c0 == r.c1:
                    continue
                if l < r.l0 or l > r.l1:
                    continue
                a = r.c0 if l == r.l0 else 0
                b = r.c1 if l == r.l1 else self.buf.line_cp(l) + 1
                x0 = gw + (a - self.left) * cw
                shim_rect(x0, y, (b - a) * cw, ch, SEL)

            t = self.buf.line_text(l)
            x = gw
            i = self.left
            while i < len(t) and x < shim_width():
                x += shim_glyph(cp_of(t[i]), x, y, FG)
                i += 1

            # every caret on this line
            for k in range(self.buf.ncarets()):
                c = self.buf.caret(k)
                if c.line == l:
                    shim_rect(gw + (c.col - self.left) * cw, y, 2, ch, CARET)

        # the status bar
        sy = shim_height() - ch
        shim_rect(0, sy, shim_width(), ch, BG_STATUS)
        c = self.buf.caret(self.buf.ncarets() - 1)
        left = self.path if len(self.path) > 0 else "<no name>"
        if self.buf.dirty:
            left += " •"
        info = str(c.line + 1) + ":" + str(c.col + 1)
        if self.buf.ncarets() > 1:
            info += "  " + str(self.buf.ncarets()) + " carets"
        if self.find_mode:
            left = "find: " + self.find_text
        elif len(self.message) > 0 and shim_millis() < self.msg_until:
            left = self.message
        self.draw_text(left, shim_cell_w(), sy, FG_STATUS)
        self.draw_text(info, shim_width() - (len(info) + 1) * shim_cell_w(), sy, FG_STATUS)
        shim_present()

    def say(self, m: str):
        self.message = m
        self.msg_until = shim_millis() + 2500

    # ---------- files ----------

    # 76.2: reading a file is a job for the pool, so this is an `async def` and
    # the caller awaits it. What used to be a call that stopped the whole
    # program while the disk answered now stops only this task.
    async def open_file(self, path: str):
        try:
            f = await open(path, "r")
            self.buf.load(await f.text())
            await f.close()
            self.path = path
            self.top = 0
            self.say("opened " + path)
        catch e:
            self.buf.load("")
            self.path = path
            self.say("new file: " + path)

    async def save(self):
        if len(self.path) == 0:
            self.say("no file name")
            return
        try:
            f = await open(self.path, "w")
            await f.write(self.buf.text())
            await f.close()
            self.buf.mark_saved()
            self.say("saved " + self.path)
        catch e:
            self.say("could not save: " + e.message)

    # ---------- input ----------

    async def on_key(self, key: int, mods: int, now: int):
        ctrl = (mods & MOD_CTRL) != 0
        shift = (mods & MOD_SHIFT) != 0

        if self.find_mode:
            if key == K_ESCAPE:
                self.find_mode = False
            elif key == K_RETURN:
                c = self.buf.caret(0)
                hit = self.buf.find(self.find_text, c.line, c.col + 1, True)
                if hit == None:
                    self.say("not found")
                else:
                    self.buf.select_range(hit ?? core.Span(0, 0, 0, 0))
                    self.scroll_to_caret()
            elif key == K_BACKSPACE and len(self.find_text) > 0:
                self.find_text = self.find_text[0:len(self.find_text) - 1]
            return

        if ctrl and key == 115:            # ctrl+s
            await self.save()
        elif ctrl and key == 113:          # ctrl+q
            self.running = False
        elif ctrl and key == 122:          # ctrl+z
            self.buf.undo_step()
        elif ctrl and key == 121:          # ctrl+y
            self.buf.redo_step()
        elif ctrl and key == 97:           # ctrl+a
            self.buf.select_all()
        elif ctrl and key == 100:          # ctrl+d — one more caret on the word
            self.buf.ctrl_d()
        elif ctrl and key == 102:          # ctrl+f
            self.find_mode = True
            self.find_text = ""
        elif ctrl and key == 47:           # ctrl+/ — toggle comment
            self.buf.toggle_comment("#", now)
        elif ctrl and key == 1073741911:   # ctrl+plus
            shim_zoom(shim_zoom_at() + 1)
        elif ctrl and key == 1073741910:   # ctrl+minus
            shim_zoom(shim_zoom_at() - 1)
        elif key == K_ESCAPE:
            self.buf.collapse()
        elif key == K_RETURN:
            self.buf.insert("\n", now)
        elif key == K_BACKSPACE:
            self.buf.backspace(now)
        elif key == K_DELETE:
            self.buf.delete_fwd(now)
        elif key == K_TAB:
            if self.buf.has_sel():
                self.buf.indent(-1 if shift else 1, now)
            else:
                self.buf.insert("    ", now)
        elif key == K_LEFT:
            if ctrl:
                self.buf.move_word(-1, shift)
            else:
                self.buf.move_h(-1, shift)
        elif key == K_RIGHT:
            if ctrl:
                self.buf.move_word(1, shift)
            else:
                self.buf.move_h(1, shift)
        elif key == K_UP:
            self.buf.move_v(-1, shift)
        elif key == K_DOWN:
            self.buf.move_v(1, shift)
        elif key == K_PAGEUP:
            self.buf.move_v(-self.rows(), shift)
        elif key == K_PAGEDOWN:
            self.buf.move_v(self.rows(), shift)
        elif key == K_HOME:
            self.buf.home(shift)
        elif key == K_END:
            self.buf.end(shift)
        self.scroll_to_caret()

    def on_text(self, cp: int, now: int):
        if self.find_mode:
            self.find_text += str_of_cp(cp)
            return
        self.buf.insert(str_of_cp(cp), now)
        self.scroll_to_caret()

    def on_click(self, x: int, y: int, clicks: int, mods: int):
        row = y // shim_cell_h()
        l = self.line_at_row(row)
        if l < 0:
            return
        col = (x - self.gutter_w()) // shim_cell_w() + self.left
        if x < self.gutter_w():
            self.buf.toggle_fold(l)
            return
        if (mods & MOD_ALT) != 0:
            self.buf.add_caret(l, col)
        else:
            self.buf.move_to(l, col)
            if clicks >= 2:
                self.buf.select_word_at(0)


# the codepoint of a one-character string, and back — the two edges where the
# editor meets a driver that speaks numbers
def cp_of(ch: str) -> int:
    return ord(ch)


def str_of_cp(cp: int) -> str:
    return chr(cp)


# A headless run through the same code paths the window drives: open, type,
# move, select, undo, draw and save. It is what `tests/pstudio/` does for the P
# editor — the editor is exercised, not mocked — and it is what makes this port
# provable without a screen.
async def selftest(path: str) -> int:
    if shim_open(400, 240) == 0:
        print("no window")
        return 1
    ed = Editor(core.new_buffer(), "", 0, 0, "", 0, True, False, "")
    await ed.open_file(path)
    print("loaded", ed.buf.nlines(), "lines")

    ed.buf.move_to(0, 0)
    ed.on_text(ord("X"), 10)
    ed.on_text(ord("Y"), 20)
    print("typed", ed.buf.line_text(0))

    await ed.on_key(K_END, 0, 30)
    await ed.on_key(K_LEFT, MOD_SHIFT, 40)
    await ed.on_key(K_LEFT, MOD_SHIFT, 50)
    print("selected", "[" + ed.buf.sel_text(0) + "]")

    await ed.on_key(122, MOD_CTRL, 60)          # ctrl+z
    print("undone", ed.buf.line_text(0))

    ed.buf.move_to(1, 0)
    await ed.on_key(100, MOD_CTRL, 70)          # ctrl+d
    print("carets", ed.buf.ncarets())

    ed.draw()                             # the whole paint path, atlas included
    print("drew", shim_width(), "x", shim_height(), "cell", shim_cell_w(), "x", shim_cell_h())

    ed.path = path + ".out"
    await ed.save()
    f = await open(ed.path, "r")
    print("saved", len(await f.text()), "bytes; dirty", ed.buf.dirty)
    await f.close()
    shim_close()
    return 0


async def main(path: str):
    # a `bool` returned by P is an `int` in the C header, and the frontier
    # believes the signature (45.5) — so the test is against zero
    if shim_open(1100, 720) == 0:
        print("could not open a window")
        return
    ed = Editor(core.new_buffer(), "", 0, 0, "", 0, True, False, "")
    if len(path) > 0:
        await ed.open_file(path)
    ed.draw()
    while ed.running:
        kind = shim_poll()
        if kind == SHIM_NONE:
            continue
        now = shim_millis()
        if kind == SHIM_QUIT:
            ed.running = False
        elif kind == SHIM_KEY:
            await ed.on_key(shim_ev_key(), shim_ev_mods(), now)
        elif kind == SHIM_TEXT:
            ed.on_text(shim_ev_cp(), now)
        elif kind == SHIM_MOUSE_DOWN:
            ed.on_click(shim_ev_x(), shim_ev_y(), shim_ev_clicks(), shim_ev_mods())
        elif kind == SHIM_WHEEL:
            step = shim_ev_wheel() * 3
            self_top = ed.top - step
            ed.top = 0 if self_top < 0 else (ed.buf.nlines() - 1 if self_top >= ed.buf.nlines() else self_top)
        ed.draw()
    shim_close()


args = sys.argv
if len(args) > 2 and args[1] == "--selftest":
    sys.exit(await selftest(args[2]))
await main(args[1] if len(args) > 1 else "")
