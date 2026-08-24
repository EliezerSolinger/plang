"""The completion index, in pscript (a port of `pstudio/complete.p`).

It builds itself with THE COMPILER's LEXER, through 113's adapter — which is
what makes it work on a half-typed buffer: these are real tokens, so a string, a
comment or a number never enters as a candidate. From the token stream it
recovers declarations (`def f(...)`, `struct S:` and its members, `x: T`) and,
for the `x.` case, the TYPE of a variable — which is what turns "words in the
file" into member completion.

What it is NOT: a type checker. Typing a whole expression needs a tolerant
parser plus sema over the buffer; when that exists, it comes in behind the same
door.

**One difference from the port, and it is about LAYERING:** in P, `build` read
the `.ph` files the buffer imports itself, with `psys`. Here it does no I/O —
`imports_of` SAYS which files they are, and whoever has the event loop (which is
whoever can wait) reads them and passes the texts in `extra`. The index stops
having an opinion about files, and stays SYNCHRONOUS: `codeview` calls it
without being `async`.
"""
import "hl.ph"

import core


enum SymKind:
    SYM_KEYWORD       # the language's own words
    SYM_WORD          # an identifier seen in the file (Sublime's baseline)
    SYM_TYPE          # struct / enum / union
    SYM_FUNC          # `def` at file scope
    SYM_MEMBER        # a struct's field or method


struct CSym:
    name: str         # what goes into the text
    detail: str       # shown dimmed on the right (signature, type); "" = nothing
    owner: str        # SYM_MEMBER: the struct it belongs to; "" = none
    kind: SymKind
    # F5: WHERE it was declared. It costs two fields and it is the whole of
    # go-to-definition — the scan already walked past the position and threw it
    # away, which is why the feature looked expensive and was not.
    file: str         # "" = the buffer being edited
    line: int         # 1-based, like every position in this project


struct Source:
    """A file the index was given to read besides the open buffer.

    `extra` was a `list<str>` from the first day, documented as "the texts that
    came with it", and always empty. It is a list of these now, because a text
    without its path cannot answer "where is this defined"."""
    path: str
    text: str


# `struct` and not `record`: a record only holds numbers (58.2), and these two
# fields are strings — which are heap references
struct CVar:
    name: str
    type_name: str


# the language's own words: always offered, and ranked last. A `const` string
# and not a list, because an IMPORTED module is a set of definitions and not a
# program — it has nowhere to run a list literal (the `split` happens at the
# call, once per index built).
const KEYWORDS: str = "def return if elif else while for in do match case break continue goto const struct enum union import include and or not True False None private static lambda inline extern volatile restrict defer with out ref is pass global nonlocal declare implement sizeof range i8 i16 i32 i64 u8 u16 u32 u64 f32 f64 bool char void usize isize"


# a token's text: sliced out of the file itself by position, because a string
# does not come back across the boundary (113) — the buffer is already on this side
def tok_text(lines: list<str>, i: int) -> str:
    ln = hl_tok_line(i)
    if ln < 0 or ln >= len(lines):
        return ""
    s = lines[ln]
    c0 = hl_tok_col(i)
    c1 = c0 + hl_tok_cp(i)
    if c0 < 0 or c0 > len(s):
        return ""
    return s[c0:c1 if c1 < len(s) else len(s)]


# The NAME of the type a declaration binds to, from the token after the `:`. It
# steps over `const` and the stars: in this code nearly every variable is
# `x: *Type`, and stopping at the `*` made member completion resolve nothing.
def decl_type_name(lines: list<str>, n: int, at: int) -> str:
    i = at
    while i < n and (hl_tok_kind(i) == HLK_STAR or hl_tok_kind(i) == HLK_CONST):
        i += 1
    if i < n and hl_tok_kind(i) == HLK_IDENT:
        return tok_text(lines, i)
    return ""


