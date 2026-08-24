"""A terminal: the ANSI parser, the grid, and the ring of what scrolled away.

**It draws outside the toolkit, and that is the one design decision here.**
Every other widget in `pui` is RETAINED: it writes a list of drawing commands
once and the list is replayed until something goes dirty. A terminal cannot be
one of those. An 80x24 grid with a background per cell is 1 920 rectangles plus
1 920 glyphs — against the fifty a code view emits — and keeping that list alive
between frames would cost more memory than the text it is showing.

So the node carries a `paint` callback instead, and `pui` calls it during the
draw with the painter in hand. Immediate mode, for the one widget that cannot
afford to retain. Everything else stays as it was, including the headless test,
because what the callback is handed is the same `Painter` everybody else writes
through — a terminal that reached for the driver directly would be a terminal
nobody could test without a window.

The two things that make the cost bearable are in `draw`:

  * **runs of identical background become ONE rectangle.** Ordinary output has
    one background for a whole line, so a screenful of it is twenty-four
    rectangles and not one thousand nine hundred;
  * a cell that is blank with the default background draws nothing at all.

The colours come from the THEME (`ansi`), because the rule the theme was built on
has no exceptions: no layer writes a colour. The sixteen are derived from the
eight roots — red is `danger`, green is `ok`, blue is `primary` — so a terminal
in the light theme is a light terminal and nobody had to write a second palette.
"""
import <pui> as pui
import <pui/theme.psc> as th


# ---------- what a cell is ----------

const A_BOLD: int = 1
const A_DIM: int = 2
const A_ITALIC: int = 4
const A_UNDER: int = 8
const A_REVERSE: int = 16

const C_DEFAULT: int = -1        # "whatever the theme says text/background is"


record Cell:
    """One character on the screen. A `record` and not a `struct` because it
    holds only numbers — which is what lets `list<Cell>` be a flat array instead
    of an array of pointers, and a screen is two thousand of them."""
    ch: int          # the codepoint; 32 = blank
    fg: int          # 0..255 an ANSI colour, or C_DEFAULT
    bg: int
    attr: int


def blank(fg: int, bg: int, attr: int) -> Cell:
    return Cell(32, fg, bg, attr)


struct Line:
    """A row that has scrolled off the top. Kept whole rather than reflowed:
    reflowing history on every resize is a feature of its own, and the honest
    alternative — throwing it away — loses what somebody was reading."""
    cells: list<Cell>


# ---------- the parser's states ----------

const S_GROUND: int = 0
const S_ESC: int = 1
const S_CSI: int = 2
const S_OSC: int = 3
const S_SKIP: int = 4      # one byte to swallow (a character set selector)

const SCROLLBACK: int = 5000    # lines. A program in a loop must not eat the
                                # machine, and a copying collector should not
                                # pay twice for what it will never show.


