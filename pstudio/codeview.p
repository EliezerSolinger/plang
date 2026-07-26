# codeview.p — the editing widget's implementation (see codeview.ph)
include <stdio.h>
include <stdlib.h>
include <string.h>
import "codeview.ph"
import "psys.ph"
import "complete.ph"

CV_TAB: const i32 = 4       # soft tabs (DESIGN.md)
# completion popup. The box is fitted to the candidates ON SHOW and then clamped
# to the text area, so it can never reach over the minimap or off the widget;
# whatever does not fit is elided (cmd_text_fit) rather than painted outside.
CMP_MAX_ROWS: const i32 = 10       # candidates visible at once
CMP_MIN_COLS: const i32 = 16       # the box never looks like a sliver
CMP_MAX_COLS: const i32 = 72       # ... nor spans a wide editor
CMP_PAD: const i32 = 3             # inner margin (px)
CMP_MIN_DETAIL: const i32 = 8      # columns below which the signature is dropped
                                   #   instead of elided down to just "…"
# minimap: one pixel row per line, one pixel column per character (Godot draws
# it from the HIGHLIGHT, not from glyphs — at this scale letters are noise)
MM_COLS: const i32 = 90            # characters shown across the strip
MM_ROW: const i32 = 2              # pixels per line

static def byte_to_col_cv(s: const *char, b: i32) -> i32:
    n: i32 = 0
    for i in range(b):
        if (u8(s[i]) & 0xC0) != 0x80:
            n += 1
    return n

static def is_word_ch_cv(ch: char) -> bool:
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_'

# the pairs an editor closes for you; a quote is its own closer
static def pair_close_of(open_ch: char) -> char:
    if open_ch == '(':
        return ')'
    if open_ch == '[':
        return ']'
    if open_ch == '{':
        return '}'
    if open_ch == '"':
        return '"'
    if open_ch == '\'':
        return '\''
    return '\0'

static def pair_is_close(ch: char) -> bool:
    return ch in {')', ']', '}', '"', '\''}

# colors per highlight class (dark theme; the index is HL_*)
hl_colors: const u32[6] = {
    0xFFD4D4D4,   # HL_TEXT
    0xFFC586C0,   # HL_KW      (purple)
    0xFFCE9178,   # HL_STR     (orange)
    0xFFB5CEA8,   # HL_NUM     (light green)
    0xFF6A9955,   # HL_COMMENT (green)
    0xFFD4D4D4}   # HL_PUNCT

# a highlight color at minimap strength (translucent, so runs read as texture)
static def mm_tint(cls: u8) -> u32:
    return (hl_colors[cls if cls < 6 else 0] & 0x00FFFFFF) | 0xB0000000

# ---------- multi-caret clipboard (one editor per process) ----------
clip_parts: **char = None
clip_n: i32 = 0

def cv_clip_clear():
    for i in range(clip_n):
        free(clip_parts[i])
    free(clip_parts)
    clip_parts = None
    clip_n = 0

def cv_clip_count() -> i32:
    return clip_n

static def clip_set(parts: **char, n: i32):
    cv_clip_clear()
    clip_parts = parts
    clip_n = n

# ---------- the marks gutter (● breakpoint, ◆ bookmark) ----------
# The second and third clients of the pluggable gutter API: they prove the
# abstraction is real (line numbers were the first).
static def gutter_marks_draw(ctx: *void, cv: *CodeView, line: i32, out_text: *char, cap: usize, out_color: *u32) -> bool:
    m: u8 = cv->buf.mark_of(line)
    if (m & MARK_BREAKPOINT) != 0:
        snprintf(out_text, cap, "●")
        *out_color = 0xFFE05252
        return True
    if (m & MARK_BOOKMARK) != 0:
        snprintf(out_text, cap, "◆")
        *out_color = 0xFF4F9CF7
        return True
    return False

static def gutter_marks_click(ctx: *void, cv: *CodeView, line: i32) -> bool:
    cv->buf.toggle_mark(line, MARK_BREAKPOINT)
    cv->ui->queue_redraw(cv->id)
    return True

# ---------- the fold gutter (▾ open block, ▸ collapsed) ----------
static def gutter_fold_draw(ctx: *void, cv: *CodeView, line: i32, out_text: *char, cap: usize, out_color: *u32) -> bool:
    if cv->buf.is_folded(line):
        snprintf(out_text, cap, "▸")
        *out_color = 0xFFD0A050
        return True
    if cv->buf.can_fold(line):
        snprintf(out_text, cap, "▾")
        *out_color = 0xFF6E7075
        return True
    return False

static def gutter_fold_click(ctx: *void, cv: *CodeView, line: i32) -> bool:
    if not cv->buf.toggle_fold(line):
        return False
    cv->anchor_top()
    return True

# ---------- the default gutter: line numbers ----------
static def gutter_numbers(ctx: *void, cv: *CodeView, line: i32, out_text: *char, cap: usize, out_color: *u32) -> bool:
    snprintf(out_text, cap, "%d", line + 1)
    cur: bool = False
    for k in range(cv->buf.ncarets()):
        if cv->buf.caret(k)->line == line:
            cur = True
    *out_color = 0xFFB0B0B0 if cur else 0xFF6E7075
    return True