struct Index:
    syms: list<CSym>
    vars: list<CVar>
    version: int      # the buffer version this came out of
    ready: bool
    cur_file: str     # which file `scan` is walking right now ("" = the buffer)
    cur_line: int     #   ... and which line the declaration it is adding is on

    def is_stale(self, b: core.Buffer) -> bool:
        return not self.ready or self.version != b.version

    def sym(self, i: int) -> CSym:
        return self.syms[i]

    def has(self, name: str, owner: str) -> bool:
        for s in self.syms:
            if s.name == name and s.owner == owner:
                return True
        return False

    def add(self, name: str, detail: str, owner: str, kind: SymKind):
        """A real DECLARATION replaces a loose word.

        The buffer is scanned first and with `words` on, so every identifier in
        it becomes a `SYM_WORD` — including the ones that are uses of something
        declared elsewhere. `has` matched on (name, owner) and ignored the kind,
        so that word shadowed the declaration arriving afterwards from another
        file, and go-to-definition answered "I do not know" about a symbol it was
        holding. Nothing noticed while `extra` was always empty."""
        if len(name) == 0:
            return
        for i in range(len(self.syms)):
            sy = self.syms[i]
            if sy.name == name and sy.owner == owner:
                if sy.kind == SYM_WORD and kind != SYM_WORD:
                    self.syms[i] = CSym(name, detail, owner, kind, self.cur_file, self.cur_line)
                return
        self.syms.append(CSym(name, detail, owner, kind, self.cur_file, self.cur_line))

    def scan(self, text: str, words: bool) -> list<str>:
        """Walks ONE file's token stream. `words` = also collect loose
        identifiers (only for the buffer being edited; an import contributes only
        its declarations). Returns the imports it saw."""
        imports: list<str> = []
        lines = text.split("\n")
        n = hl_lex(text)
        cur_struct = ""     # the struct in whose body we are
        depth = 0           # INDENT depth since that header
        paren = 0           # inside a parameter list?
        i = 0
        while i < n:
            k = hl_tok_kind(i)
            # "first token of its line" is asked of the POSITIONS, not of NEWLINE
            # tokens: an unclosed '(' suppresses those (implicit continuation),
            # and a half-typed buffer is full of them.
            pv = i - 1
            while pv >= 0:
                pk = hl_tok_kind(pv)
                if pk != HLK_NEWLINE and pk != HLK_INDENT and pk != HLK_DEDENT:
                    break
                pv -= 1
            line_start = pv < 0 or hl_tok_line(pv) != hl_tok_line(i)
            if k == HLK_INDENT:
                if len(cur_struct) > 0:
                    depth += 1
                i += 1
                continue
            if k == HLK_DEDENT:
                if len(cur_struct) > 0:
                    depth -= 1
                    if depth <= 0:
                        cur_struct = ""
                i += 1
                continue
            if k == HLK_NEWLINE:
                i += 1
                continue
            if k == HLK_IMPORT:
                if i + 1 < n and hl_tok_kind(i + 1) == HLK_STRING:
                    q = tok_text(lines, i + 1)             # "x.ph" with the quotes
                    if len(q) > 2:
                        imports.append(q[1:len(q) - 1])
            elif k == HLK_DEF:
                if i + 1 < n and hl_tok_kind(i + 1) == HLK_IDENT:
                    sig = lines[hl_tok_line(i + 1)].strip() if hl_tok_line(i + 1) < len(lines) else ""
                    if len(cur_struct) > 0:
                        self.cur_line = hl_tok_line(i) + 1
                        self.add(tok_text(lines, i + 1), sig, cur_struct, SYM_MEMBER)
                    else:
                        self.cur_line = hl_tok_line(i) + 1
                        self.add(tok_text(lines, i + 1), sig, "", SYM_FUNC)
                    i += 1        # the name is already in: it does not also enter as a word
            elif k == HLK_STRUCT or k == HLK_UNION or k == HLK_ENUM:
                if i + 1 < n and hl_tok_kind(i + 1) == HLK_IDENT:
                    self.cur_line = hl_tok_line(i) + 1
                    self.add(tok_text(lines, i + 1), "", "", SYM_TYPE)
                    cur_struct = tok_text(lines, i + 1)
                    depth = 0
                    i += 1
            elif k == HLK_LPAREN:
                paren += 1
            elif k == HLK_RPAREN:
                if paren > 0:
                    paren -= 1
            elif k == HLK_IDENT:
                # a parameter is a declaration too: `def f(p: Point)` is what
                # makes `p.` work inside the body
                if paren > 0 and i + 2 < n and hl_tok_kind(i + 1) == HLK_COLON:
                    ptn = decl_type_name(lines, n, i + 2)
                    if len(ptn) > 0:
                        self.vars.append(CVar(tok_text(lines, i), ptn))
                # `name: Type` — a field inside a struct, a variable outside
                if line_start and i + 2 < n and hl_tok_kind(i + 1) == HLK_COLON:
                    tyname = decl_type_name(lines, n, i + 2)
                    if len(cur_struct) > 0:
                        d = lines[hl_tok_line(i)].strip() if hl_tok_line(i) < len(lines) else ""
                        self.cur_line = hl_tok_line(i) + 1
                        self.add(tok_text(lines, i), d, cur_struct, SYM_MEMBER)
                    elif len(tyname) > 0:
                        self.vars.append(CVar(tok_text(lines, i), tyname))
                if words:
                    self.add(tok_text(lines, i), "", "", SYM_WORD)
            i += 1
        return imports

    def imports_of(self, b: core.Buffer) -> list<str>:
        """The `.ph` files the buffer imports, without indexing anything — for
        whoever CAN read files (the event loop) to fetch the texts."""
        probe = Index([], [], 0, False, "", 0)
        return probe.scan(b.text(), False)

    def build(self, b: core.Buffer, extra: list<Source>):
        """Builds from the buffer and from whatever files came with it."""
        self.syms = []
        self.vars = []
        self.cur_file = ""
        self.cur_line = 0
        for kw in KEYWORDS.split(" "):
            self.add(kw, "", "", SYM_KEYWORD)
        self.scan(b.text(), True)
        for src in extra:
            self.cur_file = src.path
            self.scan(src.text, False)
        self.cur_file = ""
        self.version = b.version
        self.ready = True

    def define_of(self, name: str) -> str:
        """`path:line:1` for a name, or "" when this index has not seen it.

        A declaration and not a use: the scan only records what `def`, `struct`,
        `enum` and a member introduce, which is exactly the question."""
        for sy in self.syms:
            if sy.name == name and sy.kind != SYM_KEYWORD and sy.kind != SYM_WORD:
                if len(sy.file) == 0 or sy.line <= 0:
                    return ""
                return sy.file + ":" + str(sy.line) + ":1"
        return ""

    def define_in_buffer(self, name: str) -> int:
        """The line, when the declaration is in the buffer being edited. 0 = no."""
        for sy in self.syms:
            if sy.name == name and sy.kind != SYM_KEYWORD and sy.kind != SYM_WORD:
                if len(sy.file) == 0 and sy.line > 0:
                    return sy.line
                return 0
        return 0

    def owner_of(self, expr: str) -> str:
        """The struct whose members `expr` exposes: a variable's declared type,
        or the name itself when it ALREADY is a type. "" = I do not know."""
        for v in self.vars:
            if v.name == expr:
                return v.type_name
        for s in self.syms:
            if s.kind == SYM_TYPE and s.name == expr:
                return s.name
        return ""

    def rank(self, i: int, prefix: str) -> int:
        """Higher is better: exact case, a declaration before a loose word, and a
        shorter name (the closest to what was meant)."""
        s = self.syms[i]
        r = 60
        match s.kind:
            case SYM_MEMBER:
                r = 400
            case SYM_FUNC:
                r = 300
            case SYM_TYPE:
                r = 250
            case SYM_WORD:
                r = 120
            case _:
                r = 60
        if s.name.startswith(prefix):
            r += 50                      # the same case that was typed
        return r - len(s.name) // 2

    def query(self, prefix: str, owner: str) -> list<int>:
        """Indices in `syms` that complete `prefix`, best first. A non-empty
        `owner` restricts to that struct's members (the `x.` case)."""
        hits: list<int> = []
        pl = len(prefix)
        low = prefix.lower()
        for i in range(len(self.syms)):
            s = self.syms[i]
            if len(owner) > 0:
                if s.kind != SYM_MEMBER or s.owner != owner:
                    continue
            elif s.kind == SYM_MEMBER:
                continue                 # a member only after `.`/`->`
            if pl > 0 and not s.name.lower().startswith(low):
                continue
            if pl > 0 and len(s.name) == pl:
                continue                 # already typed in full
            hits.append(i)
        # insertion sort (the lists are short)
        for i in range(1, len(hits)):
            v = hits[i]
            rv = self.rank(v, prefix)
            k = i
            while k > 0 and self.rank(hits[k - 1], prefix) < rv:
                hits[k] = hits[k - 1]
                k -= 1
            hits[k] = v
        return hits


def new_index() -> Index:
    return Index([], [], 0, False, "", 0)
