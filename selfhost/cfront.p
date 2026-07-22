# cfront.p — C frontend: tokenizes + parses C (preprocessed) -> plang AST.
# See cfront.ph. Reuses the constructors from ast.ph and the TokKind ops from lexer.ph.
include <string.h>
include <stdlib.h>
import "cfront.ph"
import "vecs.ph"
import "../stl/vec.ph"
import "../stl/set.ph"
import "../stl/map.ph"

# type tables for the C frontend. StrSet is not generic (just import
# set.ph; bodies come from the implement in sema.p). StrMap<*Type> is generic -> declare.
declare StrMap<*Type>
declare StrMap<i64>
declare StrMap<*char>
implement StrMap<*char>

# C tokens (kind + text); punctuators store the string ("+", "==", ";")
enum CtKind:
    CT_EOF = 0
    CT_ID
    CT_NUM
    CT_STR
    CT_CHAR
    CT_PUNCT

# forward (used inside the tokenizer's methods, defined later)
def is_alpha_(c: char) -> bool
def is_alnum_(c: char) -> bool
def is_num_cont(c: char) -> bool
def word_count(s: const *char, w: const *char) -> i32
def word_in(s: const *char, w: const *char) -> bool

struct CTok:
    kind: CtKind
    text: const *char
    pos: Pos

declare Vec<CTok>
implement Vec<CTok>

# ---------- tokenizer ----------
struct Cx:
    file: const *char
    s: const *char
    n: usize
    i: usize
    line: i32
    col: i32
    toks: Vec<CTok>
    a: *Arena

    static def lex_punct(self: *Cx, pos: Pos)

    static def peekc(self: *Cx, k: usize) -> char:
        return self->s[self->i + k] if self->i + k < self->n else '\0'

    static def adv(self: *Cx):
        if self->s[self->i] == '\n':
            self->line += 1
            self->col = 1
        else:
            self->col += 1
        self->i += 1

    static def here(self: *Cx) -> Pos:
        p: Pos = {self->line, self->col}
        return p

    static def push(self: *Cx, kind: CtKind, pos: Pos, text: const *char):
        t: CTok = {kind, text, pos}
        self->toks.push(t)

    static def slice(self: *Cx, start: usize) -> const *char:
        return arena_strndup(self->a, self->s + start, self->i - start)

    static def tokenize(self: *Cx):
        while self->i < self->n:
            c: char = self->s[self->i]
            # whitespace
            if c == ' ' or c == '\t' or c == '\r' or c == '\n':
                self->adv()
                continue
            # preprocessor marker lines: # 1 "file" ...
            if c == '#':
                while self->i < self->n and self->s[self->i] != '\n':
                    self->adv()
                continue
            # comments
            if c == '/' and self->peekc(1) == '/':
                while self->i < self->n and self->s[self->i] != '\n':
                    self->adv()
                continue
            if c == '/' and self->peekc(1) == '*':
                self->adv()
                self->adv()
                while self->i < self->n and not (self->s[self->i] == '*' and self->peekc(1) == '/'):
                    self->adv()
                self->adv()
                self->adv()
                continue
            pos: Pos = self->here()
            # wide/unicode literal prefix (L'..' L".." u'..' U".."): the prefix
            # is KEPT in the token text — `wchar_t s[] = L"..."` must re-emit the
            # L or the initializer changes type (array of char vs wchar_t)
            if (c == 'L' or c == 'u' or c == 'U') and self->i + 1 < self->n and (self->s[self->i + 1] == '\'' or self->s[self->i + 1] == '"'):
                wst: usize = self->i
                self->adv()                    # prefix
                wq: char = self->s[self->i]
                self->adv()                    # opening quote
                while self->i < self->n and self->s[self->i] != wq:
                    if self->s[self->i] == '\\':
                        self->adv()
                    self->adv()
                self->adv()                    # closing quote
                self->push(CT_STR if wq == '"' else CT_CHAR, pos, self->slice(wst))
                continue
            # identifier / keyword
            if is_alpha_(c):
                start: usize = self->i
                while self->i < self->n and is_alnum_(self->s[self->i]):
                    self->adv()
                self->push(CT_ID, pos, self->slice(start))
                continue
            # number (int/hex/float, incl. hex-float 0x1p63 and exponent 1e-5)
            if c >= '0' and c <= '9':
                start2: usize = self->i
                while self->i < self->n and is_num_cont(self->s[self->i]):
                    ch: char = self->s[self->i]
                    self->adv()
                    # sign after exponent (e/E dec, p/P hex) is part of the number
                    if (ch == 'e' or ch == 'E' or ch == 'p' or ch == 'P') and self->i < self->n and (self->s[self->i] == '+' or self->s[self->i] == '-'):
                        self->adv()
                self->push(CT_NUM, pos, self->slice(start2))
                continue
            # string
            if c == '"':
                start3: usize = self->i
                self->adv()
                while self->i < self->n and self->s[self->i] != '"':
                    if self->s[self->i] == '\\':
                        self->adv()
                    self->adv()
                self->adv()  # closing quote
                self->push(CT_STR, pos, self->slice(start3))
                continue
            # char
            if c == '\'':
                start4: usize = self->i
                self->adv()
                while self->i < self->n and self->s[self->i] != '\'':
                    if self->s[self->i] == '\\':
                        self->adv()
                    self->adv()
                self->adv()
                self->push(CT_CHAR, pos, self->slice(start4))
                continue
            # punctuator (match the longest first)
            self->lex_punct(pos)
        self->push(CT_EOF, self->here(), None)

    static def lex_punct(self: *Cx, pos: Pos):
        start: usize = self->i
        c: char = self->s[self->i]
        c1: char = self->peekc(1)
        c2: char = self->peekc(2)
        # 3-char: <<= >>= ...
        if (c == '<' and c1 == '<' and c2 == '=') or (c == '>' and c1 == '>' and c2 == '=') or (c == '.' and c1 == '.' and c2 == '.'):
            self->adv()
            self->adv()
            self->adv()
            self->push(CT_PUNCT, pos, self->slice(start))
            return
        # 2-char
        two: bool = False
        if c == '<' and (c1 == '<' or c1 == '='):
            two = True
        elif c == '>' and (c1 == '>' or c1 == '='):
            two = True
        elif c == '-' and (c1 == '>' or c1 == '-' or c1 == '='):
            two = True
        elif c == '+' and (c1 == '+' or c1 == '='):
            two = True
        elif c == '&' and (c1 == '&' or c1 == '='):
            two = True
        elif c == '|' and (c1 == '|' or c1 == '='):
            two = True
        elif (c == '=' or c == '!' or c == '*' or c == '/' or c == '%' or c == '^') and c1 == '=':
            two = True
        if two:
            self->adv()
            self->adv()
            self->push(CT_PUNCT, pos, self->slice(start))
            return
        self->adv()
        self->push(CT_PUNCT, pos, self->slice(start))

# counts occurrences of the word `w` in `s` (space-separated)
def word_count(s: const *char, w: const *char) -> i32:
    n = 0
    wl: usize = strlen(w)
    p: const *char = s
    while True:
        hit: const *char = strstr(p, w)
        if hit == None:
            break
        # word boundary
        before_ok: bool = hit == s or *(hit - 1) == ' '
        after: char = hit[wl]
        after_ok: bool = after == ' ' or after == '\0'
        if before_ok and after_ok:
            n += 1
        p = hit + wl
    return n

def word_in(s: const *char, w: const *char) -> bool:
    return word_count(s, w) > 0

def is_alpha_(c: char) -> bool:
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'

def is_alnum_(c: char) -> bool:
    return is_alpha_(c) or (c >= '0' and c <= '9')

def is_num_cont(c: char) -> bool:
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F') or c == 'x' or c == 'X' or c == '.' or c == 'u' or c == 'U' or c == 'l' or c == 'L' or c == 'p' or c == 'P'

# value of a C char literal ('a', '\n', '\x41', '\0') for ceval
def cchar_val(lex: const *char) -> i32:
    n: usize = strlen(lex)
    if n < 3:
        return 0
    c: char = lex[1]
    if c != '\\':
        return i32(c)
    e: char = lex[2]
    match e:
        case 'n':
            return 10
        case 't':
            return 9
        case 'r':
            return 13
        case '0':
            return 0
        case 'a':
            return 7
        case 'b':
            return 8
        case 'f':
            return 12
        case 'v':
            return 11
        case '\\':
            return 92
        case '\'':
            return 39
        case '"':
            return 34
        case 'x':
            v = 0
            k: usize = 3
            while k < n - 1:
                h: char = lex[k]
                if h >= '0' and h <= '9':
                    v = v * 16 + i32(h - '0')
                elif h >= 'a' and h <= 'f':
                    v = v * 16 + i32(h - 'a') + 10
                elif h >= 'A' and h <= 'F':
                    v = v * 16 + i32(h - 'A') + 10
                else:
                    break
                k += 1
            return v
        case _:
            return i32(e)
    return 0