struct CodeView:
    static def sync_bars(ref self: CodeView)
    static def build(ref self: CodeView)
    static def handle_input(ref self: CodeView, ev: *PgEvent) -> bool
    static def max_screen_cols(in self: CodeView) -> i32
    static def sel_lines_range(ref self: CodeView, out l0: i32, out l1: i32) -> bool
    static def minimap_jump(ref self: CodeView, y: i32)
    static def word_before(in self: CodeView, out start_col: i32) -> *char
    static def owner_before(in self: CodeView, word_start: i32) -> *char
    static def enclosing_struct(in self: CodeView, line: i32) -> *char
    static def auto_pair(ref self: CodeView, text: const *char, now_ms: i64) -> bool
    static def pair_backspace(ref self: CodeView, now_ms: i64) -> bool
    static def char_after(in self: CodeView, c: *Caret) -> char
    static def char_before(in self: CodeView, c: *Caret) -> char

    # ---------- file ----------

    def load_file(ref self: CodeView, path: const *char) -> bool:
        v: Vfs = vfs_local()
        n: usize
        data: *char = vfs_read_all(in v, path, out n)
        if data == None:
            return False
        self.buf.load(data, n)
        free(data)
        free(self.path)
        self.path = malloc(strlen(path) + 1)
        strcpy(self.path, path)
        st: PsStat
        self.mtime = st.mtime if vfs_stat(in v, path, out st) else 0
        # highlighting only for P files (everything else stays plain text)
        ext: const *char = strrchr(path, '.')
        self.hl.deinit()
        self.hl.init(ext != None and (strcmp(ext, ".p") == 0 or strcmp(ext, ".ph") == 0))
        self.top = 0
        self.left = 0
        self.changed()
        return True

    def save_file(ref self: CodeView) -> bool:
        if self.path == None:
            return False
        n: usize
        text: *char = self.buf.save_text(out n)
        v: Vfs = vfs_local()
        ok: bool = vfs_write_all(in v, self.path, text, n)
        free(text)
        if ok:
            self.buf.mark_saved()
            st: PsStat
            self.mtime = st.mtime if vfs_stat(in v, self.path, out st) else 0
            if self.on_change != None:
                self.on_change(self.on_change_ctx, &self)
        return ok

    def reload(ref self: CodeView) -> bool:
        if self.path == None:
            return False
        keep_top: i32 = self.top
        p: *char = self.path
        self.path = None      # load_file frees the old one; keep the name alive
        ok: bool = self.load_file(p)
        free(p)
        if ok:
            self.top = keep_top
        return ok

    def set_text(ref self: CodeView, text: const *char):
        self.buf.load(text, strlen(text))
        self.changed()

    # ---------- geometry ----------

    def gutter_w(in self: CodeView) -> i32:
        if self.ngutters == 0:
            return 0
        cw: i32 = self.ui->font.char_w()
        total: i32 = 0
        for i in range(self.ngutters):
            total += self.gutters[i].width_cp * cw
        return total + cw   # one character of breathing room before the text

    def minimap_rect(in self: CodeView) -> PgRect:
        r: PgRect = self.ui->rect_of(self.id)
        hs: i32 = self.ui->theme.handle + 2
        if not self.minimap:
            return pg_rect(r.x + r.w - hs, r.y, 0, 0)
        w: i32 = MM_COLS
        if w > r.w / 4:
            w = r.w / 4          # never eat more than a quarter of the view
        return pg_rect(r.x + r.w - hs - w, r.y, w, r.h - hs)

    def text_rect(in self: CodeView) -> PgRect:
        r: PgRect = self.ui->rect_of(self.id)
        hs: i32 = self.ui->theme.handle + 2
        g: i32 = self.gutter_w()
        mm: i32 = self.minimap_rect().w
        return pg_rect(r.x + g, r.y, r.w - g - hs - mm, r.h - hs)

    def toggle_minimap(ref self: CodeView):
        self.minimap = not self.minimap
        self.ui->relayout()
        self.ui->queue_redraw(self.id)

    def visible_lines(in self: CodeView) -> i32:
        lh: i32 = self.ui->font.line_h()
        n: i32 = self.text_rect().h / lh
        return n if n > 0 else 1

    def add_gutter(ref self: CodeView, g: Gutter):
        if self.ngutters >= MAX_GUTTERS:
            return
        self.gutters[self.ngutters] = g
        self.ngutters += 1

    def line_numbers_gutter(ref self: CodeView):
        g: Gutter = {0}
        g.width_cp = 5
        g.ctx = None
        g.draw = gutter_numbers
        g.click = None
        self.add_gutter(g)

    def fold_gutter(ref self: CodeView):
        g: Gutter = {0}
        g.width_cp = 2
        g.ctx = None
        g.draw = gutter_fold_draw
        g.click = gutter_fold_click
        self.add_gutter(g)

    def marks_gutter(ref self: CodeView):
        g: Gutter = {0}
        g.width_cp = 2
        g.ctx = None
        g.draw = gutter_marks_draw
        g.click = gutter_marks_click
        self.add_gutter(g)

    # ---------- screen columns (tabs expanded) ----------

    def screen_col(in self: CodeView, line: i32, col: i32) -> i32:
        s: const *char = self.buf.line_text(line)
        sc: i32 = 0
        n: i32 = 0
        i: usize = 0
        while s[i] != '\0' and n < col:
            if (u8(s[i]) & 0xC0) != 0x80:
                if s[i] == '\t':
                    sc += CV_TAB - (sc % CV_TAB)
                else:
                    sc += 1
                n += 1
            i += 1
        return sc

    def col_from_screen(in self: CodeView, line: i32, scol: i32) -> i32:
        s: const *char = self.buf.line_text(line)
        sc: i32 = 0
        n: i32 = 0
        i: usize = 0
        while s[i] != '\0':
            if (u8(s[i]) & 0xC0) != 0x80:
                if sc >= scol:
                    return n
                if s[i] == '\t':
                    sc += CV_TAB - (sc % CV_TAB)
                else:
                    sc += 1
                n += 1
            i += 1
        return n

    def line_at_row(in self: CodeView, row: i32) -> i32:
        return self.buf.next_visible(self.top, row)

    def row_of_line(in self: CodeView, line: i32) -> i32:
        if self.buf.is_hidden(line):
            return -1
        return self.buf.to_visible(line) - self.buf.to_visible(self.top)

    def pos_from_xy(in self: CodeView, x: i32, y: i32, out line: i32, out col: i32):
        tr: PgRect = self.text_rect()
        lh: i32 = self.ui->font.line_h()
        cw: i32 = self.ui->font.char_w()
        row: i32 = (y - tr.y) / lh
        if y < tr.y:
            row = -1
        l: i32 = self.line_at_row(row)      # folds are skipped by the mapping
        sc: i32 = self.left + (x - tr.x + cw / 2) / cw
        if sc < 0:
            sc = 0
        line = l
        col = self.col_from_screen(l, sc)

    static def max_screen_cols(in self: CodeView) -> i32:
        # widest VISIBLE line (the horizontal bar tracks what is on screen,
        # as Godot does — it never scans the whole file)
        vis: i32 = self.visible_lines()
        mx: i32 = 1
        l: i32 = self.top
        for row in range(vis + 1):
            w: i32 = self.screen_col(l, self.buf.line_cp(l))
            if w > mx:
                mx = w
            nl: i32 = self.buf.next_visible(l, 1)
            if nl == l:
                break
            l = nl
        return mx

    static def sync_bars(ref self: CodeView):
        tr: PgRect = self.text_rect()
        cw: i32 = self.ui->font.char_w()
        vis: i32 = self.visible_lines()
        cols: i32 = tr.w / cw
        if cols < 1:
            cols = 1
        # the vertical bar counts VISIBLE lines (a fold shortens the document)
        self.ui->scroll_set(self.vsb, i64(self.buf.visible_count()), i64(vis),
                            i64(self.buf.to_visible(self.top)))
        self.top = self.buf.from_visible(i32(self.ui->scroll_value(self.vsb)))
        mx: i32 = self.max_screen_cols()
        self.ui->scroll_set(self.hsb, i64(mx + 1), i64(cols), i64(self.left))
        self.left = i32(self.ui->scroll_value(self.hsb))
        # the horizontal bar shows up only when needed (Sublime/Godot behavior)
        self.ui->set_visible(self.hsb, mx >= cols)

    # ---------- navigation ----------

    # `line` is a VISIBLE index here: the scrollbar and the wheel think in
    # rows, and a folded document has fewer rows than lines
    def set_top(ref self: CodeView, line: i32):
        v: i32 = line
        mx: i32 = self.buf.visible_count() - 1
        if v > mx:
            v = mx
        if v < 0:
            v = 0
        n: i32 = self.buf.from_visible(v)
        if n != self.top:
            self.top = n
            self.sync_bars()
            self.ui->queue_redraw(self.id)

    def set_left(ref self: CodeView, col: i32):
        n: i32 = col if col > 0 else 0
        if n != self.left:
            self.left = n
            self.sync_bars()
            self.ui->queue_redraw(self.id)

    # a fold changed the visible mapping: keep the viewport where it is. Folding
    # from the GUTTER must not scroll (Godot/Sublime) — the caret can be
    # anywhere, and chasing it jumps the reader out of the block being folded.
    def anchor_top(ref self: CodeView):
        self.top = self.buf.visible_at_or_before(self.top)
        self.changed()

    def scroll_to_caret(ref self: CodeView):
        c: *Caret = self.buf.caret(self.buf.ncarets() - 1)
        vis: i32 = self.visible_lines()
        top: i32 = self.top
        cv: i32 = self.buf.to_visible(c->line)      # in visible rows
        tv: i32 = self.buf.to_visible(top)
        if cv < tv:
            top = c->line
        elif cv >= tv + vis:
            top = self.buf.from_visible(cv - vis + 1)
        tr: PgRect = self.text_rect()
        cw: i32 = self.ui->font.char_w()
        cols: i32 = tr.w / cw
        if cols < 1:
            cols = 1
        sc: i32 = self.screen_col(c->line, c->col)
        left: i32 = self.left
        if sc < left:
            left = sc
        elif sc >= left + cols:
            left = sc - cols + 1
        self.top = top if top >= 0 else 0
        self.left = left if left >= 0 else 0
        self.sync_bars()
        self.ui->queue_redraw(self.id)

    def changed(ref self: CodeView):
        self.hl.update(ref self.buf)
        self.sync_bars()
        self.ui->queue_redraw(self.id)
        if self.on_change != None:
            self.on_change(self.on_change_ctx, &self)

    # ---------- drawing ----------

    static def build(ref self: CodeView):
        ui: *Ui = self.ui
        th: *Theme = &ui->theme
        r: PgRect = ui->rect_of(self.id)
        tr: PgRect = self.text_rect()
        lh: i32 = ui->font.line_h()
        cw: i32 = ui->font.char_w()
        cols: i32 = tr.w / cw + 1
        vis: i32 = self.visible_lines()
        gw: i32 = self.gutter_w()

        ui->cmd_rect(self.id, r, 0xFF1E1F22)                      # background
        if gw > 0:
            ui->cmd_rect(self.id, pg_rect(r.x, r.y, gw, r.h), 0xFF232527)

        self.hl.update(ref self.buf)

        # current line (only with a single caret and no selection, like Sublime)
        if self.buf.ncarets() == 1 and not self.buf.has_sel():
            crow: i32 = self.row_of_line(self.buf.caret(0)->line)
            if crow >= 0 and crow < vis:
                ui->cmd_rect(self.id, pg_rect(tr.x, tr.y + crow * lh, tr.w, lh), 0xFF26282C)

        # selections (before the text: the replay is in order)
        for k in range(self.buf.ncarets()):
            l0: i32; c0: i32; l1: i32; c1: i32
            self.buf.sel_range(k, out l0, out c0, out l1, out c1)
            if l0 == l1 and c0 == c1:
                continue
            for ln in range(l0, l1 + 1):
                srow: i32 = self.row_of_line(ln)
                if srow < 0 or srow >= vis:
                    continue
                s0: i32 = self.screen_col(ln, c0) if ln == l0 else 0
                s1: i32 = self.screen_col(ln, c1) if ln == l1 else self.screen_col(ln, self.buf.line_cp(ln)) + 1
                x0: i32 = tr.x + (s0 - self.left) * cw
                x1: i32 = tr.x + (s1 - self.left) * cw
                if x1 <= tr.x or x0 >= tr.x + tr.w:
                    continue
                ui->cmd_rect(self.id, pg_rect(x0, tr.y + srow * lh, x1 - x0, lh), th->sel)

        # gutters + text, walking VISIBLE rows (folds are skipped)
        buf: char[64]
        ln: i32 = self.top
        for vi in range(vis + 1):
            if vi > 0:
                nl: i32 = self.buf.next_visible(ln, 1)
                if nl == ln:
                    break        # end of the document
                ln = nl
            y: i32 = tr.y + vi * lh
            gx: i32 = r.x
            for gi in range(self.ngutters):
                g: *Gutter = &self.gutters[gi]
                col: u32 = th->text_dim
                buf[0] = '\0'
                if g->draw != None and g->draw(g->ctx, &self, ln, buf, sizeof(buf), &col):
                    # right-aligned inside the gutter column, measured in
                    # CODEPOINTS: a marker like ▾ is one glyph but three bytes
                    tw: i32 = 0
                    for bi in range(strlen(buf)):
                        if (u8(buf[bi]) & 0xC0) != 0x80:
                            tw += 1
                    ui->cmd_text(self.id, gx + (g->width_cp - tw) * cw, y, buf, col)
                gx += g->width_cp * cw
            # indent guides: a 1px rule at every tab stop inside the leading
            # whitespace, so nesting is readable in an indentation language
            ind: i32 = self.buf.indent_of(ln)
            if self.buf.is_blank(ln):
                # a blank line borrows the deeper of its neighbours, so the
                # guides do not break in the middle of a block
                pv: i32 = self.buf.next_visible(ln, -1)
                nx: i32 = self.buf.next_visible(ln, 1)
                a: i32 = self.buf.indent_of(pv) if pv != ln else 0
                bq: i32 = self.buf.indent_of(nx) if nx != ln else 0
                ind = a if a < bq else bq
            gcol: i32 = CV_TAB
            while gcol < ind:
                gx: i32 = tr.x + (gcol - self.left) * cw
                if gx >= tr.x and gx < tr.x + tr.w:
                    ui->cmd_rect(self.id, pg_rect(gx, y, 1, lh), 0xFF31343A)
                gcol += CV_TAB
            s: const *char = self.buf.line_text(ln)
            sc: i32 = 0
            cpi: i32 = 0
            i: usize = 0
            while s[i] != '\0':
                cp: u32 = pg_utf8_step(s, ref i)
                adv: i32 = 1
                if cp == u32('\t'):
                    adv = CV_TAB - (sc % CV_TAB)
                if sc + adv > self.left and sc < self.left + cols and cp != u32('\t'):
                    cls: u8 = self.hl.class_at(ln, cpi)
                    ui->cmd_glyph(self.id, tr.x + (sc - self.left) * cw, y, cp,
                                  hl_colors[cls if cls < 6 else 0])
                sc += adv
                cpi += 1
                if sc > self.left + cols:
                    break
            # a collapsed block shows the Sublime ellipsis right after the header
            if self.buf.is_folded(ln):
                ex: i32 = tr.x + (sc - self.left + 1) * cw
                ui->cmd_rect(self.id, pg_rect(ex - 2, y, cw + 4, lh), 0xFF3A3D41)
                ui->cmd_glyph(self.id, ex, y, CP_ELLIPSIS, th->text_dim)

        # ---- completion popup, anchored under the caret ----
        if self.cmp_open and not self.cmp_hits.is_empty() and self.row_of_line(self.buf.caret(0)->line) >= 0:
            pr: PgRect = self.cmp_rect()
            rows2: i32 = self.cmp_rows()
            ui->cmd_rect(self.id, pr, 0xFF2B2D30)
            ui->cmd_frame(self.id, pr, th->accent)
            inner: i32 = pr.w - 2 * CMP_PAD
            for hi in range(rows2):
                idx2: i32 = self.cmp_top + hi
                if idx2 >= self.cmp_hits.len:
                    break
                sm2: *CSym = self.index.sym(self.cmp_hits.data[idx2])
                ry: i32 = pr.y + CMP_PAD + hi * lh
                if idx2 == self.cmp_sel:
                    ui->cmd_rect(self.id, pg_rect(pr.x + 1, ry, pr.w - 2, lh), th->sel)
                # the NAME is what gets picked, so it keeps whatever it needs;
                # the signature takes the leftover and steps aside when there
                # is not enough of it left to say anything
                nw: i32 = ui->cmd_text_fit(self.id, pr.x + CMP_PAD, ry, sm2->name, inner,
                                           th->text if idx2 == self.cmp_sel else th->text_dim)
                if sm2->detail != None:
                    dw: i32 = inner - nw - 2 * cw
                    if dw >= CMP_MIN_DETAIL * cw:
                        ui->cmd_text_fit(self.id, pr.x + CMP_PAD + nw + 2 * cw, ry,
                                         sm2->detail, dw, 0xFF6E7075)

        # ---- minimap: a run of same-class characters becomes one rect ----
        if self.minimap:
            mr: PgRect = self.minimap_rect()
            ui->cmd_rect(self.id, mr, 0xFF1A1B1E)
            rows: i32 = mr.h / MM_ROW
            total: i32 = self.buf.visible_count()
            # scroll the strip so the viewport marker tracks the document
            first: i32 = 0
            if total > rows:
                topv: i32 = self.buf.to_visible(self.top)
                span: i32 = total - rows
                room: i32 = total - vis
                first = topv * span / (room if room > 0 else 1)
                if first > span:
                    first = span
            mln: i32 = self.buf.from_visible(first)
            for mrow in range(rows):
                if mrow > 0:
                    nl2: i32 = self.buf.next_visible(mln, 1)
                    if nl2 == mln:
                        break
                    mln = nl2
                my: i32 = mr.y + mrow * MM_ROW
                ms: const *char = self.buf.line_text(mln)
                mc: i32 = 0
                mi: usize = 0
                runc: u8 = 0
                runs: i32 = -1
                while ms[mi] != '\0' and mc < mr.w:
                    cpm: u32 = pg_utf8_step(ms, ref mi)
                    clsm: u8 = self.hl.class_at(mln, mc)
                    blank: bool = cpm == u32(' ') or cpm == u32('\t')
                    if blank or clsm != runc:
                        if runs >= 0:
                            ui->cmd_rect(self.id, pg_rect(mr.x + runs, my, mc - runs, MM_ROW - 1),
                                         mm_tint(runc))
                            runs = -1
                        if not blank:
                            runc = clsm
                            runs = mc
                    mc += CV_TAB - (mc % CV_TAB) if cpm == u32('\t') else 1
                if runs >= 0 and runs < mr.w:
                    e2: i32 = mc if mc < mr.w else mr.w
                    ui->cmd_rect(self.id, pg_rect(mr.x + runs, my, e2 - runs, MM_ROW - 1),
                                 mm_tint(runc))
            # the viewport window over the strip
            vy: i32 = mr.y + (self.buf.to_visible(self.top) - first) * MM_ROW
            ui->cmd_rect(self.id, pg_rect(mr.x, vy, mr.w, vis * MM_ROW), 0x18FFFFFF)
            ui->cmd_frame(self.id, pg_rect(mr.x, vy, mr.w, vis * MM_ROW), 0xFF3A3D41)

        # carets (on top of everything)
        if self.caret_on and ui->focus_get() == self.id:
            for k in range(self.buf.ncarets()):
                c: *Caret = self.buf.caret(k)
                krow: i32 = self.row_of_line(c->line)
                if krow < 0 or krow >= vis:
                    continue
                cx: i32 = tr.x + (self.screen_col(c->line, c->col) - self.left) * cw
                if cx < tr.x - 1 or cx > tr.x + tr.w:
                    continue
                ui->cmd_rect(self.id, pg_rect(cx, tr.y + krow * lh, 2, lh), 0xFFE8E8E8)

    # centres the view on the line the minimap pixel `y` stands for
    static def minimap_jump(ref self: CodeView, y: i32):
        mr: PgRect = self.minimap_rect()
        vis: i32 = self.visible_lines()
        rows: i32 = mr.h / MM_ROW
        total: i32 = self.buf.visible_count()
        first: i32 = 0
        if total > rows:
            topv: i32 = self.buf.to_visible(self.top)
            span: i32 = total - rows
            room: i32 = total - vis
            first = topv * span / (room if room > 0 else 1)
            if first > span:
                first = span
        v: i32 = first + (y - mr.y) / MM_ROW - vis / 2
        self.set_top(v)

    # ---------- clipboard ----------

    def copy(ref self: CodeView) -> bool:
        if not self.buf.has_sel():
            return False
        n: i32 = self.buf.ncarets()
        parts: **char = malloc(usize(n) * sizeof(*parts))
        total: usize = 0
        for k in range(n):
            t: *char = self.buf.sel_text(k)
            if t == None:
                t = malloc(1)
                t[0] = '\0'
            parts[k] = t
            total += strlen(t) + 1
        joined: *char = malloc(total + 1)
        p: usize = 0
        for k in range(n):
            l: usize = strlen(parts[k])
            memcpy(joined + p, parts[k], l)
            p += l
            if k + 1 < n:
                joined[p] = '\n'
                p += 1
        joined[p] = '\0'
        pgfx_clipboard_set(joined)
        free(joined)
        clip_set(parts, n)
        return True

    def cut(ref self: CodeView, now_ms: i64) -> bool:
        if not self.copy():
            return False
        self.buf.delete_sel(now_ms)
        self.changed()
        self.scroll_to_caret()
        return True

    def paste(ref self: CodeView, now_ms: i64):
        sys: *char = pgfx_clipboard_get()
        # N pieces for N carets (Sublime): only while the system clipboard
        # still matches what we copied (otherwise outside text wins)
        if clip_n == self.buf.ncarets() and clip_n > 1:
            self.buf.insert_each(clip_parts, clip_n, now_ms)
        elif sys != None:
            self.buf.insert(sys, now_ms)
        elif clip_n == 1:
            self.buf.insert(clip_parts[0], now_ms)
        free(sys)
        self.changed()
        self.scroll_to_caret()

    # ---------- indentation ----------

    static def sel_lines_range(ref self: CodeView, out l0: i32, out l1: i32) -> bool:
        l0 = 0; l1 = -1
        multi: bool = False
        for k in range(self.buf.ncarets()):
            a: i32; b: i32; c: i32; d: i32
            self.buf.sel_range(k, out a, out b, out c, out d)
            if a != c:
                multi = True
            if l1 < 0 or a < l0:
                l0 = a
            if c > l1:
                l1 = c
        return multi

    def indent(ref self: CodeView, now_ms: i64):
        l0: i32; l1: i32
        if self.sel_lines_range(out l0, out l1):
            # block: 4 spaces on each line (bottom-up, so the positions not
            # yet processed stay valid)
            for ln in range(l1, l0 - 1, -1):
                self.buf.replace_range(ln, 0, ln, 0, "    ", now_ms)
            self.buf.select_range(l0, 0, l1, self.buf.line_cp(l1))
        else:
            c: *Caret = self.buf.caret(0)
            sc: i32 = self.screen_col(c->line, c->col)
            pad: i32 = CV_TAB - (sc % CV_TAB)
            sp: char[8]
            for i in range(pad):
                sp[i] = ' '
            sp[pad] = '\0'
            self.buf.insert(sp, now_ms)
        self.changed()
        self.scroll_to_caret()

    def unindent(ref self: CodeView, now_ms: i64):
        l0: i32; l1: i32
        self.sel_lines_range(out l0, out l1)
        if l1 < l0:
            l1 = l0
        for ln in range(l1, l0 - 1, -1):
            s: const *char = self.buf.line_text(ln)
            k: i32 = 0
            while k < CV_TAB and s[k] == ' ':
                k += 1
            if k == 0 and s[0] == '\t':
                k = 1
            if k > 0:
                self.buf.replace_range(ln, 0, ln, k, "", now_ms)
        self.changed()
        self.scroll_to_caret()

    def newline(ref self: CodeView, now_ms: i64):
        # auto-indent: repeat the line's indent, and go deeper after a ':'
        c: *Caret = self.buf.caret(self.buf.ncarets() - 1)
        s: const *char = self.buf.line_text(c->line)
        ind: i32 = 0
        while s[ind] == ' ':
            ind += 1
        cb: i32 = self.buf.col_byte(c->line, c->col)
        deeper: bool = False
        j: i32 = cb - 1
        while j >= 0 and s[j] == ' ':
            j -= 1
        if j >= 0 and s[j] == ':':
            deeper = True
        if ind > cb:
            ind = cb          # caret inside the indent: do not duplicate it
        total: i32 = ind + (CV_TAB if deeper else 0)
        txt: *char = malloc(usize(total) + 2)
        txt[0] = '\n'
        for i in range(total):
            txt[1 + i] = ' '
        txt[1 + total] = '\0'
        self.buf.insert(txt, now_ms)
        free(txt)
        self.changed()
        self.scroll_to_caret()

    # ---------- auto-pairs ----------

    # the codepoint right after the caret (0 at end of line)
    static def char_after(in self: CodeView, c: *Caret) -> char:
        s: const *char = self.buf.line_text(c->line)
        b: i32 = self.buf.col_byte(c->line, c->col)
        return s[b]

    static def char_before(in self: CodeView, c: *Caret) -> char:
        if c->col == 0:
            return '\0'
        s: const *char = self.buf.line_text(c->line)
        return s[self.buf.col_byte(c->line, c->col - 1)]

    # True when the typed text was handled as a pair operation
    static def auto_pair(ref self: CodeView, text: const *char, now_ms: i64) -> bool:
        if text[0] == '\0' or text[1] != '\0':
            return False          # only single characters
        ch: char = text[0]
        close: char = pair_close_of(ch)
        c: *Caret = self.buf.caret(0)
        # typing the closing character where it already is: step over it
        if pair_is_close(ch) and self.buf.ncarets() == 1 and not self.buf.has_sel():
            if self.char_after(c) == ch:
                self.buf.move_h(1, False)
                return True
        if close == '\0':
            return False
        # wrap the selection instead of replacing it
        if self.buf.has_sel():
            wrapped: bool = False
            for k in range(self.buf.ncarets() - 1, -1, -1):
                l0: i32; c0: i32; l1: i32; c1: i32
                self.buf.sel_range(k, out l0, out c0, out l1, out c1)
                if l0 == l1 and c0 == c1:
                    continue
                body: *char = self.buf.sel_text(k)
                nw: *char = malloc(strlen(body) + 3)
                nw[0] = ch
                strcpy(nw + 1, body)
                nw[strlen(body) + 1] = close
                nw[strlen(body) + 2] = '\0'
                free(body)
                self.buf.select_range(l0, c0, l1, c1)
                self.buf.replace_range(l0, c0, l1, c1, nw, now_ms)
                free(nw)
                wrapped = True
            return wrapped
        # a quote right after a word is an apostrophe, not a pair
        if (ch == '"' or ch == '\'') and is_word_ch_cv(self.char_before(c)):
            return False
        after: char = self.char_after(c)
        if after != '\0' and not pair_is_close(after) and after != ' ' and after != '\t':
            return False          # only pair when the caret is at a boundary
        both: char[3]
        both[0] = ch
        both[1] = close
        both[2] = '\0'
        self.buf.insert(both, now_ms)
        self.buf.move_h(-1, False)
        return True

    # backspace between an empty pair removes both sides
    static def pair_backspace(ref self: CodeView, now_ms: i64) -> bool:
        if self.buf.ncarets() != 1 or self.buf.has_sel():
            return False
        c: *Caret = self.buf.caret(0)
        b: char = self.char_before(c)
        a: char = self.char_after(c)
        cl: char = pair_close_of(b)
        # `b` must be an OPENER whose closer sits right after the caret; with
        # both sides absent the two '\0' would compare equal and eat a newline
        if cl == '\0' or cl != a:
            return False
        self.buf.delete_fwd(now_ms)
        self.buf.backspace(now_ms)
        return True

    # ---------- completion ----------

    # the word being typed right before the caret (identifier characters)
    static def word_before(in self: CodeView, out start_col: i32) -> *char:
        c: *Caret = self.buf.caret(0)
        s: const *char = self.buf.line_text(c->line)
        e: i32 = self.buf.col_byte(c->line, c->col)
        b: i32 = e
        while b > 0 and is_word_ch_cv(s[b - 1]):
            b -= 1
        start_col = byte_to_col_cv(s, b)
        r: *char = malloc(usize(e - b) + 1)
        memcpy(r, s + b, usize(e - b))
        r[e - b] = '\0'
        return r

    # the expression whose members to list: what sits before a trailing `.`
    # or `->`, when there is one. None otherwise.
    static def owner_before(in self: CodeView, word_start: i32) -> *char:
        c: *Caret = self.buf.caret(0)
        s: const *char = self.buf.line_text(c->line)
        b: i32 = self.buf.col_byte(c->line, word_start)
        if b >= 1 and s[b - 1] == '.':
            b -= 1
        elif b >= 2 and s[b - 2] == '-' and s[b - 1] == '>':
            b -= 2
        else:
            return None
        e: i32 = b
        while b > 0 and is_word_ch_cv(s[b - 1]):
            b -= 1
        if b == e:
            return None
        r: *char = malloc(usize(e - b) + 1)
        memcpy(r, s + b, usize(e - b))
        r[e - b] = '\0'
        return r

    # How many candidates the popup shows. Both the drawing and the arrow keys
    # ask HERE — they used to each carry their own `8`, so a popup shortened by
    # a low pane scrolled against rows that were not on screen.
    def cmp_rows(in self: CodeView) -> i32:
        n: i32 = self.cmp_hits.len
        if n > CMP_MAX_ROWS:
            n = CMP_MAX_ROWS
        fits: i32 = self.text_rect().h / self.ui->font.line_h() - 1
        if n > fits:
            n = fits
        return n if n > 1 else 1

    # The popup box: as wide as the candidates on show need, then clamped to the
    # text area. Every overflow is decided here, once — the rows that follow
    # only have to keep their text inside `w`.
    def cmp_rect(in self: CodeView) -> PgRect:
        tr: PgRect = self.text_rect()
        cw: i32 = self.ui->font.char_w()
        lh: i32 = self.ui->font.line_h()
        rows: i32 = self.cmp_rows()
        w: i32 = CMP_MIN_COLS * cw
        for hi in range(rows):
            i: i32 = self.cmp_top + hi
            if i >= self.cmp_hits.len:
                break
            sm: *CSym = self.index.sym(self.cmp_hits.data[i])
            # measured in CODEPOINTS (what the font draws), never in bytes
            cand: i32 = self.ui->font.text_width(sm->name)
            if sm->detail != None:
                cand += 2 * cw + self.ui->font.text_width(sm->detail)
            if cand > w:
                w = cand
        w += 2 * CMP_PAD
        if w > CMP_MAX_COLS * cw:
            w = CMP_MAX_COLS * cw
        if w > tr.w - cw:                  # a narrow pane wins over any minimum
            w = tr.w - cw
        h: i32 = rows * lh + 2 * CMP_PAD
        if h > tr.h:                       # a pane shorter than one row + margin
            h = tr.h
        x: i32 = tr.x + (self.screen_col(self.buf.caret(0)->line, self.cmp_col) - self.left) * cw
        if x + w > tr.x + tr.w:
            x = tr.x + tr.w - w
        if x < tr.x:
            x = tr.x
        row: i32 = self.row_of_line(self.buf.caret(0)->line)
        y: i32 = tr.y + (row + 1) * lh
        if y + h > tr.y + tr.h:
            y = tr.y + row * lh - h        # flip above the caret
        # neither side fits — a low pane, or a caret the view has scrolled away
        # from. Keep the box in the area: covering the text beats hanging off it.
        if y + h > tr.y + tr.h:
            y = tr.y + tr.h - h
        if y < tr.y:
            y = tr.y
        return pg_rect(x, y, w, h)

    def complete_close(ref self: CodeView):
        if not self.cmp_open:
            return
        self.cmp_open = False
        free(self.cmp_owner)
        self.cmp_owner = None
        self.ui->queue_redraw(self.id)

    def complete_open(ref self: CodeView):
        if self.index.is_stale(ref self.buf):
            self.index.build(ref self.buf, self.path)
        self.cmp_open = True
        self.cmp_sel = 0
        self.cmp_top = 0
        self.complete_refresh()

    # the struct whose body contains `line`, by indentation — this is how
    # `self.` resolves without guessing (a file-wide index could not)
    static def enclosing_struct(in self: CodeView, line: i32) -> *char:
        for l in range(line, -1, -1):
            s: const *char = self.buf.line_text(l)
            if strncmp(s, "struct ", 7) != 0:
                continue
            b: i32 = 7
            while s[b] == ' ':
                b += 1
            e: i32 = b
            while is_word_ch_cv(s[e]):
                e += 1
            if e == b:
                return None
            r: *char = malloc(usize(e - b) + 1)
            memcpy(r, s + b, usize(e - b))
            r[e - b] = '\0'
            return r
        return None

    def complete_refresh(ref self: CodeView):
        if not self.cmp_open:
            return
        start: i32
        w: *char = self.word_before(out start)
        free(self.cmp_owner)
        self.cmp_owner = self.owner_before(start)
        self.cmp_col = start
        owner: const *char = None
        encl: *char = None
        if self.cmp_owner != None:
            if strcmp(self.cmp_owner, "self") == 0:
                encl = self.enclosing_struct(self.buf.caret(0)->line)
                owner = encl
            else:
                owner = self.index.owner_of(self.cmp_owner)
            if owner == None:
                # unknown receiver: nothing honest to offer
                free(w)
                self.complete_close()
                return
        self.index.query(w, owner, ref self.cmp_hits)
        free(w)
        free(encl)
        if self.cmp_hits.is_empty():
            self.complete_close()
            return
        if self.cmp_sel >= self.cmp_hits.len:
            self.cmp_sel = self.cmp_hits.len - 1
        self.ui->queue_redraw(self.id)

    def complete_accept(ref self: CodeView, now_ms: i64) -> bool:
        if not self.cmp_open or self.cmp_hits.is_empty():
            return False
        s: *CSym = self.index.sym(self.cmp_hits.data[self.cmp_sel])
        name: *char = malloc(strlen(s->name) + 1)
        strcpy(name, s->name)
        c: *Caret = self.buf.caret(0)
        self.buf.replace_range(c->line, self.cmp_col, c->line, c->col, name, now_ms)
        free(name)
        self.complete_close()
        self.changed()
        self.scroll_to_caret()
        return True

    # ---------- folding / line commands ----------

    def toggle_fold_at_caret(ref self: CodeView):
        c: *Caret = self.buf.caret(0)
        l: i32 = c->line
        if not self.buf.can_fold(l) and not self.buf.is_folded(l):
            # not a header: fold the block that CONTAINS the caret (Sublime)
            for h in range(l - 1, -1, -1):
                if self.buf.can_fold(h) and self.buf.fold_end(h) >= l:
                    l = h
                    break
        if self.buf.toggle_fold(l):
            self.changed()
            self.scroll_to_caret()

    # fold/unfold ALL is a view operation, not a navigation one: it keeps the
    # reader where they are (the caret may be anywhere). Folding away the block
    # the viewport starts on leaves its header as the first row.
    def fold_all(ref self: CodeView):
        self.buf.fold_all()
        self.anchor_top()

    def unfold_all(ref self: CodeView):
        self.buf.unfold_all()
        self.anchor_top()

    def toggle_bookmark(ref self: CodeView):
        self.buf.toggle_mark(self.buf.caret(0)->line, MARK_BOOKMARK)
        self.ui->queue_redraw(self.id)

    def goto_mark(ref self: CodeView, forward: bool):
        l: i32 = self.buf.next_mark(self.buf.caret(0)->line, MARK_BOOKMARK, forward)
        if l < 0:
            return
        self.buf.move_to(l, 0)
        self.scroll_to_caret()
        self.ui->queue_redraw(self.id)

    def toggle_comment(ref self: CodeView, now_ms: i64):
        self.buf.toggle_comment("#", now_ms)
        self.changed()
        self.scroll_to_caret()

    def move_lines(ref self: CodeView, dir: i32, now_ms: i64):
        self.buf.move_lines(dir, now_ms)
        self.changed()
        self.scroll_to_caret()

    def duplicate_lines(ref self: CodeView, now_ms: i64):
        self.buf.duplicate_lines(now_ms)
        self.changed()
        self.scroll_to_caret()

    def delete_lines(ref self: CodeView, now_ms: i64):
        self.buf.delete_lines(now_ms)
        self.changed()
        self.scroll_to_caret()

    def join_lines(ref self: CodeView, now_ms: i64):
        self.buf.join_lines(now_ms)
        self.changed()
        self.scroll_to_caret()

    # ---------- search ----------

    def search(ref self: CodeView, needle: const *char, forward: bool, re: bool, from_caret: bool) -> bool:
        if needle == None or needle[0] == '\0':
            return False
        c: *Caret = self.buf.caret(0)
        sl: i32 = c->line
        sc: i32 = c->col
        if not from_caret:
            sl = 0
            sc = 0
        elif forward:
            # start AFTER the current selection (else it finds itself again)
            a: i32; b: i32; d: i32; e: i32
            self.buf.sel_range(0, out a, out b, out d, out e)
            sl = d
            sc = e
        fl: i32; fc0: i32; fc1: i32
        if re:
            if not self.buf.find_re(needle, sl, sc, forward, out fl, out fc0, out fc1):
                return False
        else:
            if not self.buf.find(needle, sl, sc, forward, out fl, out fc0):
                return False
            fc1 = fc0
            n: i32 = 0
            for i in range(strlen(needle)):
                if (u8(needle[i]) & 0xC0) != 0x80:
                    n += 1
            fc1 = fc0 + n
        self.buf.select_range(fl, fc0, fl, fc1)
        self.scroll_to_caret()
        self.ui->queue_redraw(self.id)
        return True

    # ---------- input ----------

    static def handle_input(ref self: CodeView, ev: *PgEvent) -> bool:
        ui: *Ui = self.ui
        now: i64 = ps_millis()
        match ev->kind:
            case PGE_MOUSE_DOWN:
                if ev->button != 1:
                    return False
                ui->focus_set(self.id)
                l: i32; c: i32
                self.pos_from_xy(ev->x, ev->y, out l, out c)
                # the minimap: click or drag jumps the view (Godot's TextEdit)
                mmr: PgRect = self.minimap_rect()
                if self.minimap and mmr.contains(ev->x, ev->y):
                    self.minimap_drag = True
                    self.minimap_jump(ev->y)
                    return True
                # a click inside the gutters belongs to the gutter that owns
                # that column (folding today, breakpoints tomorrow)
                r0: PgRect = ui->rect_of(self.id)
                if ev->x < r0.x + self.gutter_w():
                    gx: i32 = r0.x
                    cwg: i32 = ui->font.char_w()
                    for gi in range(self.ngutters):
                        gw: i32 = self.gutters[gi].width_cp * cwg
                        if ev->x >= gx and ev->x < gx + gw and self.gutters[gi].click != None:
                            if self.gutters[gi].click(self.gutters[gi].ctx, &self, l):
                                return True
                        gx += gw
                    return True
                if ev->clicks >= 3:
                    self.buf.select_range(l, 0, l, self.buf.line_cp(l))
                elif ev->clicks == 2:
                    self.buf.move_to(l, c)
                    self.buf.select_word_at(0)
                elif (ev->mods & PGM_ALT) != 0:
                    self.buf.add_caret(l, c)     # extra caret (alt+click)
                elif (ev->mods & PGM_SHIFT) != 0:
                    cr: *Caret = self.buf.caret(0)
                    self.buf.select_range(cr->aline, cr->acol, l, c)
                else:
                    self.buf.move_to(l, c)
                    self.mouse_sel = True
                self.caret_on = True
                ui->queue_redraw(self.id)
                return True
            case PGE_MOUSE_MOVE:
                if self.minimap_drag:
                    self.minimap_jump(ev->y)
                    return True
                if not self.mouse_sel:
                    return False
                l2: i32; c2: i32
                self.pos_from_xy(ev->x, ev->y, out l2, out c2)
                cr2: *Caret = self.buf.caret(0)
                self.buf.select_range(cr2->aline, cr2->acol, l2, c2)
                # dragging outside the area scrolls it
                tr: PgRect = self.text_rect()
                if ev->y < tr.y:
                    self.set_top(self.top - 1)
                elif ev->y > tr.y + tr.h:
                    self.set_top(self.top + 1)
                ui->queue_redraw(self.id)
                return True
            case PGE_MOUSE_UP:
                self.mouse_sel = False
                self.minimap_drag = False
                return True
            case PGE_WHEEL:
                if (ev->mods & PGM_CTRL) != 0:
                    return False   # ctrl+wheel = zoom (the app handles it)
                self.set_top(self.top - ev->wheel_y * 3)
                return True
            case PGE_TEXT:
                if self.cmp_open:
                    # a word character keeps filtering; anything else closes
                    if not is_word_ch_cv(ev->text[0]):
                        self.complete_close()
                self.caret_on = True
                if self.auto_pair(ev->text, now):
                    self.caret_on = True
                    self.changed()
                    self.scroll_to_caret()
                    return True
                self.buf.insert(ev->text, now)
                self.changed()
                self.scroll_to_caret()
                # `.`/`->` offers members; while open, keep the list in sync
                if self.cmp_open:
                    self.complete_refresh()
                elif ev->text[0] == '.' or ev->text[0] == '>':
                    self.complete_open()
                return True
            case PGE_KEY:
                sel: bool = (ev->mods & PGM_SHIFT) != 0
                ctrl: bool = (ev->mods & PGM_CTRL) != 0
                self.caret_on = True
                # ctrl+space asks for candidates; while the popup is up it owns
                # the arrows, enter/tab and escape
                if ctrl and ev->key == PGK_SPACE:
                    self.complete_open()
                    return True
                if self.cmp_open:
                    if ev->key == PGK_ESCAPE:
                        self.complete_close()
                        return True
                    if ev->key in {PGK_RETURN, PGK_TAB}:
                        if self.complete_accept(now):
                            return True
                    if ev->key in {PGK_UP, PGK_DOWN}:
                        n2: i32 = self.cmp_hits.len
                        self.cmp_sel += 1 if ev->key == PGK_DOWN else -1
                        if self.cmp_sel < 0:
                            self.cmp_sel = n2 - 1
                        if self.cmp_sel >= n2:
                            self.cmp_sel = 0
                        rows3: i32 = self.cmp_rows()      # what is actually on screen
                        if self.cmp_sel < self.cmp_top:
                            self.cmp_top = self.cmp_sel
                        elif self.cmp_sel >= self.cmp_top + rows3:
                            self.cmp_top = self.cmp_sel - rows3 + 1
                        ui->queue_redraw(self.id)
                        return True
                    if ev->key not in {PGK_BACKSPACE, PGK_LEFT, PGK_RIGHT}:
                        self.complete_close()
                if ev->key == PGK_LEFT:
                    if ctrl:
                        self.buf.move_word(-1, sel)
                    else:
                        self.buf.move_h(-1, sel)
                elif ev->key == PGK_RIGHT:
                    if ctrl:
                        self.buf.move_word(1, sel)
                    else:
                        self.buf.move_h(1, sel)
                elif ev->key == PGK_UP:
                    self.buf.move_v(-1, sel)
                elif ev->key == PGK_DOWN:
                    self.buf.move_v(1, sel)
                elif ev->key == PGK_PAGEUP:
                    self.buf.move_v(-self.visible_lines(), sel)
                elif ev->key == PGK_PAGEDOWN:
                    self.buf.move_v(self.visible_lines(), sel)
                elif ev->key == PGK_HOME:
                    if ctrl:
                        self.buf.move_to(0, 0)
                    else:
                        self.buf.home(sel)
                elif ev->key == PGK_END:
                    if ctrl:
                        self.buf.move_to(self.buf.nlines() - 1, self.buf.line_cp(self.buf.nlines() - 1))
                    else:
                        self.buf.end(sel)
                elif ev->key == PGK_BACKSPACE:
                    if not self.pair_backspace(now):
                        self.buf.backspace(now)
                    self.changed()
                    if self.cmp_open:
                        self.complete_refresh()
                elif ev->key == PGK_DELETE:
                    self.buf.delete_fwd(now)
                    self.changed()
                elif ev->key == PGK_RETURN:
                    self.newline(now)
                elif ev->key == PGK_TAB:
                    if sel:
                        self.unindent(now)
                    else:
                        self.indent(now)
                elif ev->key == PGK_ESCAPE:
                    self.buf.collapse()
                else:
                    return False
                self.scroll_to_caret()
                ui->queue_redraw(self.id)
                return True
            case _:
                pass
        return False

