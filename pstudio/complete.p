# complete.p — the completion index (see complete.ph)
include <stdio.h>
include <stdlib.h>
include <string.h>
import "complete.ph"
import "psys.ph"
import "../selfhost/lexer.ph"

implement Vec<CSym>
implement Vec<CVar>
implement Vec<i32>

MAX_IMPORTS: const i32 = 32      # how many .ph files one buffer pulls in

# the language's own words: always offered, ranked last. `static` keeps the
# table TU-local — the compiler's lexer has a `keywords` of its own and the
# editor links against it.
static keywords: const *char[] = {
    "def", "return", "if", "elif", "else", "while", "for", "in", "do",
    "match", "case", "break", "continue", "goto", "const", "struct", "enum",
    "union", "import", "include", "and", "or", "not", "True", "False", "None",
    "static", "inline", "extern", "volatile", "restrict", "defer", "with",
    "out", "ref", "is", "pass", "global", "nonlocal", "declare", "implement",
    "sizeof", "range", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64",
    "f32", "f64", "bool", "char", "void", "usize", "isize", None}

# the arena the tolerant lexer filled (its blocks are plain malloc)
static def arena_drop_c(a: *Arena):
    blk: *ArenaBlock = a->head
    while blk != None:
        nx: *ArenaBlock = blk->next
        free(blk)
        blk = nx
    a->head = None

static def own(s: const *char) -> *char:
    r: *char = malloc(strlen(s) + 1)
    strcpy(r, s)
    return r

# the source line `n` (0-based), trimmed — used for the signature shown on the
# right of a candidate
static def line_of(text: const *char, n: i32) -> *char:
    ln: i32 = 0
    i: usize = 0
    start: usize = 0
    while text[i] != '\0':
        if ln == n and text[i] == '\n':
            break
        if text[i] == '\n':
            ln += 1
            start = i + 1
        i += 1
    if ln != n:
        return own("")
    while start < i and (text[start] == ' ' or text[start] == '\t'):
        start += 1
    e: usize = i
    while e > start and (text[e - 1] == ' ' or text[e - 1] == '\t' or text[e - 1] == '\r'):
        e -= 1
    r: *char = malloc(e - start + 1)
    memcpy(r, text + start, e - start)
    r[e - start] = '\0'
    return r

# The type NAME a declaration binds to, starting at the token after the `:`.
# Walks past `const` and the stars: in this codebase practically every variable
# is `x: *Type`, and stopping at the `*` meant member completion never resolved
# anything. A pointer completes just like the value — `->` and `.` are one thing
# to the index, and the editor already accepts either.
static def decl_type_name(tl: TokenList, at: usize) -> const *char:
    i: usize = at
    while i < tl.n and tl.toks[i].kind in {TK_STAR, TK_CONST}:
        i += 1
    if i < tl.n and tl.toks[i].kind == TK_IDENT:
        return tl.toks[i].text
    return None