# ---------- parser ----------
struct Cp:
    file: const *char
    t: *CTok
    nt: usize
    i: usize
    a: *Arena
    types: StrSet            # known type names (builtins + typedefs + tags)
    typedefs: StrMap<*Type>  # typedef name -> underlying type (resolved)
    enumvals: StrMap<i64>    # enum constant -> value (for ceval)
    enum_signed: StrSet      # enum tags with a negative enumerator (-> int)
    fwd_tags: StrSet         # struct/union tags already declared (fwd or def):
                             #   a bodyless `struct X` emits ONE forward decl
    def_tags: StrSet         # tags DEFINED with a body: a redefinition in an
                             #   inner scope shadows -> renamed (T -> T__sN)
    tag_alias: StrMap<*char> # active tag renames (scoped; undone at block exit)
    alias_names: **char      # undo stack for tag_alias: original tag +
    alias_prevs: **char      #   previous alias value (None = none)
    nalias: i32
    ca_n: i32
    ca_p: i32
    out_decls: *Vec<*Decl>   # structs/enums found are emitted here
    anon: i32                # counter for anonymous tags
    saw_const: bool          # skip_gnu saw 'const' (read by parse_base_type)

    static def skip_gnu(self: *Cp)
    static def skip_parens(self: *Cp)
    static def skip_to(self: *Cp, a: const *char, b: const *char)
    static def is_type_kw(self: *Cp, w: const *char) -> bool
    static def canon_arith(self: *Cp, n: const *char) -> const *char
    static def parse_base_type(self: *Cp) -> *Type
    static def base_name(self: *Cp, n: const *char) -> *Type
    static def parse_stars(self: *Cp, base: *Type) -> *Type
    static def is_fnptr_ahead(self: *Cp) -> bool
    static def parse_fnptr(self: *Cp, ret: *Type, out_name: **char) -> *Type
    static def parse_declarator(self: *Cp, base: *Type, out_name: **char, prms: *Vec<Param>, varargs: *bool, has_params: *bool) -> *Type
    static def parse_decl_suffix(self: *Cp, ty: *Type) -> *Type
    static def parse_params(self: *Cp, prms: *Vec<Param>, varargs: *bool)
    static def parse_struct_body(self: *Cp, tag: const *char, is_union: bool) -> *Decl
    static def parse_enum_body(self: *Cp, tag: const *char) -> *Decl
    static def tok_is_type(self: *Cp, w: const *char) -> bool
    static def type_size(self: *Cp, t: *Type, ok: *bool) -> i64
    static def ceval_prim(self: *Cp, ok: *bool) -> i64
    static def ceval_prec(self: *Cp) -> i32
    static def ceval_bin(self: *Cp, minprec: i32, ok: *bool) -> i64
    static def ceval(self: *Cp, ok: *bool) -> i64

    static def pk(self: *Cp) -> *CTok:
        return &self->t[self->i]

    static def pk1(self: *Cp) -> *CTok:
        return &self->t[self->i + 1] if self->i + 1 < self->nt else &self->t[self->nt - 1]

    static def adv(self: *Cp) -> *CTok:
        t: *CTok = &self->t[self->i]
        if t->kind != CT_EOF:
            self->i += 1
        return t

    static def is_punct(self: *Cp, p: const *char) -> bool:
        return self->pk()->kind == CT_PUNCT and strcmp(self->pk()->text, p) == 0

    static def is_kw(self: *Cp, w: const *char) -> bool:
        return self->pk()->kind == CT_ID and strcmp(self->pk()->text, w) == 0

    static def eat(self: *Cp, p: const *char) -> bool:
        if self->is_punct(p):
            self->adv()
            return True
        return False

    static def expect_punct(self: *Cp, p: const *char):
        if not self->is_punct(p):
            fatal_at(self->file, self->pk()->pos, "expected '%s'", p)
        self->adv()

    # C type keyword (base arithmetic)
    static def is_type_kw(self: *Cp, w: const *char) -> bool:
        return strcmp(w, "void") == 0 or strcmp(w, "char") == 0 or strcmp(w, "short") == 0 or strcmp(w, "int") == 0 or strcmp(w, "long") == 0 or strcmp(w, "float") == 0 or strcmp(w, "double") == 0 or strcmp(w, "signed") == 0 or strcmp(w, "unsigned") == 0 or strcmp(w, "_Bool") == 0

    # GNU noise/qualifiers that cproc accepts and we ignore:
    # __attribute__((...)) / __asm__(...) / const / volatile / restrict /
    # __extension__ / storage classes. Returns after skipping everything applicable.
    static def skip_gnu(self: *Cp):
        while self->pk()->kind == CT_ID:
            w: const *char = self->pk()->text
            if strcmp(w, "__attribute__") == 0 or strcmp(w, "__attribute") == 0 or strcmp(w, "__asm__") == 0 or strcmp(w, "__asm") == 0 or strcmp(w, "asm") == 0:
                self->adv()
                if self->is_punct("("):
                    self->skip_parens()
            elif strcmp(w, "const") == 0 or strcmp(w, "volatile") == 0 or strcmp(w, "__volatile__") == 0 or strcmp(w, "restrict") == 0 or strcmp(w, "__restrict") == 0 or strcmp(w, "__restrict__") == 0 or strcmp(w, "__extension__") == 0 or strcmp(w, "static") == 0 or strcmp(w, "extern") == 0 or strcmp(w, "register") == 0 or strcmp(w, "auto") == 0 or strcmp(w, "inline") == 0 or strcmp(w, "__inline") == 0 or strcmp(w, "__inline__") == 0 or strcmp(w, "_Noreturn") == 0 or strcmp(w, "__thread") == 0 or strcmp(w, "_Thread_local") == 0:
                if strcmp(w, "const") == 0:
                    self->saw_const = True   # for parse_base_type to mark the type
                self->adv()
            else:
                break

    static def skip_parens(self: *Cp):
        self->expect_punct("(")
        depth = 1
        while depth > 0 and self->pk()->kind != CT_EOF:
            if self->is_punct("("):
                depth += 1
            elif self->is_punct(")"):
                depth -= 1
            self->adv()

    # is this the start of a type?
    # does the word `w` begin a type name? (builtin/struct/union/enum/
    # qualifier/known typedef) — used by at_type and sizeof in ceval
    static def tok_is_type(self: *Cp, w: const *char) -> bool:
        if self->is_type_kw(w) or strcmp(w, "struct") == 0 or strcmp(w, "union") == 0 or strcmp(w, "enum") == 0:
            return True
        if strcmp(w, "const") == 0 or strcmp(w, "volatile") == 0 or strcmp(w, "unsigned") == 0 or strcmp(w, "signed") == 0:
            return True
        return self->types.has(w)

    static def at_type(self: *Cp) -> bool:
        t: *CTok = self->pk()
        if t->kind != CT_ID:
            return False
        w: const *char = t->text
        if self->is_type_kw(w) or strcmp(w, "struct") == 0 or strcmp(w, "union") == 0 or strcmp(w, "enum") == 0:
            return True
        # qualifiers/storage also start a type
        if strcmp(w, "const") == 0 or strcmp(w, "volatile") == 0 or strcmp(w, "static") == 0 or strcmp(w, "extern") == 0 or strcmp(w, "register") == 0 or strcmp(w, "inline") == 0 or strcmp(w, "__extension__") == 0 or strcmp(w, "__inline") == 0 or strcmp(w, "__inline__") == 0 or strcmp(w, "unsigned") == 0 or strcmp(w, "signed") == 0:
            return True
        return self->types.has(w)

    # base type: skips qualifiers/GNU, resolves typedef, builds a multi-word
    # arithmetic type, and handles struct/union/enum (with optional body def).
    static def parse_base_type(self: *Cp) -> *Type:
        self->saw_const = False
        self->skip_gnu()
        w: const *char = self->pk()->text
        # struct / union / enum
        if strcmp(w, "struct") == 0 or strcmp(w, "union") == 0:
            is_union: bool = strcmp(w, "union") == 0
            self->adv()
            self->skip_gnu()
            tag: const *char = None
            if self->pk()->kind == CT_ID and not self->is_punct("{"):
                tag = self->adv()->text
            if self->is_punct("{"):
                if tag == None:
                    tag = arena_printf(self->a, "__anon%d", self->anon)
                    self->anon += 1
                elif self->def_tags.has(tag):
                    # redefinition in an inner scope: C tags are block-scoped
                    # (`struct T` in a function shadows the file-scope one), but
                    # our decls are hoisted — rename and alias until block exit
                    renamed: const *char = arena_printf(self->a, "%s__s%d", tag, self->anon)
                    self->anon += 1
                    self->alias_names = vec_grow(self->alias_names, self->nalias, &self->ca_n, sizeof(*self->alias_names))
                    self->alias_prevs = vec_grow(self->alias_prevs, self->nalias, &self->ca_p, sizeof(*self->alias_prevs))
                    self->alias_names[self->nalias] = (*char)(tag)
                    self->alias_prevs[self->nalias] = self->tag_alias.get_or(tag, None)
                    self->nalias += 1
                    self->tag_alias.put(tag, (*char)(renamed))
                    tag = renamed
                d: *Decl = self->parse_struct_body(tag, is_union)
                self->out_decls.push(d)
                self->def_tags.add(tag)
                self->fwd_tags.add(tag)
            elif tag != None:
                al: *char = self->tag_alias.get_or(tag, None)
                if al != None:
                    tag = al   # reference inside a scope that renamed this tag
                if not self->fwd_tags.has(tag):
                    # bodyless `struct X` (a forward like glibc's `struct _IO_marker;`
                    # or a field/param referencing an opaque tag): emit ONE forward
                    # decl so the C backend's upfront typedef pass covers the name.
                    fd: *Decl = arena_alloc(self->a, sizeof(Decl))
                    fd->kind = DL_UNION if is_union else DL_STRUCT
                    fd->name = tag
                    fd->is_fwd = True
                    fd->pos = self->pk()->pos
                    self->out_decls.push(fd)
                    self->fwd_tags.add(tag)
            # does NOT register the tag as a type name: in C, tags live in
            # their own namespace (a function and a struct can have the SAME name;
            # only `struct X` refers to the tag). The SPELLING is preserved via
            # tag_kind — the C backend re-emits `struct X`, never a bare `X`.
            tt: *Type = self->base_name(tag)
            tt->tag_kind = TAG_UNION if is_union else TAG_STRUCT
            return tt
        if strcmp(w, "enum") == 0:
            self->adv()
            self->skip_gnu()
            tag2: const *char = None
            if self->pk()->kind == CT_ID and not self->is_punct("{"):
                tag2 = self->adv()->text
            if self->is_punct("{"):
                d2: *Decl = self->parse_enum_body(tag2)
                self->out_decls.push(d2)
            # like gcc: an enum without a negative enumerator represents UNSIGNED
            # (matters so an enum bitfield doesn't sign-extend — 00218)
            if tag2 != None and self->enum_signed.has(tag2):
                return self->base_name("int")
            return self->base_name("unsigned")
        # multi-word arithmetic type: unsigned long long int, etc.
        if self->is_type_kw(w):
            name: const *char = self->adv()->text
            while self->pk()->kind == CT_ID and self->is_type_kw(self->pk()->text):
                name = arena_printf(self->a, "%s %s", name, self->adv()->text)
            return self->base_name(self->canon_arith(name))
        # typedef name: resolves to the underlying type (the backend doesn't change;
        # doesn't mark const on the typedef's shared node)
        if self->types.has(w):
            self->adv()
            u: *Type = self->typedefs.get_or(w, None)
            if u != None:
                return u
            return self->base_name(w)  # struct tag
        # unknown: assume int (tolerant, like header noise)
        self->adv()
        return self->base_name("int")

    # new TY_NAME node with the const seen from the qualifiers ahead
    # (significant for _Generic matching: const char* vs char*)
    static def base_name(self: *Cp, n: const *char) -> *Type:
        t: *Type = ty_name(self->a, n)
        t->is_const = self->saw_const
        return t

    # canonicalizes a multi-word arithmetic type for the backend, ORDER-INSENSITIVE
    # (C allows "long unsigned int" == "unsigned long"). Counts the words.
    static def canon_arith(self: *Cp, n: const *char) -> const *char:
        uns: bool = word_in(n, "unsigned")
        longs: i32 = word_count(n, "long")
        if word_in(n, "double"):
            # `long double` is a DISTINCT type (x87 80-bit on x86-64): collapsing
            # it to double breaks the ABI (e.g. printf %Lf reads garbage)
            return "long double" if longs > 0 else "double"
        if word_in(n, "float"):
            return "float"
        if word_in(n, "void"):
            return "void"
        # DISTINCT C types must stay distinct (e.g. for _Generic): long !=
        # long long, char != signed char — even when the width coincides.
        # u8/u16/i8 are used where the C type identity is the same typedef
        # (uint8_t IS unsigned char, int8_t IS signed char).
        if word_in(n, "char"):
            if uns:
                return "u8"
            return "i8" if word_in(n, "signed") else "char"
        if word_in(n, "short"):
            return "u16" if uns else "short"
        if longs >= 2:
            return "unsigned long long" if uns else "long long"
        if longs == 1:
            return "unsigned long" if uns else "long"
        # plain int/signed/unsigned
        return "unsigned" if uns else "int"

    static def parse_stars(self: *Cp, base: *Type) -> *Type:
        t: *Type = base
        while self->is_punct("*"):
            self->adv()
            # const after '*' qualifies the POINTER (int * const != const int *):
            # recorded on the TY_PTR node so _Generic/casts keep them distinct
            sc: bool = self->saw_const
            self->saw_const = False
            self->skip_gnu()  # const/volatile/__restrict after '*'
            t = ty_ptr(self->a, t)
            t->is_const = self->saw_const
            self->saw_const = sc
        return t

    # does the next token start a pointer-to-function declarator? pattern
    # "( [gnu] * ..." — distinguishes it from grouping and from a normal function.
    static def is_fnptr_ahead(self: *Cp) -> bool:
        if not self->is_punct("("):
            return False
        if strcmp(self->pk1()->text, "*") == 0:
            return True
        # GNU noise before the star: ( __attribute__((...)) * ). Scan past the
        # attribute's parenthesized group and require the '*' — a lookahead
        # that does not consume (the declarator parser skip_gnu()s for real).
        if self->pk1()->kind == CT_ID and strcmp(self->pk1()->text, "__attribute__") == 0:
            k: usize = self->i + 2      # token after '(' '__attribute__'
            if k >= self->nt or self->t[k].kind != CT_PUNCT or strcmp(self->t[k].text, "(") != 0:
                return False
            depth = 0
            while k < self->nt:
                if self->t[k].kind == CT_PUNCT and strcmp(self->t[k].text, "(") == 0:
                    depth += 1
                elif self->t[k].kind == CT_PUNCT and strcmp(self->t[k].text, ")") == 0:
                    depth -= 1
                    if depth == 0:
                        k += 1
                        break
                k += 1
            return k < self->nt and self->t[k].kind == CT_PUNCT and strcmp(self->t[k].text, "*") == 0
        return False

    # pointer-to-function declarator starting from '(' — compat: delegates to
    # the full recursive declarator (params capture discarded)
    static def parse_fnptr(self: *Cp, ret: *Type, out_name: **char) -> *Type:
        prms: Vec<Param>
        prms.init()
        va: bool = False
        hp: bool = False
        return self->parse_declarator(ret, out_name, &prms, &va, &hp)

    # full C declarator (recursive, two passes chibicc-style):
    #   declarator := '*'* ( '(' declarator ')' | name ) suffix*
    #   suffix     := '(' params ')' | '[' dim ']'
    # Nested group: skips to the matching ')', applies the EXTERNAL suffixes
    # to the type, and re-parses the inner part with the type already built
    # (saves/restores the token index). The params of the declarator that HAS
    # the name are captured in prms/varargs (has_params marks the capture) —
    # it's the function's signature when the result is TY_FUNC.
    static def parse_declarator(self: *Cp, base: *Type, out_name: **char, prms: *Vec<Param>, varargs: *bool, has_params: *bool) -> *Type:
        ty: *Type = base
        self->skip_gnu()
        while self->is_punct("*"):
            self->adv()
            self->skip_gnu()
            ty = ty_ptr(self->a, ty)
        if self->is_punct("("):
            # '(' here is either a GROUPED declarator — (*name), (name) — or a
            # PARAMETER LIST of an abstract function declarator: `int ()`,
            # `int (int x)` (C11 6.7.6.3p8: such a parameter decays to a
            # pointer to function). It is a parameter list when what follows
            # starts a type (or is ')' / '...').
            nx2: *CTok = self->pk1()
            starts_params: bool = False
            if nx2->kind == CT_PUNCT and (strcmp(nx2->text, ")") == 0 or strcmp(nx2->text, "...") == 0):
                starts_params = True
            elif nx2->kind == CT_ID and (self->is_type_kw(nx2->text) or strcmp(nx2->text, "struct") == 0 or strcmp(nx2->text, "union") == 0 or strcmp(nx2->text, "enum") == 0 or strcmp(nx2->text, "const") == 0 or strcmp(nx2->text, "volatile") == 0 or self->types.has(nx2->text)):
                starts_params = True
            if starts_params:
                self->skip_parens()   # signature detail not needed: emits as ()
                *out_name = ""
                return ty_func(self->a, ty)
            start: usize = self->i
            self->adv()
            depth = 1
            while depth > 0 and self->pk()->kind != CT_EOF:
                if self->is_punct("("):
                    depth += 1
                elif self->is_punct(")"):
                    depth -= 1
                self->adv()
            ty = self->parse_decl_suffix(ty)
            end: usize = self->i
            self->i = start + 1
            r: *Type = self->parse_declarator(ty, out_name, prms, varargs, has_params)
            self->i = end
            return r
        *out_name = ""
        if self->pk()->kind == CT_ID:
            *out_name = self->adv()->text
        if self->is_punct("("):
            # suffix directly on the name: function signature — captures params
            self->adv()
            self->parse_params(prms, varargs)
            self->expect_punct(")")
            self->skip_gnu()
            *has_params = True
            return ty_func(self->a, ty)
        return self->parse_decl_suffix(ty)

    # suffixes WITHOUT params capture: (params) -> function; [dims] -> array
    # (literal dims; complex ones fall through to skip — rare in group declarators)
    static def parse_decl_suffix(self: *Cp, ty: *Type) -> *Type:
        if self->is_punct("("):
            self->skip_parens()
            return ty_func(self->a, ty)
        dims: *Expr[8]
        nd = 0
        while self->eat("["):
            dd: *Expr = None
            if not self->is_punct("]"):
                dsave: usize = self->i
                dok: bool = True
                dv: i64 = self->ceval(&dok)
                if dok and self->is_punct("]"):
                    dd = ex_new(self->a, EX_NUMBER, self->pk()->pos)
                    dd->text = arena_printf(self->a, "%lld", dv)
                else:
                    self->i = dsave
                    self->skip_to("]", "]")
            self->expect_punct("]")
            if nd < 8:
                dims[nd] = dd
                nd += 1
        k: i32
        for k in range(nd - 1, -1, -1):
            ty = ty_array(self->a, ty, dims[k])
        return ty

    # parameter list (after the '(' already consumed; leaves at the ')')
    static def parse_params(self: *Cp, prms: *Vec<Param>, varargs: *bool):
        *varargs = False
        if self->is_punct(")"):
            return
        if self->is_kw("void") and strcmp(self->pk1()->text, ")") == 0:
            self->adv()
            return
        do:
            if self->is_punct("..."):
                self->adv()
                *varargs = True
                return
            pbase: *Type = self->parse_base_type()
            pty: *Type = self->parse_stars(pbase)
            pname: const *char = ""
            # function-pointer parameter: T (*name)(args) -> captured via
            # the recursive declarator (the precise type matters for inference)
            if self->is_punct("("):
                fpn: *char = None
                pty = self->parse_fnptr(pty, &fpn)
                if fpn != None:
                    pname = fpn
                # abstract FUNCTION-type parameter — `int ()`, `int (int x)` —
                # decays to a pointer to function (C11 6.7.6.3p8)
                if pty->kind == TY_FUNC:
                    pty = ty_ptr(self->a, pty)
            elif self->pk()->kind == CT_ID:
                pname = self->adv()->text
                # FUNCTION-type parameter: T name(params) — decays to a
                # pointer-to-function (C11 6.7.6.3p8)
                if self->is_punct("("):
                    self->skip_parens()
                    pty = ty_ptr(self->a, ty_func(self->a, pty))
            while self->eat("["):
                if not self->is_punct("]"):
                    self->skip_to("]", "]")
                self->expect_punct("]")
                pty = ty_ptr(self->a, pty)  # param array decays to a pointer
            self->skip_gnu()
            prm: Param = {pname, pty, self->pk()->pos}
            prms->push(prm)
        while self->eat(",")

    # skips tokens (respecting () [] {}) until one of the terminators at level 0
    static def skip_to(self: *Cp, a: const *char, b: const *char):
        depth = 0
        while self->pk()->kind != CT_EOF:
            if depth == 0 and (self->is_punct(a) or self->is_punct(b)):
                return
            if self->is_punct("(") or self->is_punct("[") or self->is_punct("{"):
                depth += 1
            elif self->is_punct(")") or self->is_punct("]") or self->is_punct("}"):
                depth -= 1
            self->adv()

    # { field; ... } -> DL_STRUCT/DL_UNION. Doesn't use c_expr (methods can't
    # see free functions): array dims and bitfields are skipped via
    # tokens — the header struct's layout is ignored by the backend anyway.
    static def parse_struct_body(self: *Cp, tag: const *char, is_union: bool) -> *Decl:
        self->expect_punct("{")
        fields: Vec<Field>
        fields.init()
        while not self->is_punct("}") and self->pk()->kind != CT_EOF:
            base: *Type = self->parse_base_type()
            do:
                fty: *Type = self->parse_stars(base)
                fname: const *char = ""
                # function-pointer field: T (*name)(args)
                if self->is_fnptr_ahead():
                    fpn: *char = None
                    fty = self->parse_fnptr(fty, &fpn); fname = fpn
                else:
                    if self->pk()->kind == CT_ID:
                        fname = self->adv()->text
                    # array field: literal dim becomes a real TY_ARRAY (correct
                    # layout for offsets/sizeof); complex dim falls back to the
                    # ptr fallback (methods can't see c_expr). Dims in reverse order.
                    fdims: *Expr[8]
                    fndim = 0
                    bad_dim: bool = False
                    while self->eat("["):
                        fd: *Expr = None
                        if not self->is_punct("]"):
                            fdsave: usize = self->i
                            fok: bool = True
                            fv: i64 = self->ceval(&fok)
                            if fok and self->is_punct("]"):
                                fd = ex_new(self->a, EX_NUMBER, self->pk()->pos)
                                fd->text = arena_printf(self->a, "%lld", fv)
                            else:
                                self->i = fdsave
                                bad_dim = True   # non-constant dim: ptr fallback
                                self->skip_to("]", "]")
                        self->expect_punct("]")
                        if fndim < 8:
                            fdims[fndim] = fd
                            fndim += 1
                    if bad_dim:
                        for fk0 in range(fndim):
                            fty = ty_ptr(self->a, fty)   # old fallback
                    else:
                        fk: i32
                        for fk in range(fndim - 1, -1, -1):
                            fty = ty_array(self->a, fty, fdims[fk])
                bw = -1                     # -1 = not a bitfield
                if self->eat(":"):               # bitfield: constant width
                    wok: bool = True
                    wv: i64 = self->ceval(&wok)
                    if wok:
                        bw = i32(wv)
                    else:
                        self->skip_to(",", ";")
                if fname[0] != '\0':
                    fl: Field = {fname, fty, self->pk()->pos, bw}
                    fields.push(fl)
                elif bw >= 0:
                    # unnamed bitfield (`int :3` padding / `int :0` closes the
                    # unit): enters the layout, invisible to lookup
                    fp: Field = {"", fty, self->pk()->pos, bw}
                    fields.push(fp)
                elif fty != None and fty->kind == TY_NAME and fty->name != None and strncmp(fty->name, "__anon", 6) == 0 and self->is_punct(";"):
                    # anonymous member (struct/union without a declarator): field
                    # with name "" — the layout incorporates it and lookup descends
                    # into it. The nested definition (just pushed to out_decls) is
                    # linked on the field: the C backend inlines it at this position.
                    fa: Field = {"", fty, self->pk()->pos, -1}
                    if fty->kind == TY_NAME:
                        for ai in range(self->out_decls.len - 1, -1, -1):
                            ad: *Decl = self->out_decls.get(ai)
                            if (ad->kind == DL_STRUCT or ad->kind == DL_UNION) and strcmp(ad->name, fty->name) == 0:
                                fa.anon = ad
                                ad->is_anon = True
                                break
                    fields.push(fa)
            while self->eat(",")
            if not self->eat(";"):
                self->skip_to(";", ";")  # weird field declarator: skip it
                self->eat(";")
        self->expect_punct("}")
        d: *Decl = arena_alloc(self->a, sizeof(Decl))
        with d:
            .kind = DL_UNION if is_union else DL_STRUCT
            .name = tag
            .fields = fields.data
            .nfields = fields.len
            .is_def = True   # has a body (even `struct X {}`: GNU empty struct)
        return d

    # evaluator for CONSTANT integer expressions over the tokens (for enum
    # values like `1 << 20`, `A | B`): precedence climbing. Idents resolve via
    # enum constants already seen (enumvals). *ok=False if not constant.
    # size of a basic type for sizeof in const-expr (primitives, pointer,
    # array of constant dim, resolved typedef). *ok=False if unknown
    # (e.g.: struct without a layout in the frontend).
    static def type_size(self: *Cp, t: *Type, ok: *bool) -> i64:
        if t == None:
            *ok = False
            return 0
        if t->kind == TY_PTR or t->kind == TY_FUNC:
            return 8
        if t->kind == TY_ARRAY:
            if t->arr_len == None or t->arr_len->kind != EX_NUMBER:
                *ok = False
                return 0
            return i64(strtoll(t->arr_len->text, None, 0)) * self->type_size(t->inner, ok)
        n: const *char = t->name
        if n == None:
            *ok = False
            return 0
        if strcmp(n, "char") == 0 or strcmp(n, "i8") == 0 or strcmp(n, "u8") == 0 or strcmp(n, "bool") == 0 or strcmp(n, "_Bool") == 0:
            return 1
        if strcmp(n, "short") == 0 or strcmp(n, "i16") == 0 or strcmp(n, "u16") == 0:
            return 2
        if strcmp(n, "int") == 0 or strcmp(n, "unsigned") == 0 or strcmp(n, "i32") == 0 or strcmp(n, "u32") == 0 or strcmp(n, "float") == 0 or strcmp(n, "f32") == 0:
            return 4
        if strcmp(n, "long") == 0 or strcmp(n, "i64") == 0 or strcmp(n, "u64") == 0 or strcmp(n, "double") == 0 or strcmp(n, "f64") == 0 or strcmp(n, "size_t") == 0 or strcmp(n, "ssize_t") == 0 or strcmp(n, "ptrdiff_t") == 0 or strcmp(n, "usize") == 0 or strcmp(n, "isize") == 0 or strcmp(n, "intptr_t") == 0 or strcmp(n, "uintptr_t") == 0:
            return 8
        u: *Type = self->typedefs.get_or(n, None)
        if u != None:
            return self->type_size(u, ok)
        *ok = False
        return 0

    static def ceval_prim(self: *Cp, ok: *bool) -> i64:
        t: *CTok = self->pk()
        if t->kind == CT_NUM:
            self->adv()
            return i64(strtoll(t->text, None, 0))
        if t->kind == CT_CHAR:
            self->adv()
            return i64(cchar_val(t->text))
        # sizeof(type) / sizeof expr in const-expr (e.g.: enum NBit = 8*sizeof(x))
        if t->kind == CT_ID and strcmp(t->text, "sizeof") == 0:
            self->adv()
            # sizeof ( TYPE ): the token after '(' starts a type
            if self->is_punct("(") and self->pk1()->kind == CT_ID and self->tok_is_type(self->pk1()->text):
                self->adv()
                sty: *Type = self->parse_decl_suffix(self->parse_stars(self->parse_base_type()))
                if self->is_punct(")"):
                    self->adv()
                else:
                    *ok = False
                return self->type_size(sty, ok)
            # sizeof expr: only the simple case of an identifier with a type
            # is rare in const-expr; not reducible -> aborts the evaluation
            *ok = False
            return 0
        if t->kind == CT_ID:
            self->adv()
            v: i64 = self->enumvals.get_or(t->text, 0x7FFFFFFFFFFFFFFF)
            if v == 0x7FFFFFFFFFFFFFFF:
                *ok = False
                return 0
            return v
        if self->is_punct("("):
            self->adv()
            r: i64 = self->ceval(ok)
            if self->is_punct(")"):
                self->adv()
            else:
                *ok = False   # never fatals: the caller restores and skips
            return r
        if self->is_punct("-"):
            self->adv()
            return -self->ceval_prim(ok)
        if self->is_punct("+"):
            self->adv()
            return self->ceval_prim(ok)
        if self->is_punct("~"):
            self->adv()
            return ~self->ceval_prim(ok)
        if self->is_punct("!"):
            self->adv()
            return 0 if self->ceval_prim(ok) != 0 else 1
        *ok = False
        return 0

    static def ceval_prec(self: *Cp) -> i32:
        p: const *char = self->pk()->text
        if p == None or self->pk()->kind != CT_PUNCT:
            return -1
        if strcmp(p, "*") == 0 or strcmp(p, "/") == 0 or strcmp(p, "%") == 0:
            return 10
        if strcmp(p, "+") == 0 or strcmp(p, "-") == 0:
            return 9
        if strcmp(p, "<<") == 0 or strcmp(p, ">>") == 0:
            return 8
        if strcmp(p, "<") == 0 or strcmp(p, "<=") == 0 or strcmp(p, ">") == 0 or strcmp(p, ">=") == 0:
            return 7
        if strcmp(p, "==") == 0 or strcmp(p, "!=") == 0:
            return 6
        if strcmp(p, "&") == 0:
            return 5
        if strcmp(p, "^") == 0:
            return 4
        if strcmp(p, "|") == 0:
            return 3
        if strcmp(p, "&&") == 0:
            return 2
        if strcmp(p, "||") == 0:
            return 1
        return -1

    static def ceval_bin(self: *Cp, minprec: i32, ok: *bool) -> i64:
        lhs: i64 = self->ceval_prim(ok)
        while *ok:
            prec: i32 = self->ceval_prec()
            if prec < minprec:
                break
            op: const *char = self->adv()->text
            rhs: i64 = self->ceval_bin(prec + 1, ok)
            if strcmp(op, "*") == 0:
                lhs = lhs * rhs
            elif strcmp(op, "/") == 0:
                lhs = lhs / rhs if rhs != 0 else 0
            elif strcmp(op, "%") == 0:
                lhs = lhs % rhs if rhs != 0 else 0
            elif strcmp(op, "+") == 0:
                lhs = lhs + rhs
            elif strcmp(op, "-") == 0:
                lhs = lhs - rhs
            elif strcmp(op, "<<") == 0:
                lhs = lhs << rhs
            elif strcmp(op, ">>") == 0:
                lhs = lhs >> rhs
            elif strcmp(op, "<") == 0:
                lhs = 1 if lhs < rhs else 0
            elif strcmp(op, "<=") == 0:
                lhs = 1 if lhs <= rhs else 0
            elif strcmp(op, ">") == 0:
                lhs = 1 if lhs > rhs else 0
            elif strcmp(op, ">=") == 0:
                lhs = 1 if lhs >= rhs else 0
            elif strcmp(op, "==") == 0:
                lhs = 1 if lhs == rhs else 0
            elif strcmp(op, "!=") == 0:
                lhs = 1 if lhs != rhs else 0
            elif strcmp(op, "&") == 0:
                lhs = lhs & rhs
            elif strcmp(op, "^") == 0:
                lhs = lhs ^ rhs
            elif strcmp(op, "|") == 0:
                lhs = lhs | rhs
            elif strcmp(op, "&&") == 0:
                lhs = 1 if lhs != 0 and rhs != 0 else 0
            elif strcmp(op, "||") == 0:
                lhs = 1 if lhs != 0 or rhs != 0 else 0
        return lhs

    static def ceval(self: *Cp, ok: *bool) -> i64:
        c: i64 = self->ceval_bin(0, ok)
        if *ok and self->is_punct("?"):
            self->adv()
            a: i64 = self->ceval(ok)
            if self->is_punct(":"):
                self->adv()
            else:
                *ok = False
                return 0
            b: i64 = self->ceval(ok)
            return a if c != 0 else b
        return c

    # { A, B = 3, C, D = 1 << 4 } -> DL_ENUM. Values are constant expressions
    # evaluated HERE (become EX_NUMBER with the exact value); auto-increment
    # registered in enumvals for subsequent constants to reference.
    static def parse_enum_body(self: *Cp, tag: const *char) -> *Decl:
        self->expect_punct("{")
        items: Vec<EnumItem>
        items.init()
        next_val: i64 = 0
        while not self->is_punct("}") and self->pk()->kind != CT_EOF:
            iname: const *char = self->adv()->text
            it: EnumItem = {iname, None, self->pk()->pos}
            if self->eat("="):
                vok: bool = True
                v: i64 = self->ceval(&vok)
                if vok:
                    ve: *Expr = ex_new(self->a, EX_NUMBER, self->pk()->pos)
                    ve->text = arena_printf(self->a, "%lld", v)
                    it.value = ve
                    next_val = v + 1
                    self->enumvals.put(iname, v)
                    if v < 0 and tag != None:
                        self->enum_signed.add(tag)   # int representation
                else:
                    self->skip_to(",", "}")
            else:
                self->enumvals.put(iname, next_val)
                next_val += 1
            items.push(it)
            if not self->eat(","):
                break
        self->expect_punct("}")
        d: *Decl = arena_alloc(self->a, sizeof(Decl))
        d->kind = DL_ENUM
        d->name = tag if tag != None else arena_printf(self->a, "__enum%d", self->anon)
        if tag == None:
            self->anon += 1
        d->items = items.data
        d->nitems = items.len
        return d