# ---------- pui callbacks ----------
static def cv_min(ui: *Ui, id: i32, out_w: *i32, out_h: *i32):
    cv: *CodeView = ui->data_of(id)
    *out_w = cv->gutter_w() + ui->font.char_w() * 8
    *out_h = ui->font.line_h() * 3

static def cv_layout(ui: *Ui, id: i32, r: PgRect):
    cv: *CodeView = ui->data_of(id)
    hs: i32 = ui->theme.handle + 2
    # internal scrollbars (Godot's TextEdit layout): the vertical one takes
    # the full right edge; the horizontal one the bottom minus that width
    ui->set_rect(cv->vsb, pg_rect(r.x + r.w - hs, r.y, hs, r.h - hs))
    ui->set_rect(cv->hsb, pg_rect(r.x + cv->gutter_w(), r.y + r.h - hs,
                                  r.w - hs - cv->gutter_w(), hs))
    cv->sync_bars()

static def cv_build(ui: *Ui, id: i32):
    cv: *CodeView = ui->data_of(id)
    cv->build()

static def cv_input(ui: *Ui, id: i32, ev: *PgEvent) -> bool:
    cv: *CodeView = ui->data_of(id)
    return cv->handle_input(ev)

static def cv_free(ui: *Ui, id: i32):
    cv: *CodeView = ui->data_of(id)
    cv->buf.deinit()
    cv->hl.deinit()
    cv->index.deinit()
    cv->cmp_hits.deinit()
    free(cv->cmp_owner)
    free(cv->path)
    free(cv)

