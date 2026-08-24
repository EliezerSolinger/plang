"""pstudio's editing buffer, in pscript — the trial by fire.

This is a port of `pstudio/core.p` (1505 lines of P), and the point of the
exercise is what the port DOES NOT have to say. In P the buffer owns every
line with malloc/free, counts codepoints by hand, and carries an `ncp` cache
because `strlen` is bytes; here a line is a `str`, `len(s)` is codepoints
(3.4), slicing copies, and the collector owns the graph. What is left is the
editing model itself — which is the part worth reading.

The model is the same one the P version fixed:

  * a caret is a `record` (pure bytes): line, column and a selection anchor,
    plus the "goal" column that vertical movement remembers;
  * there is ALWAYS at least one caret, and they stay sorted, because every
    edit walks them from the last to the first so earlier positions do not
    shift under later ones;
  * undo is a list of GROUPS, and typing coalesces into one group until a
    space, a newline, a movement or a pause of 700ms breaks it — a Ctrl+Z
    that undid one character at a time would be nobody's idea of undo;
  * a fold hides lines without deleting them, and a mark travels with its
    line through every edit.

Everything here is headless and therefore testable: no window, no drawing.
"""

import re     # 113: `find_re` — POSIX's ERE, which is pscript's `re` (41.2)


const TAB_WIDTH: int = 4
const UNDO_PAUSE_MS: int = 700

# 115: the SAME numbers as the editor in P (`MARK_BOOKMARK`=1,
# `MARK_BREAKPOINT`=2), so both implementations talk about the same bit when
# somebody compares
const MARK_BOOK: int = 1         # a bookmark (F2 jumps between them)
const MARK_BREAK: int = 2        # a breakpoint the debugger will want
# 119/F6: the line where the build failed. It is a mark and not an underline
# for a practical reason: the gutter is already drawn, it already has two
# marks, and a third costs one line — while a wavy underline costs a whole new
# drawing path beneath the text. The information that matters (WHICH line) is
# the same.
const MARK_ERROR: int = 4


record Caret:
    line: int
    col: int
    aline: int             # selection anchor; equal to line/col when there is none
    acol: int
    goal: int              # column vertical movement aims for (-1 = use col)


struct BufLine:
    text: str
    hidden: bool           # folded away: never drawn, never holds a caret
    folded: bool           # a fold HEADER: the block below it is hidden
    mark: int


record Span:
    l0: int
    c0: int
    l1: int
    c1: int


enum OpKind:
    OP_INSERT
    OP_DELETE


struct EditOp:
    kind: OpKind
    line: int
    col: int
    text: str


struct UndoGroup:
    ops: list<EditOp>
    before: list<Caret>
    after: list<Caret>


# ---------- helpers ----------

def is_word_ch(c: str) -> bool:
    return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_"


# where a text inserted at (l, c) ends
def text_end(l: int, c: int, text: str) -> Span:
    el = l
    seg = 0
    nl = False
    for ch in text:
        if ch == "\n":
            el += 1
            seg = 0
            nl = True
        else:
            seg += 1
    return Span(l, c, el, seg if nl else c + seg)


# a position after the removal of [l0,c0 .. l1,c1)
def adj_del_pos(r: Span, pl: int, pc: int) -> Caret:
    if pl < r.l0 or (pl == r.l0 and pc <= r.c0):
        return Caret(pl, pc, 0, 0, -1)
    if pl < r.l1 or (pl == r.l1 and pc < r.c1):
        return Caret(r.l0, r.c0, 0, 0, -1)      # inside: clamps to the start
    if pl == r.l1:
        return Caret(r.l0, r.c0 + (pc - r.c1), 0, 0, -1)
    return Caret(pl - (r.l1 - r.l0), pc, 0, 0, -1)