# ---------- mapping of C operators -> TokKind (op in the AST) ----------
def punct2tok(p: const *char) -> i32:
    if strcmp(p, "+") == 0:
        return TK_PLUS
    if strcmp(p, "-") == 0:
        return TK_MINUS
    if strcmp(p, "*") == 0:
        return TK_STAR
    if strcmp(p, "/") == 0:
        return TK_SLASH
    if strcmp(p, "%") == 0:
        return TK_PERCENT
    if strcmp(p, "&") == 0:
        return TK_AMP
    if strcmp(p, "|") == 0:
        return TK_PIPE
    if strcmp(p, "^") == 0:
        return TK_CARET
    if strcmp(p, "<<") == 0:
        return TK_SHL
    if strcmp(p, ">>") == 0:
        return TK_SHR
    if strcmp(p, "==") == 0:
        return TK_EQ
    if strcmp(p, "!=") == 0:
        return TK_NE
    if strcmp(p, "<") == 0:
        return TK_LT
    if strcmp(p, "<=") == 0:
        return TK_LE
    if strcmp(p, ">") == 0:
        return TK_GT
    if strcmp(p, ">=") == 0:
        return TK_GE
    if strcmp(p, "&&") == 0:
        return TK_AND
    if strcmp(p, "||") == 0:
        return TK_OR
    return TK_EOF

