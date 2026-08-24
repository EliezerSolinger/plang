"""Highlighting, in pscript, with THE COMPILER's lexer on the other side of the boundary.

113: the `hl.p` adapter lexes and answers in numbers (see `hl.ph`); everything
that is a DECISION lives here — which classes get painted, what a comment is,
how a span becomes a colour in the column. It is the same division as the
`shim`'s: the hand that touches the pointer stays in P, the logic stays here.

Two things the adapter does NOT say, and why they are not missed:

  * a token's TEXT. Whoever needs an identifier's name slices their own text by
    (line, column, length) — the buffer is already here, and that way no string
    crosses back;
  * the COMMENT. The compiler's lexer eats comments (they are not tokens), so
    the editor in P already looked for the `#` by hand. It is still by hand, but
    here: it is the one highlighting rule that is not the lexer's, and it needs
    to know which spans are strings — which is information that is already in
    this layer.
"""
import "hl.ph"

import lib_core as core


# the classes the editor paints. HL_TEXT is "nothing special" and becomes no span.
const HL_TEXT: int = 0
const HL_KW: int = 1
const HL_STR: int = 2
const HL_NUM: int = 3
const HL_COMMENT: int = 4


record HlSpan:
    col: int          # the first codepoint
    length: int       # length in codepoints
    cls: int


struct Hl:
    lines: list<list<HlSpan>>   # one per buffer line
    version: int                # the buffer version this came out of
    enabled: bool               # False = not a P file (no spans at all)

    def class_at(self, line: int, col: int) -> int:
        if not self.enabled or line < 0 or line >= len(self.lines):
            return HL_TEXT
        for sp in self.lines[line]:
            if col >= sp.col and col < sp.col + sp.length:
                return sp.cls
        return HL_TEXT

    def add(self, line: int, col: int, length: int, cls: int):
        if line >= 0 and line < len(self.lines) and length > 0:
            self.lines[line].append(HlSpan(col, length, cls))

    def update(self, b: core.Buffer):
        """Relexes the WHOLE file when the buffer's version changed.

        It is what the editor in P does, and it is called once per FRAME (from
        `build`) rather than once per edit — several edits between two frames
        cost one relex, and only the last one of them was going to be seen.

        On the biggest file in this repository (11 076 lines) the whole thing is
        under 16 ms, and where it goes is worth knowing before anybody makes it
        incremental: about 9 ms is the compiler's lexer itself, and the rest is
        the spans. It used to be 78 ms, and 35 of those were walking the
        codepoints of every line looking for a `#`."""
        if self.version == b.version and len(self.lines) == b.nlines():
            return
        # REUSE the per-line lists when the line count did not change, which is
        # the common case (typing inside a line). Rebuilding them allocated one
        # list per line on every keystroke — eleven thousand of them on a big
        # file, and the collector paid for all of it.
        if len(self.lines) == b.nlines():
            for l in self.lines:
                l.clear()
        else:
            self.lines = []
            for i in range(b.nlines()):
                self.lines.append([])
        self.version = b.version
        if not self.enabled:
            return
        n = hl_lex(b.text())
        for i in range(n):
            cls = hl_tok_class(i)
            # an identifier is not a span (it is ordinary text) and punctuation
            # is not painted — both stay out, as in the editor in P
            if cls == HLC_TEXT or cls == HLC_PUNCT:
                continue
            mine = HL_KW
            if cls == HLC_STR:
                mine = HL_STR
            elif cls == HLC_NUM:
                mine = HL_NUM
            self.add(hl_tok_line(i), hl_tok_col(i), hl_tok_cp(i), mine)
        # the comment: the first `#` OUTSIDE a string runs to the end of the line
        for ln in range(b.nlines()):
            s = b.line_text(ln)
            # asking "is there a `#` at all" in one go is a scan in C; walking the
            # codepoints of EVERY line was 35 of the 48 ms that one keystroke cost
            # on an 11 000-line file, and nine lines in ten have no `#`
            if "#" not in s:
                continue
            col = 0
            for ch in s:
                if ch == "#":
                    inside = False
                    for sp in self.lines[ln]:
                        if sp.cls == HL_STR and col >= sp.col and col < sp.col + sp.length:
                            inside = True
                            break
                    if not inside:
                        self.add(ln, col, len(s) - col, HL_COMMENT)
                        break
                col += 1


def new_hl(enabled: bool) -> Hl:
    return Hl([], 0, enabled)


def is_p_file(path: str) -> bool:
    """Highlighting is for P and pscript — other files open with no spans at
    all, which is what `enabled=False` means."""
    for ext in [".p", ".ph", ".psc", ".psh"]:
        if path.endswith(ext):
            return True
    return False