struct Buffer:
    lines: list<BufLine>
    carets: list<Caret>        # ALWAYS >= 1, sorted by position
    undo: list<UndoGroup>
    redo: list<UndoGroup>
    group_open: bool
    last_ms: int
    crlf: bool                 # the EOL found on load, preserved on save
    dirty: bool
    version: int               # bumped on every edit; the view watches it

    # ---------- lifetime ----------

    def load(self, data: str):
        """Replaces the content. CRLF is detected and remembered for saving.

        `replace` and `split` rather than a walk over the codepoints, for the
        reason `text()` gives: appending to a string in a loop is quadratic, and
        the CRLF strip walked the WHOLE FILE that way — a big file with Windows
        line endings would have taken minutes to open.

        One behaviour changed with it, and for the better: the old walk deleted
        EVERY `\r`, so a lone carriage return in the middle of a line — content,
        not a line ending — disappeared without anybody being told. Only `\r\n`
        is a line ending here."""
        self.crlf = "\r\n" in data
        body = data.replace("\r\n", "\n") if self.crlf else data
        self.lines = []
        for t in body.split("\n"):
            self.lines.append(BufLine(t, False, False, 0))
        self.carets = [Caret(0, 0, 0, 0, -1)]
        self.undo = []
        self.redo = []
        self.group_open = False
        self.dirty = False
        self.version += 1

    def text(self) -> str:
        """The whole content, with the EOL the file arrived with.

        `join`, and not `+=` in a loop, for a measured reason: the loop is
        quadratic. 8 000 lines cost 672 ms that way and 0 ms this way; 32 000
        cost 16 972 ms against 3 ms. And this is called on EVERY save and on
        every rebuild of the completion index, so the biggest file in this
        repository (11 076 lines) used to freeze the editor for over a second,
        twice."""
        parts: list<str> = []
        for l in self.lines:
            parts.append(l.text)
        return ("\r\n" if self.crlf else "\n").join(parts)

    def mark_saved(self):
        self.dirty = False

    # ---------- queries ----------

    def nlines(self) -> int:
        return len(self.lines)

    def ncarets(self) -> int:
        return len(self.carets)

    def line_text(self, line: int) -> str:
        if line < 0 or line >= len(self.lines):
            return ""
        return self.lines[line].text

    def line_cp(self, line: int) -> int:
        return len(self.line_text(line))

    def caret(self, k: int) -> Caret:
        return self.carets[k]

    def has_sel(self) -> bool:
        for c in self.carets:
            if c.line != c.aline or c.col != c.acol:
                return True
        return False

    def sel_range(self, k: int) -> Span:
        """Caret k's selection, ordered. The two ends are equal when empty."""
        c = self.carets[k]
        if c.aline < c.line or (c.aline == c.line and c.acol <= c.col):
            return Span(c.aline, c.acol, c.line, c.col)
        return Span(c.line, c.col, c.aline, c.acol)

    def range_text(self, r: Span) -> str:
        # `join` for the same reason `text()` uses it: copying a selection that
        # spans the whole file went down the same quadratic path
        if r.l0 == r.l1:
            return self.line_text(r.l0)[r.c0:r.c1]
        parts: list<str> = [self.line_text(r.l0)[r.c0:]]
        for l in range(r.l0 + 1, r.l1):
            parts.append(self.line_text(l))
        parts.append(self.line_text(r.l1)[0:r.c1])
        return "\n".join(parts)

    def sel_text(self, k: int) -> str:
        return self.range_text(self.sel_range(k))

    def clamp_col(self, line: int, col: int) -> int:
        n = self.line_cp(line)
        return 0 if col < 0 else (n if col > n else col)

    # ---------- undo bookkeeping ----------

    def snap(self) -> list<Caret>:
        out: list<Caret> = []
        for c in self.carets:
            out.append(c)
        return out

    def group_begin(self, coalesce: bool, now_ms: int):
        if self.group_open and coalesce and now_ms - self.last_ms <= UNDO_PAUSE_MS:
            self.last_ms = now_ms
            return
        g = UndoGroup([], self.snap(), [])
        self.undo.append(g)
        self.group_open = True
        self.last_ms = now_ms
        self.redo = []

    def group_end(self):
        if len(self.undo) > 0:
            self.undo[len(self.undo) - 1].after = self.snap()
        self.dirty = True
        self.version += 1

    def break_group(self):
        """Movement (and anything deliberate) ends the typing group."""
        self.group_open = False

    def op_push(self, kind: OpKind, line: int, col: int, text: str):
        if len(self.undo) > 0:
            self.undo[len(self.undo) - 1].ops.append(EditOp(kind, line, col, text))

    # ---------- raw edits (no undo, no caret adjustment) ----------

    def raw_insert(self, line: int, col: int, text: str) -> Span:
        self.unfold_range(line, line)      # 115: editing inside a fold releases it
        end = text_end(line, col, text)
        cur = self.lines[line]
        head = cur.text[0:col]
        tail = cur.text[col:]
        if not ("\n" in text):
            cur.text = head + text + tail
            return end
        parts: list<str> = []
        acc = ""
        for ch in text:
            if ch == "\n":
                parts.append(acc)
                acc = ""
            else:
                acc += ch
        parts.append(acc)
        cur.text = head + parts[0]
        at = line
        for i in range(1, len(parts)):
            at += 1
            body = parts[i]
            if i == len(parts) - 1:
                body += tail
            self.lines.insert(at, BufLine(body, False, False, 0))
        return end

    def raw_delete(self, r: Span) -> str:
        self.unfold_range(r.l0, r.l1)      # 115: the same invariant as insert's
        gone = self.range_text(r)
        if r.l0 == r.l1:
            l = self.lines[r.l0]
            l.text = l.text[0:r.c0] + l.text[r.c1:]
            return gone
        first = self.lines[r.l0]
        last = self.lines[r.l1]
        first.text = first.text[0:r.c0] + last.text[r.c1:]
        for i in range(r.l1 - r.l0):
            self.lines.remove_at(r.l0 + 1)
        return gone

    # ---------- caret adjustment ----------

    def adj_after_insert(self, skip: int, at: Span):
        for k in range(len(self.carets)):
            if k == skip:
                continue
            c = self.carets[k]
            nl = c.line
            nc = c.col
            if c.line == at.l0 and c.col >= at.c0:
                nl = at.l1
                nc = at.c1 + (c.col - at.c0)
            elif c.line > at.l0:
                nl = c.line + (at.l1 - at.l0)
            al = c.aline
            ac = c.acol
            if c.aline == at.l0 and c.acol >= at.c0:
                al = at.l1
                ac = at.c1 + (c.acol - at.c0)
            elif c.aline > at.l0:
                al = c.aline + (at.l1 - at.l0)
            self.carets[k] = Caret(nl, nc, al, ac, c.goal)

    def adj_after_delete(self, skip: int, r: Span):
        for k in range(len(self.carets)):
            if k == skip:
                continue
            c = self.carets[k]
            p = adj_del_pos(r, c.line, c.col)
            a = adj_del_pos(r, c.aline, c.acol)
            self.carets[k] = Caret(p.line, p.col, a.line, a.col, c.goal)

    def carets_sort(self):
        """Insertion sort by position, dropping duplicates — the list is tiny."""
        i = 1
        while i < len(self.carets):
            j = i
            while j > 0:
                a = self.carets[j - 1]
                b = self.carets[j]
                if a.line > b.line or (a.line == b.line and a.col > b.col):
                    self.carets[j - 1] = b
                    self.carets[j] = a
                    j -= 1
                else:
                    j = 0
            i += 1
        out: list<Caret> = []
        for c in self.carets:
            keep = True
            for d in out:
                if d.line == c.line and d.col == c.col:
                    keep = False
            if keep:
                out.append(c)
        self.carets = out

    # ---------- editing ----------

    def del_sel_at(self, k: int) -> bool:
        r = self.sel_range(k)
        if r.l0 == r.l1 and r.c0 == r.c1:
            return False
        gone = self.raw_delete(r)
        self.op_push(OP_DELETE, r.l0, r.c0, gone)
        self.carets[k] = Caret(r.l0, r.c0, r.l0, r.c0, -1)
        self.adj_after_delete(k, r)
        return True

    def insert(self, text: str, now_ms: int):
        """Inserts at every caret. A newline or a space breaks the group."""
        coalesce = not ("\n" in text) and text != " "
        self.group_begin(coalesce, now_ms)
        k = len(self.carets) - 1
        while k >= 0:
            self.del_sel_at(k)
            c = self.carets[k]
            end = self.raw_insert(c.line, c.col, text)
            self.op_push(OP_INSERT, c.line, c.col, text)
            self.carets[k] = Caret(end.l1, end.c1, end.l1, end.c1, -1)
            self.adj_after_insert(k, end)
            k -= 1
        if not coalesce:
            self.group_open = False
        self.group_end()

    def delete_sel(self, now_ms: int) -> bool:
        if not self.has_sel():
            return False
        self.group_begin(False, now_ms)
        k = len(self.carets) - 1
        while k >= 0:
            self.del_sel_at(k)
            k -= 1
        self.group_open = False
        self.group_end()
        return True

    def backspace(self, now_ms: int):
        if self.delete_sel(now_ms):
            return
        self.group_begin(True, now_ms)
        k = len(self.carets) - 1
        while k >= 0:
            c = self.carets[k]
            if c.col > 0:
                r = Span(c.line, c.col - 1, c.line, c.col)
                gone = self.raw_delete(r)
                self.op_push(OP_DELETE, r.l0, r.c0, gone)
                self.carets[k] = Caret(r.l0, r.c0, r.l0, r.c0, -1)
                self.adj_after_delete(k, r)
            elif c.line > 0:
                prev = self.line_cp(c.line - 1)
                r = Span(c.line - 1, prev, c.line, 0)
                gone = self.raw_delete(r)
                self.op_push(OP_DELETE, r.l0, r.c0, gone)
                self.carets[k] = Caret(r.l0, r.c0, r.l0, r.c0, -1)
                self.adj_after_delete(k, r)
            k -= 1
        self.group_end()

    def delete_fwd(self, now_ms: int):
        if self.delete_sel(now_ms):
            return
        self.group_begin(True, now_ms)
        k = len(self.carets) - 1
        while k >= 0:
            c = self.carets[k]
            if c.col < self.line_cp(c.line):
                r = Span(c.line, c.col, c.line, c.col + 1)
                gone = self.raw_delete(r)
                self.op_push(OP_DELETE, r.l0, r.c0, gone)
                self.adj_after_delete(k, r)
            elif c.line + 1 < len(self.lines):
                r = Span(c.line, c.col, c.line + 1, 0)
                gone = self.raw_delete(r)
                self.op_push(OP_DELETE, r.l0, r.c0, gone)
                self.adj_after_delete(k, r)
            k -= 1
        self.group_end()

    def replace_range(self, r: Span, text: str, now_ms: int):
        """Replaces a range and leaves ONE caret at the end of what was written."""
        self.group_begin(False, now_ms)
        gone = self.raw_delete(r)
        if len(gone) > 0:
            self.op_push(OP_DELETE, r.l0, r.c0, gone)
        end = self.raw_insert(r.l0, r.c0, text)
        if len(text) > 0:
            self.op_push(OP_INSERT, r.l0, r.c0, text)
        self.carets = [Caret(end.l1, end.c1, end.l1, end.c1, -1)]
        self.group_open = False
        self.group_end()

    # ---------- undo / redo ----------

    def apply_reverse(self, g: UndoGroup):
        i = len(g.ops) - 1
        while i >= 0:
            op = g.ops[i]
            if op.kind == OP_INSERT:
                end = text_end(op.line, op.col, op.text)
                self.raw_delete(Span(op.line, op.col, end.l1, end.c1))
            else:
                self.raw_insert(op.line, op.col, op.text)
            i -= 1

    def apply_forward(self, g: UndoGroup):
        for op in g.ops:
            if op.kind == OP_INSERT:
                self.raw_insert(op.line, op.col, op.text)
            else:
                end = text_end(op.line, op.col, op.text)
                self.raw_delete(Span(op.line, op.col, end.l1, end.c1))

    def undo_step(self) -> bool:
        if len(self.undo) == 0:
            return False
        g = self.undo[len(self.undo) - 1]
        self.undo.remove_at(len(self.undo) - 1)
        self.apply_reverse(g)
        self.carets = g.before
        self.redo.append(g)
        self.group_open = False
        self.dirty = True
        self.version += 1
        return True

    def redo_step(self) -> bool:
        if len(self.redo) == 0:
            return False
        g = self.redo[len(self.redo) - 1]
        self.redo.remove_at(len(self.redo) - 1)
        self.apply_forward(g)
        self.carets = g.after
        self.undo.append(g)
        self.group_open = False
        self.dirty = True
        self.version += 1
        return True

    # ---------- movement ----------

    def move_h(self, delta: int, sel: bool):
        self.break_group()
        for k in range(len(self.carets)):
            c = self.carets[k]
            line = c.line
            col = c.col
            if not sel and (c.line != c.aline or c.col != c.acol):
                r = self.sel_range(k)
                if delta < 0:
                    line = r.l0
                    col = r.c0
                else:
                    line = r.l1
                    col = r.c1
            elif delta < 0:
                if col > 0:
                    col -= 1
                elif line > 0:
                    line -= 1
                    col = self.line_cp(line)
            else:
                if col < self.line_cp(line):
                    col += 1
                elif line + 1 < len(self.lines):
                    line += 1
                    col = 0
            al = line if not sel else c.aline
            ac = col if not sel else c.acol
            self.carets[k] = Caret(line, col, al, ac, -1)
        self.carets_sort()

    def move_v(self, delta: int, sel: bool):
        self.break_group()
        for k in range(len(self.carets)):
            c = self.carets[k]
            goal = c.col if c.goal < 0 else c.goal
            line = c.line + delta
            if line < 0:
                line = 0
            if line >= len(self.lines):
                line = len(self.lines) - 1
            # a folded block is skipped over, never landed in
            while line > 0 and line < len(self.lines) and self.lines[line].hidden:
                line += 1 if delta > 0 else -1
                if line <= 0 or line >= len(self.lines):
                    break
            if line < 0:
                line = 0
            if line >= len(self.lines):
                line = len(self.lines) - 1
            col = self.clamp_col(line, goal)
            al = line if not sel else c.aline
            ac = col if not sel else c.acol
            self.carets[k] = Caret(line, col, al, ac, goal)
        self.carets_sort()

    def move_word(self, dir: int, sel: bool):
        self.break_group()
        for k in range(len(self.carets)):
            c = self.carets[k]
            line = c.line
            col = c.col
            t = self.line_text(line)
            if dir < 0:
                if col == 0 and line > 0:
                    line -= 1
                    col = self.line_cp(line)
                else:
                    while col > 0 and not is_word_ch(t[col - 1]):
                        col -= 1
                    while col > 0 and is_word_ch(t[col - 1]):
                        col -= 1
            else:
                n = len(t)
                if col >= n and line + 1 < len(self.lines):
                    line += 1
                    col = 0
                else:
                    while col < n and is_word_ch(t[col]):
                        col += 1
                    while col < n and not is_word_ch(t[col]):
                        col += 1
            al = line if not sel else c.aline
            ac = col if not sel else c.acol
            self.carets[k] = Caret(line, col, al, ac, -1)
        self.carets_sort()

    def home(self, sel: bool):
        """Smart home: the first non-blank, then column zero."""
        self.break_group()
        for k in range(len(self.carets)):
            c = self.carets[k]
            t = self.line_text(c.line)
            ind = 0
            while ind < len(t) and (t[ind] == " " or t[ind] == "\t"):
                ind += 1
            col = ind if c.col != ind else 0
            al = c.line if not sel else c.aline
            ac = col if not sel else c.acol
            self.carets[k] = Caret(c.line, col, al, ac, -1)

    def end(self, sel: bool):
        self.break_group()
        for k in range(len(self.carets)):
            c = self.carets[k]
            col = self.line_cp(c.line)
            al = c.line if not sel else c.aline
            ac = col if not sel else c.acol
            self.carets[k] = Caret(c.line, col, al, ac, -1)

    def move_to(self, line: int, col: int):
        self.break_group()
        l = 0 if line < 0 else (len(self.lines) - 1 if line >= len(self.lines) else line)
        c = self.clamp_col(l, col)
        self.carets = [Caret(l, c, l, c, -1)]

    def select_range(self, r: Span):
        self.break_group()
        self.carets = [Caret(r.l1, r.c1, r.l0, r.c0, -1)]

    def select_all(self):
        last = len(self.lines) - 1
        self.select_range(Span(0, 0, last, self.line_cp(last)))

    def collapse(self):
        """Back to one caret, no selection — what Escape does."""
        self.break_group()
        c = self.carets[0]
        self.carets = [Caret(c.line, c.col, c.line, c.col, -1)]

    def add_caret(self, line: int, col: int):
        self.break_group()
        l = 0 if line < 0 else (len(self.lines) - 1 if line >= len(self.lines) else line)
        c = self.clamp_col(l, col)
        self.carets.append(Caret(l, c, l, c, -1))
        self.carets_sort()

    def select_word_at(self, k: int) -> bool:
        c = self.carets[k]
        t = self.line_text(c.line)
        if len(t) == 0:
            return False
        s = c.col
        if s >= len(t):
            s = len(t) - 1
        if not is_word_ch(t[s]):
            return False
        a = s
        while a > 0 and is_word_ch(t[a - 1]):
            a -= 1
        b = s
        while b < len(t) and is_word_ch(t[b]):
            b += 1
        self.carets[k] = Caret(c.line, b, c.line, a, -1)
        return True

    def ctrl_d(self) -> bool:
        """Selects the word, then each next occurrence — one caret per hit."""
        k = len(self.carets) - 1
        if not self.has_sel():
            return self.select_word_at(k)
        needle = self.sel_text(k)
        if len(needle) == 0:
            return False
        c = self.carets[k]
        hit = self.find(needle, c.line, c.col, True)
        if hit == None:
            return False
        # after the guard, `hit` IS a Span (114): the `?? Span(0,0,0,0)` that
        # used to be here existed only because the proof did not survive the `if`
        self.carets.append(Caret(hit.l1, hit.c1, hit.l0, hit.c0, -1))
        self.carets_sort()
        return True

    # ---------- search ----------

    def find(self, needle: str, from_line: int, from_col: int, wrap: bool) -> Span?:
        """The first hit at or after (from_line, from_col). None when there is none."""
        if len(needle) == 0:
            return None
        n = len(self.lines)
        for step in range(n + 1):
            l = from_line + step
            if l >= n:
                if not wrap:
                    return None
                l = l - n
                if l > from_line:
                    return None
            t = self.lines[l].text
            start = from_col if step == 0 else 0
            # `find` and not a column-by-column compare: the loop that was here
            # allocated one slice PER COLUMN — half a million of them to scan an
            # 11 000-line file, which is 50 ms where a native scan takes one
            k = (t[start:].find(needle) if start > 0 else t.find(needle))
            if k >= 0:
                col = start + k
                return Span(l, col, l, col + len(needle))
        return None

    def find_all(self, needle: str) -> list<Span>:
        out: list<Span> = []
        if len(needle) == 0:
            return out
        for l in range(len(self.lines)):
            t = self.lines[l].text
            col = 0
            # the same native scan as `find`, walked forward hit by hit
            while col <= len(t) - len(needle):
                k = (t[col:].find(needle) if col > 0 else t.find(needle))
                if k < 0:
                    break
                col += k
                out.append(Span(l, col, l, col + len(needle)))
                col += len(needle)
        return out

    def replace_all(self, needle: str, with_text: str, now_ms: int) -> int:
        """Replaces every hit, back to front so earlier offsets stay valid."""
        hits = self.find_all(needle)
        if len(hits) == 0:
            return 0
        self.group_begin(False, now_ms)
        i = len(hits) - 1
        while i >= 0:
            r = hits[i]
            gone = self.raw_delete(r)
            self.op_push(OP_DELETE, r.l0, r.c0, gone)
            self.raw_insert(r.l0, r.c0, with_text)
            self.op_push(OP_INSERT, r.l0, r.c0, with_text)
            i -= 1
        self.carets = [Caret(0, 0, 0, 0, -1)]
        self.group_open = False
        self.group_end()
        return len(hits)

    # ---------- whole-line commands ----------

    def line_span(self) -> list<Span>:
        """The blocks of whole lines the carets cover, merged when they touch.

        One block per caret, in order — and two that meet or are neighbours
        become one, so a command that moves lines never moves the same line
        twice.
        """
        out: list<Span> = []
        for k in range(len(self.carets)):
            c = self.carets[k]
            lo = c.line if c.line < c.aline else c.aline
            hi = c.line if c.line > c.aline else c.aline
            if len(out) > 0 and out[len(out) - 1].l1 >= lo - 1:
                prev = out[len(out) - 1]
                out[len(out) - 1] = Span(prev.l0, 0, hi if hi > prev.l1 else prev.l1, 0)
            else:
                out.append(Span(lo, 0, hi, 0))
        return out

    def duplicate_lines(self, now_ms: int):
        self.group_begin(False, now_ms)
        blocks = self.line_span()
        i = len(blocks) - 1
        while i >= 0:
            b = blocks[i]
            body = ""
            for l in range(b.l0, b.l1 + 1):
                body += self.lines[l].text + "\n"
            at = b.l1 + 1
            if at >= len(self.lines):
                self.raw_insert(b.l1, self.line_cp(b.l1), "\n" + body[0:len(body) - 1])
                self.op_push(OP_INSERT, b.l1, self.line_cp(b.l1), "\n" + body[0:len(body) - 1])
            else:
                self.raw_insert(at, 0, body)
                self.op_push(OP_INSERT, at, 0, body)
            i -= 1
        self.group_open = False
        self.group_end()

    def delete_lines(self, now_ms: int):
        self.group_begin(False, now_ms)
        blocks = self.line_span()
        i = len(blocks) - 1
        while i >= 0:
            b = blocks[i]
            if b.l1 + 1 < len(self.lines):
                r = Span(b.l0, 0, b.l1 + 1, 0)
                gone = self.raw_delete(r)
                self.op_push(OP_DELETE, r.l0, r.c0, gone)
            else:
                start = 0 if b.l0 == 0 else b.l0 - 1
                c0 = 0 if b.l0 == 0 else self.line_cp(start)
                r = Span(start, c0, b.l1, self.line_cp(b.l1))
                gone = self.raw_delete(r)
                self.op_push(OP_DELETE, r.l0, r.c0, gone)
            i -= 1
        self.carets = [Caret(0, 0, 0, 0, -1)]
        for k in range(len(self.carets)):
            c = self.carets[k]
            l = c.line if c.line < len(self.lines) else len(self.lines) - 1
            self.carets[k] = Caret(l, self.clamp_col(l, c.col), l, self.clamp_col(l, c.col), -1)
        self.group_open = False
        self.group_end()

    def toggle_comment(self, marker: str, now_ms: int):
        """Comments the block, or uncomments it when every line already is."""
        self.group_begin(False, now_ms)
        blocks = self.line_span()
        for b in blocks:
            all_commented = True
            for probe in range(b.l0, b.l1 + 1):
                t = self.lines[probe].text
                i = 0
                while i < len(t) and (t[i] == " " or t[i] == "\t"):
                    i += 1
                if len(t) == 0 or t[i:i + len(marker)] != marker:
                    all_commented = False
            l = b.l1
            while l >= b.l0:
                t = self.lines[l].text
                i = 0
                while i < len(t) and (t[i] == " " or t[i] == "\t"):
                    i += 1
                if all_commented:
                    cut = len(marker)
                    if i + cut < len(t) and t[i + cut] == " ":
                        cut += 1
                    r = Span(l, i, l, i + cut)
                    gone = self.raw_delete(r)
                    self.op_push(OP_DELETE, r.l0, r.c0, gone)
                elif len(t) > 0:
                    self.raw_insert(l, i, marker + " ")
                    self.op_push(OP_INSERT, l, i, marker + " ")
                l -= 1
        self.group_open = False
        self.group_end()

    def indent(self, dir: int, now_ms: int):
        """Shifts the block by one TAB_WIDTH of spaces (soft tabs)."""
        pad = ""
        for i in range(TAB_WIDTH):
            pad += " "
        self.group_begin(False, now_ms)
        for b in self.line_span():
            l = b.l1
            while l >= b.l0:
                t = self.lines[l].text
                if dir > 0:
                    if len(t) > 0:
                        self.raw_insert(l, 0, pad)
                        self.op_push(OP_INSERT, l, 0, pad)
                else:
                    cut = 0
                    while cut < TAB_WIDTH and cut < len(t) and t[cut] == " ":
                        cut += 1
                    if cut > 0:
                        r = Span(l, 0, l, cut)
                        gone = self.raw_delete(r)
                        self.op_push(OP_DELETE, r.l0, r.c0, gone)
                l -= 1
        self.group_open = False
        self.group_end()

    # ---------- folding and marks ----------

    def indent_of(self, line: int) -> int:
        t = self.line_text(line)
        n = 0
        while n < len(t) and (t[n] == " " or t[n] == "\t"):
            n += 1
        return n if n < len(t) else -1      # a blank line has no indent

    def can_fold(self, line: int) -> bool:
        base = self.indent_of(line)
        if base < 0:
            return False
        l = line + 1
        while l < len(self.lines):
            ind = self.indent_of(l)
            if ind >= 0:
                return ind > base
            l += 1
        return False

    def fold_end(self, line: int) -> int:
        base = self.indent_of(line)
        last = line
        l = line + 1
        while l < len(self.lines):
            ind = self.indent_of(l)
            if ind >= 0:
                if ind <= base:
                    return last
                last = l
            l += 1
        return last

    def fold(self, line: int) -> bool:
        if not self.can_fold(line) or self.lines[line].folded:
            return False
        last = self.fold_end(line)
        self.lines[line].folded = True
        for l in range(line + 1, last + 1):
            self.lines[l].hidden = True
        self.version += 1
        return True

    def unfold(self, line: int) -> bool:
        if not self.lines[line].folded:
            return False
        last = self.fold_end(line)
        self.lines[line].folded = False
        for l in range(line + 1, last + 1):
            self.lines[l].hidden = False
        self.version += 1
        return True

    def toggle_fold(self, line: int) -> bool:
        return self.unfold(line) if self.lines[line].folded else self.fold(line)

    def is_hidden(self, line: int) -> bool:
        return self.lines[line].hidden

    def is_folded(self, line: int) -> bool:
        return self.lines[line].folded

    def mark_of(self, line: int) -> int:
        return self.lines[line].mark

    def toggle_mark(self, line: int, mark: int):
        l = self.lines[line]
        l.mark = l.mark ^ mark
        self.version += 1

    def clear_marks(self, mark: int):
        for l in self.lines:
            l.mark = l.mark & ~mark
        self.version += 1

    def next_mark(self, from_line: int, mark: int, forward: bool) -> int:
        """The next marked line, wrapping around. -1 = there is none."""
        n = len(self.lines)
        for step in range(1, n + 1):
            i = (from_line + step) % n if forward else (from_line - step + n * 2) % n
            if (self.lines[i].mark & mark) != 0:
                return i
        return -1

    def is_blank(self, line: int) -> bool:
        return len(self.lines[line].text.strip()) == 0

    def fold_all(self):
        for i in range(len(self.lines)):
            if self.can_fold(i):
                self.fold(i)      # `can_fold` is false on a hidden line: level 1

    def unfold_enclosing(self, line: int) -> bool:
        """Releases the fold that HIDES this line. An orphan line (hidden with no
        header above it) is revealed — an invisible line is never left behind."""
        if line < 0 or line >= len(self.lines) or not self.lines[line].hidden:
            return False
        h = line - 1
        while h >= 0:
            if self.lines[h].folded:
                self.unfold(h)
                return True
            h -= 1
        self.lines[line].hidden = False
        return True

    def unfold_range(self, l0: int, l1: int):
        """115: an edit that REACHES a collapsed block releases it. Undo/redo
        reaches (undoing may rewrite hidden lines), and without this there were
        lines with new content the view never showed. It was the one fold
        invariant the port had left behind."""
        a = l0 if l0 > 0 else 0
        b = l1 if l1 < len(self.lines) - 1 else len(self.lines) - 1
        for i in range(a, b + 1):
            if self.lines[i].folded:
                self.unfold(i)
        guard = 0
        while guard < 64:
            hit = False
            for i in range(a, b + 1):
                if self.lines[i].hidden:
                    self.unfold_enclosing(i)
                    hit = True
                    break
            if not hit:
                return
            guard += 1

    def unfold_all(self):
        for l in self.lines:
            l.hidden = False
            l.folded = False
        self.version += 1

    # ---------- the map of VISIBLE lines ----------
    # A fold shortens the document, and every screen coordinate goes through
    # here: the scrollbar, the wheel and the click all think in SCREEN LINES.

    def visible_count(self) -> int:
        n = 0
        for l in self.lines:
            if not l.hidden:
                n += 1
        return n

    def next_visible(self, line: int, delta: int) -> int:
        l = 0 if line < 0 else (len(self.lines) - 1 if line >= len(self.lines) else line)
        if delta > 0:
            for step in range(delta):
                i = l + 1
                while i < len(self.lines) and self.lines[i].hidden:
                    i += 1
                if i >= len(self.lines):
                    break
                l = i
        elif delta < 0:
            for step in range(-delta):
                j = l - 1
                while j >= 0 and self.lines[j].hidden:
                    j -= 1
                if j < 0:
                    break
                l = j
        while l > 0 and self.lines[l].hidden:
            l -= 1        # the starting line itself may have been folded
        return l

    def to_visible(self, line: int) -> int:
        n = 0
        top = line if line < len(self.lines) else len(self.lines)
        for i in range(top):
            if not self.lines[i].hidden:
                n += 1
        return n

    def from_visible(self, vidx: int) -> int:
        n = 0
        for i in range(len(self.lines)):
            if self.lines[i].hidden:
                continue
            if n >= vidx:
                return i
            n += 1
        return len(self.lines) - 1

    def visible_at_or_before(self, line: int) -> int:
        """After a fold: the nearest visible line WALKING BACKWARDS. Walking
        forwards (which is what `from_visible(to_visible(l))` does) would land
        after the block and take the view away from the fold just closed."""
        i = line if line < len(self.lines) else len(self.lines) - 1
        # line 0 is never hidden: a fold hides what COMES AFTER it
        while i > 0 and self.lines[i].hidden:
            i -= 1
        return i if i > 0 else 0

    # ---------- the line commands that were missing ----------

    def insert_each(self, texts: list<str>, now_ms: int):
        """N pieces for N cursors (Sublime's model). From the bottom up, so the
        positions not yet used stay valid."""
        if len(texts) != len(self.carets):
            return
        self.group_begin(False, now_ms)
        k = len(self.carets) - 1
        while k >= 0:
            c = self.carets[k]
            self.raw_insert(c.line, c.col, texts[k])
            self.op_push(OP_INSERT, c.line, c.col, texts[k])
            e = text_end(c.line, c.col, texts[k])
            self.carets[k] = Caret(e.l1, e.c1, e.l1, e.c1, -1)
            self.adj_after_insert(k, Span(c.line, c.col, e.l1, e.c1))
            k -= 1
        self.group_open = False
        self.group_end()

    def move_lines(self, dir: int, now_ms: int):
        """Moves the cursors' blocks up or down. Nothing moves if a block would
        fall outside the file — and the cursor goes WITH the text."""
        blocks = self.line_span()
        for b in blocks:
            if dir < 0 and b.l0 == 0:
                return
            if dir > 0 and b.l1 >= len(self.lines) - 1:
                return
        self.group_begin(False, now_ms)
        i = len(blocks) - 1
        while i >= 0:
            b = blocks[i]
            if dir < 0:
                # the line above moves to after the block
                r = Span(b.l0 - 1, 0, b.l0, 0)
                gone = self.raw_delete(r)
                self.op_push(OP_DELETE, r.l0, r.c0, gone)
                at = b.l1
                if at >= len(self.lines):
                    self.raw_insert(b.l1 - 1, self.line_cp(b.l1 - 1), "\n" + gone[0:len(gone) - 1])
                    self.op_push(OP_INSERT, b.l1 - 1, self.line_cp(b.l1 - 1), "\n" + gone[0:len(gone) - 1])
                else:
                    self.raw_insert(at, 0, gone)
                    self.op_push(OP_INSERT, at, 0, gone)
            else:
                # the line below moves to before the block. `nonlocal` because
                # the value is born inside both branches and used after them —
                # the scope is the BLOCK's in both languages (64.1)
                nonlocal gone2
                nxt = b.l1 + 1
                if nxt + 1 < len(self.lines):
                    r2 = Span(nxt, 0, nxt + 1, 0)
                    gone2 = self.raw_delete(r2)
                    self.op_push(OP_DELETE, r2.l0, r2.c0, gone2)
                else:
                    r2 = Span(nxt - 1, self.line_cp(nxt - 1), nxt, self.line_cp(nxt))
                    cut = self.raw_delete(r2)
                    self.op_push(OP_DELETE, r2.l0, r2.c0, cut)
                    gone2 = cut[1:len(cut)] + "\n"
                self.raw_insert(b.l0, 0, gone2)
                self.op_push(OP_INSERT, b.l0, 0, gone2)
            i -= 1
        for k in range(len(self.carets)):
            c = self.carets[k]
            self.carets[k] = Caret(c.line + dir, c.col, c.aline + dir, c.acol, -1)
        self.carets_sort()
        self.group_open = False
        self.group_end()

    def join_lines(self, now_ms: int):
        """Joins the next line to the cursor's, with ONE space between them —
        except when one of the sides is empty or the line already ends in a
        space (Sublime's ctrl+j)."""
        self.group_begin(False, now_ms)
        k = len(self.carets) - 1
        while k >= 0:
            c = self.carets[k]
            l = c.line
            if l + 1 < len(self.lines):
                nx = self.lines[l + 1].text
                ind = len(nx) - len(nx.lstrip())
                endc = self.line_cp(l)
                cur = self.lines[l].text
                glue = " "
                if endc == 0 or len(nx.strip()) == 0:
                    glue = ""
                elif cur.endswith(" ") or cur.endswith("\t"):
                    glue = ""
                r = Span(l, endc, l + 1, ind)
                gone = self.raw_delete(r)
                self.op_push(OP_DELETE, r.l0, r.c0, gone)
                if len(glue) > 0:
                    self.raw_insert(l, endc, glue)
                    self.op_push(OP_INSERT, l, endc, glue)
                self.carets[k] = Caret(l, endc, l, endc, -1)
            k -= 1
        self.group_open = False
        self.group_end()

    def find_re(self, pattern: str, from_line: int, from_col: int, forward: bool) -> Span?:
        """Regular expression search (POSIX's ERE, which is pscript's `re` —
        41.2). Line by line, because an editor's pattern does not cross the
        line break."""
        n = len(self.lines)
        for step in range(n):
            l = (from_line + step) % n if forward else (from_line - step + n * 2) % n
            s = self.lines[l].text
            base = 0
            if step == 0:
                if forward:
                    base = from_col
                    if base > len(s):
                        continue
                    s = s[base:len(s)]
                else:
                    if from_col <= 0:
                        continue
                    s = s[0:from_col]
            m = re.match(pattern, s)
            # the non-null proof holds INSIDE the branch (43.1): a `continue` in
            # the None branch does not narrow what comes after it
            if m != None:
                hit = m[0]
                if len(hit) > 0:
                    at = s.find(hit)
                    return Span(l, base + at, l, base + at + len(hit))
        return None


def new_buffer() -> Buffer:
    """An empty buffer: one line, one caret — never zero of either."""
    b = Buffer([], [], [], [], False, 0, False, False, 0)
    b.load("")
    return b