def cbin_prec(p: const *char) -> i32:
    if strcmp(p, "||") == 0:
        return 1
    if strcmp(p, "&&") == 0:
        return 2
    if strcmp(p, "|") == 0:
        return 3
    if strcmp(p, "^") == 0:
        return 4
    if strcmp(p, "&") == 0:
        return 5
    if strcmp(p, "==") == 0 or strcmp(p, "!=") == 0:
        return 6
    if strcmp(p, "<") == 0 or strcmp(p, "<=") == 0 or strcmp(p, ">") == 0 or strcmp(p, ">=") == 0:
        return 7
    if strcmp(p, "<<") == 0 or strcmp(p, ">>") == 0:
        return 8
    if strcmp(p, "+") == 0 or strcmp(p, "-") == 0:
        return 9
    if strcmp(p, "*") == 0 or strcmp(p, "/") == 0 or strcmp(p, "%") == 0:
        return 10
    return 0  # not a binary operator

def is_assign_punct(p: const *char) -> bool:
    return strcmp(p, "=") == 0 or strcmp(p, "+=") == 0 or strcmp(p, "-=") == 0 or strcmp(p, "*=") == 0 or strcmp(p, "/=") == 0 or strcmp(p, "%=") == 0 or strcmp(p, "&=") == 0 or strcmp(p, "|=") == 0 or strcmp(p, "^=") == 0 or strcmp(p, "<<=") == 0 or strcmp(p, ">>=") == 0

