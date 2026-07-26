# core.p — the editing buffer (see core.ph). No window: all testable headless.
include <stdlib.h>
include <string.h>
include <regex.h>
import "core.ph"
import "../selfhost/lexer.ph"   # the REAL relex (tolerant mode) for highlighting

# the STL instances the buffer uses (a single TU materializes them)
implement Vec<BufLine>
implement Vec<Caret>
implement Vec<EditOp>
implement Vec<UndoGroup>
implement Vec<LineRange>
implement Vec<HlSpan>
implement Vec<HlLine>

UNDO_PAUSE_MS: const i64 = 700   # pause that breaks typing coalescence
TAB_WIDTH: const i32 = 4         # soft tabs (DESIGN.md)

# ---------- utf8 / strings ----------

static def cp_count(s: const *char) -> i32:
    n: i32 = 0
    i: usize = 0
    while s[i] != '\0':
        if (u8(s[i]) & 0xC0) != 0x80:
            n += 1
        i += 1
    return n

# byte offset of codepoint `col` (clamps at the end)
static def col_to_byte(s: const *char, col: i32) -> i32:
    n: i32 = 0
    i: usize = 0
    while s[i] != '\0':
        if (u8(s[i]) & 0xC0) != 0x80:
            if n == col:
                return i32(i)
            n += 1
        i += 1
    return i32(i)

# codepoints before byte offset b
static def byte_to_col(s: const *char, b: i32) -> i32:
    n: i32 = 0
    for i in range(b):
        if (u8(s[i]) & 0xC0) != 0x80:
            n += 1
    return n

static def own(s: const *char) -> *char:
    r: *char = malloc(strlen(s) + 1)
    strcpy(r, s)
    return r

static def own_n(s: const *char, n: usize) -> *char:
    r: *char = malloc(n + 1)
    memcpy(r, s, n)
    r[n] = '\0'
    return r

static def is_word_ch(ch: char) -> bool:
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_'

# end (line,col) of a text inserted at (l,c)
static def text_end(l: i32, c: i32, text: const *char, el: *i32, ec: *i32):
    *el = l
    seg: i32 = 0
    nl: bool = False
    for i in range(strlen(text)):
        if text[i] == '\n':
            *el += 1
            seg = 0
            nl = True
        elif (u8(text[i]) & 0xC0) != 0x80:
            seg += 1
    *ec = seg if nl else c + seg

# adjusts a position after the removal of [l0,c0 .. l1,c1)
static def adj_del_pos(l0: i32, c0: i32, l1: i32, c1: i32, pl: *i32, pc: *i32):
    l: i32 = *pl
    c: i32 = *pc
    if l < l0 or (l == l0 and c <= c0):
        return
    if l < l1 or (l == l1 and c < c1):
        *pl = l0; *pc = c0   # inside the deleted range: clamp to its start
        return
    if l == l1:
        *pl = l0
        *pc = c0 + (c - c1)
    else:
        *pl = l - (l1 - l0)

static def group_drop(g: *UndoGroup):
    for i in range(g->ops.len):
        free(g->ops.data[i].text)
    g->ops.deinit()
    g->before.deinit()
    g->after.deinit()

