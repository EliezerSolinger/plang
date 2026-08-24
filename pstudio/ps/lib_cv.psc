"""The editing widget, in pscript (a port of `pstudio/codeview.p`).

It ties the three layers together: the buffer (`lib_core`), the toolkit (`pui`,
the package), the highlighting and the completion (`lib_hl`, `lib_complete`,
which talk to the compiler's lexer through 113's adapter). It follows Godot's
`TextEdit` where it matters: the scrollbars are INTERNAL children the widget
positions, and the gutters are pluggable.

Three differences from the original, all about LAYERING and all for the same
end — that the editor's logic runs without a driver, and is therefore testable:

  * **a gutter is DATA, not a function.** `enum GutKind` + `match`, which is
    28.5 ("dispatch is data") applied where it fits. The three that exist
    (marks, fold, numbers) are the three the editor uses;
  * **the clipboard does not live here.** `copy()` RETURNS the text and
    `paste(text)` RECEIVES it: whoever talks to the system is the app, which is
    the one with the driver. The multi-cursor model (N pieces for N cursors)
    stays here;
  * **files do not either.** `load_text`/`text_to_save` instead of reading and
    writing: I/O in pscript is `await` (76.2), and whoever waits is the event
    loop.
"""
import lib_core as core
import <pui> as pui
import lib_hl as hlm
import lib_complete as cmp


const CV_TAB: int = 4              # tab suave (DESIGN.md)
# the completion popup. The box is fitted to the candidates AT OPENING and
# then pinned to the text area, so it never reaches the minimap and never leaves
# the widget; what does not fit is elided (`cmd_text_fit`), not painted outside.
const CMP_MAX_ROWS: int = 10
const CMP_MIN_COLS: int = 16
const CMP_MAX_COLS: int = 72
const CMP_PAD: int = 3
const CMP_MIN_DETAIL: int = 8      # below this the signature goes instead of becoming "…"
# minimap: one row of pixels per line, one column per character (Godot draws it
# from the HIGHLIGHTING, not from glyphs — at this scale a letter is noise)
const MM_COLS: int = 90
const MM_ROW: int = 2


# the colours per highlight class (dark theme; the index is lib_hl's HL_*). A
# `match` and not a module list: an imported module does not run statements.
def hl_color(cls: int) -> int:
    if cls == 1:
        return 0xFFC586C0      # a language keyword (purple)
    if cls == 2:
        return 0xFFCE9178      # a string (orange)
    if cls == 3:
        return 0xFFB5CEA8      # a number (light green)
    if cls == 4:
        return 0xFF6A9955      # a comment (green)
    return 0xFFD4D4D4          # plain text


# a highlight colour at minimap strength (translucent, so the runs read as a
# texture)
def mm_tint(cls: int) -> int:
    return (hl_color(cls) & 0x00FFFFFF) | 0xB0000000


enum GutKind:
    GUT_NUMBERS       # the line number
    GUT_FOLD          # ▾ block open, ▸ collapsed
    GUT_MARKS         # ● breakpoint, ◆ bookmark


record Gutter:
    kind: GutKind
    width_cp: int     # width in CHARACTERS (monospaced font)


def is_word_ch(c: str) -> bool:
    return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_"


# the pairs an editor closes for you; a quote is its own closer
def pair_close_of(open_ch: str) -> str:
    if open_ch == "(":
        return ")"
    if open_ch == "[":
        return "]"
    if open_ch == "{":
        return "}"
    if open_ch == "\"" or open_ch == "'":
        return open_ch
    return ""


def pair_is_close(ch: str) -> bool:
    return ch == ")" or ch == "]" or ch == "}" or ch == "\"" or ch == "'"