def assign2tok(p: const *char) -> i32:
    if strcmp(p, "=") == 0:
        return TK_ASSIGN
    if strcmp(p, "+=") == 0:
        return TK_PLUS_EQ
    if strcmp(p, "-=") == 0:
        return TK_MINUS_EQ
    if strcmp(p, "*=") == 0:
        return TK_STAR_EQ
    if strcmp(p, "/=") == 0:
        return TK_SLASH_EQ
    if strcmp(p, "%=") == 0:
        return TK_PERCENT_EQ
    if strcmp(p, "&=") == 0:
        return TK_AMP_EQ
    if strcmp(p, "|=") == 0:
        return TK_PIPE_EQ
    if strcmp(p, "^=") == 0:
        return TK_CARET_EQ
    if strcmp(p, "<<=") == 0:
        return TK_SHL_EQ
    return TK_SHR_EQ

# forward (mutual recursion between expressions and statements)
def c_expr(p: *Cp) -> *Expr
def c_assign(p: *Cp) -> *Expr
def c_initializer(p: *Cp) -> *Expr
def c_init_elem(p: *Cp, out: *Vec<*Expr>)
def c_unary(p: *Cp) -> *Expr
def c_binary(p: *Cp, minprec: i32) -> *Expr
def c_ternary(p: *Cp) -> *Expr
def c_primary(p: *Cp) -> *Expr
def c_postfix(p: *Cp) -> *Expr
def c_postfix_from(p: *Cp, e: *Expr) -> *Expr
def c_peek_is_type(p: *Cp) -> bool
def c_block(p: *Cp) -> *Block
def cp_alias_restore(p: *Cp, mark: i32)
def c_stmt_into(p: *Cp, out: *Vec<*Stmt>)
def c_decl_into(p: *Cp, out: *Vec<*Stmt>)
def c_simple_stmt(p: *Cp) -> *Stmt
def c_for_into(p: *Cp, out: *Vec<*Stmt>)
def c_typedef(p: *Cp)
def parse_one_decl(p: *Cp, base: *Type, is_extern: bool, pos: Pos) -> *Decl
def parse_one_decl_named(p: *Cp, ty: *Type, name: const *char, is_extern: bool, pos: Pos) -> *Decl
def mark_static(d: *Decl, is_static: bool)
def c_top(p: *Cp) -> *Decl

# ---------- expressions ----------
def c_primary(p: *Cp) -> *Expr:
    t: *CTok = p->pk()
    match t->kind:
        case CT_NUM:
            e: *Expr = ex_new(p->a, EX_NUMBER, t->pos)
            e->text = p->adv()->text
            return e
        case CT_STR:
            e2: *Expr = ex_new(p->a, EX_STRING, t->pos)
            txt: const *char = p->adv()->text
            # adjacent literals concatenate: "a" "b" -> "ab" (joins the bytes
            # between the quotes, preserving escapes)
            while p->pk()->kind == CT_STR:
                nxt: const *char = p->adv()->text
                n1: usize = strlen(txt)
                sb: StrBuf = {0}
                sb_puts(&sb, txt)
                sb.len = n1 - 1        # drop the first string's closing quote
                sb.data[sb.len] = '\0'
                sb_puts(&sb, nxt + 1)  # skip the second string's opening quote
                txt = arena_strdup(p->a, sb.data)
                sb_free(&sb)
            e2->text = txt
            return e2
        case CT_CHAR:
            e3: *Expr = ex_new(p->a, EX_CHARLIT, t->pos)
            e3->text = p->adv()->text
            return e3
        case CT_ID:
            # va_arg(ap, T) / __builtin_va_arg: special form with a TYPE
            if (strcmp(t->text, "va_arg") == 0 or strcmp(t->text, "__builtin_va_arg") == 0) and strcmp(p->pk1()->text, "(") == 0:
                p->adv()
                p->adv()  # (
                va: *Expr = ex_new(p->a, EX_VAARG, t->pos)
                va->lhs = c_assign(p)
                p->expect_punct(",")
                va->cast_type = p->parse_decl_suffix(p->parse_stars(p->parse_base_type()))
                p->expect_punct(")")
                return va
            # __builtin_offsetof(T, field[.sub]): layout constant — becomes
            # EX_CALL("__offsetof", [typeref, ident(path)]) for the backend
            if strcmp(t->text, "__builtin_offsetof") == 0 and strcmp(p->pk1()->text, "(") == 0:
                p->adv()
                p->adv()  # (
                oc: *Expr = ex_new(p->a, EX_CALL, t->pos)
                oce: *Expr = ex_new(p->a, EX_IDENT, t->pos)
                oce->text = "__offsetof"
                oc->lhs = oce
                otr: *Expr = ex_new(p->a, EX_TYPEREF, t->pos)
                otr->cast_type = p->parse_stars(p->parse_base_type())
                p->expect_punct(",")
                path: const *char = p->adv()->text
                while p->eat("."):
                    path = arena_printf(p->a, "%s.%s", path, p->adv()->text)
                p->expect_punct(")")
                onm: *Expr = ex_new(p->a, EX_IDENT, t->pos)
                onm->text = path
                oargs: Vec<*Expr>
                oargs.init()
                oargs.push(otr)
                oargs.push(onm)
                oc->args = oargs.data
                oc->nargs = oargs.len
                return oc
            # _Generic(ctrl, T1: e1, ..., default: eN) — selection by type
            # (C11); the choice happens in the backend (which knows the types)
            if strcmp(t->text, "_Generic") == 0:
                p->adv()
                p->expect_punct("(")
                g: *Expr = ex_new(p->a, EX_GENERIC, t->pos)
                g->lhs = c_assign(p)   # control expr (no comma)
                gtys: Vec<*Type>
                gtys.init()
                gexs: Vec<*Expr>
                gexs.init()
                while p->eat(","):
                    at: *Type = None
                    if p->is_kw("default"):
                        p->adv()
                    else:
                        ab: *Type = p->parse_base_type()
                        at = p->parse_decl_suffix(p->parse_stars(ab))
                    p->expect_punct(":")
                    gexs.push(c_assign(p))
                    gtys.push(at)
                p->expect_punct(")")
                g->args = gexs.data
                g->nargs = gexs.len
                g->gen_types = gtys.data
                return g
            e4: *Expr = ex_new(p->a, EX_IDENT, t->pos)
            e4->text = p->adv()->text
            return e4
        case _:
            if p->is_punct("("):
                p->adv()
                # ({ ... }) GNU: statement expression — becomes control flow (the
                # statements execute at the expression's point; value = the block's
                # last expression, pulled out of it). No backend re-emits the syntax.
                if p->is_punct("{"):
                    se: *Expr = ex_new(p->a, EX_STMTEXPR, t->pos)
                    blk: *Block = c_block(p)
                    p->expect_punct(")")
                    if blk->n > 0 and blk->stmts[blk->n - 1]->kind == ST_EXPR:
                        se->lhs = blk->stmts[blk->n - 1]->expr
                        blk->n -= 1
                    se->xblock = blk
                    return se
                inner: *Expr = c_expr(p)
                p->expect_punct(")")
                return inner
            fatal_at(p->file, t->pos, "invalid expression (found '%s')", t->text if t->text != None else "EOF")
            return None

