# codeview.p — the editing widget's implementation (see codeview.ph)
include <stdio.h>
include <stdlib.h>
include <string.h>
import "codeview.ph"
import "psys.ph"

CV_TAB: const i32 = 4       # soft tabs (DESIGN.md)

# colors per highlight class (dark theme; the index is HL_*)
hl_colors: const u32[6] = {
    0xFFD4D4D4,   # HL_TEXT
    0xFFC586C0,   # HL_KW      (purple)
    0xFFCE9178,   # HL_STR     (orange)
    0xFFB5CEA8,   # HL_NUM     (light green)
    0xFF6A9955,   # HL_COMMENT (green)
    0xFFD4D4D4}   # HL_PUNCT

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

    def text_rect(in self: CodeView) -> PgRect:
        r: PgRect = self.ui->rect_of(self.id)
        hs: i32 = self.ui->theme.handle + 2
        g: i32 = self.gutter_w()
        return pg_rect(r.x + g, r.y, r.w - g - hs, r.h - hs)

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

    def pos_from_xy(in self: CodeView, x: i32, y: i32, out line: i32, out col: i32):
        tr: PgRect = self.text_rect()
        lh: i32 = self.ui->font.line_h()
        cw: i32 = self.ui->font.char_w()
        l: i32 = self.top + (y - tr.y) / lh
        if y < tr.y:
            l = self.top - 1
        if l < 0:
            l = 0
        if l >= self.buf.nlines():
            l = self.buf.nlines() - 1
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
        for i in range(self.top, self.top + vis + 1):
            if i >= self.buf.nlines():
                break
            w: i32 = self.screen_col(i, self.buf.line_cp(i))
            if w > mx:
                mx = w
        return mx

    static def sync_bars(ref self: CodeView):
        tr: PgRect = self.text_rect()
        cw: i32 = self.ui->font.char_w()
        vis: i32 = self.visible_lines()
        cols: i32 = tr.w / cw
        if cols < 1:
            cols = 1
        self.ui->scroll_set(self.vsb, i64(self.buf.nlines()), i64(vis), i64(self.top))
        self.top = i32(self.ui->scroll_value(self.vsb))
        mx: i32 = self.max_screen_cols()
        self.ui->scroll_set(self.hsb, i64(mx + 1), i64(cols), i64(self.left))
        self.left = i32(self.ui->scroll_value(self.hsb))
        # the horizontal bar shows up only when needed (Sublime/Godot behavior)
        self.ui->set_visible(self.hsb, mx >= cols)

    # ---------- navigation ----------

    def set_top(ref self: CodeView, line: i32):
        n: i32 = line
        mx: i32 = self.buf.nlines() - 1
        if n > mx:
            n = mx
        if n < 0:
            n = 0
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

    def scroll_to_caret(ref self: CodeView):
        c: *Caret = self.buf.caret(self.buf.ncarets() - 1)
        vis: i32 = self.visible_lines()
        top: i32 = self.top
        if c->line < top:
            top = c->line
        elif c->line >= top + vis:
            top = c->line - vis + 1
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
            cl: i32 = self.buf.caret(0)->line
            if cl >= self.top and cl < self.top + vis:
                ui->cmd_rect(self.id, pg_rect(tr.x, tr.y + (cl - self.top) * lh, tr.w, lh),
                             0xFF26282C)

        # selections (before the text: the replay is in order)
        for k in range(self.buf.ncarets()):
            l0: i32; c0: i32; l1: i32; c1: i32
            self.buf.sel_range(k, out l0, out c0, out l1, out c1)
            if l0 == l1 and c0 == c1:
                continue
            for ln in range(l0, l1 + 1):
                if ln < self.top or ln >= self.top + vis:
                    continue
                s0: i32 = self.screen_col(ln, c0) if ln == l0 else 0
                s1: i32 = self.screen_col(ln, c1) if ln == l1 else self.screen_col(ln, self.buf.line_cp(ln)) + 1
                x0: i32 = tr.x + (s0 - self.left) * cw
                x1: i32 = tr.x + (s1 - self.left) * cw
                if x1 <= tr.x or x0 >= tr.x + tr.w:
                    continue
                ui->cmd_rect(self.id, pg_rect(x0, tr.y + (ln - self.top) * lh, x1 - x0, lh), th->sel)

        # gutters + text
        buf: char[64]
        for vi in range(vis + 1):
            ln: i32 = self.top + vi
            if ln >= self.buf.nlines():
                break
            y: i32 = tr.y + vi * lh
            gx: i32 = r.x
            for gi in range(self.ngutters):
                g: *Gutter = &self.gutters[gi]
                col: u32 = th->text_dim
                buf[0] = '\0'
                if g->draw != None and g->draw(g->ctx, &self, ln, buf, sizeof(buf), &col):
                    # numbers right-aligned inside the gutter column
                    tw: i32 = i32(strlen(buf))
                    ui->cmd_text(self.id, gx + (g->width_cp - tw) * cw, y, buf, col)
                gx += g->width_cp * cw
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

        # carets (on top of everything)
        if self.caret_on and ui->focus_get() == self.id:
            for k in range(self.buf.ncarets()):
                c: *Caret = self.buf.caret(k)
                if c->line < self.top or c->line >= self.top + vis:
                    continue
                cx: i32 = tr.x + (self.screen_col(c->line, c->col) - self.left) * cw
                if cx < tr.x - 1 or cx > tr.x + tr.w:
                    continue
                ui->cmd_rect(self.id, pg_rect(cx, tr.y + (c->line - self.top) * lh, 2, lh),
                             0xFFE8E8E8)

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
                return True
            case PGE_WHEEL:
                if (ev->mods & PGM_CTRL) != 0:
                    return False   # ctrl+wheel = zoom (the app handles it)
                self.set_top(self.top - ev->wheel_y * 3)
                return True
            case PGE_TEXT:
                self.buf.insert(ev->text, now)
                self.caret_on = True
                self.changed()
                self.scroll_to_caret()
                return True
            case PGE_KEY:
                sel: bool = (ev->mods & PGM_SHIFT) != 0
                ctrl: bool = (ev->mods & PGM_CTRL) != 0
                self.caret_on = True
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
                    self.buf.backspace(now)
                    self.changed()
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
    id: i32 = ui.custom(parent, cv, cv_min, cv_build, cv_input, cv_layout, cv_free)
    ui.set_focusable(id, True)
    ui.set_expand(id, True, True)
    cv->ui = &ui
    cv->id = id
    cv->vsb = ui.scrollbar(id, True)
    cv->hsb = ui.scrollbar(id, False)
    ui.on_scroll(cv->vsb, vsb_changed, cv)
    ui.on_scroll(cv->hsb, hsb_changed, cv)
    cv->line_numbers_gutter()
    return id

def cv_of(ref ui: Ui, id: i32) -> *CodeView:
    return ui.data_of(id)