static def vsb_changed(ctx: *void, id: i32, arg: i64):
    cv: *CodeView = ctx
    cv->top = i32(arg)
    cv->ui->queue_redraw(cv->id)

static def hsb_changed(ctx: *void, id: i32, arg: i64):
    cv: *CodeView = ctx
    cv->left = i32(arg)
    cv->ui->queue_redraw(cv->id)

def cv_create(ref ui: Ui, parent: i32) -> i32:
    cv: *CodeView = malloc(sizeof(CodeView))
    memset(cv, 0, sizeof(CodeView))
    cv->buf.init()
    cv->hl.init(True)
    cv->caret_on = True
    cv->minimap = True
    cv->index.init()
    cv->cmp_hits.init()
    id: i32 = ui.custom(parent, cv, cv_min, cv_build, cv_input, cv_layout, cv_free)
    ui.set_focusable(id, True)
    ui.set_expand(id, True, True)
    cv->ui = &ui
    cv->id = id
    cv->vsb = ui.scrollbar(id, True)
    cv->hsb = ui.scrollbar(id, False)
    ui.on_scroll(cv->vsb, vsb_changed, cv)
    ui.on_scroll(cv->hsb, hsb_changed, cv)
    cv->marks_gutter()         # ● / ◆ on the far left
    cv->fold_gutter()          # then ▾/▸, then the numbers (Sublime's order)
    cv->line_numbers_gutter()
    return id

def cv_of(ref ui: Ui, id: i32) -> *CodeView:
    return ui.data_of(id)