def c_postfix(p: *Cp) -> *Expr:
    return c_postfix_from(p, c_primary(p))

# postfix suffixes applied to an already-parsed base (also used for
# compound literal: (char[16]){...}[i] indexes the anonymous object)
def c_postfix_from(p: *Cp, e: *Expr) -> *Expr:
    while True:
        pos: Pos = p->pk()->pos
        if p->is_punct("("):
            p->adv()
            call: *Expr = ex_new(p->a, EX_CALL, pos)
            call->lhs = e
            args: Vec<*Expr>
            args.init()
            if not p->is_punct(")"):
                do:
                    args.push(c_assign(p))
                while p->eat(",")
            p->expect_punct(")")
            # __builtin_expect(x, c) is just a branch hint: reinterpret as x
            if e->kind == EX_IDENT and strcmp(e->text, "__builtin_expect") == 0 and args.len >= 1:
                e = args.get(0)
                continue
            call->args = args.data
            call->nargs = args.len
            e = call
        elif p->is_punct("["):
            p->adv()
            ix: *Expr = ex_new(p->a, EX_INDEX, pos)
            ix->lhs = e
            ix->rhs = c_expr(p)
            p->expect_punct("]")
            e = ix
        elif p->is_punct("."):
            p->adv()
            f: *Expr = ex_new(p->a, EX_FIELD, pos)
            f->op = TK_DOT
            f->lhs = e
            f->field = p->adv()->text
            e = f
        elif p->is_punct("->"):
            p->adv()
            f2: *Expr = ex_new(p->a, EX_FIELD, pos)
            f2->op = TK_ARROW
            f2->lhs = e
            f2->field = p->adv()->text
            e = f2
        elif p->is_punct("++") or p->is_punct("--"):
            id: *Expr = ex_new(p->a, EX_INCDEC, pos)
            id->op = TK_PLUS if p->is_punct("++") else TK_MINUS
            id->incdec_post = True
            id->lhs = e
            p->adv()
            e = id
        else:
            break
    return e

def c_unary(p: *Cp) -> *Expr:
    pos: Pos = p->pk()->pos
    # sizeof ( type )  or  sizeof unary-expr. Reuses P's post-sema form:
    # EX_CALL(sizeof, [EX_TYPEREF]) — the C backend emits sizeof(type), QBE
    # emits the constant. (There's no sema in the C frontend, so we already produce the EX_TYPEREF.)
    if p->is_kw("sizeof"):
        p->adv()
        call: *Expr = ex_new(p->a, EX_CALL, pos)
        callee: *Expr = ex_new(p->a, EX_IDENT, pos)
        callee->text = "sizeof"
        call->lhs = callee
        sargs: Vec<*Expr>
        sargs.init()
        if p->is_punct("(") and c_peek_is_type(p):
            p->adv()  # (
            ty: *Type = p->parse_decl_suffix(p->parse_stars(p->parse_base_type()))
            p->expect_punct(")")
            tr: *Expr = ex_new(p->a, EX_TYPEREF, pos)
            tr->cast_type = ty
            sargs.push(tr)
        else:
            sargs.push(c_unary(p))
        call->args = sargs.data
        call->nargs = sargs.len
        return call
    # ++x / --x (prefix)
    if p->is_punct("++") or p->is_punct("--"):
        id: *Expr = ex_new(p->a, EX_INCDEC, pos)
        id->op = TK_PLUS if p->is_punct("++") else TK_MINUS
        id->incdec_post = False
        p->adv()
        id->lhs = c_unary(p)
        return id
    op = 0
    if p->is_punct("-"):
        op = TK_MINUS
    elif p->is_punct("+"):
        op = TK_PLUS
    elif p->is_punct("!"):
        op = TK_NOT
    elif p->is_punct("~"):
        op = TK_TILDE
    elif p->is_punct("*"):
        op = TK_STAR
    elif p->is_punct("&"):
        op = TK_AMP
    if op != 0:
        p->adv()
        e: *Expr = ex_new(p->a, EX_UNARY, pos)
        e->op = op
        e->lhs = c_unary(p)
        return e
    # cast: ( type ) unary   (includes pointer-to-function and abstract
    # declarator with a suffix: (Blk*[]){...}, (int[4]){...})
    if p->is_punct("(") and c_peek_is_type(p):
        p->adv()
        ty: *Type = p->parse_stars(p->parse_base_type())
        if p->is_fnptr_ahead():
            dummy: *char = None
            ty = p->parse_fnptr(ty, &dummy)
        elif p->is_punct("["):
            ty = p->parse_decl_suffix(ty)
        p->expect_punct(")")
        # C99 compound literal:  (type){ ... }  -> anonymous object (postfix
        # suffixes apply: (char[16]){...}[i], (T){...}.field)
        if p->is_punct("{"):
            lit: *Expr = c_initializer(p)   # EX_INITLIST
            cl: *Expr = ex_new(p->a, EX_COMPOUND, pos)
            cl->cast_type = ty
            cl->args = lit->args
            cl->nargs = lit->nargs
            return c_postfix_from(p, cl)
        c: *Expr = ex_new(p->a, EX_CAST, pos)
        c->cast_type = ty
        c->lhs = c_unary(p)
        return c
    return c_postfix(p)

def c_peek_is_type(p: *Cp) -> bool:
    # looks 1 token ahead of the '(' — is it a type name? (builtin, struct/
    # union/enum, or a known typedef)
    nx: *CTok = p->pk1()
    if nx->kind != CT_ID:
        return False
    w: const *char = nx->text
    if p->is_type_kw(w) or strcmp(w, "struct") == 0 or strcmp(w, "union") == 0 or strcmp(w, "enum") == 0 or strcmp(w, "const") == 0:
        return True
    # a cast may open with GNU noise: ((__attribute__((noinline)) int(*)(void))fp)
    if strcmp(w, "__attribute__") == 0 or strcmp(w, "__extension__") == 0 or strcmp(w, "volatile") == 0:
        return True
    return p->types.has(w)

def c_binary(p: *Cp, minprec: i32) -> *Expr:
    left: *Expr = c_unary(p)
    while p->pk()->kind == CT_PUNCT:
        opp: const *char = p->pk()->text
        prec: i32 = cbin_prec(opp)
        if prec == 0 or prec < minprec:
            break
        pos: Pos = p->pk()->pos
        p->adv()
        right: *Expr = c_binary(p, prec + 1)
        b: *Expr = ex_new(p->a, EX_BINARY, pos)
        b->op = punct2tok(opp)
        b->lhs = left
        b->rhs = right
        left = b
    return left

def c_ternary(p: *Cp) -> *Expr:
    c: *Expr = c_binary(p, 1)
    if p->is_punct("?"):
        pos: Pos = p->pk()->pos
        p->adv()
        t: *Expr = c_expr(p)
        p->expect_punct(":")
        f: *Expr = c_ternary(p)
        e: *Expr = ex_new(p->a, EX_TERNARY, pos)
        e->cond = c
        e->lhs = t
        e->rhs = f
        return e
    return c

# assignment level (C): conditional (assign-op assignment)? — right-assoc.
# It's the level used in call arguments and initializer elements (the
# comma there is a separator, not the comma operator).
def c_assign(p: *Cp) -> *Expr:
    left: *Expr = c_ternary(p)
    if p->pk()->kind == CT_PUNCT and is_assign_punct(p->pk()->text):
        pos: Pos = p->pk()->pos
        op: i32 = assign2tok(p->adv()->text)
        e: *Expr = ex_new(p->a, EX_ASSIGN, pos)
        e->op = op
        e->lhs = left
        e->rhs = c_assign(p)
        return e
    return left

# full expression: assignment (',' assignment)* — comma operator
def c_expr(p: *Cp) -> *Expr:
    left: *Expr = c_assign(p)
    while p->is_punct(","):
        pos: Pos = p->pk()->pos
        p->adv()
        e: *Expr = ex_new(p->a, EX_COMMA, pos)
        e->lhs = left
        e->rhs = c_assign(p)
        left = e
    return left

# initializer: expression OR list { ... } (nestable, with C99 designators)
def c_initializer(p: *Cp) -> *Expr:
    if not p->is_punct("{"):
        return c_assign(p)
    pos: Pos = p->pk()->pos
    p->adv()  # {
    e: *Expr = ex_new(p->a, EX_INITLIST, pos)
    args: Vec<*Expr>
    args.init()
    while not p->is_punct("}") and p->pk()->kind != CT_EOF:
        c_init_elem(p, &args)
        if not p->eat(","):
            break
    p->expect_punct("}")
    e->args = args.data
    e->nargs = args.len
    return e