struct Buffer:
    # ---- internal helpers ----
    static def line_put(ref self: Buffer, i: i32, text: *char)
    static def push_line(ref self: Buffer, text: *char)
    static def raw_insert(ref self: Buffer, line: i32, col: i32, text: const *char, el: *i32, ec: *i32)
    static def raw_delete(ref self: Buffer, l0: i32, c0: i32, l1: i32, c1: i32) -> *char
    static def adj_insert(ref self: Buffer, skip: i32, l: i32, c: i32, el: i32, ec: i32)
    static def adj_delete(ref self: Buffer, skip: i32, l0: i32, c0: i32, l1: i32, c1: i32)
    static def snap(ref self: Buffer) -> Vec<Caret>
    static def restore(ref self: Buffer, in cs: Vec<Caret>)
    static def group_begin(ref self: Buffer, coalesce: bool, now_ms: i64)
    static def group_end(ref self: Buffer)
    static def op_push(ref self: Buffer, kind: EditOpKind, line: i32, col: i32, text: *char)
    static def redo_clear(ref self: Buffer)
    static def carets_sort(ref self: Buffer)
    static def del_sel_at(ref self: Buffer, k: i32)
    static def clamp_col(in self: Buffer, line: i32, col: i32) -> i32
    static def move_one_h(ref self: Buffer, c: *Caret, delta: i32, sel: bool)
    static def line_cut(ref self: Buffer, l: i32) -> *char
    static def line_paste(ref self: Buffer, at: i32, text: const *char)
    static def unfold_enclosing(ref self: Buffer, line: i32) -> bool

    # ---------- lifetime ----------

    def init(out self: Buffer):
        memset(&self, 0, sizeof(Buffer))
        self.lines.init()
        self.carets.init()
        self.undo.init()
        self.redo.init()
        self.push_line(own(""))
        c0: Caret = {0, 0, 0, 0, -1}
        self.carets.push(c0)

    static def push_line(ref self: Buffer, text: *char):
        bl: BufLine = {text, cp_count(text), False, False, 0}
        self.lines.push(bl)

    static def redo_clear(ref self: Buffer):
        for i in range(self.redo.len):
            group_drop(&self.redo.data[i])
        self.redo.clear()

    def deinit(ref self: Buffer):
        for i in range(self.lines.len):
            free(self.lines.data[i].text)
        self.lines.deinit()
        self.carets.deinit()
        for i in range(self.undo.len):
            group_drop(&self.undo.data[i])
        self.undo.deinit()
        self.redo_clear()
        self.redo.deinit()
        memset(&self, 0, sizeof(Buffer))

    def load(ref self: Buffer, data: const *char, len: usize):
        for i in range(self.lines.len):
            free(self.lines.data[i].text)
        self.lines.clear()
        self.crlf = False
        for i in range(self.undo.len):
            group_drop(&self.undo.data[i])
        self.undo.clear()
        self.redo_clear()
        start: usize = 0
        i: usize = 0
        while i <= len:
            if i == len or data[i] == '\n':
                end: usize = i
                if end > start and data[end - 1] == '\r':
                    end -= 1
                    self.crlf = True
                self.push_line(own_n(data + start, end - start))
                start = i + 1
            i += 1
        if self.lines.is_empty():
            self.push_line(own(""))
        self.carets.clear()
        c0: Caret = {0, 0, 0, 0, -1}
        self.carets.push(c0)
        self.dirty = False
        self.version += 1
        self.group_open = False

    def save_text(ref self: Buffer, out len: usize) -> *char:
        eol: const *char = "\r\n" if self.crlf else "\n"
        el: usize = strlen(eol)
        total: usize = 0
        for i in range(self.lines.len):
            total += strlen(self.lines.data[i].text)
            if i + 1 < self.lines.len:
                total += el
        r: *char = malloc(total + 1)
        p: usize = 0
        for i in range(self.lines.len):
            n: usize = strlen(self.lines.data[i].text)
            memcpy(r + p, self.lines.data[i].text, n)
            p += n
            if i + 1 < self.lines.len:
                memcpy(r + p, eol, el)
                p += el
        r[p] = '\0'
        len = p
        return r

    def mark_saved(ref self: Buffer):
        self.dirty = False

    # ---------- queries ----------

    def nlines(in self: Buffer) -> i32:
        return self.lines.len

    def ncarets(in self: Buffer) -> i32:
        return self.carets.len

    def line_text(in self: Buffer, line: i32) -> const *char:
        return self.lines.data[line].text

    def line_cp(in self: Buffer, line: i32) -> i32:
        return self.lines.data[line].ncp

    def col_byte(in self: Buffer, line: i32, col: i32) -> i32:
        return col_to_byte(self.lines.data[line].text, col)

    def caret(ref self: Buffer, k: i32) -> *Caret:
        return &self.carets.data[k]

    def has_sel(in self: Buffer) -> bool:
        for i in range(self.carets.len):
            c: *Caret = &self.carets.data[i]
            if c->aline != c->line or c->acol != c->col:
                return True
        return False

    def sel_range(in self: Buffer, k: i32, out l0: i32, out c0: i32, out l1: i32, out c1: i32):
        c: *Caret = &self.carets.data[k]
        if c->aline < c->line or (c->aline == c->line and c->acol <= c->col):
            l0 = c->aline; c0 = c->acol; l1 = c->line; c1 = c->col
        else:
            l0 = c->line; c0 = c->col; l1 = c->aline; c1 = c->acol

    def range_text(ref self: Buffer, l0: i32, c0: i32, l1: i32, c1: i32) -> *char:
        if l0 == l1:
            b0: i32 = self.col_byte(l0, c0)
            b1: i32 = self.col_byte(l0, c1)
            return own_n(self.lines.data[l0].text + b0, usize(b1 - b0))
        total: usize = 0
        for i in range(l0, l1 + 1):
            if i == l0:
                total += strlen(self.lines.data[i].text) - usize(self.col_byte(i, c0))
            elif i == l1:
                total += usize(self.col_byte(i, c1))
            else:
                total += strlen(self.lines.data[i].text)
            if i < l1:
                total += 1
        r: *char = malloc(total + 1)
        p: usize = 0
        for i in range(l0, l1 + 1):
            s: const *char = self.lines.data[i].text
            n: usize
            if i == l0:
                s += self.col_byte(i, c0)
                n = strlen(s)
            elif i == l1:
                n = usize(self.col_byte(i, c1))
            else:
                n = strlen(s)
            memcpy(r + p, s, n)
            p += n
            if i < l1:
                r[p] = '\n'
                p += 1
        r[p] = '\0'
        return r

    def sel_text(ref self: Buffer, k: i32) -> *char:
        c: *Caret = &self.carets.data[k]
        if c->aline == c->line and c->acol == c->col:
            return None
        l0: i32; c0: i32; l1: i32; c1: i32
        self.sel_range(k, out l0, out c0, out l1, out c1)
        return self.range_text(l0, c0, l1, c1)

    # ---------- lines (raw) ----------

    static def line_put(ref self: Buffer, i: i32, text: *char):
        free(self.lines.data[i].text)
        self.lines.data[i].text = text
        self.lines.data[i].ncp = cp_count(text)

    static def raw_insert(ref self: Buffer, line: i32, col: i32, text: const *char, el: *i32, ec: *i32):
        # editing a fold header releases its block: `folded` must always mean
        # "the lines below are exactly the hidden ones"
        self.unfold_range(line, line)
        cb: i32 = self.col_byte(line, col)
        old: const *char = self.lines.data[line].text
        nl: i32 = 0
        for i in range(strlen(text)):
            if text[i] == '\n':
                nl += 1
        if nl == 0:
            n: usize = strlen(old)
            t: usize = strlen(text)
            nw: *char = malloc(n + t + 1)
            memcpy(nw, old, usize(cb))
            memcpy(nw + cb, text, t)
            strcpy(nw + usize(cb) + t, old + cb)
            self.line_put(line, nw)
            *el = line
            *ec = col + cp_count(text)
            self.version += 1
            self.dirty = True
            return
        # multi-line: head + first segment | middles | last segment + tail
        tail: *char = own(old + cb)
        self.lines.insert_gap(line + 1, nl)
        for gi in range(line + 1, line + 1 + nl):
            self.lines.data[gi].text = None    # fresh slots: nothing to free
            self.lines.data[gi].ncp = 0
            self.lines.data[gi].hidden = False
            self.lines.data[gi].folded = False
            self.lines.data[gi].mark = 0
        seg_start: usize = 0
        li: i32 = line
        i: usize = 0
        first: bool = True
        while True:
            ch: char = text[i]
            if ch == '\n' or ch == '\0':
                seg: *char = own_n(text + seg_start, i - seg_start)
                if first:
                    nw2: *char = malloc(usize(cb) + strlen(seg) + 1)
                    memcpy(nw2, self.lines.data[line].text, usize(cb))
                    strcpy(nw2 + cb, seg)
                    free(seg)
                    self.line_put(li, nw2)
                    first = False
                elif ch == '\0':
                    # the last segment takes the tail
                    nw3: *char = malloc(strlen(seg) + strlen(tail) + 1)
                    strcpy(nw3, seg)
                    strcat(nw3, tail)
                    *ec = cp_count(seg)
                    free(seg)
                    self.line_put(li, nw3)
                    break
                else:
                    self.line_put(li, seg)
                seg_start = i + 1
                if ch == '\0':
                    break
                li += 1
            i += 1
        free(tail)
        *el = li
        self.version += 1
        self.dirty = True

    static def raw_delete(ref self: Buffer, l0: i32, c0: i32, l1: i32, c1: i32) -> *char:
        self.unfold_range(l0, l1)     # same invariant as raw_insert
        deleted: *char = self.range_text(l0, c0, l1, c1)
        b0: i32 = self.col_byte(l0, c0)
        if l0 == l1:
            b1: i32 = self.col_byte(l0, c1)
            old: const *char = self.lines.data[l0].text
            nw: *char = malloc(strlen(old) - usize(b1 - b0) + 1)
            memcpy(nw, old, usize(b0))
            strcpy(nw + b0, old + b1)
            self.line_put(l0, nw)
        else:
            bt: i32 = self.col_byte(l1, c1)
            head: const *char = self.lines.data[l0].text
            tail: const *char = self.lines.data[l1].text + bt
            nw2: *char = malloc(usize(b0) + strlen(tail) + 1)
            memcpy(nw2, head, usize(b0))
            strcpy(nw2 + b0, tail)
            self.line_put(l0, nw2)
            for i in range(l0 + 1, l1 + 1):
                free(self.lines.data[i].text)
            self.lines.remove_range(l0 + 1, l1 - l0)
        self.version += 1
        self.dirty = True
        return deleted

    # ---------- fixing up the OTHER carets after an edit ----------

    static def adj_insert(ref self: Buffer, skip: i32, l: i32, c: i32, el: i32, ec: i32):
        dl: i32 = el - l
        for i in range(self.carets.len):
            if i == skip:
                continue
            cr: *Caret = &self.carets.data[i]
            if cr->line == l and cr->col >= c:
                cr->col = ec + (cr->col - c) if dl > 0 else cr->col + (ec - c)
                cr->line += dl
            elif cr->line > l:
                cr->line += dl
            if cr->aline == l and cr->acol >= c:
                cr->acol = ec + (cr->acol - c) if dl > 0 else cr->acol + (ec - c)
                cr->aline += dl
            elif cr->aline > l:
                cr->aline += dl

    static def adj_delete(ref self: Buffer, skip: i32, l0: i32, c0: i32, l1: i32, c1: i32):
        for i in range(self.carets.len):
            if i == skip:
                continue
            cr: *Caret = &self.carets.data[i]
            adj_del_pos(l0, c0, l1, c1, &cr->line, &cr->col)
            adj_del_pos(l0, c0, l1, c1, &cr->aline, &cr->acol)

    # ---------- undo ----------

    static def snap(ref self: Buffer) -> Vec<Caret>:
        r: Vec<Caret>
        r.init()
        r.reserve(self.carets.len)
        for i in range(self.carets.len):
            r.push(self.carets.data[i])
        return r

    static def restore(ref self: Buffer, in cs: Vec<Caret>):
        self.carets.clear()
        for i in range(cs.len):
            self.carets.push(cs.data[i])

    # opens (or continues) the top group; coalesce = continuous typing
    static def group_begin(ref self: Buffer, coalesce: bool, now_ms: i64):
        self.redo_clear()
        if coalesce and self.group_open and not self.undo.is_empty() and now_ms - self.last_ms < UNDO_PAUSE_MS:
            self.last_ms = now_ms
            return
        g: UndoGroup
        g.ops.init()
        g.after.init()
        g.before = self.snap()
        self.undo.push(g)
        self.group_open = coalesce
        self.last_ms = now_ms

    static def group_end(ref self: Buffer):
        g: *UndoGroup = &self.undo.data[self.undo.len - 1]
        g->after.deinit()
        g->after = self.snap()

    static def op_push(ref self: Buffer, kind: EditOpKind, line: i32, col: i32, text: *char):
        o: EditOp = {kind, line, col, text}
        self.undo.data[self.undo.len - 1].ops.push(o)

    def break_group(ref self: Buffer):
        self.group_open = False

    def undo_step(ref self: Buffer) -> bool:
        if self.undo.is_empty():
            return False
        g: UndoGroup = self.undo.pop()
        for i in range(g.ops.len - 1, -1, -1):
            o: *EditOp = &g.ops.data[i]
            if o->kind == OP_INSERT:
                el: i32; ec: i32
                text_end(o->line, o->col, o->text, &el, &ec)
                free(self.raw_delete(o->line, o->col, el, ec))
            else:
                el2: i32; ec2: i32
                self.raw_insert(o->line, o->col, o->text, &el2, &ec2)
        self.restore(in g.before)
        self.redo.push(g)
        self.group_open = False
        self.dirty = True
        return True

    def redo_step(ref self: Buffer) -> bool:
        if self.redo.is_empty():
            return False
        g: UndoGroup = self.redo.pop()
        for i in range(g.ops.len):
            o: *EditOp = &g.ops.data[i]
            if o->kind == OP_INSERT:
                el: i32; ec: i32
                self.raw_insert(o->line, o->col, o->text, &el, &ec)
            else:
                el2: i32; ec2: i32
                text_end(o->line, o->col, o->text, &el2, &ec2)
                free(self.raw_delete(o->line, o->col, el2, ec2))
        self.restore(in g.after)
        self.undo.push(g)
        self.group_open = False
        self.dirty = True
        return True

    # ---------- carets ----------

    static def carets_sort(ref self: Buffer):
        # insertion sort by (line,col) + dedup of identical positions
        cs: *Caret = self.carets.data
        for i in range(1, self.carets.len):
            t: Caret = cs[i]
            j: i32 = i
            while j > 0 and (cs[j - 1].line > t.line or (cs[j - 1].line == t.line and cs[j - 1].col > t.col)):
                cs[j] = cs[j - 1]
                j -= 1
            cs[j] = t
        w: i32 = 1
        for i in range(1, self.carets.len):
            if cs[i].line != cs[w - 1].line or cs[i].col != cs[w - 1].col:
                cs[w] = cs[i]
                w += 1
        self.carets.len = w

    static def clamp_col(in self: Buffer, line: i32, col: i32) -> i32:
        n: i32 = self.lines.data[line].ncp
        return 0 if col < 0 else (n if col > n else col)

    def add_caret(ref self: Buffer, line: i32, col: i32):
        if line < 0 or line >= self.lines.len:
            return
        cc: i32 = self.clamp_col(line, col)
        c: Caret = {line, cc, line, cc, -1}
        self.carets.push(c)
        self.carets_sort()
        self.group_open = False

    def select_word_at(ref self: Buffer, k: i32) -> bool:
        c: *Caret = &self.carets.data[k]
        s: const *char = self.lines.data[c->line].text
        cb: i32 = self.col_byte(c->line, c->col)
        a: i32 = cb
        e: i32 = cb
        while a > 0 and is_word_ch(s[a - 1]):
            a -= 1
        while s[e] != '\0' and is_word_ch(s[e]):
            e += 1
        if a == e:
            return False
        c->aline = c->line
        c->acol = byte_to_col(s, a)
        c->col = byte_to_col(s, e)
        c->goal = -1
        return True

    # ---------- public editing (multi-caret) ----------

    # deletes caret k's selection (if any), recording it in the undo group
    static def del_sel_at(ref self: Buffer, k: i32):
        c: *Caret = &self.carets.data[k]
        if c->aline == c->line and c->acol == c->col:
            return
        l0: i32; c0: i32; l1: i32; c1: i32
        self.sel_range(k, out l0, out c0, out l1, out c1)
        dt: *char = self.raw_delete(l0, c0, l1, c1)
        self.op_push(OP_DELETE, l0, c0, dt)
        self.adj_delete(k, l0, c0, l1, c1)
        c2: *Caret = &self.carets.data[k]
        c2->line = l0; c2->col = c0
        c2->aline = l0; c2->acol = c0
        c2->goal = -1

    def insert(ref self: Buffer, text: const *char, now_ms: i64):
        # "normal" typing coalesces; space/enter/tab break the group (Sublime)
        breaker: bool = text[0] in {' ', '\n', '\t'} and text[1] == '\0'
        self.group_begin(not breaker and not self.has_sel(), now_ms)
        for k in range(self.carets.len - 1, -1, -1):
            self.del_sel_at(k)
            c: *Caret = &self.carets.data[k]
            el: i32; ec: i32
            self.raw_insert(c->line, c->col, text, &el, &ec)
            self.op_push(OP_INSERT, c->line, c->col, own(text))
            self.adj_insert(k, c->line, c->col, el, ec)
            c2: *Caret = &self.carets.data[k]
            c2->line = el; c2->col = ec
            c2->aline = el; c2->acol = ec
            c2->goal = -1
        self.carets_sort()
        self.group_end()
        if breaker:
            self.group_open = False

    def insert_each(ref self: Buffer, texts: **char, n: i32, now_ms: i64):
        if n != self.carets.len:
            return
        self.group_begin(False, now_ms)
        for k in range(self.carets.len - 1, -1, -1):
            self.del_sel_at(k)
            c: *Caret = &self.carets.data[k]
            t: const *char = texts[k]
            el: i32; ec: i32
            self.raw_insert(c->line, c->col, t, &el, &ec)
            self.op_push(OP_INSERT, c->line, c->col, own(t))
            self.adj_insert(k, c->line, c->col, el, ec)
            c2: *Caret = &self.carets.data[k]
            c2->line = el; c2->col = ec
            c2->aline = el; c2->acol = ec
            c2->goal = -1
        self.carets_sort()
        self.group_end()
        self.group_open = False

    def delete_sel(ref self: Buffer, now_ms: i64):
        if not self.has_sel():
            return
        self.group_begin(False, now_ms)
        for k in range(self.carets.len - 1, -1, -1):
            self.del_sel_at(k)
        self.carets_sort()
        self.group_end()
        self.group_open = False

    def backspace(ref self: Buffer, now_ms: i64):
        self.group_begin(not self.has_sel(), now_ms)
        for k in range(self.carets.len - 1, -1, -1):
            c: *Caret = &self.carets.data[k]
            if c->aline != c->line or c->acol != c->col:
                self.del_sel_at(k)
                continue
            l0: i32 = c->line
            c0: i32 = c->col - 1
            if c0 < 0:
                if l0 == 0:
                    continue
                l0 -= 1
                c0 = self.lines.data[l0].ncp
            elif c->col > 0:
                # smart backspace: only spaces to the left -> go back to the
                # previous multiple of TAB_WIDTH
                allsp: bool = True
                lb: const *char = self.lines.data[c->line].text
                for i in range(self.col_byte(c->line, c->col)):
                    if lb[i] != ' ':
                        allsp = False
                        break
                if allsp:
                    back: i32 = c->col % TAB_WIDTH
                    if back == 0:
                        back = TAB_WIDTH
                    if back > c->col:
                        back = c->col
                    c0 = c->col - back
            dt: *char = self.raw_delete(l0, c0, c->line, c->col)
            self.op_push(OP_DELETE, l0, c0, dt)
            self.adj_delete(k, l0, c0, c->line, c->col)
            c2: *Caret = &self.carets.data[k]
            c2->line = l0; c2->col = c0
            c2->aline = l0; c2->acol = c0
            c2->goal = -1
        self.carets_sort()
        self.group_end()

    def delete_fwd(ref self: Buffer, now_ms: i64):
        self.group_begin(not self.has_sel(), now_ms)
        for k in range(self.carets.len - 1, -1, -1):
            c: *Caret = &self.carets.data[k]
            if c->aline != c->line or c->acol != c->col:
                self.del_sel_at(k)
                continue
            l1: i32 = c->line
            c1: i32 = c->col + 1
            if c->col >= self.lines.data[c->line].ncp:
                if c->line + 1 >= self.lines.len:
                    continue
                l1 = c->line + 1
                c1 = 0
            dt: *char = self.raw_delete(c->line, c->col, l1, c1)
            self.op_push(OP_DELETE, c->line, c->col, dt)
            self.adj_delete(k, c->line, c->col, l1, c1)
        self.carets_sort()
        self.group_end()

    def replace_range(ref self: Buffer, l0: i32, c0: i32, l1: i32, c1: i32, text: const *char, now_ms: i64):
        self.group_begin(False, now_ms)
        dt: *char = self.raw_delete(l0, c0, l1, c1)
        self.op_push(OP_DELETE, l0, c0, dt)
        el: i32; ec: i32
        self.raw_insert(l0, c0, text, &el, &ec)
        self.op_push(OP_INSERT, l0, c0, own(text))
        self.carets.len = 1
        c: *Caret = &self.carets.data[0]
        c->line = el; c->col = ec
        c->aline = el; c->acol = ec
        c->goal = -1
        self.group_end()
        self.group_open = False

    # ---------- movement ----------

    static def move_one_h(ref self: Buffer, c: *Caret, delta: i32, sel: bool):
        if not sel and (c->aline != c->line or c->acol != c->col):
            # collapse onto the selection's edge (Sublime)
            anchor_first: bool = c->aline < c->line or (c->aline == c->line and c->acol <= c->col)
            if (anchor_first and delta < 0) or (not anchor_first and delta > 0):
                c->line = c->aline; c->col = c->acol
            c->aline = c->line; c->acol = c->col
            c->goal = -1
            return
        col: i32 = c->col + delta
        line: i32 = c->line
        while col < 0 and self.next_visible(line, -1) != line:
            line = self.next_visible(line, -1)
            col += self.lines.data[line].ncp + 1
        while col > self.lines.data[line].ncp and self.next_visible(line, 1) != line:
            col -= self.lines.data[line].ncp + 1
            line = self.next_visible(line, 1)
        c->line = line
        c->col = self.clamp_col(line, col)
        if not sel:
            c->aline = c->line; c->acol = c->col
        c->goal = -1

    def move_h(ref self: Buffer, delta: i32, sel: bool):
        for k in range(self.carets.len):
            self.move_one_h(&self.carets.data[k], delta, sel)
        self.carets_sort()
        self.group_open = False

    def move_v(ref self: Buffer, delta: i32, sel: bool):
        for k in range(self.carets.len):
            c: *Caret = &self.carets.data[k]
            if c->goal < 0:
                c->goal = c->col
            line: i32 = self.next_visible(c->line, delta)   # skips folds
            c->line = line
            c->col = self.clamp_col(line, c->goal)
            if not sel:
                c->aline = c->line; c->acol = c->col
        self.carets_sort()
        self.group_open = False

    def move_word(ref self: Buffer, dir: i32, sel: bool):
        for k in range(self.carets.len):
            c: *Caret = &self.carets.data[k]
            s: const *char = self.lines.data[c->line].text
            b: i32 = self.col_byte(c->line, c->col)
            if dir < 0:
                if b == 0:
                    self.move_one_h(c, -1, sel)
                    continue
                while b > 0 and not is_word_ch(s[b - 1]):
                    b -= 1
                while b > 0 and is_word_ch(s[b - 1]):
                    b -= 1
            else:
                n: i32 = i32(strlen(s))
                if b >= n:
                    self.move_one_h(c, 1, sel)
                    continue
                while b < n and is_word_ch(s[b]):
                    b += 1
                while b < n and not is_word_ch(s[b]):
                    b += 1
            c->col = byte_to_col(s, b)
            if not sel:
                c->aline = c->line; c->acol = c->col
            c->goal = -1
        self.carets_sort()
        self.group_open = False

    def home(ref self: Buffer, sel: bool):
        for k in range(self.carets.len):
            c: *Caret = &self.carets.data[k]
            s: const *char = self.lines.data[c->line].text
            ind: i32 = 0
            i: usize = 0
            while s[i] == ' ' or s[i] == '\t':
                ind += 1
                i += 1
            c->col = 0 if c->col == ind else ind
            if not sel:
                c->aline = c->line; c->acol = c->col
            c->goal = -1
        self.carets_sort()
        self.group_open = False

    def end(ref self: Buffer, sel: bool):
        for k in range(self.carets.len):
            c: *Caret = &self.carets.data[k]
            c->col = self.lines.data[c->line].ncp
            if not sel:
                c->aline = c->line; c->acol = c->col
            c->goal = -1
        self.carets_sort()
        self.group_open = False

    def move_to(ref self: Buffer, line: i32, col: i32):
        if line < 0:
            line = 0
        if line >= self.lines.len:
            line = self.lines.len - 1
        self.carets.len = 1
        c: *Caret = &self.carets.data[0]
        c->line = line
        c->col = self.clamp_col(line, col)
        c->aline = c->line; c->acol = c->col
        c->goal = -1
        self.group_open = False

    def select_range(ref self: Buffer, l0: i32, c0: i32, l1: i32, c1: i32):
        self.move_to(l0, c0)
        c: *Caret = &self.carets.data[0]
        c->aline = c->line; c->acol = c->col
        if l1 < 0:
            return
        c->line = l1 if l1 < self.lines.len else self.lines.len - 1
        c->col = self.clamp_col(c->line, c1)

    def select_all(ref self: Buffer):
        self.carets.len = 1
        c: *Caret = &self.carets.data[0]
        c->aline = 0; c->acol = 0
        c->line = self.lines.len - 1
        c->col = self.lines.data[self.lines.len - 1].ncp
        c->goal = -1
        self.group_open = False

    def collapse(ref self: Buffer):
        self.carets.len = 1
        c: *Caret = &self.carets.data[0]
        c->aline = c->line; c->acol = c->col
        c->goal = -1
        self.group_open = False

    # ---------- ctrl+d ----------

    def ctrl_d(ref self: Buffer):
        self.group_open = False
        if not self.has_sel():
            for k in range(self.carets.len):
                self.select_word_at(k)
            return
        # add a caret at the NEXT occurrence of the last caret's text (wrapping)
        last: i32 = self.carets.len - 1
        needle: *char = self.sel_text(last)
        if needle == None:
            return
        if strchr(needle, '\n') != None:
            free(needle)
            return
        l1: i32; c1x: i32; l0d: i32; c0d: i32
        self.sel_range(last, out l0d, out c0d, out l1, out c1x)
        fl: i32; fc: i32
        if self.find(needle, l1, c1x, True, out fl, out fc):
            dup: bool = False
            for k in range(self.carets.len):
                if self.carets.data[k].aline == fl and self.carets.data[k].acol == fc:
                    dup = True
            if not dup:
                nc: Caret = {fl, fc + cp_count(needle), fl, fc, -1}
                self.carets.push(nc)
                self.carets_sort()
        free(needle)

    # ---------- search ----------

    def find(in self: Buffer, needle: const *char, from_line: i32, from_col: i32,
             forward: bool, out l: i32, out c: i32) -> bool:
        l = -1
        c = -1
        if needle[0] == '\0':
            return False
        nb: usize = strlen(needle)
        if forward:
            sl: i32 = from_line
            sb: i32 = self.col_byte(from_line, from_col)
            for step in range(self.lines.len + 1):
                s: const *char = self.lines.data[sl].text
                if usize(sb) <= strlen(s):
                    hit: const *char = strstr(s + sb, needle)
                    if hit != None:
                        l = sl
                        c = byte_to_col(s, i32(hit - s))
                        return True
                sl = (sl + 1) % self.lines.len
                sb = 0
            return False
        # backwards: the last occurrence BEFORE (from_line, from_col)
        sl2: i32 = from_line
        limit: i32 = self.col_byte(from_line, from_col)
        for step in range(self.lines.len + 1):
            s2: const *char = self.lines.data[sl2].text
            best: i32 = -1
            p: const *char = s2
            while True:
                hit2: const *char = strstr(p, needle)
                if hit2 == None:
                    break
                off: i32 = i32(hit2 - s2)
                if limit >= 0 and off + i32(nb) > limit:
                    break
                best = off
                p = hit2 + 1
            if best >= 0:
                l = sl2
                c = byte_to_col(s2, best)
                return True
            sl2 = sl2 - 1 if sl2 > 0 else self.lines.len - 1
            limit = -1   # earlier lines: the whole line counts
        return False

    def find_re(in self: Buffer, pattern: const *char, from_line: i32, from_col: i32,
                forward: bool, out l: i32, out c0: i32, out c1: i32) -> bool:
        l = -1; c0 = -1; c1 = -1
        re: regex_t
        if regcomp(&re, pattern, REG_EXTENDED) != 0:
            return False
        found: bool = False
        sl: i32 = from_line
        start_b: i32 = self.col_byte(from_line, from_col)
        for step in range(self.lines.len + 1):
            s: const *char = self.lines.data[sl].text
            base: i32 = start_b if step == 0 and forward else 0
            m: regmatch_t[1]
            bestso: i32 = -1
            besteo: i32 = -1
            off: i32 = base
            while usize(off) <= strlen(s):
                if regexec(&re, s + off, 1, m, 0) != 0:
                    break
                so: i32 = off + i32(m[0].rm_so)
                eo: i32 = off + i32(m[0].rm_eo)
                if forward:
                    bestso = so; besteo = eo
                    break
                if step == 0 and eo > start_b:
                    break
                bestso = so; besteo = eo
                off = so + 1 if eo == so else eo
            if bestso >= 0:
                l = sl
                c0 = byte_to_col(s, bestso)
                c1 = byte_to_col(s, besteo)
                found = True
                break
            if forward:
                sl = (sl + 1) % self.lines.len
            else:
                sl = sl - 1 if sl > 0 else self.lines.len - 1
        regfree(&re)
        return found

    # ---------- line-oriented commands ----------

    # removes line `l` whole (with its newline) and returns its text; the edit
    # is recorded in the open undo group like any other
    static def line_cut(ref self: Buffer, l: i32) -> *char:
        n: i32 = self.lines.len
        if n == 1:
            only: *char = own(self.lines.data[0].text)
            if self.lines.data[0].ncp > 0:
                d0: *char = self.raw_delete(0, 0, 0, self.lines.data[0].ncp)
                self.op_push(OP_DELETE, 0, 0, d0)
            return only
        if l + 1 < n:
            d1: *char = self.raw_delete(l, 0, l + 1, 0)      # "text\n"
            self.op_push(OP_DELETE, l, 0, d1)
            k: usize = strlen(d1)
            return own_n(d1, k - 1 if k > 0 else 0)
        # last line: swallow the newline that precedes it
        pc: i32 = self.lines.data[l - 1].ncp
        d2: *char = self.raw_delete(l - 1, pc, l, self.lines.data[l].ncp)
        self.op_push(OP_DELETE, l - 1, pc, d2)               # "\ntext"
        return own(d2 + 1)

    # inserts `text` as a NEW line at index `at` (at == nlines appends)
    static def line_paste(ref self: Buffer, at: i32, text: const *char):
        el: i32; ec: i32
        if at < self.lines.len:
            ins: *char = malloc(strlen(text) + 2)
            strcpy(ins, text)
            strcat(ins, "\n")
            self.raw_insert(at, 0, ins, &el, &ec)
            self.op_push(OP_INSERT, at, 0, ins)              # the group owns it
            return
        last: i32 = self.lines.len - 1
        col: i32 = self.lines.data[last].ncp
        ins2: *char = malloc(strlen(text) + 2)
        strcpy(ins2, "\n")
        strcat(ins2, text)
        self.raw_insert(last, col, ins2, &el, &ec)
        self.op_push(OP_INSERT, last, col, ins2)

    def line_ranges(in self: Buffer) -> Vec<LineRange>:
        r: Vec<LineRange>
        r.init()
        for k in range(self.carets.len):
            a: i32; b: i32; c: i32; d: i32
            self.sel_range(k, out a, out b, out c, out d)
            if c > a and d == 0:
                c -= 1        # a selection ending at column 0 excludes that line
            if not r.is_empty() and a <= r.data[r.len - 1].l1 + 1:
                if c > r.data[r.len - 1].l1:
                    r.data[r.len - 1].l1 = c      # merge touching blocks
            else:
                lr: LineRange = {a, c}
                r.push(lr)
        return r

    def move_lines(ref self: Buffer, dir: i32, now_ms: i64):
        rs: Vec<LineRange> = self.line_ranges()
        defer:
            rs.deinit()
        for i in range(rs.len):     # nothing moves if a block would fall off
            if dir < 0 and rs.data[i].l0 == 0:
                return
            if dir > 0 and rs.data[i].l1 >= self.lines.len - 1:
                return
        self.group_begin(False, now_ms)
        if dir < 0:
            for i in range(rs.len):
                t: *char = self.line_cut(rs.data[i].l0 - 1)
                self.line_paste(rs.data[i].l1, t)
                free(t)
        else:
            for i in range(rs.len - 1, -1, -1):
                t2: *char = self.line_cut(rs.data[i].l1 + 1)
                self.line_paste(rs.data[i].l0, t2)
                free(t2)
        for k in range(self.carets.len):
            c: *Caret = &self.carets.data[k]
            c->line += dir
            c->aline += dir
            c->goal = -1
        self.carets_sort()
        self.group_end()
        self.group_open = False

    def duplicate_lines(ref self: Buffer, now_ms: i64):
        rs: Vec<LineRange> = self.line_ranges()
        defer:
            rs.deinit()
        self.group_begin(False, now_ms)
        for i in range(rs.len - 1, -1, -1):
            a: i32 = rs.data[i].l0
            b: i32 = rs.data[i].l1
            col: i32 = self.lines.data[b].ncp
            body: *char = self.range_text(a, 0, b, col)
            ins: *char = malloc(strlen(body) + 2)
            strcpy(ins, "\n")
            strcat(ins, body)
            free(body)
            el: i32; ec: i32
            self.raw_insert(b, col, ins, &el, &ec)
            self.op_push(OP_INSERT, b, col, ins)
        # every caret lands on the COPY: it shifts by its own block plus the
        # height of every block above it
        for k in range(self.carets.len):
            c: *Caret = &self.carets.data[k]
            up: i32 = 0
            for i in range(rs.len):
                h: i32 = rs.data[i].l1 - rs.data[i].l0 + 1
                if rs.data[i].l1 < c->line or (c->line >= rs.data[i].l0 and c->line <= rs.data[i].l1):
                    up += h
            c->line += up
            c->aline += up
            c->goal = -1
        self.carets_sort()
        self.group_end()
        self.group_open = False

    def delete_lines(ref self: Buffer, now_ms: i64):
        rs: Vec<LineRange> = self.line_ranges()
        defer:
            rs.deinit()
        self.group_begin(False, now_ms)
        for i in range(rs.len - 1, -1, -1):
            for l in range(rs.data[i].l1, rs.data[i].l0 - 1, -1):
                free(self.line_cut(l))
        # each caret goes to the top of its block, minus what was cut above it
        for k in range(self.carets.len):
            c: *Caret = &self.carets.data[k]
            gone: i32 = 0
            home: i32 = c->line
            for i in range(rs.len):
                h: i32 = rs.data[i].l1 - rs.data[i].l0 + 1
                if rs.data[i].l1 < c->line:
                    gone += h
                elif c->line >= rs.data[i].l0:
                    home = rs.data[i].l0
            nl: i32 = home - gone
            if nl >= self.lines.len:
                nl = self.lines.len - 1
            if nl < 0:
                nl = 0
            c->line = nl
            c->col = self.clamp_col(nl, c->col)
            c->aline = c->line
            c->acol = c->col
            c->goal = -1
        self.carets_sort()
        self.group_end()
        self.group_open = False

    def join_lines(ref self: Buffer, now_ms: i64):
        self.group_begin(False, now_ms)
        for k in range(self.carets.len - 1, -1, -1):
            c: *Caret = &self.carets.data[k]
            l: i32 = c->line
            if l + 1 >= self.lines.len:
                continue
            s: const *char = self.lines.data[l].text
            nx: const *char = self.lines.data[l + 1].text
            ind: i32 = 0
            while nx[ind] == ' ' or nx[ind] == '\t':
                ind += 1
            endc: i32 = self.lines.data[l].ncp
            # a space between the two, unless one side is empty or the current
            # line already ends in whitespace (Sublime's ctrl+j)
            glue: const *char = " "
            if endc == 0 or nx[ind] == '\0':
                glue = ""
            else:
                lastch: char = s[strlen(s) - 1]
                if lastch in {' ', '\t'}:
                    glue = ""
            dt: *char = self.raw_delete(l, endc, l + 1, byte_to_col(nx, ind))
            self.op_push(OP_DELETE, l, endc, dt)
            if glue[0] != '\0':
                el: i32; ec: i32
                self.raw_insert(l, endc, glue, &el, &ec)
                self.op_push(OP_INSERT, l, endc, own(glue))
            c2: *Caret = &self.carets.data[k]
            c2->line = l
            c2->col = endc
            c2->aline = l
            c2->acol = endc
            c2->goal = -1
        self.carets_sort()
        self.group_end()
        self.group_open = False

    def toggle_comment(ref self: Buffer, marker: const *char, now_ms: i64):
        rs: Vec<LineRange> = self.line_ranges()
        defer:
            rs.deinit()
        mlen: usize = strlen(marker)
        all_commented: bool = True
        any_line: bool = False
        min_ind: i32 = 1 << 28
        for i in range(rs.len):
            for l in range(rs.data[i].l0, rs.data[i].l1 + 1):
                if self.is_blank(l):
                    continue
                any_line = True
                s: const *char = self.lines.data[l].text
                b: i32 = 0
                while s[b] == ' ' or s[b] == '\t':
                    b += 1
                if strncmp(s + b, marker, mlen) != 0:
                    all_commented = False
                col: i32 = byte_to_col(s, b)
                if col < min_ind:
                    min_ind = col
        if not any_line:
            return
        self.group_begin(False, now_ms)
        for i in range(rs.len - 1, -1, -1):
            for l in range(rs.data[i].l1, rs.data[i].l0 - 1, -1):
                if self.is_blank(l):
                    continue
                s2: const *char = self.lines.data[l].text
                if all_commented:
                    b2: i32 = 0
                    while s2[b2] == ' ' or s2[b2] == '\t':
                        b2 += 1
                    n: usize = mlen
                    if s2[usize(b2) + mlen] == ' ':
                        n += 1        # the space added when commenting
                    c0: i32 = byte_to_col(s2, b2)
                    c1: i32 = c0 + i32(n)
                    dt: *char = self.raw_delete(l, c0, l, c1)
                    self.op_push(OP_DELETE, l, c0, dt)
                    for k in range(self.carets.len):
                        cc: *Caret = &self.carets.data[k]
                        if cc->line == l and cc->col > c0:
                            cc->col = c0 if cc->col < c1 else cc->col - i32(n)
                        if cc->aline == l and cc->acol > c0:
                            cc->acol = c0 if cc->acol < c1 else cc->acol - i32(n)
                else:
                    txt: *char = malloc(mlen + 2)
                    strcpy(txt, marker)
                    strcat(txt, " ")
                    el: i32; ec: i32
                    self.raw_insert(l, min_ind, txt, &el, &ec)
                    self.op_push(OP_INSERT, l, min_ind, txt)
                    add: i32 = i32(mlen) + 1
                    for k in range(self.carets.len):
                        cc2: *Caret = &self.carets.data[k]
                        if cc2->line == l and cc2->col >= min_ind:
                            cc2->col += add
                        if cc2->aline == l and cc2->acol >= min_ind:
                            cc2->acol += add
        self.carets_sort()
        self.group_end()
        self.group_open = False

    # ---------- folding (by indentation) ----------

    def is_blank(in self: Buffer, line: i32) -> bool:
        s: const *char = self.lines.data[line].text
        i: usize = 0
        while s[i] == ' ' or s[i] == '\t':
            i += 1
        return s[i] == '\0'

    def indent_of(in self: Buffer, line: i32) -> i32:
        s: const *char = self.lines.data[line].text
        n: i32 = 0
        i: usize = 0
        while s[i] == ' ' or s[i] == '\t':
            if s[i] == '\t':
                n += TAB_WIDTH - (n % TAB_WIDTH)
            else:
                n += 1
            i += 1
        return n

    def can_fold(in self: Buffer, line: i32) -> bool:
        if line < 0 or line + 1 >= self.lines.len:
            return False
        if self.lines.data[line].hidden or self.lines.data[line].folded:
            return False
        if self.is_blank(line):
            return False
        base: i32 = self.indent_of(line)
        for i in range(line + 1, self.lines.len):
            if self.is_blank(i):
                continue
            return self.indent_of(i) > base
        return False

    def fold_end(in self: Buffer, line: i32) -> i32:
        base: i32 = self.indent_of(line)
        end: i32 = line
        for i in range(line + 1, self.lines.len):
            if self.is_blank(i):
                continue        # blank lines never end a block
            if self.indent_of(i) > base:
                end = i
            else:
                break
        return end

    def is_hidden(in self: Buffer, line: i32) -> bool:
        return self.lines.data[line].hidden

    def is_folded(in self: Buffer, line: i32) -> bool:
        return self.lines.data[line].folded

    def fold(ref self: Buffer, line: i32) -> bool:
        if not self.can_fold(line):
            return False
        e: i32 = self.fold_end(line)
        for i in range(line + 1, e + 1):
            self.lines.data[i].hidden = True
        self.lines.data[line].folded = True
        # a caret may not sit on a hidden line: pull it onto the header
        hc: i32 = self.lines.data[line].ncp
        for k in range(self.carets.len):
            c: *Caret = &self.carets.data[k]
            if c->line > line and c->line <= e:
                c->line = line
                c->col = hc
            if c->aline > line and c->aline <= e:
                c->aline = line
                c->acol = hc
        self.carets_sort()
        return True

    def unfold(ref self: Buffer, line: i32) -> bool:
        if line < 0 or line >= self.lines.len or not self.lines.data[line].folded:
            return False
        self.lines.data[line].folded = False
        e: i32 = self.fold_end(line)
        i: i32 = line + 1
        while i <= e and i < self.lines.len:
            self.lines.data[i].hidden = False
            if self.lines.data[i].folded:
                i = self.fold_end(i) + 1     # a nested fold STAYS collapsed
            else:
                i += 1
        return True

    def toggle_fold(ref self: Buffer, line: i32) -> bool:
        if self.lines.data[line].folded:
            return self.unfold(line)
        return self.fold(line)

    # the enclosing folded header of a hidden line (Godot walks back the same
    # way); False when the line was not hidden
    static def unfold_enclosing(ref self: Buffer, line: i32) -> bool:
        if line < 0 or line >= self.lines.len or not self.lines.data[line].hidden:
            return False
        for h in range(line - 1, -1, -1):
            if self.lines.data[h].folded:
                self.unfold(h)
                return True
        self.lines.data[line].hidden = False   # orphan: never leave it invisible
        return True

    def unfold_range(ref self: Buffer, l0: i32, l1: i32):
        a: i32 = l0 if l0 > 0 else 0
        b: i32 = l1 if l1 < self.lines.len - 1 else self.lines.len - 1
        for i in range(a, b + 1):
            if self.lines.data[i].folded:
                self.unfold(i)
        # an edit reaching INTO a collapsed block (undo/redo can) releases it
        guard: i32 = 0
        while guard < 64:
            hit: bool = False
            for i in range(a, b + 1):
                if self.lines.data[i].hidden:
                    self.unfold_enclosing(i)
                    hit = True
                    break
            if not hit:
                return
            guard += 1

    def fold_all(ref self: Buffer):
        for i in range(self.lines.len):
            if self.can_fold(i):
                self.fold(i)      # can_fold is False on hidden lines: level 1

    def unfold_all(ref self: Buffer):
        for i in range(self.lines.len):
            self.lines.data[i].hidden = False
            self.lines.data[i].folded = False

    # ---------- per-line marks ----------

    def mark_of(in self: Buffer, line: i32) -> u8:
        if line < 0 or line >= self.lines.len:
            return 0
        return self.lines.data[line].mark

    def toggle_mark(ref self: Buffer, line: i32, mark: u8):
        if line < 0 or line >= self.lines.len:
            return
        self.lines.data[line].mark = self.lines.data[line].mark ^ mark

    def clear_marks(ref self: Buffer, mark: u8):
        for i in range(self.lines.len):
            self.lines.data[i].mark = self.lines.data[i].mark & ~mark

    def next_mark(in self: Buffer, from_line: i32, mark: u8, forward: bool) -> i32:
        n: i32 = self.lines.len
        for step in range(1, n + 1):
            i: i32 = ((from_line + step) % n) if forward else ((from_line - step + n * 2) % n)
            if (self.lines.data[i].mark & mark) != 0:
                return i
        return -1

    # ---------- visible-line mapping ----------

    def visible_count(in self: Buffer) -> i32:
        n: i32 = 0
        for i in range(self.lines.len):
            if not self.lines.data[i].hidden:
                n += 1
        return n

    def next_visible(in self: Buffer, line: i32, delta: i32) -> i32:
        l: i32 = line
        if l < 0:
            l = 0
        if l >= self.lines.len:
            l = self.lines.len - 1
        if delta > 0:
            for step in range(delta):
                i: i32 = l + 1
                while i < self.lines.len and self.lines.data[i].hidden:
                    i += 1
                if i >= self.lines.len:
                    break
                l = i
        elif delta < 0:
            for step in range(-delta):
                j: i32 = l - 1
                while j >= 0 and self.lines.data[j].hidden:
                    j -= 1
                if j < 0:
                    break
                l = j
        while l > 0 and self.lines.data[l].hidden:
            l -= 1        # the starting line itself may have just been folded
        return l

    def to_visible(in self: Buffer, line: i32) -> i32:
        n: i32 = 0
        for i in range(line if line < self.lines.len else self.lines.len):
            if not self.lines.data[i].hidden:
                n += 1
        return n

    def from_visible(in self: Buffer, vidx: i32) -> i32:
        n: i32 = 0
        for i in range(self.lines.len):
            if self.lines.data[i].hidden:
                continue
            if n >= vidx:
                return i
            n += 1
        return self.lines.len - 1