struct CodeView:
    buf: core.Buffer
    hl: hlm.Hl
    index: cmp.Index
    path: str              # "" = a loose buffer, with no file
    u: pui.Ui              # the toolkit that draws it
    id: int                # this widget's id in the pool
    vsb: int               # the vertical bar (internal child)
    hsb: int               # the horizontal one
    top: int               # first visible line
    left: int              # first visible SCREEN COLUMN (tabs expanded)
    gutters: list<Gutter>
    cmp_open: bool         # the popup is showing
    cmp_hits: list<int>
    cmp_sel: int
    cmp_top: int           # first line shown in the popup
    cmp_col: int           # column where the word being completed starts
    cmp_owner: str         # struct whose members are listed (the `x.` case); "" = none
    minimap: bool
    minimap_drag: bool
    caret_on: bool         # blink phase (the app toggles it on timeout)
    mouse_sel: bool        # dragging a selection
    mtime: int             # the file's mtime at the last read
    clip: list<str>        # the pieces of the last copy (one per cursor)
    dirty_cb: bool         # something changed and the app has not looked yet
    now_ms: int            # the clock, set by the app every frame — the input
                           #   comes from the toolkit, which knows nothing of time

    # ---------- what the toolkit calls ----------

    def set_now(self, ms: int):
        self.now_ms = ms

    def layout(self, r: pui.Rect):
        """The internal bars (Godot's TextEdit layout): the vertical one takes
        the whole right edge, the horizontal one the footer minus that width."""
        hs = self.u.theme.handle + 2
        self.u.set_rect(self.vsb, pui.Rect(r.x + r.w - hs, r.y, hs, r.h - hs))
        self.u.set_rect(self.hsb, pui.Rect(r.x + self.gutter_w(), r.y + r.h - hs,
                                           r.w - hs - self.gutter_w(), hs))
        self.sync_bars()

    def on_vscroll(self, v: int):
        self.top = self.buf.from_visible(v)
        self.u.queue_redraw(self.id)

    def on_hscroll(self, v: int):
        self.left = v
        self.u.queue_redraw(self.id)

    # ---------- files (no I/O: whoever waits is the app) ----------

    def load_text(self, path: str, data: str, mtime: int):
        self.buf.load(data)
        self.path = path
        self.mtime = mtime
        self.hl = hlm.new_hl(hlm.is_p_file(path))
        self.top = 0
        self.left = 0
        self.changed()
        self.hl.update(self.buf)      # opening is not a keystroke: lex it now

    def text_to_save(self) -> str:
        return self.buf.text()

    def mark_saved(self, mtime: int):
        self.buf.mark_saved()
        self.mtime = mtime
        self.dirty_cb = True

    def set_text(self, text: str):
        self.buf.load(text)
        self.changed()

    # ---------- geometria ----------

    def gutter_w(self) -> int:
        if len(self.gutters) == 0:
            return 0
        total = 0
        for g in self.gutters:
            total += g.width_cp * self.u.cell_w
        return total + self.u.cell_w   # one character of breathing room before the text

    def minimap_rect(self) -> pui.Rect:
        r = self.u.rect_of(self.id)
        hs = self.u.theme.handle + 2
        if not self.minimap:
            return pui.Rect(r.x + r.w - hs, r.y, 0, 0)
        w = MM_COLS
        if w > r.w // 4:
            w = r.w // 4          # never eats more than a quarter of the view
        return pui.Rect(r.x + r.w - hs - w, r.y, w, r.h - hs)

    def text_rect(self) -> pui.Rect:
        r = self.u.rect_of(self.id)
        hs = self.u.theme.handle + 2
        g = self.gutter_w()
        mm = self.minimap_rect().w
        return pui.Rect(r.x + g, r.y, r.w - g - hs - mm, r.h - hs)

    def toggle_minimap(self):
        self.minimap = not self.minimap
        self.u.relayout()
        self.u.queue_redraw(self.id)

    def visible_lines(self) -> int:
        n = self.text_rect().h // self.u.cell_h
        return n if n > 0 else 1

    def add_gutter(self, kind: GutKind, width_cp: int):
        self.gutters.append(Gutter(kind, width_cp))

    # a gutter cell's text and colour; "" = an empty cell
    def gutter_cell(self, kind: GutKind, line: int) -> str:
        match kind:
            case GUT_MARKS:
                m = self.buf.mark_of(line)
                # the ERROR wins over the others: if the build failed here,
                # that is what whoever looks needs to see first
                if (m & core.MARK_ERROR) != 0:
                    return "✗"
                if (m & core.MARK_BREAK) != 0:
                    return "●"
                if (m & core.MARK_BOOK) != 0:
                    return "◆"
                return ""
            case GUT_FOLD:
                if self.buf.is_folded(line):
                    return "▸"
                if self.buf.can_fold(line):
                    return "▾"
                return ""
            case _:
                return str(line + 1)

    def gutter_color(self, kind: GutKind, line: int) -> int:
        match kind:
            case GUT_MARKS:
                return 0xFFE05252 if (self.buf.mark_of(line) & core.MARK_BREAK) != 0 else 0xFF4F9CF7
            case GUT_FOLD:
                return 0xFFD0A050 if self.buf.is_folded(line) else 0xFF6E7075
            case _:
                for k in range(self.buf.ncarets()):
                    if self.buf.caret(k).line == line:
                        return 0xFFB0B0B0
                return 0xFF6E7075

    def gutter_click(self, kind: GutKind, line: int) -> bool:
        match kind:
            case GUT_MARKS:
                self.buf.toggle_mark(line, core.MARK_BREAK)
                self.u.queue_redraw(self.id)
                return True
            case GUT_FOLD:
                if not self.buf.toggle_fold(line):
                    return False
                self.anchor_top()
                return True
            case _:
                return False

    # ---------- SCREEN columns (tabs expanded) ----------

    def screen_col(self, line: int, col: int) -> int:
        s = self.buf.line_text(line)
        sc = 0
        n = 0
        for ch in s:
            if n >= col:
                break
            if ch == "\t":
                sc += CV_TAB - (sc % CV_TAB)
            else:
                sc += 1
            n += 1
        return sc

    def col_from_screen(self, line: int, scol: int) -> int:
        s = self.buf.line_text(line)
        sc = 0
        n = 0
        for ch in s:
            if sc >= scol:
                return n
            if ch == "\t":
                sc += CV_TAB - (sc % CV_TAB)
            else:
                sc += 1
            n += 1
        return n

    def line_at_row(self, row: int) -> int:
        return self.buf.next_visible(self.top, row)

    def row_of_line(self, line: int) -> int:
        if self.buf.is_hidden(line):
            return -1
        return self.buf.to_visible(line) - self.buf.to_visible(self.top)

    def pos_from_xy(self, x: int, y: int) -> core.Span:
        tr = self.text_rect()
        row = (y - tr.y) // self.u.cell_h
        if y < tr.y:
            row = -1
        l = self.line_at_row(row)      # the fold is skipped by the mapping
        sc = self.left + (x - tr.x + self.u.cell_w // 2) // self.u.cell_w
        if sc < 0:
            sc = 0
        c = self.col_from_screen(l, sc)
        return core.Span(l, c, l, c)

    def max_screen_cols(self) -> int:
        """The widest VISIBLE line: the horizontal bar follows what is on screen,
        as Godot does — it never scans the whole file."""
        vis = self.visible_lines()
        mx = 1
        l = self.top
        for row in range(vis + 1):
            w = self.screen_col(l, self.buf.line_cp(l))
            if w > mx:
                mx = w
            nl = self.buf.next_visible(l, 1)
            if nl == l:
                break
            l = nl
        return mx

    def sync_bars(self):
        tr = self.text_rect()
        vis = self.visible_lines()
        cols = tr.w // self.u.cell_w
        if cols < 1:
            cols = 1
        # the vertical bar counts VISIBLE lines (a fold shortens the document)
        self.u.scroll_set(self.vsb, self.buf.visible_count(), vis, self.buf.to_visible(self.top))
        self.top = self.buf.from_visible(self.u.scroll_value(self.vsb))
        mx = self.max_screen_cols()
        self.u.scroll_set(self.hsb, mx + 1, cols, self.left)
        self.left = self.u.scroll_value(self.hsb)
        # the horizontal one only appears when needed (Sublime/Godot)
        self.u.set_visible(self.hsb, mx >= cols)

    # ---------- navigation ----------

    def set_top(self, line: int):
        """`line` is a VISIBLE index here: the bar and the wheel think in rows,
        and a folded document has fewer rows than lines."""
        v = line
        mx = self.buf.visible_count() - 1
        if v > mx:
            v = mx
        if v < 0:
            v = 0
        n = self.buf.from_visible(v)
        if n != self.top:
            self.top = n
            self.sync_bars()
            self.u.queue_redraw(self.id)

    def set_left(self, col: int):
        n = col if col > 0 else 0
        if n != self.left:
            self.left = n
            self.sync_bars()
            self.u.queue_redraw(self.id)

    def anchor_top(self):
        """A fold changed the map: keep the view where it is. Folding from the
        GUTTER must not scroll (Godot/Sublime) — the cursor may be anywhere, and
        chasing it takes the reader away from the block they just folded."""
        self.top = self.buf.visible_at_or_before(self.top)
        self.changed()

    def scroll_to_caret(self):
        c = self.buf.caret(self.buf.ncarets() - 1)
        vis = self.visible_lines()
        top = self.top
        cv = self.buf.to_visible(c.line)
        tv = self.buf.to_visible(top)
        if cv < tv:
            top = c.line
        elif cv >= tv + vis:
            top = self.buf.from_visible(cv - vis + 1)
        tr = self.text_rect()
        cols = tr.w // self.u.cell_w
        if cols < 1:
            cols = 1
        sc = self.screen_col(c.line, c.col)
        left = self.left
        if sc < left:
            left = sc
        elif sc >= left + cols:
            left = sc - cols + 1
        self.top = top if top >= 0 else 0
        self.left = left if left >= 0 else 0
        self.sync_bars()
        self.u.queue_redraw(self.id)

    def changed(self):
        # the relex is NOT done here: `build` does it, once per FRAME. Between two
        # frames there can be several edits — a paste, a multi-caret insert,
        # undoing a whole group — and only the last one of them matters.
        self.sync_bars()
        self.u.queue_redraw(self.id)
        self.dirty_cb = True

    # ---------- desenho ----------

    def build(self):
        r = self.u.rect_of(self.id)
        tr = self.text_rect()
        th = self.u.theme
        lh = self.u.cell_h
        cw = self.u.cell_w
        cols = tr.w // cw + 1
        vis = self.visible_lines()
        gw = self.gutter_w()

        self.u.cmd_rect(self.id, r, 0xFF1E1F22)
        if gw > 0:
            self.u.cmd_rect(self.id, pui.Rect(r.x, r.y, gw, r.h), 0xFF232527)

        self.hl.update(self.buf)

        # the current line (only with one cursor and no selection, like Sublime)
        if self.buf.ncarets() == 1 and not self.buf.has_sel():
            crow = self.row_of_line(self.buf.caret(0).line)
            if crow >= 0 and crow < vis:
                self.u.cmd_rect(self.id, pui.Rect(tr.x, tr.y + crow * lh, tr.w, lh), 0xFF26282C)

        # the selections (before the text: the replay is in order)
        for k in range(self.buf.ncarets()):
            sr = self.buf.sel_range(k)
            if sr.l0 == sr.l1 and sr.c0 == sr.c1:
                continue
            for ln in range(sr.l0, sr.l1 + 1):
                srow = self.row_of_line(ln)
                if srow < 0 or srow >= vis:
                    continue
                s0 = self.screen_col(ln, sr.c0) if ln == sr.l0 else 0
                s1 = self.screen_col(ln, sr.c1) if ln == sr.l1 else self.screen_col(ln, self.buf.line_cp(ln)) + 1
                x0 = tr.x + (s0 - self.left) * cw
                x1 = tr.x + (s1 - self.left) * cw
                if x1 <= tr.x or x0 >= tr.x + tr.w:
                    continue
                self.u.cmd_rect(self.id, pui.Rect(x0, tr.y + srow * lh, x1 - x0, lh), th.sel)

        # gutters and text, walking the VISIBLE rows (a fold is skipped)
        ln = self.top
        for vi in range(vis + 1):
            if vi > 0:
                nl = self.buf.next_visible(ln, 1)
                if nl == ln:
                    break            # end of the document
                ln = nl
            y = tr.y + vi * lh
            gx = r.x
            for g in self.gutters:
                cell = self.gutter_cell(g.kind, ln)
                if len(cell) > 0:
                    # right-aligned inside the column, measured in CODEPOINTS:
                    # a marker like ▾ is one glyph and three bytes
                    self.u.cmd_text(self.id, gx + (g.width_cp - len(cell)) * cw, y, cell,
                                    self.gutter_color(g.kind, ln))
                gx += g.width_cp * cw
            # indentation guides: a 1px thread at every tab stop inside the
            # left-hand space, so the nesting is legible in an indentation-based
            # language
            ind = self.buf.indent_of(ln)
            if self.buf.is_blank(ln):
                # an empty line borrows the smaller of its neighbours', so the
                # guides do not break in the middle of a block
                pv = self.buf.next_visible(ln, -1)
                nx = self.buf.next_visible(ln, 1)
                a = self.buf.indent_of(pv) if pv != ln else 0
                bq = self.buf.indent_of(nx) if nx != ln else 0
                ind = a if a < bq else bq
            gcol = CV_TAB
            while gcol < ind:
                gxx = tr.x + (gcol - self.left) * cw
                if gxx >= tr.x and gxx < tr.x + tr.w:
                    self.u.cmd_rect(self.id, pui.Rect(gxx, y, 1, lh), 0xFF31343A)
                gcol += CV_TAB
            s = self.buf.line_text(ln)
            sc = 0
            cpi = 0
            for ch in s:
                adv = 1
                if ch == "\t":
                    adv = CV_TAB - (sc % CV_TAB)
                if sc + adv > self.left and sc < self.left + cols and ch != "\t":
                    self.u.cmd_glyph(self.id, tr.x + (sc - self.left) * cw, y, ord(ch),
                                     hl_color(self.hl.class_at(ln, cpi)))
                sc += adv
                cpi += 1
                if sc > self.left + cols:
                    break
            # a collapsed block shows Sublime's ellipsis after the header
            if self.buf.is_folded(ln):
                ex = tr.x + (sc - self.left + 1) * cw
                self.u.cmd_rect(self.id, pui.Rect(ex - 2, y, cw + 4, lh), 0xFF3A3D41)
                self.u.cmd_glyph(self.id, ex, y, pui.CP_ELLIPSIS, th.text_dim)

        # ---- the completion popup, anchored under the cursor ----
        if self.cmp_open and len(self.cmp_hits) > 0 and self.row_of_line(self.buf.caret(0).line) >= 0:
            pr = self.cmp_rect()
            rows2 = self.cmp_rows()
            self.u.cmd_rect(self.id, pr, 0xFF2B2D30)
            self.u.cmd_frame(self.id, pr, th.accent)
            inner = pr.w - 2 * CMP_PAD
            for hi in range(rows2):
                idx2 = self.cmp_top + hi
                if idx2 >= len(self.cmp_hits):
                    break
                sm = self.index.sym(self.cmp_hits[idx2])
                ry = pr.y + CMP_PAD + hi * lh
                if idx2 == self.cmp_sel:
                    self.u.cmd_rect(self.id, pui.Rect(pr.x + 1, ry, pr.w - 2, lh), th.sel)
                # the NAME is what gets chosen, so it takes what it needs; the
                # signature takes what is left and leaves the stage when there is
                # not enough left to say anything
                nw = self.u.cmd_text_fit(self.id, pr.x + CMP_PAD, ry, sm.name, inner,
                                         th.text if idx2 == self.cmp_sel else th.text_dim)
                if len(sm.detail) > 0:
                    dw = inner - nw - 2 * cw
                    if dw >= CMP_MIN_DETAIL * cw:
                        self.u.cmd_text_fit(self.id, pr.x + CMP_PAD + nw + 2 * cw, ry,
                                            sm.detail, dw, 0xFF6E7075)

        # ---- the minimap: a run of the same class becomes one rectangle ----
        if self.minimap:
            mr = self.minimap_rect()
            self.u.cmd_rect(self.id, mr, 0xFF1A1B1E)
            rows = mr.h // MM_ROW
            total = self.buf.visible_count()
            first = self.mm_first(rows, vis, total)
            mln = self.buf.from_visible(first)
            for mrow in range(rows):
                if mrow > 0:
                    nl2 = self.buf.next_visible(mln, 1)
                    if nl2 == mln:
                        break
                    mln = nl2
                my = mr.y + mrow * MM_ROW
                mc = 0
                runc = 0
                runs = -1
                for chm in self.buf.line_text(mln):
                    if mc >= mr.w:
                        break
                    clsm = self.hl.class_at(mln, mc)
                    blank = chm == " " or chm == "\t"
                    if blank or clsm != runc:
                        if runs >= 0:
                            self.u.cmd_rect(self.id, pui.Rect(mr.x + runs, my, mc - runs, MM_ROW - 1),
                                            mm_tint(runc))
                            runs = -1
                        if not blank:
                            runc = clsm
                            runs = mc
                    mc += CV_TAB - (mc % CV_TAB) if chm == "\t" else 1
                if runs >= 0 and runs < mr.w:
                    e2 = mc if mc < mr.w else mr.w
                    self.u.cmd_rect(self.id, pui.Rect(mr.x + runs, my, e2 - runs, MM_ROW - 1),
                                    mm_tint(runc))
            # the view's window over the strip
            vy = mr.y + (self.buf.to_visible(self.top) - first) * MM_ROW
            self.u.cmd_rect(self.id, pui.Rect(mr.x, vy, mr.w, vis * MM_ROW), 0x18FFFFFF)
            self.u.cmd_frame(self.id, pui.Rect(mr.x, vy, mr.w, vis * MM_ROW), 0xFF3A3D41)

        # the cursors (on top of everything)
        if self.caret_on and self.u.focus_get() == self.id:
            for k in range(self.buf.ncarets()):
                c = self.buf.caret(k)
                krow = self.row_of_line(c.line)
                if krow < 0 or krow >= vis:
                    continue
                cx = tr.x + (self.screen_col(c.line, c.col) - self.left) * cw
                if cx < tr.x - 1 or cx > tr.x + tr.w:
                    continue
                self.u.cmd_rect(self.id, pui.Rect(cx, tr.y + krow * lh, 2, lh), 0xFFE8E8E8)

    def mm_first(self, rows: int, vis: int, total: int) -> int:
        """The first row the strip shows — the arithmetic is here because the
        drawing and the minimap click need the SAME one."""
        if total <= rows:
            return 0
        topv = self.buf.to_visible(self.top)
        span = total - rows
        room = total - vis
        first = topv * span // (room if room > 0 else 1)
        return span if first > span else first

    def minimap_jump(self, y: int):
        """Centres the view on the line that the minimap's pixel `y` stands for."""
        mr = self.minimap_rect()
        vis = self.visible_lines()
        rows = mr.h // MM_ROW
        first = self.mm_first(rows, vis, self.buf.visible_count())
        self.set_top(first + (y - mr.y) // MM_ROW - vis // 2)

    # ---------- clipboard (the app talks to the system) ----------

    def copy(self) -> str:
        """Returns the text for the system (the pieces joined by \\n) and keeps the
        N pieces for the multi-cursor paste. "" = there was no selection."""
        if not self.buf.has_sel():
            return ""
        parts: list<str> = []
        for k in range(self.buf.ncarets()):
            parts.append(self.buf.sel_text(k))
        self.clip = parts
        return "\n".join(parts)

    def cut(self, now_ms: int) -> str:
        got = self.copy()
        if len(got) == 0:
            return ""
        self.buf.delete_sel(now_ms)
        self.changed()
        self.scroll_to_caret()
        return got

    def paste(self, sys_text: str, now_ms: int):
        # N pieces for N cursors (Sublime): only while what came from the system
        # is still what we copied (otherwise outside text wins)
        if len(self.clip) == self.buf.ncarets() and len(self.clip) > 1 and sys_text == "\n".join(self.clip):
            self.buf.insert_each(self.clip, now_ms)
        elif len(sys_text) > 0:
            self.buf.insert(sys_text, now_ms)
        elif len(self.clip) == 1:
            self.buf.insert(self.clip[0], now_ms)
        self.changed()
        self.scroll_to_caret()

    # ---------- indentation ----------

    def sel_lines_range(self) -> core.Span:
        """The lines the cursors cover, and whether ANY of them has a selection
        of more than one line (which decides whether tab indents the block)."""
        l0 = 0
        l1 = -1
        multi = 0
        for k in range(self.buf.ncarets()):
            sr = self.buf.sel_range(k)
            if sr.l0 != sr.l1:
                multi = 1
            if l1 < 0 or sr.l0 < l0:
                l0 = sr.l0
            if sr.l1 > l1:
                l1 = sr.l1
        return core.Span(l0, multi, l1, 0)

    def indent(self, now_ms: int):
        rg = self.sel_lines_range()
        if rg.c0 == 1:
            self.buf.indent(1, now_ms)
        else:
            c = self.buf.caret(0)
            pad = CV_TAB - (self.screen_col(c.line, c.col) % CV_TAB)
            self.buf.insert(" " * pad, now_ms)
        self.changed()
        self.scroll_to_caret()

    def unindent(self, now_ms: int):
        self.buf.indent(-1, now_ms)
        self.changed()
        self.scroll_to_caret()

    def newline(self, now_ms: int):
        """Auto-indent: repeats the line's indentation, and goes one level deeper
        after a ':'."""
        c = self.buf.caret(self.buf.ncarets() - 1)
        s = self.buf.line_text(c.line)
        ind = len(s) - len(s.lstrip())
        head = s[0:c.col]
        deeper = head.rstrip().endswith(":")
        if ind > c.col:
            ind = c.col          # a cursor inside the indentation: do not duplicate it
        total = ind + (CV_TAB if deeper else 0)
        self.buf.insert("\n" + " " * total, now_ms)
        self.changed()
        self.scroll_to_caret()

    # ---------- automatic pairs ----------

    def char_after(self, c: core.Caret) -> str:
        s = self.buf.line_text(c.line)
        return s[c.col:c.col + 1] if c.col < len(s) else ""

    def char_before(self, c: core.Caret) -> str:
        if c.col == 0:
            return ""
        return self.buf.line_text(c.line)[c.col - 1:c.col]

    def auto_pair(self, ch: str, now_ms: int) -> bool:
        """True when the typed character was handled as a pair."""
        close = pair_close_of(ch)
        c = self.buf.caret(0)
        # typing the closer where it already is: step over it
        if pair_is_close(ch) and self.buf.ncarets() == 1 and not self.buf.has_sel():
            if self.char_after(c) == ch:
                self.buf.move_h(1, False)
                return True
        if len(close) == 0:
            return False
        # wraps the selection instead of replacing it
        if self.buf.has_sel():
            wrapped = False
            k = self.buf.ncarets() - 1
            while k >= 0:
                sr = self.buf.sel_range(k)
                if sr.l0 != sr.l1 or sr.c0 != sr.c1:
                    body = self.buf.sel_text(k)
                    self.buf.select_range(sr)
                    self.buf.replace_range(sr, ch + body + close, now_ms)
                    wrapped = True
                k -= 1
            return wrapped
        # a quote after a word is an apostrophe, not a pair
        if (ch == "\"" or ch == "'") and is_word_ch(self.char_before(c)):
            return False
        after = self.char_after(c)
        if len(after) > 0 and not pair_is_close(after) and after != " " and after != "\t":
            return False          # it only forms a pair at a boundary
        self.buf.insert(ch + close, now_ms)
        self.buf.move_h(-1, False)
        return True

    def pair_backspace(self, now_ms: int) -> bool:
        """Backspace between an empty pair takes both sides."""
        if self.buf.ncarets() != 1 or self.buf.has_sel():
            return False
        c = self.buf.caret(0)
        b = self.char_before(c)
        a = self.char_after(c)
        cl = pair_close_of(b)
        # `b` has to be an OPENER whose closer is right after the cursor; with
        # both sides absent, two "" would compare equal and the arithmetic would
        # eat a line break
        if len(cl) == 0 or len(a) == 0 or cl != a:
            return False
        self.buf.delete_fwd(now_ms)
        self.buf.backspace(now_ms)
        return True

    # ---------- completion ----------

    def word_before(self) -> core.Span:
        """The word being typed before the cursor: returns the starting column in
        `c0` and the text goes through `word_text`."""
        c = self.buf.caret(0)
        s = self.buf.line_text(c.line)
        b = c.col
        while b > 0 and is_word_ch(s[b - 1:b]):
            b -= 1
        return core.Span(c.line, b, c.line, c.col)

    def word_text(self, r: core.Span) -> str:
        return self.buf.line_text(r.l0)[r.c0:r.c1]

    def owner_before(self, word_start: int) -> str:
        """The expression whose members to list: what comes before a `.` or `->`
        to the left of the word. "" when there is none."""
        c = self.buf.caret(0)
        s = self.buf.line_text(c.line)
        b = word_start
        if b >= 1 and s[b - 1:b] == ".":
            b -= 1
        elif b >= 2 and s[b - 2:b] == "->":
            b -= 2
        else:
            return ""
        e = b
        while b > 0 and is_word_ch(s[b - 1:b]):
            b -= 1
        return "" if b == e else s[b:e]

    def cmp_rows(self) -> int:
        """How many candidates the popup shows. The drawing and the arrow keys ask
        HERE — each of them used to carry its own `8`, and a popup shortened by a
        low panel scrolled against rows that were not on screen."""
        n = len(self.cmp_hits)
        if n > CMP_MAX_ROWS:
            n = CMP_MAX_ROWS
        fits = self.text_rect().h // self.u.cell_h - 1
        if n > fits:
            n = fits
        return n if n > 1 else 1

    def cmp_rect(self) -> pui.Rect:
        """The box: as wide as the candidates on show ask for, then pinned to the
        text area. Every overflow is decided here, once."""
        tr = self.text_rect()
        cw = self.u.cell_w
        lh = self.u.cell_h
        rows = self.cmp_rows()
        w = CMP_MIN_COLS * cw
        for hi in range(rows):
            i = self.cmp_top + hi
            if i >= len(self.cmp_hits):
                break
            sm = self.index.sym(self.cmp_hits[i])
            cand = self.u.text_w(sm.name)
            if len(sm.detail) > 0:
                cand += 2 * cw + self.u.text_w(sm.detail)
            if cand > w:
                w = cand
        w += 2 * CMP_PAD
        if w > CMP_MAX_COLS * cw:
            w = CMP_MAX_COLS * cw
        if w > tr.w - cw:                  # a narrow panel beats any minimum
            w = tr.w - cw
        h = rows * lh + 2 * CMP_PAD
        if h > tr.h:
            h = tr.h
        x = tr.x + (self.screen_col(self.buf.caret(0).line, self.cmp_col) - self.left) * cw
        if x + w > tr.x + tr.w:
            x = tr.x + tr.w - w
        if x < tr.x:
            x = tr.x
        row = self.row_of_line(self.buf.caret(0).line)
        y = tr.y + (row + 1) * lh
        if y + h > tr.y + tr.h:
            y = tr.y + row * lh - h        # flips above the cursor
        # neither side fits — a low panel, or a cursor the view has scrolled away
        # from. It stays INSIDE the area: covering text is better than leaving it.
        if y + h > tr.y + tr.h:
            y = tr.y + tr.h - h
        if y < tr.y:
            y = tr.y
        return pui.Rect(x, y, w, h)

    def complete_close(self):
        if not self.cmp_open:
            return
        self.cmp_open = False
        self.cmp_owner = ""
        self.u.queue_redraw(self.id)

    def complete_open(self):
        if self.index.is_stale(self.buf):
            self.index.build(self.buf, [])
        self.cmp_open = True
        self.cmp_sel = 0
        self.cmp_top = 0
        self.complete_refresh()

    def enclosing_struct(self, line: int) -> str:
        """The struct in whose body `line` sits, by indentation — it is how
        `self.` resolves without guessing (a file index could not)."""
        l = line
        while l >= 0:
            s = self.buf.line_text(l)
            if s.startswith("struct "):
                rest = s[7:len(s)].lstrip()
                e = 0
                while e < len(rest) and is_word_ch(rest[e:e + 1]):
                    e += 1
                return rest[0:e] if e > 0 else ""
            l -= 1
        return ""

    def complete_refresh(self):
        if not self.cmp_open:
            return
        wr = self.word_before()
        w = self.word_text(wr)
        self.cmp_owner = self.owner_before(wr.c0)
        self.cmp_col = wr.c0
        owner = ""
        if len(self.cmp_owner) > 0:
            if self.cmp_owner == "self":
                owner = self.enclosing_struct(self.buf.caret(0).line)
            else:
                owner = self.index.owner_of(self.cmp_owner)
            if len(owner) == 0:
                self.complete_close()      # unknown receiver: nothing honest to offer
                return
        self.cmp_hits = self.index.query(w, owner)
        if len(self.cmp_hits) == 0:
            self.complete_close()
            return
        if self.cmp_sel >= len(self.cmp_hits):
            self.cmp_sel = len(self.cmp_hits) - 1
        self.u.queue_redraw(self.id)

    def complete_accept(self, now_ms: int) -> bool:
        if not self.cmp_open or len(self.cmp_hits) == 0:
            return False
        name = self.index.sym(self.cmp_hits[self.cmp_sel]).name
        c = self.buf.caret(0)
        self.buf.replace_range(core.Span(c.line, self.cmp_col, c.line, c.col), name, now_ms)
        self.complete_close()
        self.changed()
        self.scroll_to_caret()
        return True

    # ---------- folding and line commands ----------

    def toggle_fold_at_caret(self):
        l = self.buf.caret(0).line
        if not self.buf.can_fold(l) and not self.buf.is_folded(l):
            # not a header: fold the block that CONTAINS the cursor (Sublime)
            h = l - 1
            while h >= 0:
                if self.buf.can_fold(h) and self.buf.fold_end(h) >= l:
                    l = h
                    break
                h -= 1
        if self.buf.toggle_fold(l):
            self.changed()
            self.scroll_to_caret()

    def fold_all(self):
        self.buf.fold_all()
        self.anchor_top()

    def unfold_all(self):
        self.buf.unfold_all()
        self.anchor_top()

    def toggle_bookmark(self):
        self.buf.toggle_mark(self.buf.caret(0).line, core.MARK_BOOK)
        self.u.queue_redraw(self.id)

    def goto_mark(self, forward: bool):
        l = self.buf.next_mark(self.buf.caret(0).line, core.MARK_BOOK, forward)
        if l < 0:
            return
        self.buf.move_to(l, 0)
        self.scroll_to_caret()
        self.u.queue_redraw(self.id)

    def toggle_comment(self, now_ms: int):
        self.buf.toggle_comment("#", now_ms)
        self.changed()
        self.scroll_to_caret()

    def move_lines(self, dir: int, now_ms: int):
        self.buf.move_lines(dir, now_ms)
        self.changed()
        self.scroll_to_caret()

    def duplicate_lines(self, now_ms: int):
        self.buf.duplicate_lines(now_ms)
        self.changed()
        self.scroll_to_caret()

    def delete_lines(self, now_ms: int):
        self.buf.delete_lines(now_ms)
        self.changed()
        self.scroll_to_caret()

    def join_lines(self, now_ms: int):
        self.buf.join_lines(now_ms)
        self.changed()
        self.scroll_to_caret()

    # ---------- search ----------

    def search(self, needle: str, forward: bool, use_re: bool, from_caret: bool) -> bool:
        if len(needle) == 0:
            return False
        c = self.buf.caret(0)
        sl = c.line
        sc = c.col
        if not from_caret:
            sl = 0
            sc = 0
        elif forward:
            sr = self.buf.sel_range(0)     # starts AFTER the current selection
            sl = sr.l1
            sc = sr.c1
        hit = self.buf.find_re(needle, sl, sc, forward) if use_re else self.buf.find(needle, sl, sc, True)
        if hit != None:
            # the non-null proof holds INSIDE the branch (43.1), and this is where
            # the Span's fields exist
            end = hit.c1 if use_re else hit.c0 + len(needle)
            self.buf.select_range(core.Span(hit.l0, hit.c0, hit.l0, end))
            self.scroll_to_caret()
            self.u.queue_redraw(self.id)
            return True
        return False

    # ---------- input ----------

    def handle_input(self, ev: pui.Event, now: int) -> bool:
        match ev.kind:
            case pui.EV_MOUSE_DOWN:
                if ev.button != 1:
                    return False
                self.u.focus_set(self.id)
                p = self.pos_from_xy(ev.x, ev.y)
                # the minimap: a click or a drag jumps the view (Godot's TextEdit)
                mmr = self.minimap_rect()
                if self.minimap and pui.rect_has(mmr, ev.x, ev.y):
                    self.minimap_drag = True
                    self.minimap_jump(ev.y)
                    return True
                # a click on the gutters belongs to that column's gutter
                r0 = self.u.rect_of(self.id)
                if ev.x < r0.x + self.gutter_w():
                    gx = r0.x
                    for g in self.gutters:
                        gw = g.width_cp * self.u.cell_w
                        if ev.x >= gx and ev.x < gx + gw:
                            if self.gutter_click(g.kind, p.l0):
                                return True
                        gx += gw
                    return True
                if ev.clicks >= 3:
                    self.buf.select_range(core.Span(p.l0, 0, p.l0, self.buf.line_cp(p.l0)))
                elif ev.clicks == 2:
                    self.buf.move_to(p.l0, p.c0)
                    self.buf.select_word_at(0)
                elif (ev.mods & 4) != 0:
                    self.buf.add_caret(p.l0, p.c0)     # cursor extra (alt+clique)
                elif (ev.mods & 1) != 0:
                    cr = self.buf.caret(0)
                    self.buf.select_range(core.Span(cr.aline, cr.acol, p.l0, p.c0))
                else:
                    self.buf.move_to(p.l0, p.c0)
                    self.mouse_sel = True
                self.caret_on = True
                self.u.queue_redraw(self.id)
                return True
            case pui.EV_MOUSE_MOVE:
                if self.minimap_drag:
                    self.minimap_jump(ev.y)
                    return True
                if not self.mouse_sel:
                    return False
                p2 = self.pos_from_xy(ev.x, ev.y)
                cr2 = self.buf.caret(0)
                self.buf.select_range(core.Span(cr2.aline, cr2.acol, p2.l0, p2.c0))
                tr = self.text_rect()
                if ev.y < tr.y:
                    self.set_top(self.buf.to_visible(self.top) - 1)
                elif ev.y > tr.y + tr.h:
                    self.set_top(self.buf.to_visible(self.top) + 1)
                self.u.queue_redraw(self.id)
                return True
            case pui.EV_MOUSE_UP:
                self.mouse_sel = False
                self.minimap_drag = False
                return True
            case pui.EV_WHEEL:
                if (ev.mods & 2) != 0:
                    return False   # ctrl+wheel = zoom (that is the app's)
                self.set_top(self.buf.to_visible(self.top) - ev.wheel * 3)
                return True
            case pui.EV_TEXT:
                ch = chr(ev.cp)
                if self.cmp_open and not is_word_ch(ch):
                    self.complete_close()
                self.caret_on = True
                if self.auto_pair(ch, now):
                    self.changed()
                    self.scroll_to_caret()
                    return True
                self.buf.insert(ch, now)
                self.changed()
                self.scroll_to_caret()
                # `.`/`->` offers members; with the popup open, keeps the list
                if self.cmp_open:
                    self.complete_refresh()
                elif ch == "." or ch == ">":
                    self.complete_open()
                return True
            case pui.EV_KEY:
                return self.handle_key(ev, now)
            case _:
                pass
        return False

    def handle_key(self, ev: pui.Event, now: int) -> bool:
        sel = (ev.mods & 1) != 0
        ctrl = (ev.mods & 2) != 0
        self.caret_on = True
        # ctrl+space asks for candidates; with the popup open, it keeps the
        # arrows, the enter/tab and the escape
        if ctrl and ev.key == pui.K_SPACE:
            self.complete_open()
            return True
        if self.cmp_open:
            if ev.key == pui.K_ESCAPE:
                self.complete_close()
                return True
            if ev.key == pui.K_RETURN or ev.key == pui.K_TAB:
                if self.complete_accept(now):
                    return True
            if ev.key == K_UP or ev.key == K_DOWN:
                n2 = len(self.cmp_hits)
                self.cmp_sel += 1 if ev.key == K_DOWN else -1
                if self.cmp_sel < 0:
                    self.cmp_sel = n2 - 1
                if self.cmp_sel >= n2:
                    self.cmp_sel = 0
                rows3 = self.cmp_rows()      # what is actually on screen
                if self.cmp_sel < self.cmp_top:
                    self.cmp_top = self.cmp_sel
                elif self.cmp_sel >= self.cmp_top + rows3:
                    self.cmp_top = self.cmp_sel - rows3 + 1
                self.u.queue_redraw(self.id)
                return True
            if ev.key != pui.K_BACKSPACE and ev.key != pui.K_LEFT and ev.key != pui.K_RIGHT:
                self.complete_close()
        if ev.key == pui.K_LEFT:
            self.buf.move_word(-1, sel) if ctrl else self.buf.move_h(-1, sel)
        elif ev.key == pui.K_RIGHT:
            self.buf.move_word(1, sel) if ctrl else self.buf.move_h(1, sel)
        elif ev.key == K_UP:
            self.buf.move_v(-1, sel)
        elif ev.key == K_DOWN:
            self.buf.move_v(1, sel)
        elif ev.key == K_PAGEUP:
            self.buf.move_v(-self.visible_lines(), sel)
        elif ev.key == K_PAGEDOWN:
            self.buf.move_v(self.visible_lines(), sel)
        elif ev.key == pui.K_HOME:
            self.buf.move_to(0, 0) if ctrl else self.buf.home(sel)
        elif ev.key == pui.K_END:
            if ctrl:
                last = self.buf.nlines() - 1
                self.buf.move_to(last, self.buf.line_cp(last))
            else:
                self.buf.end(sel)
        elif ev.key == pui.K_BACKSPACE:
            if not self.pair_backspace(now):
                self.buf.backspace(now)
            self.changed()
            if self.cmp_open:
                self.complete_refresh()
        elif ev.key == pui.K_DELETE:
            self.buf.delete_fwd(now)
            self.changed()
        elif ev.key == pui.K_RETURN:
            self.newline(now)
        elif ev.key == pui.K_TAB:
            self.unindent(now) if sel else self.indent(now)
        elif ev.key == pui.K_ESCAPE:
            self.buf.collapse()
        else:
            return False
        self.scroll_to_caret()
        self.u.queue_redraw(self.id)
        return True


# the keys only the codeview uses (the others come from the `pui` package)
const K_UP: int = 1073741906
const K_DOWN: int = 1073741905
const K_PAGEUP: int = 1073741899
const K_PAGEDOWN: int = 1073741902


def cv_create(u: pui.Ui, parent: int) -> CodeView:
    """Creates the widget with the internal bars and the three gutters, and
    returns the CodeView — its id is in `.id`."""
    cv = CodeView(core.new_buffer(), hlm.new_hl(True), cmp.new_index(), "",
                  u, -1, -1, -1, 0, 0, [], False, [], 0, 0, 0, "",
                  True, False, True, False, 0, [], False, 0)
    id = u.custom(parent, None)
    u.set_focusable(id, True)
    u.set_expand(id, True, True)
    cv.id = id
    cv.vsb = u.scrollbar(id, True)
    cv.hsb = u.scrollbar(id, False)
    u.on_scroll(cv.vsb, lambda wid, arg: cv.on_vscroll(arg))
    u.on_scroll(cv.hsb, lambda wid, arg: cv.on_hscroll(arg))
    u.set_custom(id,
                 lambda ui2, wid: pui.Size(cv.gutter_w() + u.cell_w * 8, u.cell_h * 3),
                 lambda ui2, wid: cv.build(),
                 lambda ui2, wid, ev: cv.handle_input(ev, cv.now_ms),
                 lambda ui2, wid, r: cv.layout(r))
    cv.add_gutter(GUT_MARKS, 2)        # ● / ◆ at the left edge
    cv.add_gutter(GUT_FOLD, 2)         # then ▾/▸, then the numbers (Sublime's order)
    cv.add_gutter(GUT_NUMBERS, 5)
    return cv