# one list element: [idx]=v / .field=v (C99 designator) or value/nested.
# Extensions reinterpreted as standard C99 (the GNU form doesn't survive into the AST):
#   [a ... b] = v  ->  [a]=v, [a+1]=v, ..., [b]=v   (expansion)
#   .a.j = v / [i][j] = v  ->  .a = {.j = v} / [i] = {[j] = v}  (nesting;
#   zero-initialization of the rest is the same in both)
def c_init_elem(p: *Cp, out: *Vec<*Expr>):
    if p->is_punct("[") or p->is_punct("."):
        pos: Pos = p->pk()->pos
        d: *Expr = ex_new(p->a, EX_DESIG, pos)
        lo: i64 = 0
        hi: i64 = 0
        is_range: bool = False
        if p->is_punct("["):
            p->adv()
            d->rhs = c_expr(p)   # index (constant)
            if p->is_punct("..."):
                p->adv()
                he: *Expr = c_expr(p)
                if d->rhs->kind != EX_NUMBER or he->kind != EX_NUMBER:
                    fatal_at(p->file, pos, "range designator bounds must be integer literals")
                lo = strtoll(d->rhs->text, None, 0)
                hi = strtoll(he->text, None, 0)
                if hi < lo:
                    fatal_at(p->file, pos, "range designator with descending bounds")
                is_range = True
            p->expect_punct("]")
        else:
            p->adv()  # .
            d->field = p->adv()->text
        # chained designators: each extra level becomes a nested list
        chain: *Expr[8]
        nchain = 0
        while p->is_punct("[") or p->is_punct("."):
            cpos: Pos = p->pk()->pos
            cd: *Expr = ex_new(p->a, EX_DESIG, cpos)
            if p->eat("["):
                cd->rhs = c_expr(p)
                p->expect_punct("]")
            else:
                p->adv()
                cd->field = p->adv()->text
            if nchain < 8:
                chain[nchain] = cd
                nchain += 1
        p->expect_punct("=")
        v: *Expr = c_initializer(p)
        # wraps from inside out: .a.j=v -> .a = {.j = v}
        ci: i32
        for ci in range(nchain - 1, -1, -1):
            chain[ci]->lhs = v
            wrap: *Expr = ex_new(p->a, EX_INITLIST, chain[ci]->pos)
            wa: **Expr = arena_alloc(p->a, sizeof(v))
            wa[0] = chain[ci]
            wrap->args = wa
            wrap->nargs = 1
            v = wrap
        d->lhs = v
        if is_range:
            # range: expands into unit designators (same value)
            for k in range(lo, hi + 1):
                dk: *Expr = ex_new(p->a, EX_DESIG, pos)
                ik: *Expr = ex_new(p->a, EX_NUMBER, pos)
                ik->text = arena_printf(p->a, "%lld", k)
                dk->rhs = ik
                dk->lhs = v
                out->push(dk)
            return
        out->push(d)
        return
    out->push(c_initializer(p))

# ---------- statements ----------
# undoes scoped struct-tag renames registered after `mark` (block exit)
def cp_alias_restore(p: *Cp, mark: i32):
    while p->nalias > mark:
        p->nalias -= 1
        p->tag_alias.put(p->alias_names[p->nalias], p->alias_prevs[p->nalias])

def c_block(p: *Cp) -> *Block:
    v: Vec<*Stmt>
    v.init()
    amark: i32 = p->nalias
    if p->eat("{"):
        while not p->is_punct("}") and p->pk()->kind != CT_EOF:
            c_stmt_into(p, &v)
        p->expect_punct("}")
    else:
        c_stmt_into(p, &v)
    cp_alias_restore(p, amark)
    b: *Block = arena_alloc(p->a, sizeof(Block))
    b->stmts = v.data
    b->n = v.len
    return b

def c_decl_into(p: *Cp, out: *Vec<*Stmt>):
    is_static: bool = p->is_kw("static")  # parse_base_type/skip_gnu consumes it
    base: *Type = p->parse_base_type()
    # local type def without a declarator:  struct T { ... } ;
    if p->is_punct(";"):
        p->adv()
        return
    do:
        ty: *Type = p->parse_stars(base)
        name: const *char
        # local function pointer:  RET (*name)(params)
        if p->is_fnptr_ahead():
            fpn: *char = None
            ty = p->parse_fnptr(ty, &fpn); name = fpn
        else:
            name = p->adv()->text
            # local function prototype:  RET name(params) ;  -> just skip it
            if p->is_punct("("):
                p->skip_parens()
                p->skip_gnu()
                continue
            # arrays: name[d0][d1]... — in C, arr[2][4] = array[2] of array[4],
            # so apply the dims in REVERSE order (the innermost last)
            adims: *Expr[8]
            andim = 0
            while p->eat("["):
                dd: *Expr = None
                if not p->is_punct("]"):
                    dd = c_expr(p)
                p->expect_punct("]")
                if andim < 8:
                    adims[andim] = dd
                    andim += 1
            ak: i32
            for ak in range(andim - 1, -1, -1):
                ty = ty_array(p->a, ty, adims[ak])
        s: *Stmt = st_new(p->a, ST_VAR, p->pk()->pos)
        s->name = name
        s->type = ty
        s->is_static = is_static
        if p->eat("="):
            s->init = c_initializer(p)
        out.push(s)
    while p->eat(",")
    p->expect_punct(";")

def c_stmt_into(p: *Cp, out: *Vec<*Stmt>):
    pos: Pos = p->pk()->pos
    # null statement:  ;
    if p->is_punct(";"):
        p->adv()
        return
    # local typedef (inside a function): registers the type, doesn't generate a statement
    if p->is_kw("typedef"):
        c_typedef(p)
        return
    # case V:  /  default:  (markers inside a switch). Like `label:`, the marker
    # PREFIXES the following statement — parse it into the same block, or the
    # body of a braceless `switch (x) case 0: stmt;` would escape the switch.
    if p->is_kw("case"):
        p->adv()
        cv: *Expr = c_ternary(p)   # the case's constant expression
        p->expect_punct(":")
        cs: *Stmt = st_new(p->a, ST_CASE, pos)
        cs->expr = cv
        out.push(cs)
        if not p->is_punct("}"):
            c_stmt_into(p, out)
        return
    if p->is_kw("default"):
        p->adv()
        p->expect_punct(":")
        out.push(st_new(p->a, ST_CASE, pos))  # expr=None => default
        if not p->is_punct("}"):
            c_stmt_into(p, out)
        return
    if p->is_kw("switch"):
        p->adv()
        p->expect_punct("(")
        subj: *Expr = c_expr(p)
        p->expect_punct(")")
        sw: *Stmt = st_new(p->a, ST_SWITCH, pos)
        sw->subject = subj
        sw->body = c_block(p)
        out.push(sw)
        return
    # label:  name :
    if p->pk()->kind == CT_ID and p->pk1()->kind == CT_PUNCT and strcmp(p->pk1()->text, ":") == 0:
        lbl: const *char = p->adv()->text
        p->adv()  # ':'
        ls: *Stmt = st_new(p->a, ST_LABEL, pos)
        ls->label = lbl
        out.push(ls)
        # in C, `label:` prefixes the following statement — parse it in the same
        # block (otherwise, as the body of an if/while without braces, it would escape)
        if not p->is_punct("}"):
            c_stmt_into(p, out)
        return
    if p->is_kw("goto"):
        p->adv()
        gs: *Stmt = st_new(p->a, ST_GOTO, pos)
        gs->label = p->adv()->text
        p->expect_punct(";")
        out.push(gs)
        return
    if p->is_punct("{"):
        # nested block: a REAL scope (ST_BLOCK) — an inner `int s;` must not
        # collide with a sibling `s`, and local struct tags shadow outer ones
        p->adv()
        bs: *Stmt = st_new(p->a, ST_BLOCK, pos)
        bv: Vec<*Stmt>
        bv.init()
        amark: i32 = p->nalias
        while not p->is_punct("}") and p->pk()->kind != CT_EOF:
            c_stmt_into(p, &bv)
        p->expect_punct("}")
        cp_alias_restore(p, amark)
        bb: *Block = arena_alloc(p->a, sizeof(Block))
        bb->stmts = bv.data
        bb->n = bv.len
        bs->body = bb
        out.push(bs)
        return
    if p->is_kw("return"):
        p->adv()
        s: *Stmt = st_new(p->a, ST_RETURN, pos)
        if not p->is_punct(";"):
            s->expr = c_expr(p)
        p->expect_punct(";")
        out.push(s)
        return
    if p->is_kw("if"):
        p->adv()
        p->expect_punct("(")
        cond: *Expr = c_expr(p)
        p->expect_punct(")")
        thenb: *Block = c_block(p)
        s2: *Stmt = st_new(p->a, ST_IF, pos)
        conds: Vec<*Expr>
        blocks: Vec<*Block>
        conds.init()
        blocks.init()
        conds.push(cond)
        blocks.push(thenb)
        s2->conds = conds.data
        s2->blocks = blocks.data
        s2->nconds = 1
        if p->is_kw("else"):
            p->adv()
            s2->else_block = c_block(p)
        out.push(s2)
        return
    if p->is_kw("while"):
        p->adv()
        p->expect_punct("(")
        wc: *Expr = c_expr(p)
        p->expect_punct(")")
        s3: *Stmt = st_new(p->a, ST_WHILE, pos)
        s3->cond = wc
        s3->body = c_block(p)
        out.push(s3)
        return
    if p->is_kw("do"):
        p->adv()
        body: *Block = c_block(p)
        if not p->is_kw("while"):
            fatal_at(p->file, p->pk()->pos, "expected 'while' after do-block")
        p->adv()  # while
        p->expect_punct("(")
        dc: *Expr = c_expr(p)
        p->expect_punct(")")
        p->expect_punct(";")
        sd: *Stmt = st_new(p->a, ST_DO, pos)
        sd->cond = dc
        sd->body = body
        out.push(sd)
        return
    if p->is_kw("for"):
        c_for_into(p, out)
        return
    if p->is_kw("break"):
        p->adv()
        p->expect_punct(";")
        out.push(st_new(p->a, ST_BREAK, pos))
        return
    if p->is_kw("continue"):
        p->adv()
        p->expect_punct(";")
        out.push(st_new(p->a, ST_CONTINUE, pos))
        return
    if p->at_type():
        c_decl_into(p, out)
        return
    # expression statement (assignment is now an expression; demote a top-level
    # assignment to ST_ASSIGN, reusing the backends' solid path)
    e: *Expr = c_expr(p)
    p->expect_punct(";")
    if e->kind == EX_ASSIGN:
        s4: *Stmt = st_new(p->a, ST_ASSIGN, pos)
        s4->lhs = e->lhs
        s4->op = e->op
        s4->rhs = e->rhs
        out.push(s4)
        return
    s5: *Stmt = st_new(p->a, ST_EXPR, pos)
    s5->expr = e
    out.push(s5)

# a "simple statement" for the for's init/post: 1-var decl, assignment, or
# expression. Doesn't consume ';'. Returns None if empty.
def c_simple_stmt(p: *Cp) -> *Stmt:
    pos: Pos = p->pk()->pos
    if p->at_type():
        base: *Type = p->parse_base_type()
        ty: *Type = p->parse_stars(base)
        name: const *char = p->adv()->text
        while p->eat("["):
            dim: *Expr = None
            if not p->is_punct("]"):
                dim = c_expr(p)
            p->expect_punct("]")
            ty = ty_array(p->a, ty, dim)
        s: *Stmt = st_new(p->a, ST_VAR, pos)
        s->name = name
        s->type = ty
        if p->eat("="):
            s->init = c_initializer(p)
        return s
    e: *Expr = c_expr(p)
    if e->kind == EX_ASSIGN:
        s2: *Stmt = st_new(p->a, ST_ASSIGN, pos)
        s2->lhs = e->lhs
        s2->op = e->op
        s2->rhs = e->rhs
        return s2
    s3: *Stmt = st_new(p->a, ST_EXPR, pos)
    s3->expr = e
    return s3