# ---------- highlight ----------

static def arena_drop(a: *Arena):
    blk: *ArenaBlock = a->head
    while blk != None:
        nx: *ArenaBlock = blk->next
        free(blk)
        blk = nx
    a->head = None

static def span_add(h: *HlLine, col: i32, len: i32, cls: u8):
    if len <= 0:
        return
    sp: HlSpan = {col, len, cls}
    h->spans.push(sp)

struct Highlight:
    def init(out self: Highlight, enabled: bool):
        self.lines.init()
        self.version = 0
        self.enabled = enabled

    def deinit(ref self: Highlight):
        for i in range(self.lines.len):
            self.lines.data[i].spans.deinit()
        self.lines.deinit()

    def class_at(in self: Highlight, line: i32, col: i32) -> u8:
        if line < 0 or line >= self.lines.len:
            return HL_TEXT
        sp: *Vec<HlSpan> = &self.lines.data[line].spans
        for i in range(sp->len):
            if col >= sp->data[i].col and col < sp->data[i].col + sp->data[i].len:
                return sp->data[i].cls
        return HL_TEXT

    def update(ref self: Highlight, ref b: Buffer):
        if self.version == b.version and self.lines.len == b.nlines():
            return
        en: bool = self.enabled
        self.deinit()
        self.lines.init()
        self.enabled = en
        for i in range(b.nlines()):
            h0: HlLine
            h0.spans.init()
            self.lines.push(h0)
        self.version = b.version
        if not self.enabled:
            return
        n: usize
        text: *char = b.save_text(out n)
        a: Arena = {0}
        tl: TokenList = lex_ex("<buffer>", text, n, &a, True)
        defer:
            free(tl.toks)      # the array belongs to the caller (lexer.ph); we
            arena_drop(&a)     # relex on every keystroke — else the editor leaks
        for i in range(tl.n):
            t: *Token = &tl.toks[i]
            if t->text == None or t->kind in {TK_EOF, TK_NEWLINE, TK_INDENT, TK_DEDENT}:
                continue
            ln: i32 = t->pos.line - 1
            if ln < 0 or ln >= self.lines.len:
                continue
            cls: u8 = HL_KW   # a token with text that is not an ident/number/string
            if t->kind == TK_IDENT:
                cls = HL_TEXT
            elif t->kind == TK_NUMBER:
                cls = HL_NUM
            elif t->kind in {TK_STRING, TK_CHARLIT, TK_HEADER}:
                cls = HL_STR
            if cls == HL_TEXT:
                continue
            span_add(&self.lines.data[ln], t->pos.col - 1, cp_count(t->text), cls)
        free(text)
        # comments: the first '#' outside a string runs to the end of the line
        for ln in range(b.nlines()):
            s: const *char = b.line_text(ln)
            h: *HlLine = &self.lines.data[ln]
            col: i32 = 0
            i: usize = 0
            while s[i] != '\0':
                if (u8(s[i]) & 0xC0) != 0x80:
                    if s[i] == '#':
                        inside: bool = False
                        for k in range(h->spans.len):
                            sp2: *HlSpan = &h->spans.data[k]
                            if sp2->cls == HL_STR and col >= sp2->col and col < sp2->col + sp2->len:
                                inside = True
                                break
                        if not inside:
                            span_add(h, col, b.line_cp(ln) - col, HL_COMMENT)
                            break
                    col += 1
                i += 1