struct Index:
    static def add(ref self: Index, name: const *char, detail: const *char, owner: const *char, kind: SymKind)
    static def has(in self: Index, name: const *char, owner: const *char) -> bool
    static def scan(ref self: Index, text: const *char, words: bool, out_imports: *Vec<CVar>)
    static def rank(in self: Index, i: i32, prefix: const *char) -> i32

    def init(out self: Index):
        self.syms.init()
        self.vars.init()
        self.version = 0
        self.ready = False

    def deinit(ref self: Index):
        for i in range(self.syms.len):
            free(self.syms.data[i].name)
            free(self.syms.data[i].detail)
            free(self.syms.data[i].owner)
        self.syms.deinit()
        for i in range(self.vars.len):
            free(self.vars.data[i].name)
            free(self.vars.data[i].type_name)
        self.vars.deinit()

    def sym(in self: Index, i: i32) -> *CSym:
        return &self.syms.data[i]

    def is_stale(in self: Index, ref b: Buffer) -> bool:
        return not self.ready or self.version != b.version

    static def has(in self: Index, name: const *char, owner: const *char) -> bool:
        for i in range(self.syms.len):
            s: *CSym = &self.syms.data[i]
            if strcmp(s->name, name) != 0:
                continue
            if owner == None and s->owner == None:
                return True
            if owner != None and s->owner != None and strcmp(s->owner, owner) == 0:
                return True
        return False

    static def add(ref self: Index, name: const *char, detail: const *char, owner: const *char, kind: SymKind):
        if name == None or name[0] == '\0' or self.has(name, owner):
            return
        s: CSym = {own(name), None, None, kind}
        if detail != None:
            s.detail = own(detail)
        if owner != None:
            s.owner = own(owner)
        self.syms.push(s)

    # walks the token stream of one file. `words` = also collect plain
    # identifiers (only for the buffer being edited; imports contribute just
    # their declarations). Imports found are appended to out_imports.
    static def scan(ref self: Index, text: const *char, words: bool, out_imports: *Vec<CVar>):
        a: Arena = {0}
        tl: TokenList = lex_ex("<complete>", text, strlen(text), &a, True)
        defer:
            free(tl.toks)
            arena_drop_c(&a)
        cur_struct: *char = None       # struct whose body we are inside
        depth: i32 = 0                 # INDENT depth since that header
        paren: i32 = 0                 # inside a parameter list?
        i: usize = 0
        while i < tl.n:
            t: *Token = &tl.toks[i]
            # "first token of its source line" is asked of the POSITIONS, not
            # of NEWLINE tokens: an unclosed '(' suppresses those (implicit
            # continuation), and a half-typed buffer is full of them. The
            # layout tokens are transparent here — INDENT carries the position
            # of the very line it opens.
            pv: i32 = i32(i) - 1
            while pv >= 0:
                pk2: TokKind = tl.toks[pv].kind
                if pk2 not in {TK_NEWLINE, TK_INDENT, TK_DEDENT}:
                    break
                pv -= 1
            line_start: bool = pv < 0 or tl.toks[pv].pos.line != t->pos.line
            match t->kind:
                case TK_INDENT:
                    if cur_struct != None:
                        depth += 1
                    i += 1
                    continue        # still the start of a logical line
                case TK_DEDENT:
                    if cur_struct != None:
                        depth -= 1
                        if depth <= 0:
                            free(cur_struct)
                            cur_struct = None
                    i += 1
                    continue
                case TK_NEWLINE:
                    i += 1
                    continue
                case TK_IMPORT:
                    if i + 1 < tl.n and tl.toks[i + 1].kind == TK_STRING and out_imports != None:
                        q: const *char = tl.toks[i + 1].text     # "x.ph" with quotes
                        n: usize = strlen(q)
                        if n > 2:
                            p: *char = malloc(n - 1)
                            memcpy(p, q + 1, n - 2)
                            p[n - 2] = '\0'
                            im: CVar = {p, None}
                            out_imports->push(im)
                case TK_DEF:
                    if i + 1 < tl.n and tl.toks[i + 1].kind == TK_IDENT:
                        sig: *char = line_of(text, tl.toks[i + 1].pos.line - 1)
                        if cur_struct != None:
                            self.add(tl.toks[i + 1].text, sig, cur_struct, SYM_MEMBER)
                        else:
                            self.add(tl.toks[i + 1].text, sig, None, SYM_FUNC)
                        free(sig)
                        i += 1       # the name is indexed: not a plain word too
                case TK_STRUCT, TK_UNION, TK_ENUM:
                    if i + 1 < tl.n and tl.toks[i + 1].kind == TK_IDENT:
                        self.add(tl.toks[i + 1].text, None, None, SYM_TYPE)
                        free(cur_struct)
                        cur_struct = own(tl.toks[i + 1].text)
                        depth = 0
                        i += 1
                case TK_LPAREN:
                    paren += 1
                case TK_RPAREN:
                    if paren > 0:
                        paren -= 1
                case TK_IDENT:
                    # a parameter is a declaration too: `def f(p: Point)` is
                    # what makes `p.` work inside the body
                    if paren > 0 and i + 2 < tl.n and tl.toks[i + 1].kind == TK_COLON:
                        ptn: const *char = decl_type_name(tl, i + 2)
                        if ptn != None:
                            pv2: CVar = {own(t->text), own(ptn)}
                            self.vars.push(pv2)
                    # `name: Type` — a field inside a struct, a variable outside
                    if line_start and i + 2 < tl.n and tl.toks[i + 1].kind == TK_COLON:
                        tyname: const *char = decl_type_name(tl, i + 2)
                        if cur_struct != None:
                            d: *char = line_of(text, t->pos.line - 1)
                            self.add(t->text, d, cur_struct, SYM_MEMBER)
                            free(d)
                        elif tyname != None:
                            v: CVar = {own(t->text), own(tyname)}
                            self.vars.push(v)
                    if words:
                        self.add(t->text, None, None, SYM_WORD)
                case _:
                    pass
            i += 1
        free(cur_struct)

    def build(ref self: Index, ref b: Buffer, path: const *char):
        self.deinit()
        self.syms.init()
        self.vars.init()
        j: i32 = 0
        while keywords[j] != None:
            self.add(keywords[j], None, None, SYM_KEYWORD)
            j += 1
        imports: Vec<CVar>
        imports.init()
        defer:
            for i in range(imports.len):
                free(imports.data[i].name)
            imports.deinit()
        n: usize
        text: *char = b.save_text(out n)
        self.scan(text, True, &imports)
        free(text)
        # the .ph files this buffer imports, resolved next to it
        if path != None:
            dir: *char = ps_path_dirname(path)
            v: Vfs = vfs_local()
            for i in range(imports.len):
                if i >= MAX_IMPORTS:
                    break
                full: *char = ps_path_join(dir, imports.data[i].name)
                ln: usize
                src: *char = vfs_read_all(in v, full, out ln)
                free(full)
                if src == None:
                    continue
                self.scan(src, False, None)
                free(src)
            free(dir)
        self.version = b.version
        self.ready = True

    def owner_of(in self: Index, expr: const *char) -> const *char:
        for i in range(self.vars.len):
            if strcmp(self.vars.data[i].name, expr) == 0:
                return self.vars.data[i].type_name
        for i in range(self.syms.len):
            if self.syms.data[i].kind == SYM_TYPE and strcmp(self.syms.data[i].name, expr) == 0:
                return self.syms.data[i].name
        return None

    # higher is better: exact case match, then declarations over plain words,
    # then shorter names (the closest thing to what you meant)
    static def rank(in self: Index, i: i32, prefix: const *char) -> i32:
        s: *CSym = &self.syms.data[i]
        r: i32 = 0
        match s->kind:
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
        if strncmp(s->name, prefix, strlen(prefix)) == 0:
            r += 50                      # same case as typed
        r -= i32(strlen(s->name)) / 2
        return r

    def query(in self: Index, prefix: const *char, owner: const *char, ref out_hits: Vec<i32>):
        out_hits.clear()
        pl: usize = strlen(prefix)
        for i in range(self.syms.len):
            s: *CSym = &self.syms.data[i]
            if owner != None:
                if s->kind != SYM_MEMBER or s->owner == None:
                    continue
                if strcmp(s->owner, owner) != 0:
                    continue
            elif s->kind == SYM_MEMBER:
                continue                 # members only after `.`/`->`
            if pl > 0 and strncasecmp(s->name, prefix, pl) != 0:
                continue
            if pl > 0 and strlen(s->name) == pl:
                continue                 # already fully typed
            out_hits.push(i)
        # insertion sort by rank (the lists are short)
        for i in range(1, out_hits.len):
            v: i32 = out_hits.data[i]
            rv: i32 = self.rank(v, prefix)
            k: i32 = i
            while k > 0 and self.rank(out_hits.data[k - 1], prefix) < rv:
                out_hits.data[k] = out_hits.data[k - 1]
                k -= 1
            out_hits.data[k] = v