# for(init; cond; post) body  ->  faithful ST_CFOR (the C backend emits a for;
# the QBE backend flattens it with continue -> post step)
def c_for_into(p: *Cp, out: *Vec<*Stmt>):
    pos: Pos = p->pk()->pos
    p->adv()  # for
    p->expect_punct("(")
    s: *Stmt = st_new(p->a, ST_CFOR, pos)
    if not p->is_punct(";"):
        # declaration with MULTIPLE declarators in the init (C99:
        # `for (char *a = x, b = 0; ...)`): hoists the declarations before the
        # for (equivalent — the scope model here is flat)
        if p->at_type():
            fbase: *Type = p->parse_base_type()
            do:
                fty: *Type = p->parse_stars(fbase)
                fname: const *char = p->adv()->text
                while p->eat("["):
                    fdim: *Expr = None
                    if not p->is_punct("]"):
                        fdim = c_expr(p)
                    p->expect_punct("]")
                    fty = ty_array(p->a, fty, fdim)
                fs: *Stmt = st_new(p->a, ST_VAR, pos)
                fs->name = fname
                fs->type = fty
                if p->eat("="):
                    fs->init = c_initializer(p)
                out.push(fs)
            while p->eat(",")
        else:
            s->for_init = c_simple_stmt(p)
    p->expect_punct(";")
    if not p->is_punct(";"):
        s->cond = c_expr(p)
    p->expect_punct(";")
    if not p->is_punct(")"):
        s->for_post = c_simple_stmt(p)
    p->expect_punct(")")
    s->body = c_block(p)
    out.push(s)

# typedef <type> <name> ;  — registers the resolved name; the embedded
# struct/enum def was already emitted by parse_base_type. Doesn't generate its own decl.
def c_typedef(p: *Cp):
    p->adv()  # typedef
    base: *Type = p->parse_base_type()
    do:
        ty: *Type = p->parse_stars(base)
        # function-pointer declarator: typedef T (*name)(...) — captures the
        # name and registers the pointer-to-function type (needed for inference
        # of chained calls: `fty go(); go()()->field`)
        if p->is_fnptr_ahead():
            fpn: *char = None
            fpt: *Type = p->parse_fnptr(ty, &fpn)
            if fpn != None and fpn[0] != '\0':
                p->types.add(fpn)
                p->typedefs.put(fpn, fpt)
            continue
        if p->is_punct("("):
            p->skip_parens()   # unsupported form: ignore this declarator
            if p->is_punct("("):
                p->skip_parens()  # (args)
            continue
        p->skip_gnu()
        if p->pk()->kind != CT_ID:
            break
        name: const *char = p->adv()->text
        # function-type typedef:  typedef RET name (params) ;  -> registers name
        if p->is_punct("("):
            p->skip_parens()
            p->skip_gnu()
            p->types.add(name)
            p->typedefs.put(name, ty)
            continue
        if p->is_punct("["):
            # ARRAY typedef (jmp_buf[1], __jmp_buf[8]): a real array type —
            # the size matters (variables of this type reserve the buffer)
            ty = p->parse_decl_suffix(ty)
        p->skip_gnu()
        p->types.add(name)
        p->typedefs.put(name, ty)
    while p->eat(",")
    p->expect_punct(";")

# ---------- top level: typedef / type def / function / global variable ----------
# parses ONE declarator given the base type: RET (*name)(p) | name(params) |
# name[dims] | name. Returns DL_FUNC (proto/def) or DL_VAR. Does NOT consume ',' or
# ';' (the caller handles the list).
def parse_one_decl(p: *Cp, base: *Type, is_extern: bool, pos: Pos) -> *Decl:
    ty: *Type = p->parse_stars(base)
    # declarator with a group: RET (*name)(params) = fn-ptr var, OR
    # RET (*name(params))(params2) = FUNCTION whose return type is fn-ptr (00124)
    if p->is_fnptr_ahead():
        fpname: *char = None
        fprms: Vec<Param>
        fprms.init()
        fva: bool = False
        fhp: bool = False
        fpty: *Type = p->parse_declarator(ty, &fpname, &fprms, &fva, &fhp)
        if fpty != None and fpty->kind == TY_FUNC and fhp:
            ff: *Func = arena_alloc(p->a, sizeof(Func))
            with ff:
                .pos = pos
                .name = fpname
                .cname = fpname
                .ret = fpty->inner
                .params = fprms.data
                .nparams = fprms.len
                .is_varargs = fva
                if p->is_punct("{"):
                    .body = c_block(p)   # definition
            df: *Decl = arena_alloc(p->a, sizeof(Decl))
            df->kind = DL_FUNC
            df->pos = pos
            df->func = ff
            return df
        dfp: *Decl = arena_alloc(p->a, sizeof(Decl))
        with dfp:
            .kind = DL_VAR
            .pos = pos
            .name = fpname
            .type = fpty
            .is_extern = is_extern
            if p->eat("="):
                .init = c_initializer(p)
        return dfp
    # parens-only declarator: `void *(incmem)(...)` — strips the parens
    if p->is_punct("(") and p->pk1()->kind == CT_ID and p->i + 2 < p->nt and p->t[p->i + 2].text != None and strcmp(p->t[p->i + 2].text, ")") == 0:
        p->adv()
        name0: const *char = p->adv()->text
        p->expect_punct(")")
        return parse_one_decl_named(p, ty, name0, is_extern, pos)
    name: const *char = p->adv()->text
    return parse_one_decl_named(p, ty, name, is_extern, pos)

# continuation of parse_one_decl after the name has already been consumed (function or variable)
def parse_one_decl_named(p: *Cp, ty: *Type, name: const *char, is_extern: bool, pos: Pos) -> *Decl:
    if p->is_punct("("):
        # function (prototype or definition)
        p->adv()
        params: Vec<Param>
        params.init()
        is_vararg: bool = False
        p->parse_params(&params, &is_vararg)
        p->expect_punct(")")
        p->skip_gnu()   # __attribute__/__asm__ after the parameter list
        f: *Func = arena_alloc(p->a, sizeof(Func))
        with f:
            .pos = pos
            .name = name
            .cname = name
            .ret = ty
            .params = params.data
            .nparams = params.len
            .is_varargs = is_vararg
            if p->is_punct("{"):
                .body = c_block(p)   # definition
        d: *Decl = arena_alloc(p->a, sizeof(Decl))
        d->kind = DL_FUNC
        d->pos = pos
        d->func = f
        return d
    # variable (with array; dims in REVERSE order: a[2][4] = array[2] of
    # array[4] — the innermost applies last)
    gdims: *Expr[8]
    gnd = 0
    while p->eat("["):
        dim: *Expr = None
        if not p->is_punct("]"):
            dim = c_expr(p)
        p->expect_punct("]")
        if gnd < 8:
            gdims[gnd] = dim
            gnd += 1
    gk: i32
    for gk in range(gnd - 1, -1, -1):
        ty = ty_array(p->a, ty, gdims[gk])
    p->skip_gnu()
    d2: *Decl = arena_alloc(p->a, sizeof(Decl))
    with d2:
        .kind = DL_VAR
        .pos = pos
        .name = name
        .type = ty
        .is_extern = is_extern
        if p->eat("="):
            .init = c_initializer(p)
    return d2

def c_top(p: *Cp) -> *Decl:
    pos: Pos = p->pk()->pos
    is_extern: bool = p->is_kw("extern")   # before skip_gnu consumes it
    is_static: bool = p->is_kw("static")   # local symbol of the TU (not exported)
    p->skip_gnu()
    if p->is_kw("typedef"):
        c_typedef(p)
        return None
    base: *Type = p->parse_base_type()
    p->skip_gnu()
    # struct/enum/union def without a declarator:  struct S { ... } ;
    if p->is_punct(";"):
        p->adv()
        return None
    d: *Decl = parse_one_decl(p, base, is_extern, pos)
    mark_static(d, is_static)
    # function definition (with a body): there's no list or ';'
    if d != None and d->kind == DL_FUNC and d->func->body != None:
        return d
    # list of declarators (prototypes and/or variables):  base D1, D2, ... ;
    while p->eat(","):
        dn: *Decl = parse_one_decl(p, base, is_extern, pos)
        mark_static(dn, is_static)
        if dn != None:
            p->out_decls.push(dn)
    p->expect_punct(";")
    return d

# propagates top-level `static`: function isn't exported; global becomes a TU symbol
def mark_static(d: *Decl, is_static: bool):
    if d == None or not is_static:
        return
    if d->kind == DL_FUNC:
        d->func->is_static = True
    elif d->kind == DL_VAR:
        d->is_static = True

def c_parse(a: *Arena, file: const *char, bytes: const *char, nbytes: usize) -> *Module:
    cx: Cx = {0}
    cx.file = file
    cx.s = bytes
    cx.n = nbytes
    cx.line = 1
    cx.col = 1
    cx.a = a
    cx.toks.init()
    cx.tokenize()

    cp: Cp = {0}
    cp.file = file
    cp.t = cx.toks.data
    cp.nt = cx.toks.len
    cp.a = a
    cp.types.init()
    cp.typedefs.init()
    cp.enumvals.init()
    cp.enum_signed.init()
    cp.anon = 0
    # types the backend already understands (C builtins + P aliases)
    builtins: const *char[] = {"void", "char", "short", "int", "long",
        "float", "double", "signed", "unsigned", "_Bool", "size_t",
        "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t", "wchar_t",
        "va_list", "__builtin_va_list", None}
    bi = 0
    while builtins[bi] != None:
        cp.types.add(builtins[bi])
        bi += 1

    m: *Module = arena_alloc(a, sizeof(Module))
    m->path = arena_strdup(a, file)
    m->is_header = False
    m->is_c = True
    decls: Vec<*Decl>
    decls.init()
    cp.out_decls = &decls
    while cp.pk()->kind != CT_EOF:
        d: *Decl = c_top(&cp)
        if d != None:
            decls.push(d)
    m->decls = decls.data
    m->ndecls = decls.len
    cp.types.deinit()
    cp.typedefs.deinit()
    cp.fwd_tags.deinit()
    cp.def_tags.deinit()
    cp.tag_alias.deinit()
    free(cp.alias_names)
    free(cp.alias_prevs)
    return m