struct Term:
    cols: int
    rows: int
    cells: list<Cell>        # rows*cols, row-major: the screen being written
    other: list<Cell>        # the screen that is not being written (alt/main)
    on_alt: bool
    # Which physical row is the TOP one. Scrolling a full screen moves this by
    # one instead of copying every cell up: a program printing a thousand lines
    # a second would otherwise move nearly two million cells a second, and `cat`
    # of a large file would crawl. A scrolling REGION still copies — it is a few
    # rows, it is rare, and the index would have to be per-region to help.
    origin: int

    # the ring of what scrolled off the top
    back: list<Line>
    back_head: int           # where the NEXT line goes
    back_len: int
    view: int                # how far back we are looking; 0 = live

    cx: int
    cy: int
    save_cx: int
    save_cy: int
    top: int                 # the scrolling region, inclusive
    bot: int

    fg: int
    bg: int
    attr: int
    wrap_next: bool          # DEC's deferred wrap: the column past the last one
    autowrap: bool
    cursor_on: bool
    title: str

    # the byte-level parser
    state: int
    params: list<int>
    priv: str                # `?` and friends, between CSI and the final byte
    osc: str
    # UTF-8 arrives a chunk at a time and a codepoint can straddle two chunks
    u_acc: int
    u_left: int

    dirty: bool              # something changed since the last frame

    # ---------- the grid ----------

    def idx(self, x: int, y: int) -> int:
        return ((self.origin + y) % self.rows) * self.cols + x

    def at(self, x: int, y: int) -> Cell:
        return self.cells[self.idx(x, y)]

    def put(self, x: int, y: int, c: Cell):
        self.cells[self.idx(x, y)] = c

    def normalise(self):
        """Rewrite the grid so that row 0 really is the first one.

        Called before the two things that cannot live with a rotated buffer — a
        resize and a swap to the other screen. Both are O(cells), and both happen
        when a person does something, never per line of output."""
        if self.origin == 0:
            return
        fresh: list<Cell> = []
        for y in range(self.rows):
            for x in range(self.cols):
                fresh.append(self.at(x, y))
        self.cells = fresh
        self.origin = 0

    def clear_span(self, y: int, x0: int, x1: int):
        b = blank(self.fg, self.bg, 0)
        for x in range(x0, x1 + 1):
            if x >= 0 and x < self.cols:
                self.put(x, y, b)

    def push_back(self, y: int):
        """One row into the ring. It is a RING and not a list somebody trims:
        dropping the front of a five-thousand-element list on every scrolled
        line is five thousand moves per line, and a program in a loop scrolls
        thousands of times a second."""
        ln = Line([])
        for x in range(self.cols):
            ln.cells.append(self.at(x, y))
        if len(self.back) < SCROLLBACK:
            self.back.append(ln)
            self.back_head = len(self.back) % SCROLLBACK
            self.back_len = len(self.back)
        else:
            self.back[self.back_head] = ln
            self.back_head = (self.back_head + 1) % SCROLLBACK
            self.back_len = SCROLLBACK

    def back_line(self, i: int) -> Line:
        """`i` counted BACKWARDS from the newest: 0 is the line that scrolled off
        most recently."""
        k = (self.back_head - 1 - i + SCROLLBACK * 2) % SCROLLBACK
        return self.back[k]

    def scroll_up(self, n: int):
        """The region moves up by `n`. Only what leaves the TOP of the screen
        proper is history — a program that set a scrolling region is drawing a
        pane, and its lines are not the session's output."""
        whole = self.top == 0 and self.bot == self.rows - 1
        for i in range(n):
            if whole and not self.on_alt:
                self.push_back(self.top)
            if whole:
                # the cheap path, and the one that runs: move the window, do not
                # move the pixels
                self.origin = (self.origin + 1) % self.rows
                self.clear_span(self.bot, 0, self.cols - 1)
            else:
                for y in range(self.top, self.bot):
                    for x in range(self.cols):
                        self.put(x, y, self.at(x, y + 1))
                self.clear_span(self.bot, 0, self.cols - 1)

    def scroll_down(self, n: int):
        whole = self.top == 0 and self.bot == self.rows - 1
        for i in range(n):
            if whole:
                self.origin = (self.origin - 1 + self.rows) % self.rows
                self.clear_span(self.top, 0, self.cols - 1)
                continue
            y = self.bot
            while y > self.top:
                for x in range(self.cols):
                    self.put(x, y, self.at(x, y - 1))
                y -= 1
            self.clear_span(self.top, 0, self.cols - 1)

    def newline(self):
        if self.cy >= self.bot:
            self.scroll_up(1)
        else:
            self.cy += 1

    def write_cp(self, cp: int):
        if self.wrap_next and self.autowrap:
            self.cx = 0
            self.newline()
            self.wrap_next = False
        if self.cx >= self.cols:
            self.cx = self.cols - 1
        self.put(self.cx, self.cy, Cell(cp, self.fg, self.bg, self.attr))
        if self.cx == self.cols - 1:
            # DEC's DEFERRED wrap: the cursor sits ON the last column and the
            # line only breaks when another character arrives. Wrapping eagerly
            # is what makes a program that fills a line exactly leave a blank
            # one behind it.
            self.wrap_next = True
        else:
            self.cx += 1

    # ---------- the parser ----------

    def feed_bytes(self, b: list<u8>):
        for raw in b:
            self.feed_byte(int(raw))
        self.dirty = True

    def feed_text(self, s: str):
        """Text this PROGRAM is putting on the screen — a note about the child,
        never output from it. ASCII, so a character is a byte, and it goes
        through the same parser so a note can carry an escape if it wants."""
        for ch in s:
            self.feed_byte(ord(ch))
        self.dirty = True

    def feed_byte(self, x: int):
        if self.state == S_SKIP:
            self.state = S_GROUND
            return
        if self.state == S_OSC:
            # ends at BEL, or at ESC \ — and the ESC is handled by the state
            # machine below, so what is left here is the BEL and the text
            if x == 7:
                self.osc_done()
            elif x == 27:
                self.state = S_ESC
            elif x >= 32:
                self.osc += chr(x)
            return
        if self.state == S_ESC:
            self.esc_byte(x)
            return
        if self.state == S_CSI:
            self.csi_byte(x)
            return
        # ---- ground ----
        if x == 27:
            self.state = S_ESC
            self.params = []
            self.priv = ""
            return
        if self.u_left > 0:
            if x >= 0x80 and x < 0xC0:
                self.u_acc = (self.u_acc << 6) | (x & 0x3F)
                self.u_left -= 1
                if self.u_left == 0:
                    self.write_cp(self.u_acc)
                return
            # a broken sequence: the byte that broke it is still a byte, and
            # dropping it silently would swallow real output
            self.u_left = 0
            self.write_cp(0xFFFD)
        if x < 32:
            self.control(x)
            return
        if x < 0x80:
            self.write_cp(x)
        elif x >= 0xC0 and x < 0xE0:
            self.u_acc = x & 0x1F
            self.u_left = 1
        elif x >= 0xE0 and x < 0xF0:
            self.u_acc = x & 0x0F
            self.u_left = 2
        elif x >= 0xF0 and x < 0xF8:
            self.u_acc = x & 0x07
            self.u_left = 3
        else:
            self.write_cp(0xFFFD)

    def control(self, x: int):
        if x == 10:
            self.newline()
            self.wrap_next = False
        elif x == 13:
            self.cx = 0
            self.wrap_next = False
        elif x == 8:
            if self.cx > 0:
                self.cx -= 1
            self.wrap_next = False
        elif x == 9:
            n = 8 - (self.cx % 8)
            self.cx += n
            if self.cx > self.cols - 1:
                self.cx = self.cols - 1
            self.wrap_next = False
        elif x == 12:
            self.newline()

    def esc_byte(self, x: int):
        if x == 91:            # [
            self.state = S_CSI
            self.params = []
            self.priv = ""
            return
        if x == 93:            # ]
            self.state = S_OSC
            self.osc = ""
            return
        self.state = S_GROUND
        if x == 40 or x == 41 or x == 42 or x == 43:   # ( ) * +  charset
            self.state = S_SKIP
        elif x == 55 or x == 51:     # 7 / DECSC
            self.save_cx = self.cx
            self.save_cy = self.cy
        elif x == 56 or x == 52:     # 8 / DECRC
            self.cx = self.save_cx
            self.cy = self.save_cy
        elif x == 77:                # M — reverse index
            if self.cy <= self.top:
                self.scroll_down(1)
            else:
                self.cy -= 1
        elif x == 99:                # c — full reset
            self.reset()
        elif x == 92:                # \ — the end of an OSC that used ESC \
            self.osc_done()

    def csi_byte(self, x: int):
        if x >= 48 and x <= 57:      # a digit
            if len(self.params) == 0:
                self.params.append(0)
            self.params[len(self.params) - 1] = self.params[len(self.params) - 1] * 10 + (x - 48)
            return
        if x == 59:                  # ;
            self.params.append(0)
            return
        if x < 64:                   # ? > ! $ " ' space ...
            self.priv += chr(x)
            return
        self.state = S_GROUND
        self.csi_final(chr(x))

    def param(self, i: int, dflt: int) -> int:
        if i >= len(self.params):
            return dflt
        v = self.params[i]
        return dflt if v == 0 and dflt != 0 else v

    def csi_final(self, f: str):
        n = self.param(0, 1)
        if f == "A":
            self.cy = max_i(self.top, self.cy - n)
        elif f == "B" or f == "e":
            self.cy = min_i(self.bot, self.cy + n)
        elif f == "C" or f == "a":
            self.cx = min_i(self.cols - 1, self.cx + n)
            self.wrap_next = False
        elif f == "D":
            self.cx = max_i(0, self.cx - n)
            self.wrap_next = False
        elif f == "E":
            self.cy = min_i(self.bot, self.cy + n)
            self.cx = 0
        elif f == "F":
            self.cy = max_i(self.top, self.cy - n)
            self.cx = 0
        elif f == "G" or f == "`":
            self.cx = clamp_i(n - 1, 0, self.cols - 1)
            self.wrap_next = False
        elif f == "d":
            self.cy = clamp_i(n - 1, 0, self.rows - 1)
        elif f == "H" or f == "f":
            self.cy = clamp_i(self.param(0, 1) - 1, 0, self.rows - 1)
            self.cx = clamp_i(self.param(1, 1) - 1, 0, self.cols - 1)
            self.wrap_next = False
        elif f == "J":
            self.erase_display(self.param(0, 0))
        elif f == "K":
            self.erase_line(self.param(0, 0))
        elif f == "L":
            self.insert_lines(n)
        elif f == "M":
            self.delete_lines(n)
        elif f == "P":
            self.delete_chars(n)
        elif f == "@":
            self.insert_chars(n)
        elif f == "X":
            self.clear_span(self.cy, self.cx, self.cx + n - 1)
        elif f == "S":
            self.scroll_up(n)
        elif f == "T":
            self.scroll_down(n)
        elif f == "r":
            t = clamp_i(self.param(0, 1) - 1, 0, self.rows - 1)
            b = clamp_i(self.param(1, self.rows) - 1, 0, self.rows - 1)
            if t < b:
                self.top = t
                self.bot = b
                self.cx = 0
                self.cy = t
        elif f == "m":
            self.sgr()
        elif f == "s":
            self.save_cx = self.cx
            self.save_cy = self.cy
        elif f == "u":
            self.cx = self.save_cx
            self.cy = self.save_cy
        elif f == "h" or f == "l":
            self.mode(f == "h")

    def mode(self, on: bool):
        if "?" not in self.priv:
            return
        for p in self.params:
            if p == 7:
                self.autowrap = on
            elif p == 25:
                self.cursor_on = on
            elif p == 1049 or p == 1047 or p == 47:
                self.set_alt(on)

    def set_alt(self, on: bool):
        """The alternate screen: what a full-screen program draws on, so that
        what was on the terminal before it started comes back when it stops.
        Two buffers and a swap — and the alternate one is never history, which
        is why `scroll_up` asks."""
        if on == self.on_alt:
            return
        self.normalise()
        keep = self.cells
        self.cells = self.other
        self.other = keep
        self.on_alt = on
        if on:
            self.save_cx = self.cx
            self.save_cy = self.cy
            self.cx = 0
            self.cy = 0
            for y in range(self.rows):
                self.clear_span(y, 0, self.cols - 1)
        else:
            self.cx = self.save_cx
            self.cy = self.save_cy
        self.view = 0

    def erase_display(self, k: int):
        if k == 0:
            self.clear_span(self.cy, self.cx, self.cols - 1)
            for y in range(self.cy + 1, self.rows):
                self.clear_span(y, 0, self.cols - 1)
        elif k == 1:
            for y in range(0, self.cy):
                self.clear_span(y, 0, self.cols - 1)
            self.clear_span(self.cy, 0, self.cx)
        else:
            for y in range(self.rows):
                self.clear_span(y, 0, self.cols - 1)

    def erase_line(self, k: int):
        if k == 0:
            self.clear_span(self.cy, self.cx, self.cols - 1)
        elif k == 1:
            self.clear_span(self.cy, 0, self.cx)
        else:
            self.clear_span(self.cy, 0, self.cols - 1)

    def insert_lines(self, n: int):
        if self.cy < self.top or self.cy > self.bot:
            return
        for i in range(n):
            y = self.bot
            while y > self.cy:
                for x in range(self.cols):
                    self.put(x, y, self.at(x, y - 1))
                y -= 1
            self.clear_span(self.cy, 0, self.cols - 1)

    def delete_lines(self, n: int):
        if self.cy < self.top or self.cy > self.bot:
            return
        for i in range(n):
            for y in range(self.cy, self.bot):
                for x in range(self.cols):
                    self.put(x, y, self.at(x, y + 1))
            self.clear_span(self.bot, 0, self.cols - 1)

    def delete_chars(self, n: int):
        for x in range(self.cx, self.cols):
            src = x + n
            self.put(x, self.cy, self.at(src, self.cy) if src < self.cols else blank(self.fg, self.bg, 0))

    def insert_chars(self, n: int):
        x = self.cols - 1
        while x >= self.cx:
            src = x - n
            self.put(x, self.cy, self.at(src, self.cy) if src >= self.cx else blank(self.fg, self.bg, 0))
            x -= 1

    def sgr(self):
        if len(self.params) == 0:
            self.params = [0]
        i = 0
        while i < len(self.params):
            p = self.params[i]
            if p == 0:
                self.fg = C_DEFAULT
                self.bg = C_DEFAULT
                self.attr = 0
            elif p == 1:
                self.attr = self.attr | A_BOLD
            elif p == 2:
                self.attr = self.attr | A_DIM
            elif p == 3:
                self.attr = self.attr | A_ITALIC
            elif p == 4:
                self.attr = self.attr | A_UNDER
            elif p == 7:
                self.attr = self.attr | A_REVERSE
            elif p == 22:
                self.attr = self.attr & ~(A_BOLD | A_DIM)
            elif p == 23:
                self.attr = self.attr & ~A_ITALIC
            elif p == 24:
                self.attr = self.attr & ~A_UNDER
            elif p == 27:
                self.attr = self.attr & ~A_REVERSE
            elif p >= 30 and p <= 37:
                self.fg = p - 30
            elif p == 39:
                self.fg = C_DEFAULT
            elif p >= 40 and p <= 47:
                self.bg = p - 40
            elif p == 49:
                self.bg = C_DEFAULT
            elif p >= 90 and p <= 97:
                self.fg = p - 90 + 8
            elif p >= 100 and p <= 107:
                self.bg = p - 100 + 8
            elif p == 38 or p == 48:
                # 38;5;n is one of 256; 38;2;r;g;b is direct colour, which this
                # grid stores as an index it does not have — so it is rounded
                # into the cube, and saying so beats storing a colour the theme
                # can never override
                kind = self.params[i + 1] if i + 1 < len(self.params) else 0
                nonlocal v
                v = C_DEFAULT
                if kind == 5 and i + 2 < len(self.params):
                    v = clamp_i(self.params[i + 2], 0, 255)
                    i += 2
                elif kind == 2 and i + 4 < len(self.params):
                    v = th.cube_of(self.params[i + 2], self.params[i + 3], self.params[i + 4])
                    i += 4
                if p == 38:
                    self.fg = v
                else:
                    self.bg = v
            i += 1

    def osc_done(self):
        # `0;text` and `2;text` set the title; everything else is somebody
        # else's protocol and is dropped rather than guessed at
        self.state = S_GROUND
        cut = self.osc.find(";")
        if cut > 0:
            k = self.osc[:cut]
            if k == "0" or k == "2":
                self.title = self.osc[cut + 1:]
        self.osc = ""

    def reset(self):
        self.fg = C_DEFAULT
        self.bg = C_DEFAULT
        self.attr = 0
        self.cx = 0
        self.cy = 0
        self.top = 0
        self.bot = self.rows - 1
        self.autowrap = True
        self.cursor_on = True
        self.wrap_next = False
        self.view = 0
        self.origin = 0
        for y in range(self.rows):
            self.clear_span(y, 0, self.cols - 1)

    # ---------- size ----------

    def resize(self, cols: int, rows: int):
        """A new grid, with what fits carried over from the corner that matters:
        the BOTTOM left, because that is where the prompt is."""
        if cols < 1:
            cols = 1
        if rows < 1:
            rows = 1
        if cols == self.cols and rows == self.rows:
            return
        self.normalise()
        old = self.cells
        oc = self.cols
        orr = self.rows
        b = blank(C_DEFAULT, C_DEFAULT, 0)
        fresh: list<Cell> = []
        for i in range(cols * rows):
            fresh.append(b)
        keep_rows = min_i(rows, orr)
        keep_cols = min_i(cols, oc)
        for y in range(keep_rows):
            sy = orr - keep_rows + y
            dy = rows - keep_rows + y
            for x in range(keep_cols):
                fresh[dy * cols + x] = old[sy * oc + x]
        other: list<Cell> = []
        for i in range(cols * rows):
            other.append(b)
        self.cells = fresh
        self.other = other
        self.origin = 0
        self.cols = cols
        self.rows = rows
        self.cx = clamp_i(self.cx, 0, cols - 1)
        self.cy = clamp_i(self.cy + (rows - orr), 0, rows - 1)
        self.top = 0
        self.bot = rows - 1
        self.view = 0
        self.dirty = True

    # ---------- what is on screen right now ----------

    def visible(self, y: int) -> list<Cell>:
        """Row `y` of what the user is LOOKING at, which is the screen when the
        view is live and the ring when it is not."""
        if self.view <= 0 or self.on_alt:
            return self.row_of(self.cells, y)
        back = self.view - y
        if back > 0:
            if back > self.back_len:
                return self.empty_row()
            return self.back_line(back - 1).cells
        return self.row_of(self.cells, -back)

    def row_of(self, src: list<Cell>, y: int) -> list<Cell>:
        out: list<Cell> = []
        if y < 0 or y >= self.rows:
            return self.empty_row()
        base = ((self.origin + y) % self.rows) * self.cols
        for x in range(self.cols):
            out.append(src[base + x])
        return out

    def empty_row(self) -> list<Cell>:
        out: list<Cell> = []
        b = blank(C_DEFAULT, C_DEFAULT, 0)
        for x in range(self.cols):
            out.append(b)
        return out

    def scroll_view(self, delta: int):
        v = self.view + delta
        if v < 0:
            v = 0
        if v > self.back_len:
            v = self.back_len
        if v != self.view:
            self.view = v
            self.dirty = True


def max_i(a: int, b: int) -> int:
    return a if a > b else b


def min_i(a: int, b: int) -> int:
    return a if a < b else b


def clamp_i(v: int, lo: int, hi: int) -> int:
    if v < lo:
        return lo
    return hi if v > hi else v


def new_term(cols: int, rows: int) -> Term:
    t = Term(cols, rows, [], [], False,
             0,
             [], 0, 0, 0,
             0, 0, 0, 0, 0, rows - 1,
             C_DEFAULT, C_DEFAULT, 0, False, True, True, "",
             S_GROUND, [], "", "", 0, 0, False)
    b = blank(C_DEFAULT, C_DEFAULT, 0)
    for i in range(cols * rows):
        t.cells.append(b)
        t.other.append(b)
    return t


# ---------- the drawing ----------

def draw(t: Term, p: pui.Painter, r: pui.Rect, cw: int, chh: int, tm: th.Theme,
         focused: bool, blink_on: bool):
    """One frame, straight into the painter. No command list is kept.

    The one optimisation that matters is the RUN: consecutive cells with the
    same background become one rectangle. Ordinary output has one background for
    a whole line, so a screenful is twenty-four rectangles instead of one
    thousand nine hundred and twenty."""
    p.rect(r.x, r.y, r.w, r.h, tm.bg)
    rows = min_i(t.rows, r.h // chh)
    for y in range(rows):
        row = t.visible(y)
        ry = r.y + y * chh
        # ---- the backgrounds, coalesced ----
        x = 0
        while x < t.cols:
            bgc = cell_bg(row[x], tm)
            run = 1
            while x + run < t.cols and cell_bg(row[x + run], tm) == bgc:
                run += 1
            if bgc != tm.bg:
                p.rect(r.x + x * cw, ry, run * cw, chh, bgc)
            x += run
        # ---- and the glyphs ----
        for gx in range(t.cols):
            c = row[gx]
            if c.ch == 32 or c.ch == 0:
                continue
            p.glyph(c.ch, r.x + gx * cw, ry, cell_fg(c, tm))
    # ---- the cursor, only where it really is ----
    if t.cursor_on and t.view == 0 and t.cy < rows:
        cxp = r.x + min_i(t.cx, t.cols - 1) * cw
        cyp = r.y + t.cy * chh
        if focused and blink_on:
            p.rect(cxp, cyp, cw, chh, tm.caret)
            c = t.visible(t.cy)[min_i(t.cx, t.cols - 1)]
            if c.ch != 32 and c.ch != 0:
                p.glyph(c.ch, cxp, cyp, tm.bg)
        elif not focused:
            # hollow when the keyboard is elsewhere: it is the one honest way to
            # say "typing will not land here"
            p.frame(cxp, cyp, cw, chh, tm.caret)


def cell_fg(c: Cell, tm: th.Theme) -> int:
    f = c.fg
    b = c.bg
    if (c.attr & A_REVERSE) != 0:
        f = c.bg
        b = c.fg
    base = (tm.bg if (c.attr & A_REVERSE) != 0 else tm.text) if f == C_DEFAULT else th.ansi(tm, f)
    if (c.attr & A_DIM) != 0:
        return th.mix(base, tm.bg, 55)
    return base


def cell_bg(c: Cell, tm: th.Theme) -> int:
    b = c.bg
    if (c.attr & A_REVERSE) != 0:
        b = c.fg
        if b == C_DEFAULT:
            return tm.text
    if b == C_DEFAULT:
        return tm.bg
    return th.ansi(tm, b)


# ---------- what the keyboard sends ----------

def key_bytes(key: int, mods: int, cp: int) -> str:
    """A key, as the bytes a program on the other end expects.

    This is the half of a terminal nobody remembers until an arrow key prints
    `^[[A` into somebody's shell. `mods`: 1=shift 2=ctrl 4=alt."""
    ctrl = (mods & 2) != 0
    alt = (mods & 4) != 0
    if key == pui.K_RETURN:
        return "\r"
    if key == pui.K_BACKSPACE:
        return "\x7f"
    if key == pui.K_TAB:
        return "\t"
    if key == pui.K_ESCAPE:
        return "\x1b"
    if key == pui.K_UP:
        return "\x1b[A"
    if key == pui.K_DOWN:
        return "\x1b[B"
    if key == pui.K_RIGHT:
        return "\x1b[C"
    if key == pui.K_LEFT:
        return "\x1b[D"
    if key == pui.K_HOME:
        return "\x1b[H"
    if key == pui.K_END:
        return "\x1b[F"
    if key == pui.K_PAGEUP:
        return "\x1b[5~"
    if key == pui.K_PAGEDOWN:
        return "\x1b[6~"
    if key == pui.K_DELETE:
        return "\x1b[3~"
    if ctrl and cp >= 64 and cp < 128:
        # ctrl+A is 1, ctrl+C is 3, ctrl+D is 4 — the top three bits cleared,
        # which is what a control character IS
        return chr(cp & 0x1F)
    if ctrl and cp >= 97 and cp <= 122:
        return chr((cp - 32) & 0x1F)
    if cp <= 0:
        return ""
    return ("\x1b" if alt else "") + chr(cp)
