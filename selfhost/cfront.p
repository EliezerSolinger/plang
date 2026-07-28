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
def is_hex_digit(c: char) -> bool
def c_num_error(t: const *char) -> const *char
def c_static_assert(p: *Cp)
def c_ternary(p: *Cp) -> *Expr
def word_count(s: const *char, w: const *char) -> i32
def word_in(s: const *char, w: const *char) -> bool

struct CTok:
    kind: CtKind
    text: const *char
    pos: Pos

declare Vec<CTok>
implement Vec<CTok>

# ---------- tokenizer ----------
# valid C escape after a backslash: simple escapes, octal, hex, universal
# (\u/\U) and the GNU \e (kept: gcc accepts it)
static def is_c_escape(e: char) -> bool:
    if e >= '0' and e <= '7':
        return True
    return e in {'n', 't', 'r', 'a', 'b', 'f', 'v', 'x', 'u', 'U', 'e', '\'', '"', '?', '\\', '\n'}

struct Cx:
    file: const *char
    s: const *char
    n: usize
    i: usize
    line: i32
    col: i32
    toks: Vec<CTok>
    a: *Arena
    strict: bool   # user code: lexical constraint violations are errors

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
        return self->a->strndup(self->s + start, self->i - start)

    static def tokenize(self: *Cx):
        while self->i < self->n:
            c: char = self->s[self->i]
            # whitespace
            if c in {' ', '\t', '\r', '\n'}:
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
            if (c in {'L', 'u', 'U'}) and self->i + 1 < self->n and (self->s[self->i + 1] == '\'' or self->s[self->i + 1] == '"'):
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
            if (c >= '0' and c <= '9') or (c == '.' and self->peekc(1) >= '0' and self->peekc(1) <= '9'):
                start2: usize = self->i
                while self->i < self->n and is_num_cont(self->s[self->i]):
                    ch: char = self->s[self->i]
                    self->adv()
                    # sign after exponent (e/E dec, p/P hex) is part of the number
                    if (ch in {'e', 'E', 'p', 'P'}) and self->i < self->n and (self->s[self->i] == '+' or self->s[self->i] == '-'):
                        self->adv()
                # NOT validated here. What is scanned above is C's
                # PREPROCESSING-NUMBER (C11 6.4.8), which is deliberately looser
                # than a numeric constant: `10.13.4` is a well-formed pp-number
                # and only ill-formed if something tries to USE it as a value.
                # macOS headers are full of them — `__attribute__((availability(
                # macos,introduced=10.13.4)))` — inside constructs we skip, so
                # rejecting at tokenize time made <stdlib.h> unparseable.
                # c_num_error runs at the two places a CT_NUM becomes a value
                # (c_primary and ceval_prim), which is where C says it matters.
                self->push(CT_NUM, pos, self->slice(start2))
                continue
            # string
            if c == '"':
                start3: usize = self->i
                self->adv()
                while self->i < self->n and self->s[self->i] != '"':
                    if self->strict and self->s[self->i] == '\n':
                        fatal_at(self->file, pos, "newline in string literal (missing closing '\"')")
                    if self->s[self->i] == '\\':
                        self->adv()
                        if self->strict and not is_c_escape(self->s[self->i]):
                            fatal_at(self->file, pos, "invalid escape sequence '\\%c' in string literal", self->s[self->i])
                    self->adv()
                self->adv()  # closing quote
                self->push(CT_STR, pos, self->slice(start3))
                continue
            # char
            if c == '\'':
                start4: usize = self->i
                self->adv()
                while self->i < self->n and self->s[self->i] != '\'':
                    if self->strict and self->s[self->i] == '\n':
                        fatal_at(self->file, pos, "newline in character constant")
                    if self->s[self->i] == '\\':
                        self->adv()
                        if self->strict and not is_c_escape(self->s[self->i]):
                            fatal_at(self->file, pos, "invalid escape sequence '\\%c' in character constant", self->s[self->i])
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
        elif c == '-' and (c1 in {'>', '-', '='}):
            two = True
        elif c == '+' and (c1 == '+' or c1 == '='):
            two = True
        elif c == '&' and (c1 == '&' or c1 == '='):
            two = True
        elif c == '|' and (c1 == '|' or c1 == '='):
            two = True
        elif (c in {'=', '!', '*', '/', '%', '^'}) and c1 == '=':
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
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F') or c in {'x', 'X', '.', 'u', 'U', 'l', 'L', 'p', 'P'}

def is_hex_digit(c: char) -> bool:
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')

# validates the FORM of a C number constant; returns a human explanation of
# what is wrong, or None when well-formed. The lexer is greedy (12ul2 is one
# token), so this is where `1e`, `1e+`, `100ul2`, `09` get a friendly error.
def c_num_error(t: const *char) -> const *char:
    i: i32 = 0
    hex: bool = t[0] == '0' and (t[1] == 'x' or t[1] == 'X')
    isflt: bool = False
    if hex:
        i = 2
        nd = 0
        while is_hex_digit(t[i]):
            i += 1
            nd += 1
        if t[i] == '.':
            isflt = True
            i += 1
            while is_hex_digit(t[i]):
                i += 1
                nd += 1
        if nd == 0:
            return "hex constant needs at least one digit"
        if t[i] == 'p' or t[i] == 'P':
            isflt = True
            i += 1
            if t[i] == '+' or t[i] == '-':
                i += 1
            if not (t[i] >= '0' and t[i] <= '9'):
                return "hex-float exponent needs at least one digit"
            while t[i] >= '0' and t[i] <= '9':
                i += 1
        elif isflt:
            return "hex float requires a 'p' exponent"
    else:
        oct_: bool = t[0] == '0'
        bad8: bool = False
        while t[i] >= '0' and t[i] <= '9':
            if t[i] > '7':
                bad8 = True
            i += 1
        if t[i] == '.':
            isflt = True
            i += 1
            while t[i] >= '0' and t[i] <= '9':
                i += 1
        if t[i] == 'e' or t[i] == 'E':
            isflt = True
            i += 1
            if t[i] == '+' or t[i] == '-':
                i += 1
            if not (t[i] >= '0' and t[i] <= '9'):
                return "exponent needs at least one digit"
            while t[i] >= '0' and t[i] <= '9':
                i += 1
        if oct_ and bad8 and not isflt:
            return "invalid digit in octal constant (digits must be 0-7)"
    # suffix: float -> one of f/F/l/L, or a GCC _FloatN suffix (f16/f32/f64/
    # f128/f32x/f64x — como em 0.0f16 nos headers do SDL); integer -> u/U e
    # up to two l/L
    if isflt:
        if t[i] in {'f', 'F', 'l', 'L'}:
            i += 1
            # _FloatN: digits glued to the f/F (16, 32, 64, 128) + an optional 'x'
            if (t[i - 1] == 'f' or t[i - 1] == 'F') and t[i] >= '0' and t[i] <= '9':
                nfd = 0
                while t[i] >= '0' and t[i] <= '9':
                    i += 1
                    nfd += 1
                if nfd > 3:
                    return "invalid suffix on number constant"
                if t[i] == 'x' or t[i] == 'X':
                    i += 1
    else:
        # integer suffix: at most one u/U and one L-GROUP ('l', 'L', 'll' or
        # 'LL' — the two must be ADJACENT and the SAME case: 'lL' and 'lul'
        # are invalid), in either order
        us = 0; ls = 0
        while t[i] != '\0':
            if (t[i] == 'u' or t[i] == 'U') and us == 0:
                us = 1
                i += 1
            elif (t[i] == 'l' or t[i] == 'L') and ls == 0:
                lcase: char = t[i]
                ls = 1
                i += 1
                if t[i] == lcase:
                    ls = 2
                    i += 1
                elif t[i] == 'l' or t[i] == 'L':
                    return "mixed-case 'll' suffix"
            else:
                break
    if t[i] != '\0':
        return "invalid suffix on number constant"
    return None

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
            # octal escape \NNN (\0 already handled above)
            if e >= '0' and e <= '7':
                ov = 0
                ok2: usize = 2
                while ok2 < n - 1 and lex[ok2] >= '0' and lex[ok2] <= '7':
                    ov = ov * 8 + i32(lex[ok2] - '0')
                    ok2 += 1
                return ov
            return i32(e)   # \? \e etc: the character itself
    return 0

# a real C KEYWORD can never be a declarator name. Typedef names CAN (member
# and inner-scope names shadow them — C keeps separate namespaces).
static def is_c_keyword(w: const *char) -> bool:
    if w == None:
        return False
    match w[0]:
        case 'a':
            return w == "auto"
        case 'b':
            return w == "break"
        case 'c':
            return w in {"case", "char", "const", "continue"}
        case 'd':
            return w in {"default", "do", "double"}
        case 'e':
            return w in {"else", "enum", "extern"}
        case 'f':
            return w in {"float", "for"}
        case 'g':
            return w == "goto"
        case 'i':
            return w in {"if", "int", "inline"}
        case 'l':
            return w == "long"
        case 'r':
            return w in {"register", "restrict", "return"}
        case 's':
            return w in {"short", "signed", "sizeof", "static", "struct", "switch"}
        case 't':
            return w == "typedef"
        case 'u':
            return w in {"union", "unsigned"}
        case 'v':
            return w in {"void", "volatile"}
        case 'w':
            return w == "while"
        case '_':
            return w == "_Bool"
        case _:
            return False

# ---------- scoped tag table ----------
# C keeps ONE tag namespace with BLOCK scope: `struct s` in an inner block
# shadows the outer one; a standalone `struct s;` DECLARES a new incomplete
# tag in the current scope; kind (struct/union) is part of the identity.
# Each identity gets a unique emitted name (cname) because our decls are
# hoisted to module level — the outermost keeps the source spelling.
struct CTag:
    name: const *char    # tag as written in the source
    cname: const *char   # unique emitted name (name, or name__sN when shadowing)
    is_union: bool       # struct vs union — same namespace, distinct kinds
    defined: bool        # this identity has seen a body
    depth: i32           # lexical scope depth of the declaration

declare Vec<CTag>
implement Vec<CTag>

# ---------- parser ----------
# forward: parse_params (a Cp method) parses array-dimension sizes with c_expr
def c_expr(p: *Cp) -> *Expr

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
    tags: Vec<CTag>          # visible tag identities, innermost LAST; blocks
                             #   save/restore tags.len (see c_block)
    tag_depth: i32           # current lexical scope depth
    used_cnames: StrSet      # every emitted tag cname (module-wide uniqueness)
    out_decls: *Vec<*Decl>   # structs/enums found are emitted here
    params_empty: bool       # last COMPLETED parse_params saw `()` (sig unknown)
    cap_sig_empty: bool      # same, for the signature captured by parse_declarator
    anon: i32                # counter for anonymous tags
    saw_const: bool          # skip_gnu saw 'const' (read by parse_base_type)
    strict: bool             # user code: C constraint violations are ERRORS.
                             # False for ingested system headers (GNU noise).
    spec_static: bool        # storage class absorbed mid-specifier (C allows
    spec_extern: bool        #   `int static signed i`): read by the caller

    static def skip_gnu(self: *Cp)
    static def is_storage_kw(self: *Cp, w: const *char) -> bool
    static def tag_find(self: *Cp, name: const *char) -> i32
    static def tag_push(self: *Cp, name: const *char, is_union: bool, defined: bool) -> i32
    static def skip_parens(self: *Cp)
    static def skip_braces(self: *Cp)
    static def has_block_decl(self: *Cp) -> bool
    static def skip_to(self: *Cp, a: const *char, b: const *char)
    static def is_type_kw(self: *Cp, w: const *char) -> bool
    static def canon_arith(self: *Cp, n: const *char) -> const *char
    static def check_arith_specs(self: *Cp, n: const *char, pos: Pos)
    static def parse_base_type(self: *Cp) -> *Type
    static def base_name(self: *Cp, n: const *char) -> *Type
    static def parse_stars(self: *Cp, base: *Type) -> *Type
    static def is_fnptr_ahead(self: *Cp) -> bool
    static def parse_fnptr(self: *Cp, ret: *Type, out out_name: *char) -> *Type
    static def parse_declarator(self: *Cp, base: *Type, out out_name: *char, ref prms: Vec<Param>, out varargs: bool, out has_params: bool) -> *Type
    static def parse_decl_suffix(self: *Cp, ty: *Type) -> *Type
    static def parse_params(self: *Cp, ref prms: Vec<Param>, out varargs: bool)
    static def parse_params_inner(self: *Cp, ref prms: Vec<Param>, out varargs: bool)
    static def parse_struct_body(self: *Cp, tag: const *char, is_union: bool) -> *Decl
    static def parse_enum_body(self: *Cp, tag: const *char) -> *Decl
    static def tok_is_type(self: *Cp, w: const *char) -> bool
    static def type_size(self: *Cp, t: *Type, ref ok: bool) -> i64
    static def ceval_prim(self: *Cp, ref ok: bool) -> i64
    static def ceval_prec(self: *Cp) -> i32
    static def ceval_bin(self: *Cp, minprec: i32, ref ok: bool) -> i64
    static def ceval(self: *Cp, ref ok: bool) -> i64

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
        # __int128/_Complex combine as type words
        return w in {"void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "_Bool", "__int128", "_Complex", "_Imaginary"}

    # storage-class specifier — legal in any position among the type words
    static def is_storage_kw(self: *Cp, w: const *char) -> bool:
        return w in {"static", "extern", "register", "auto"}

    # GNU noise/qualifiers that cproc accepts and we ignore:
    # __attribute__((...)) / __asm__(...) / const / volatile / restrict /
    # __extension__ / storage classes. Returns after skipping everything applicable.
    static def skip_gnu(self: *Cp):
        while self->pk()->kind == CT_ID:
            w: const *char = self->pk()->text
            # takes a PARENTHESIZED argument, which is skipped whole. `_Alignas`
            # is C11's alignment specifier (`_Alignas(16) char buf[16]`) and is
            # dropped for the same reason as `__attribute__((aligned(N)))`:
            # alignment does not change the emitted C, which carries the
            # specifier's own source through unchanged.
            if w in {"__attribute__", "__attribute", "__asm__", "__asm", "asm", "_Alignas", "__alignas__"}:
                self->adv()
                if self->is_punct("("):
                    self->skip_parens()
            # clang's NULLABILITY qualifiers. They appear all over the macOS SDK
            # (`char * _Nullable s`), always right after a '*', and carry no
            # meaning for codegen — pure annotation. Both spellings exist across
            # SDK versions.
            elif w in {"_Nullable", "_Nonnull", "_Null_unspecified", "__nullable", "__nonnull", "__null_unspecified"}:
                self->adv()
                continue
            elif w in {"const", "volatile", "__volatile__", "restrict", "__restrict", "__restrict__", "__extension__", "static", "extern", "register", "auto", "inline", "__inline", "__inline__", "_Noreturn", "__thread", "_Thread_local"}:
                if w == "const":
                    self->saw_const = True   # for parse_base_type to mark the type
                elif w == "static":
                    self->spec_static = True   # storage class (any position)
                elif w == "extern":
                    self->spec_extern = True
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
        if self->is_type_kw(w) or w in {"struct", "union", "enum"}:
            return True
        if w in {"const", "volatile", "unsigned", "signed"}:
            return True
        return self->types.has(w)

    static def at_type(self: *Cp) -> bool:
        t: *CTok = self->pk()
        if t->kind != CT_ID:
            return False
        w: const *char = t->text
        if self->is_type_kw(w) or w in {"struct", "union", "enum"}:
            return True
        # qualifiers/storage also start a type
        if w in {"const", "volatile", "static", "extern", "register", "inline", "__extension__", "__inline", "__inline__", "unsigned", "signed"}:
            return True
        return self->types.has(w)

    # base type: skips qualifiers/GNU, resolves typedef, builds a multi-word
    # arithmetic type, and handles struct/union/enum (with optional body def).
    static def parse_base_type(self: *Cp) -> *Type:
        self->saw_const = False
        self->spec_static = False
        self->spec_extern = False
        self->skip_gnu()   # absorbs leading storage class into spec_static/extern
        w: const *char = self->pk()->text
        if self->strict and self->spec_static and self->spec_extern:
            fatal_at(self->file, self->pk()->pos, "conflicting storage classes ('static' and 'extern')")
        # struct / union / enum
        if w in {"struct", "union"}:
            is_union: bool = w == "union"
            self->adv()
            if self->strict and self->pk()->kind == CT_ID and self->is_storage_kw(self->pk()->text):
                fatal_at(self->file, self->pk()->pos, "misplaced storage class '%s' (must precede the type)", self->pk()->text)
            self->skip_gnu()
            tag: const *char = None
            if self->pk()->kind == CT_ID and not self->is_punct("{"):
                if self->strict and (self->is_type_kw(self->pk()->text) or is_c_keyword(self->pk()->text)):
                    fatal_at(self->file, self->pk()->pos, "invalid struct/union tag '%s' (a C keyword)", self->pk()->text)
                tag = self->adv()->text
            if self->is_punct("{"):
                if tag == None:
                    # anonymous: unique name, no lookup ever reaches it
                    tag = self->a->printf("__anon%d", self->anon)
                    self->anon += 1
                    self->used_cnames.add(tag)
                else:
                    # DEFINITION: completes a same-scope forward, redefines in
                    # an inner scope (new identity, shadowing), errors on a
                    # same-scope redefinition or kind conflict (strict)
                    di: i32 = self->tag_find(tag)
                    if di >= 0 and self->tags.data[di].depth == self->tag_depth:
                        if self->strict and self->tags.data[di].is_union != is_union:
                            fatal_at(self->file, self->pk()->pos, "'%s' declared as both struct and union (wrong kind of tag)", tag)
                        if self->tags.data[di].defined:
                            if self->strict:
                                fatal_at(self->file, self->pk()->pos, "redefinition of '%s %s'", "union" if is_union else "struct", tag)
                            di = self->tag_push(tag, is_union, True)   # tolerant: shadow anyway
                        else:
                            self->tags.data[di].defined = True         # completes the forward
                    else:
                        di = self->tag_push(tag, is_union, True)
                    tag = self->tags.data[di].cname
                # the identity is registered BEFORE the body so a self-referential
                # member (`union u { union u *p; }`) resolves to THIS tag
                d: *Decl = self->parse_struct_body(tag, is_union)
                self->out_decls.push(d)
            elif tag != None:
                # `struct T;` standalone is a DECLARATION: it declares a NEW
                # incomplete tag in the CURRENT scope (shadowing an outer one);
                # a mere REFERENCE (`struct T *p`) binds to the visible identity
                standalone: bool = self->is_punct(";")
                ri: i32 = self->tag_find(tag)
                fresh: bool = False
                if ri >= 0 and (not standalone or self->tags.data[ri].depth == self->tag_depth):
                    if self->strict and self->tags.data[ri].is_union != is_union:
                        fatal_at(self->file, self->pk()->pos, "'%s' declared as both struct and union (wrong kind of tag)", tag)
                else:
                    # undeclared reference, or standalone decl shadowing an outer
                    # scope: new incomplete identity in the current scope
                    ri = self->tag_push(tag, is_union, False)
                    fresh = True
                tag = self->tags.data[ri].cname
                if fresh:
                    # emit ONE forward decl so the C backend's upfront typedef
                    # pass covers the (possibly renamed) name
                    fd: *Decl = self->a->alloc(sizeof(Decl))
                    fd->kind = DL_UNION if is_union else DL_STRUCT
                    fd->name = tag
                    fd->is_fwd = True
                    fd->pos = self->pk()->pos
                    self->out_decls.push(fd)
            # does NOT register the tag as a type name: in C, tags live in
            # their own namespace (a function and a struct can have the SAME name;
            # only `struct X` refers to the tag). The SPELLING is preserved via
            # tag_kind — the C backend re-emits `struct X`, never a bare `X`.
            tt: *Type = self->base_name(tag)
            tt->tag_kind = TAG_UNION if is_union else TAG_STRUCT
            return tt
        if w == "enum":
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
        # multi-word arithmetic type: unsigned long long int, etc. Storage-class
        # specifiers may interleave (`int static signed i`): absorb them.
        if self->is_type_kw(w):
            spos: Pos = self->pk()->pos
            name: const *char = self->adv()->text
            while self->pk()->kind == CT_ID and (self->is_type_kw(self->pk()->text) or self->is_storage_kw(self->pk()->text)):
                if self->is_storage_kw(self->pk()->text):
                    if self->pk()->text[1] == 't':
                        if self->strict and self->spec_extern:
                            fatal_at(self->file, self->pk()->pos, "conflicting storage classes ('static' and 'extern')")
                        self->spec_static = True
                    elif self->pk()->text[0] == 'e':
                        if self->strict and self->spec_static:
                            fatal_at(self->file, self->pk()->pos, "conflicting storage classes ('static' and 'extern')")
                        self->spec_extern = True
                    self->adv()
                else:
                    name = self->a->printf("%s %s", name, self->adv()->text)
            self->check_arith_specs(name, spos)
            return self->base_name(self->canon_arith(name))
        # typedef name: resolves to the underlying type (the backend doesn't change;
        # doesn't mark const on the typedef's shared node)
        if self->types.has(w):
            self->adv()
            # builtin float seguido de _Complex: `_Float16 _Complex`
            if self->pk()->kind == CT_ID and self->pk()->text != None and (self->pk()->text == "_Complex" or self->pk()->text == "_Imaginary"):
                cw: const *char = self->a->printf("%s %s", w, self->adv()->text)
                return self->base_name(cw)
            u: *Type = self->typedefs.get_or(w, None)
            if u != None:
                return u
            return self->base_name(w)  # struct tag
        # unknown: strict user code errors; header noise assumes int
        if self->strict:
            fatal_at(self->file, self->pk()->pos, "unknown type name '%s'", w)
        self->adv()
        return self->base_name("int")

    # innermost visible tag identity with this source name (-1 = none)
    static def tag_find(self: *Cp, name: const *char) -> i32:
        k: i32
        for k in range(self->tags.len - 1, -1, -1):
            if strcmp(self->tags.data[k].name, name) == 0:
                return k
        return -1

    # new tag identity in the CURRENT scope; the emitted cname is unique
    # across the module (hoisted decls must not collide)
    static def tag_push(self: *Cp, name: const *char, is_union: bool, defined: bool) -> i32:
        cn: const *char = name
        if self->used_cnames.has(cn):
            cn = self->a->printf("%s__s%d", name, self->anon)
            self->anon += 1
        self->used_cnames.add(cn)
        ct: CTag = {name, cn, is_union, defined, self->tag_depth}
        self->tags.push(ct)
        return self->tags.len - 1

    # new TY_NAME node with the const seen from the qualifiers ahead
    # (significant for _Generic matching: const char* vs char*)
    static def base_name(self: *Cp, n: const *char) -> *Type:
        t: *Type = ty_name(self->a, n)
        t->is_const = self->saw_const
        return t

    # C11 6.7.2p2: only the listed multisets of type specifiers are valid —
    # rejects 'unsigned float', 'signed void', 'char int', 'long short', etc.
    static def check_arith_specs(self: *Cp, n: const *char, pos: Pos):
        if not self->strict:
            return
        nvoid: i32 = word_count(n, "void")
        nchar: i32 = word_count(n, "char")
        nshort: i32 = word_count(n, "short")
        nint: i32 = word_count(n, "int")
        nlong: i32 = word_count(n, "long")
        nflt: i32 = word_count(n, "float")
        ndbl: i32 = word_count(n, "double")
        nsig: i32 = word_count(n, "signed")
        nuns: i32 = word_count(n, "unsigned")
        nbool: i32 = word_count(n, "_Bool")
        bad: bool = False
        if nsig + nuns > 1:
            bad = True                              # signed unsigned / twice
        if nvoid + nchar + nflt + ndbl + nbool > 1:
            bad = True                              # two base types
        if nshort > 1 or nint > 1 or nlong > 2:
            bad = True
        if nshort > 0 and nlong > 0:
            bad = True
        if (nflt > 0 or ndbl > 0 or nvoid > 0 or nbool > 0) and nsig + nuns + nshort > 0:
            bad = True                              # unsigned double, signed void...
        if nflt > 0 and nlong > 0:
            bad = True                              # long float
        if ndbl > 0 and nlong > 1:
            bad = True                              # long long double
        if (nvoid > 0 or nchar > 0 or nflt > 0 or ndbl > 0 or nbool > 0) and nint > 0:
            bad = True                              # char int, double int...
        if nchar > 0 and nshort + nlong > 0:
            bad = True                              # short char / long char
        if nvoid > 0 and nchar + nshort + nint + nlong + nflt + ndbl + nsig + nuns + nbool > 0:
            bad = True
        if bad:
            fatal_at(self->file, pos, "invalid combination of type specifiers ('%s')", n)

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
        # qualificador PÓS-base: `void const *p` == `const void *p` (C permite
        # qualifiers em qualquer ordem entre as palavras do tipo)
        if self->pk()->kind == CT_ID and (self->pk()->text == "const" or self->pk()->text == "volatile"):
            if self->pk()->text == "const":
                t->is_const = True
            self->adv()
            self->skip_gnu()
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
        if self->pk1()->text == "*":
            return True
        # GNU noise before the star: ( __attribute__((...)) * ). Scan past the
        # attribute's parenthesized group and require the '*' — a lookahead
        # that does not consume (the declarator parser skip_gnu()s for real).
        if self->pk1()->kind == CT_ID and self->pk1()->text == "__attribute__":
            k: usize = self->i + 2      # token after '(' '__attribute__'
            if k >= self->nt or self->t[k].kind != CT_PUNCT or self->t[k].text != "(":
                return False
            depth = 0
            while k < self->nt:
                if self->t[k].kind == CT_PUNCT and self->t[k].text == "(":
                    depth += 1
                elif self->t[k].kind == CT_PUNCT and self->t[k].text == ")":
                    depth -= 1
                    if depth == 0:
                        k += 1
                        break
                k += 1
            return k < self->nt and self->t[k].kind == CT_PUNCT and self->t[k].text == "*"
        return False

    # pointer-to-function declarator starting from '(' — compat: delegates to
    # the full recursive declarator (params capture discarded)
    static def parse_fnptr(self: *Cp, ret: *Type, out out_name: *char) -> *Type:
        prms: Vec<Param>
        prms.init()
        va: bool = False
        hp: bool = False
        return self->parse_declarator(ret, out out_name, ref prms, out va, out hp)

    # full C declarator (recursive, two passes chibicc-style):
    #   declarator := '*'* ( '(' declarator ')' | name ) suffix*
    #   suffix     := '(' params ')' | '[' dim ']'
    # Nested group: skips to the matching ')', applies the EXTERNAL suffixes
    # to the type, and re-parses the inner part with the type already built
    # (saves/restores the token index). The params of the declarator that HAS
    # the name are captured in prms/varargs (has_params marks the capture) —
    # it's the function's signature when the result is TY_FUNC.
    static def parse_declarator(self: *Cp, base: *Type, out out_name: *char, ref prms: Vec<Param>, out varargs: bool, out has_params: bool) -> *Type:
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
            if nx2->kind == CT_PUNCT and (nx2->text in {")", "..."}):
                starts_params = True
            elif nx2->kind == CT_ID and (self->is_type_kw(nx2->text) or nx2->text in {"struct", "union", "enum", "const", "volatile"} or self->types.has(nx2->text)):
                starts_params = True
            if starts_params:
                self->skip_parens()   # signature detail not needed: emits as ()
                out_name = ""
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
            # EXTERNAL suffix that is a parameter list — `(name)(params)`,
            # `(*(f))(params)` — parse it FOR REAL (not skip): if the inner
            # declarator turns out not to carry its own signature, these are
            # the function's parameters and must survive to the prototype
            eprms: Vec<Param>
            eprms.init()
            eva: bool = False
            ecap: bool = False
            e_empty: bool = False
            if self->is_punct("("):
                self->adv()
                self->parse_params(ref eprms, out eva)
                self->expect_punct(")")
                self->skip_gnu()
                ty = ty_func(self->a, ty)
                ecap = True
                e_empty = self->params_empty
            else:
                ty = self->parse_decl_suffix(ty)
            end: usize = self->i
            self->i = start + 1
            r: *Type = self->parse_declarator(ty, out out_name, ref prms, out varargs, out has_params)
            self->i = end
            if ecap and not has_params:
                for ei in range(eprms.len):
                    prms.push(eprms.get(ei))
                varargs = eva
                has_params = True
                self->cap_sig_empty = e_empty
            return r
        out_name = ""
        if self->pk()->kind == CT_ID:
            out_name = self->adv()->text
        if self->is_punct("("):
            # suffix directly on the name: function signature — captures params
            self->adv()
            self->parse_params(ref prms, out varargs)
            self->expect_punct(")")
            self->skip_gnu()
            has_params = True
            self->cap_sig_empty = self->params_empty
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
                dv: i64 = self->ceval(ref dok)
                if dok and self->is_punct("]"):
                    dd = ex_new(self->a, EX_NUMBER, self->pk()->pos)
                    dd->text = self->a->printf("%lld", dv)
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
    static def parse_params(self: *Cp, ref prms: Vec<Param>, out varargs: bool):
        empty_here: bool = self->is_punct(")")
        self->parse_params_inner(ref prms, out varargs)
        self->params_empty = empty_here

    static def parse_params_inner(self: *Cp, ref prms: Vec<Param>, out varargs: bool):
        varargs = False
        if self->is_punct(")"):
            return
        if self->is_kw("void") and self->pk1()->text == ")":
            self->adv()
            return
        do:
            if self->is_punct("..."):
                self->adv()
                varargs = True
                return
            pbase: *Type = self->parse_base_type()
            if self->strict and (self->spec_static or self->spec_extern):
                fatal_at(self->file, self->pk()->pos, "storage class specifier on a function parameter")
            pty: *Type = self->parse_stars(pbase)
            pname: const *char = ""
            # function-pointer parameter: T (*name)(args) -> captured via
            # the recursive declarator (the precise type matters for inference)
            if self->is_punct("("):
                fpn: *char = None
                pty = self->parse_fnptr(pty, out fpn)
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
            # array parameter: only the OUTERMOST dimension decays to a pointer;
            # inner dimensions are kept (`int a[2][3]` -> `int (*)[3]`, NOT int**)
            dims: Vec<*Expr>
            dims.init()
            while self->eat("["):
                # C99 qualifiers inside a parameter's brackets: int x[const 5],
                # int x[static 5], int x[restrict] — not part of the size expr
                while self->pk()->kind == CT_ID and (self->pk()->text == "const" or self->pk()->text == "static" or self->pk()->text == "restrict" or self->pk()->text == "__restrict" or self->pk()->text == "volatile"):
                    self->adv()
                de: *Expr = None
                # `[*]` — unspecified VLA size in a prototype: no dimension
                if self->is_punct("*") and self->pk1()->text == "]":
                    self->adv()
                elif not self->is_punct("]"):
                    de = c_expr(self)
                self->expect_punct("]")
                dims.push(de)
            if dims.len > 0:
                if self->strict and pty != None and pty->kind == TY_NAME and pty->name != None and pty->name == "void":
                    fatal_at(self->file, self->pk()->pos, "parameter declares an array of voids")
                # build the inner array type from the innermost dimension up,
                # skipping the first (it becomes the pointer)
                for di in range(dims.len - 1, 0, -1):
                    pty = ty_array(self->a, pty, dims.get(di))
                pty = ty_ptr(self->a, pty)
            dims.deinit()
            self->skip_gnu()
            prm: Param = {pname, pty, self->pk()->pos}
            prms.push(prm)
        while self->eat(",")

    # skips tokens (respecting () [] {}) until one of the terminators at level 0
    # consumes a balanced `{ ... }` (the caller is positioned ON the '{')
    static def skip_braces(self: *Cp):
        self->expect_punct("{")
        depth = 1
        while depth > 0 and self->pk()->kind != CT_EOF:
            if self->is_punct("{"):
                depth += 1
            elif self->is_punct("}"):
                depth -= 1
            self->adv()

    # Does the declaration starting HERE use an Apple block declarator? A LOOKAHEAD
    # (consumes nothing), scanning to the ';' or '{' that ends the declaration.
    # `(` immediately followed by `^` is the signature: `^` is otherwise xor, which
    # never follows an open paren directly.
    static def has_block_decl(self: *Cp) -> bool:
        k: usize = self->i
        depth = 0
        while k < self->nt and self->t[k].kind != CT_EOF:
            tk: *CTok = &self->t[k]
            if tk->kind == CT_PUNCT and tk->text != None:
                if depth == 0 and (tk->text == ";" or tk->text == "{"):
                    return False
                if tk->text in {"(", "[", "{"}:
                    depth += 1
                    if tk->text == "(" and k + 1 < self->nt and self->t[k + 1].kind == CT_PUNCT and self->t[k + 1].text == "^":
                        return True
                elif tk->text in {")", "]", "}"}:
                    depth -= 1
            k += 1
        return False

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
            if self->strict and (self->spec_static or self->spec_extern):
                fatal_at(self->file, self->pk()->pos, "storage class specifier on a struct/union member")
            do:
                fty: *Type = self->parse_stars(base)
                fname: const *char = ""
                # function-pointer field: T (*name)(args)
                if self->is_fnptr_ahead():
                    fpn: *char = None
                    fty = self->parse_fnptr(fty, out fpn); fname = fpn
                else:
                    if self->pk()->kind == CT_ID:
                        if self->strict and is_c_keyword(self->pk()->text):
                            fatal_at(self->file, self->pk()->pos, "invalid member name '%s' (a C keyword)", self->pk()->text)
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
                            fv: i64 = self->ceval(ref fok)
                            if fok and self->is_punct("]"):
                                fd = ex_new(self->a, EX_NUMBER, self->pk()->pos)
                                fd->text = self->a->printf("%lld", fv)
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
                self->skip_gnu()   # `long long x __attribute__((aligned(...)))`
                bw = -1                     # -1 = not a bitfield
                if self->eat(":"):               # bitfield: constant width
                    wok: bool = True
                    wv: i64 = self->ceval(ref wok)
                    if wok:
                        bw = i32(wv)
                    else:
                        self->skip_to(",", ";")
                if fname[0] != '\0':
                    if self->strict and fty != None and fty->kind == TY_NAME and fty->name != None and fty->name == "void":
                        fatal_at(self->file, self->pk()->pos, "member '%s' has incomplete type 'void'", fname)
                    if self->strict:
                        for dmi in range(fields.len):
                            if fields.data[dmi].name != None and strcmp(fields.data[dmi].name, fname) == 0:
                                fatal_at(self->file, self->pk()->pos, "duplicate member '%s'", fname)
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
                elif self->strict:
                    fatal_at(self->file, self->pk()->pos, "struct/union member declaration without a declarator")
                self->skip_gnu()   # an attribute after the bitfield, too
            while self->eat(",")
            if self->strict and self->is_punct("="):
                fatal_at(self->file, self->pk()->pos, "a struct/union member cannot have an initializer")
            if not self->eat(";"):
                if self->strict:
                    fatal_at(self->file, self->pk()->pos, "malformed struct/union member declarator (found '%s')", self->pk()->text)
                self->skip_to(";", ";")  # weird field declarator: skip it
                self->eat(";")
        # NOTE: an empty member list (`struct {}`) is invalid STANDARD C but a
        # widely-used GNU extension (c-suite 00216 depends on it) — accepted
        # by default; -pedantic warns, -pedantic-errors rejects
        if self->strict and fields.len == 0:
            cdiag_at(self->file, self->pk()->pos, "gnu-empty-struct", wd_pedantic(), "empty struct is a GNU extension")
        self->expect_punct("}")
        d: *Decl = self->a->alloc(sizeof(Decl))
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
    static def type_size(self: *Cp, t: *Type, ref ok: bool) -> i64:
        if t == None:
            ok = False
            return 0
        if t->kind == TY_PTR or t->kind == TY_FUNC:
            return 8
        if t->kind == TY_ARRAY:
            if t->arr_len == None or t->arr_len->kind != EX_NUMBER:
                ok = False
                return 0
            return i64(strtoll(t->arr_len->text, None, 0)) * self->type_size(t->inner, ref ok)
        n: const *char = t->name
        if n == None:
            ok = False
            return 0
        if n in {"char", "i8", "u8", "bool", "_Bool"}:
            return 1
        if n in {"short", "i16", "u16"}:
            return 2
        if n in {"int", "unsigned", "i32", "u32", "float", "f32"}:
            return 4
        if n in {"long", "i64", "u64", "double", "f64", "size_t", "ssize_t", "ptrdiff_t", "usize", "isize", "intptr_t", "uintptr_t"}:
            return 8
        u: *Type = self->typedefs.get_or(n, None)
        if u != None:
            return self->type_size(u, ref ok)
        ok = False
        return 0

    static def ceval_prim(self: *Cp, ref ok: bool) -> i64:
        t: *CTok = self->pk()
        if t->kind == CT_NUM:
            # same as c_primary: a pp-number is only required to be a valid
            # constant at the point it is evaluated as one
            nerr: const *char = c_num_error(t->text)
            if nerr != None:
                fatal_at(self->file, t->pos, "malformed number constant '%s': %s", t->text, nerr)
            self->adv()
            return i64(strtoll(t->text, None, 0))
        if t->kind == CT_CHAR:
            self->adv()
            return i64(cchar_val(t->text))
        # sizeof(type) / sizeof expr in const-expr (e.g.: enum NBit = 8*sizeof(x))
        if t->kind == CT_ID and t->text == "sizeof":
            self->adv()
            # sizeof ( TYPE ): the token after '(' starts a type
            if self->is_punct("(") and self->pk1()->kind == CT_ID and self->tok_is_type(self->pk1()->text):
                self->adv()
                sty: *Type = self->parse_decl_suffix(self->parse_stars(self->parse_base_type()))
                if self->is_punct(")"):
                    self->adv()
                else:
                    ok = False
                return self->type_size(sty, ref ok)
            # sizeof expr: only the simple case of an identifier with a type
            # is rare in const-expr; not reducible -> aborts the evaluation
            ok = False
            return 0
        if t->kind == CT_ID:
            self->adv()
            v: i64 = self->enumvals.get_or(t->text, 0x7FFFFFFFFFFFFFFF)
            if v == 0x7FFFFFFFFFFFFFFF:
                ok = False
                return 0
            return v
        if self->is_punct("("):
            # a cast inside a constant expression: (Uint8)('Y'), ((Uint32)(x))
            # — the value is truncated/extended to the type's WIDTH (C rules)
            if self->pk1()->kind == CT_ID and self->tok_is_type(self->pk1()->text):
                self->adv()
                cbase: *Type = self->parse_stars(self->parse_base_type())
                if self->is_punct(")"):
                    self->adv()
                else:
                    ok = False
                    return 0
                if cbase->kind == TY_PTR:
                    ok = False   # a cast to a pointer is not an enum value
                    return 0
                cv: i64 = self->ceval_prim(ref ok)
                csz: i64 = self->type_size(cbase, ref ok)
                if not ok:
                    return 0
                uns: bool = cbase->kind == TY_NAME and cbase->name != None and word_in(cbase->name, "unsigned")
                if csz == 1:
                    return i64(u8(cv)) if uns else i64(i8(cv))
                if csz == 2:
                    return i64(u16(cv)) if uns else i64(i16(cv))
                if csz == 4:
                    return i64(u32(cv)) if uns else i64(i32(cv))
                return cv
            self->adv()
            r: i64 = self->ceval(ref ok)
            if self->is_punct(")"):
                self->adv()
            else:
                ok = False   # never fatals: the caller restores and skips
            return r
        if self->is_punct("-"):
            self->adv()
            return -self->ceval_prim(ref ok)
        if self->is_punct("+"):
            self->adv()
            return self->ceval_prim(ref ok)
        if self->is_punct("~"):
            self->adv()
            return ~self->ceval_prim(ref ok)
        if self->is_punct("!"):
            self->adv()
            return 0 if self->ceval_prim(ref ok) != 0 else 1
        ok = False
        return 0

    static def ceval_prec(self: *Cp) -> i32:
        p: const *char = self->pk()->text
        if p == None or self->pk()->kind != CT_PUNCT:
            return -1
        if p in {"*", "/", "%"}:
            return 10
        if p in {"+", "-"}:
            return 9
        if p in {"<<", ">>"}:
            return 8
        if p in {"<", "<=", ">", ">="}:
            return 7
        if p in {"==", "!="}:
            return 6
        if p == "&":
            return 5
        if p == "^":
            return 4
        if p == "|":
            return 3
        if p == "&&":
            return 2
        if p == "||":
            return 1
        return -1

    static def ceval_bin(self: *Cp, minprec: i32, ref ok: bool) -> i64:
        lhs: i64 = self->ceval_prim(ref ok)
        while ok:
            prec: i32 = self->ceval_prec()
            if prec < minprec:
                break
            op: const *char = self->adv()->text
            rhs: i64 = self->ceval_bin(prec + 1, ref ok)
            if op == "*":
                lhs = lhs * rhs
            elif op == "/":
                lhs = lhs / rhs if rhs != 0 else 0
            elif op == "%":
                lhs = lhs % rhs if rhs != 0 else 0
            elif op == "+":
                lhs = lhs + rhs
            elif op == "-":
                lhs = lhs - rhs
            elif op == "<<":
                lhs = lhs << rhs
            elif op == ">>":
                lhs = lhs >> rhs
            elif op == "<":
                lhs = 1 if lhs < rhs else 0
            elif op == "<=":
                lhs = 1 if lhs <= rhs else 0
            elif op == ">":
                lhs = 1 if lhs > rhs else 0
            elif op == ">=":
                lhs = 1 if lhs >= rhs else 0
            elif op == "==":
                lhs = 1 if lhs == rhs else 0
            elif op == "!=":
                lhs = 1 if lhs != rhs else 0
            elif op == "&":
                lhs = lhs & rhs
            elif op == "^":
                lhs = lhs ^ rhs
            elif op == "|":
                lhs = lhs | rhs
            elif op == "&&":
                lhs = 1 if lhs != 0 and rhs != 0 else 0
            elif op == "||":
                lhs = 1 if lhs != 0 or rhs != 0 else 0
        return lhs

    static def ceval(self: *Cp, ref ok: bool) -> i64:
        c: i64 = self->ceval_bin(0, ref ok)
        if ok and self->is_punct("?"):
            self->adv()
            a: i64 = self->ceval(ref ok)
            if self->is_punct(":"):
                self->adv()
            else:
                ok = False
                return 0
            b: i64 = self->ceval(ref ok)
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
        sym_tail: bool = False   # the last value was symbolic (not reducible)
        while not self->is_punct("}") and self->pk()->kind != CT_EOF:
            iname: const *char = self->adv()->text
            # attribute BETWEEN the enumerator and its '=' — C23 spells it
            # `identifier attribute-specifier-seq = value`, and clang/gcc have
            # taken it for far longer. macOS <time.h> declares clockid_t that
            # way (`_CLOCK_REALTIME __CLOCK_AVAILABILITY = 0`, the macro being an
            # availability attribute), so without this the header dies on
            # "expected '}'".
            self->skip_gnu()
            it: EnumItem = {iname, None, self->pk()->pos}
            if self->eat("="):
                esave: usize = self->i
                vok: bool = True
                v: i64 = self->ceval(ref vok)
                if vok:
                    ve: *Expr = ex_new(self->a, EX_NUMBER, self->pk()->pos)
                    ve->text = self->a->printf("%lld", v)
                    it.value = ve
                    next_val = v + 1
                    sym_tail = False
                    self->enumvals.put(iname, v)
                    if v < 0 and tag != None:
                        self->enum_signed.add(tag)   # int representation
                else:
                    # not reducible here: RESTORE the cursor and keep the
                    # EXPRESSION (emission stays faithful; the cc computes it).
                    # Following auto-numbered members are left out of enumvals
                    # (their value is unknown).
                    self->i = esave
                    it.value = c_ternary(self)
                    sym_tail = True
            else:
                if not sym_tail:
                    self->enumvals.put(iname, next_val)
                    next_val += 1
            items.push(it)
            self->skip_gnu()   # also legal after the value, before the ','
            if not self->eat(","):
                break
        self->expect_punct("}")
        d: *Decl = self->a->alloc(sizeof(Decl))
        d->kind = DL_ENUM
        d->name = tag if tag != None else self->a->printf("__enum%d", self->anon)
        if tag == None:
            self->anon += 1
        d->items = items.data
        d->nitems = items.len
        return d

# ---------- mapping of C operators -> TokKind (op in the AST) ----------
def punct2tok(p: const *char) -> i32:
    if p == "+":
        return TK_PLUS
    if p == "-":
        return TK_MINUS
    if p == "*":
        return TK_STAR
    if p == "/":
        return TK_SLASH
    if p == "%":
        return TK_PERCENT
    if p == "&":
        return TK_AMP
    if p == "|":
        return TK_PIPE
    if p == "^":
        return TK_CARET
    if p == "<<":
        return TK_SHL
    if p == ">>":
        return TK_SHR
    if p == "==":
        return TK_EQ
    if p == "!=":
        return TK_NE
    if p == "<":
        return TK_LT
    if p == "<=":
        return TK_LE
    if p == ">":
        return TK_GT
    if p == ">=":
        return TK_GE
    if p == "&&":
        return TK_AND
    if p == "||":
        return TK_OR
    return TK_EOF

def cbin_prec(p: const *char) -> i32:
    if p == "||":
        return 1
    if p == "&&":
        return 2
    if p == "|":
        return 3
    if p == "^":
        return 4
    if p == "&":
        return 5
    if p in {"==", "!="}:
        return 6
    if p in {"<", "<=", ">", ">="}:
        return 7
    if p in {"<<", ">>"}:
        return 8
    if p in {"+", "-"}:
        return 9
    if p in {"*", "/", "%"}:
        return 10
    return 0  # not a binary operator

def is_assign_punct(p: const *char) -> bool:
    return p in {"=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="}

def assign2tok(p: const *char) -> i32:
    if p == "=":
        return TK_ASSIGN
    if p == "+=":
        return TK_PLUS_EQ
    if p == "-=":
        return TK_MINUS_EQ
    if p == "*=":
        return TK_STAR_EQ
    if p == "/=":
        return TK_SLASH_EQ
    if p == "%=":
        return TK_PERCENT_EQ
    if p == "&=":
        return TK_AMP_EQ
    if p == "|=":
        return TK_PIPE_EQ
    if p == "^=":
        return TK_CARET_EQ
    if p == "<<=":
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
def c_abstract_decl(p: *Cp, base: *Type) -> *Type
def c_block(p: *Cp) -> *Block
def cp_tags_restore(p: *Cp, mark: i32)
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
            # a pp-number USED as a value must be a real numeric constant
            nerr: const *char = c_num_error(t->text)
            if nerr != None:
                fatal_at(p->file, t->pos, "malformed number constant '%s': %s", t->text, nerr)
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
                sb.puts(txt)
                sb.len = n1 - 1        # drop the first string's closing quote
                sb.data[sb.len] = '\0'
                sb.puts(nxt + 1)  # skip the second string's opening quote
                txt = p->a->strdup(sb.data)
                sb.deinit()
            e2->text = txt
            return e2
        case CT_CHAR:
            e3: *Expr = ex_new(p->a, EX_CHARLIT, t->pos)
            e3->text = p->adv()->text
            return e3
        case CT_ID:
            # va_arg(ap, T) / __builtin_va_arg: special form with a TYPE
            if (t->text in {"va_arg", "__builtin_va_arg"}) and p->pk1()->text == "(":
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
            if t->text == "__builtin_offsetof" and p->pk1()->text == "(":
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
                    path = p->a->printf("%s.%s", path, p->adv()->text)
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
            if t->text == "_Generic":
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
            if p->strict and p->is_type_kw(t->text):
                fatal_at(p->file, t->pos, "expected an expression, found type keyword '%s'", t->text)
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
                inner->parened = True
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
            if e->kind == EX_IDENT and e->text == "__builtin_expect" and args.len >= 1:
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
    # __extension__ prefixando uma EXPRESSÃO (compound literal etc.): no-op
    if p->pk()->kind == CT_ID and p->pk()->text != None and p->pk()->text == "__extension__":
        p->adv()
        return c_unary(p)
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
        if p->strict and not p->is_punct("(") and p->pk()->kind == CT_ID and p->tok_is_type(p->pk()->text):
            fatal_at(p->file, p->pk()->pos, "'sizeof' of a type requires parentheses: sizeof(%s)", p->pk()->text)
        if p->is_punct("(") and c_peek_is_type(p):
            p->adv()  # (
            ty: *Type = c_abstract_decl(p, p->parse_base_type())
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
    # declarator with a suffix: (Blk*[]){...}, (int[4]){...}, and grouped
    # abstract declarators: (long (*)), (double *(**)), (int ((((*))))))
    if p->is_punct("(") and c_peek_is_type(p):
        p->adv()
        ty: *Type = c_abstract_decl(p, p->parse_base_type())
        if p->is_punct("["):
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

# abstract declarator (no name) for casts/typenames: '*'* [ '(' abstract ')' ]
# suffix* — handles redundant grouping ((((*)))) and fn-pointers (*)(args)
def c_abstract_decl(p: *Cp, base: *Type) -> *Type:
    t: *Type = p->parse_stars(base)
    # fn-pointer first: is_fnptr_ahead scans past __attribute__ groups, so
    # `int(*)(void)` and `int(__attribute__((x)) *)(void)` both land here
    if p->is_fnptr_ahead():
        dummy: *char = None
        return p->parse_fnptr(t, out dummy)
    # plain redundant grouping: (*), ((((*)))), (double *(**))
    if p->is_punct("(") and (p->pk1()->text == "*" or p->pk1()->text == "("):
        p->adv()
        t = c_abstract_decl(p, t)
        p->expect_punct(")")
    # trailing suffixes: sizeof(int[2][3]), casts to array-ish abstracts
    return p->parse_decl_suffix(t)

def c_peek_is_type(p: *Cp) -> bool:
    # looks 1 token ahead of the '(' — is it a type name? (builtin, struct/
    # union/enum, or a known typedef)
    nx: *CTok = p->pk1()
    if nx->kind != CT_ID:
        return False
    w: const *char = nx->text
    if p->is_type_kw(w) or w in {"struct", "union", "enum", "const"}:
        return True
    # a cast may open with GNU noise: ((__attribute__((noinline)) int(*)(void))fp)
    if w in {"__attribute__", "__extension__", "volatile"}:
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
    # `{}` (empty initializer) is C23/GNU — accepted by default (real-world
    # code and the c-suite rely on it); -pedantic warns, -pedantic-errors rejects
    if p->strict and args.len == 0:
        cdiag_at(p->file, pos, "c23-extensions", wd_pedantic(), "use of an empty initializer is a C23 extension")
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
            wa: **Expr = p->a->alloc(sizeof(v))
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
                ik->text = p->a->printf("%lld", k)
                dk->rhs = ik
                dk->lhs = v
                out->push(dk)
            return
        out->push(d)
        return
    out->push(c_initializer(p))

# ---------- statements ----------
# undoes scoped struct-tag renames registered after `mark` (block exit)
# closes a lexical scope: tag identities declared inside die with the block
# (their hoisted DECLS keep the unique cname — only the NAME goes out of scope)
def cp_tags_restore(p: *Cp, mark: i32):
    p->tags.len = mark
    p->tag_depth -= 1

def c_block(p: *Cp) -> *Block:
    v: Vec<*Stmt>
    v.init()
    tmark: i32 = p->tags.len
    p->tag_depth += 1
    if p->eat("{"):
        while not p->is_punct("}") and p->pk()->kind != CT_EOF:
            c_stmt_into(p, &v)
        p->expect_punct("}")
    else:
        if p->strict and (p->at_type() or p->is_kw("typedef")):
            fatal_at(p->file, p->pk()->pos, "a declaration is not a statement — the body of if/else/while/for needs braces to declare")
        c_stmt_into(p, &v)
    cp_tags_restore(p, tmark)
    b: *Block = p->a->alloc(sizeof(Block))
    b->stmts = v.data
    b->n = v.len
    return b

# block-scope function declaration: hoists a file-scope prototype (the name
# refers to the external function — sema needs the signature) AND leaves an
# ST_CPROTO in the block, so the emitted C re-binds the name locally (shadowing
# any outer variable of the same name, C11 6.2.1p4)
def c_local_proto(p: *Cp, out: *Vec<*Stmt>, name: const *char, ret: *Type, prms: Vec<Param>, va: bool, sig_empty: bool):
    lf: *Func = p->a->alloc(sizeof(Func))
    with lf:
        .pos = p->pk()->pos
        .name = name
        .cname = name
        .ret = ret
        .params = prms.data
        .nparams = prms.len
        .is_varargs = va
        .sig_empty = sig_empty
    ld: *Decl = p->a->alloc(sizeof(Decl))
    ld->kind = DL_FUNC
    ld->pos = p->pk()->pos
    ld->func = lf
    p->out_decls.push(ld)
    cs: *Stmt = st_new(p->a, ST_CPROTO, p->pk()->pos)
    cs->cfunc = lf
    out.push(cs)

def c_decl_into(p: *Cp, out: *Vec<*Stmt>):
    base: *Type = p->parse_base_type()   # absorbs storage class (any position)
    is_static: bool = p->spec_static
    is_extern: bool = p->spec_extern
    # local type def without a declarator:  struct T { ... } ;
    if p->is_punct(";"):
        p->adv()
        return
    do:
        ty: *Type = p->parse_stars(base)
        name: const *char
        # grouped declarator: the full recursive engine — (name), (*fp)(params),
        # ((array_of_pointers)[3]), (*(p))... A TY_FUNC result is a block-scope
        # function PROTOTYPE (hoisted below, like the named path).
        if p->is_punct("("):
            gpn: *char = None
            gprms: Vec<Param>
            gprms.init()
            gva: bool = False
            ghp: bool = False
            ty = p->parse_declarator(ty, out gpn, ref gprms, out gva, out ghp)
            name = gpn
            if ty != None and ty->kind == TY_FUNC:
                if p->strict and is_static:
                    fatal_at(p->file, p->pk()->pos, "invalid storage class for block-scope declaration of '%s'", name)
                c_local_proto(p, out, name, ty->inner, gprms, gva, p->cap_sig_empty if ghp else False)
                continue
        else:
            if p->strict and (p->pk()->kind != CT_ID or is_c_keyword(p->pk()->text)):
                fatal_at(p->file, p->pk()->pos, "expected a declarator name, found '%s'", p->pk()->text if p->pk()->text != None else "EOF")
            name = p->adv()->text
            # local function prototype:  RET name(params) ; — in C a block-scope
            # function declaration has FILE-scope effect (the name refers to the
            # external function). Register it as a hoisted prototype so the
            # sema knows the name IS a function with this return type.
            if p->is_punct("("):
                p->adv()
                lprms: Vec<Param>
                lprms.init()
                lva: bool = False
                p->parse_params(ref lprms, out lva)
                p->expect_punct(")")
                p->skip_gnu()
                if p->strict and is_static:
                    fatal_at(p->file, p->pk()->pos, "invalid storage class for block-scope declaration of '%s'", name)
                c_local_proto(p, out, name, ty, lprms, lva, p->params_empty)
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
        s->is_extern = is_extern
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
    # extended inline asm STATEMENT: __asm__ [volatile/goto] ( ... : ... );
    # ingest (headers): skipped — the bodies are dropped anyway. Strict user
    # code: an honest error beats silently losing the asm in the round-trip.
    if p->pk()->kind == CT_ID and p->pk()->text != None and (p->pk()->text == "_Static_assert" or p->pk()->text == "static_assert"):
        c_static_assert(p)
        return
    asmw: const *char = p->pk()->text if p->pk()->kind == CT_ID else None
    if asmw != None and asmw in {"__asm__", "__asm", "asm"}:
        if p->strict:
            fatal_at(p->file, pos, "inline asm statements are not supported by the C front end")
        p->adv()
        while True:
            qw: const *char = p->pk()->text if p->pk()->kind == CT_ID else None
            if qw == None or qw not in {"__volatile__", "volatile", "goto", "inline", "__inline__"}:
                break
            p->adv()
        if p->is_punct("("):
            p->skip_parens()
        p->eat(";")
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
        if p->strict and (p->at_type() or p->is_kw("typedef")):
            fatal_at(p->file, p->pk()->pos, "a declaration is not a statement — a case label cannot prefix a declaration (wrap it in braces)")
        if not p->is_punct("}"):
            c_stmt_into(p, out)
        return
    if p->is_kw("default"):
        p->adv()
        p->expect_punct(":")
        out.push(st_new(p->a, ST_CASE, pos))  # expr=None => default
        if p->strict and (p->at_type() or p->is_kw("typedef")):
            fatal_at(p->file, p->pk()->pos, "a declaration is not a statement — a case label cannot prefix a declaration (wrap it in braces)")
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
    # label:  name :  (a C keyword is never a label name — `unsigned: ...`
    # falls through to the declaration path, which rejects it in strict mode)
    if p->pk()->kind == CT_ID and p->pk1()->kind == CT_PUNCT and p->pk1()->text == ":" and not (p->strict and is_c_keyword(p->pk()->text) and not p->types.has(p->pk()->text)):
        lbl: const *char = p->adv()->text
        p->adv()  # ':'
        p->skip_gnu()   # `L: __attribute__((unused));` — attribute on the label
        ls: *Stmt = st_new(p->a, ST_LABEL, pos)
        ls->label = lbl
        out.push(ls)
        # in C, `label:` prefixes the following statement — parse it in the same
        # block (otherwise, as the body of an if/while without braces, it would escape)
        if p->strict and p->is_punct("}"):
            fatal_at(p->file, p->pk()->pos, "label '%s' at the end of a compound statement (a label must prefix a statement)", lbl)
        if p->strict and (p->at_type() or p->is_kw("typedef")):
            fatal_at(p->file, p->pk()->pos, "a declaration is not a statement — a label cannot prefix a declaration (C11; wrap it in braces)")
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
        btmark: i32 = p->tags.len
        p->tag_depth += 1
        while not p->is_punct("}") and p->pk()->kind != CT_EOF:
            c_stmt_into(p, &bv)
        p->expect_punct("}")
        cp_tags_restore(p, btmark)
        bb: *Block = p->a->alloc(sizeof(Block))
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
    fdecls: Vec<*Stmt>
    fdecls.init()
    if not p->is_punct(";"):
        # C99 for-init declaration: `for (int i = 0; ...)` — the declaration's
        # scope is the FOR itself. A single declarator stays inline in for_init;
        # multiple declarators wrap the whole loop in an ST_BLOCK (own scope),
        # so `for (int shadow = ...)` never collides with an outer `shadow`.
        if p->at_type():
            fbase: *Type = p->parse_base_type()
            # C11 6.8.5.3: a for-init declaration only takes auto/register —
            # `for (static int i = 0; ...)` / extern are constraint violations
            if p->strict and (p->spec_static or p->spec_extern):
                fatal_at(p->file, p->pk()->pos, "storage class ('static'/'extern') on a for-loop initial declaration")
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
                fdecls.push(fs)
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
    if fdecls.len == 1:
        s->for_init = fdecls.get(0)   # inline: for (int i = 0; ...)
        out.push(s)
    elif fdecls.len > 1:
        wb: *Stmt = st_new(p->a, ST_BLOCK, pos)
        bb: *Block = p->a->alloc(sizeof(Block))
        all: **Stmt = p->a->alloc(usize(fdecls.len + 1) * sizeof(*all))
        for fi in range(fdecls.len):
            all[fi] = fdecls.get(fi)
        all[fdecls.len] = s
        bb->stmts = all
        bb->n = fdecls.len + 1
        wb->body = bb
        out.push(wb)
    else:
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
            fpt: *Type = p->parse_fnptr(ty, out fpn)
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
        # typedef struct {...} Name (INGEST ONLY, where nothing is re-emitted):
        # the anonymous tag is unreachable by any other path — rename both the
        # decl AND the type node to the typedef's name so the layout is found
        # under the name the code uses (QBE). is_td records that the C spelling
        # is the bare typedef (never `struct Name`). On the C round trip
        # (strict) the typedef still resolves to `struct __anonN`, keeping the
        # re-emitted C self-contained.
        if not p->strict and ty->kind == TY_NAME and ty->tag_kind != TAG_NONE and ty->name != None and strncmp(ty->name, "__anon", 6) == 0:
            for adx in range(p->out_decls.len - 1, -1, -1):
                ad2: *Decl = p->out_decls.get(adx)
                if ad2->kind in {DL_STRUCT, DL_UNION} and ad2->name != None and strcmp(ad2->name, ty->name) == 0:
                    ad2->name = name
                    ad2->is_td = True
                    ty->name = name
                    ty->tag_kind = TAG_NONE
                    break
    while p->eat(",")
    p->expect_punct(";")

# ---------- top level: typedef / type def / function / global variable ----------
# parses ONE declarator given the base type: RET (*name)(p) | name(params) |
# name[dims] | name. Returns DL_FUNC (proto/def) or DL_VAR. Does NOT consume ',' or
# ';' (the caller handles the list).
def parse_one_decl(p: *Cp, base: *Type, is_extern: bool, pos: Pos) -> *Decl:
    ty: *Type = p->parse_stars(base)
    # ANY grouped declarator goes through the full recursive engine:
    # (name), ((name)), (*fp)(params), (*f(params))(params2), (*p)[3][6],
    # ((*(p))[3])[6], (*foo(params))[3]... parse_declarator handles them all.
    if p->is_punct("("):
        fpname: *char = None
        fprms: Vec<Param>
        fprms.init()
        fva: bool = False
        fhp: bool = False
        fpty: *Type = p->parse_declarator(ty, out fpname, ref fprms, out fva, out fhp)
        if fpty != None and fpty->kind == TY_FUNC:
            ff: *Func = p->a->alloc(sizeof(Func))
            with ff:
                .pos = pos
                .name = fpname
                .cname = fpname
                .ret = fpty->inner
                .params = fprms.data
                .nparams = fprms.len
                .is_varargs = fva
                .sig_empty = p->cap_sig_empty if fhp else False
                if p->is_punct("{"):
                    .body = c_block(p)   # definition
            df: *Decl = p->a->alloc(sizeof(Decl))
            df->kind = DL_FUNC
            df->pos = pos
            df->func = ff
            return df
        dfp: *Decl = p->a->alloc(sizeof(Decl))
        with dfp:
            .kind = DL_VAR
            .pos = pos
            .name = fpname
            .type = fpty
            .is_extern = is_extern
            if p->eat("="):
                .init = c_initializer(p)
        return dfp
    if p->strict and not p->is_punct("(") and (p->pk()->kind != CT_ID or is_c_keyword(p->pk()->text)):
        fatal_at(p->file, p->pk()->pos, "expected a declarator name, found '%s'", p->pk()->text if p->pk()->text != None else "EOF")
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
        p->parse_params(ref params, out is_vararg)
        p->expect_punct(")")
        p->skip_gnu()   # __attribute__/__asm__ after the parameter list
        f: *Func = p->a->alloc(sizeof(Func))
        with f:
            .pos = pos
            .name = name
            .cname = name
            .ret = ty
            .params = params.data
            .nparams = params.len
            .is_varargs = is_vararg
            .sig_empty = p->params_empty
            if p->is_punct("{"):
                .body = c_block(p)   # definition
        d: *Decl = p->a->alloc(sizeof(Decl))
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
    d2: *Decl = p->a->alloc(sizeof(Decl))
    with d2:
        .kind = DL_VAR
        .pos = pos
        .name = name
        .type = ty
        .is_extern = is_extern
        if p->eat("="):
            .init = c_initializer(p)
    return d2

# `_Static_assert(cond, "msg");` — swallowed while parsing (top level and block).
def c_static_assert(p: *Cp):
    p->adv()
    p->skip_parens()
    p->eat(";")

def c_top(p: *Cp) -> *Decl:
    pos: Pos = p->pk()->pos
    is_extern: bool = p->is_kw("extern")   # before skip_gnu consumes it
    is_static: bool = p->is_kw("static")   # local symbol of the TU (not exported)
    p->spec_static = False
    p->spec_extern = False
    p->skip_gnu()   # absorbs `__extension__ static __inline ...` prefixes
    if p->spec_static:
        is_static = True
    if p->spec_extern:
        is_extern = True
    if p->strict and is_static and is_extern:
        fatal_at(p->file, pos, "conflicting storage classes ('static' and 'extern')")
    if p->is_kw("typedef"):
        c_typedef(p)
        return None
    if p->pk()->kind == CT_ID and p->pk()->text != None and (p->pk()->text == "_Static_assert" or p->pk()->text == "static_assert"):
        c_static_assert(p)
        return None
    # Apple BLOCKS (`int (^)(void)`). Not C, and we do not model them: a block is
    # a heap object with a code pointer, not a function pointer, so translating
    # `^` as `*` would be a LIE. It used to do exactly that, silently —
    # `int (^)(const void *, const void *)` came out `int (*)()`, losing the
    # parameters, and `int (^f(void))(void)` came out `int (void);`, losing the
    # name. macOS <stdlib.h> declares qsort_b/bsearch_b this way whenever
    # __BLOCKS__ is on, which is the default, so the mistranslation was already
    # happening on every macOS build.
    #
    # An ingested HEADER just drops the declaration: the P output keeps its
    # `#include`, so nothing is lost, and code that calls the name gets a clean
    # unknown-identifier error rather than wrong C. In strict USER code it is an
    # error, because there silence would hide it.
    if p->has_block_decl():
        if p->strict:
            fatal_at(p->file, pos, "Apple blocks ('^') are not supported")
        p->skip_to(";", "{")
        if p->is_punct("{"):
            p->skip_braces()
        p->eat(";")
        return None
    base: *Type = p->parse_base_type()
    # storage class in any position (before/after/among the type words) was
    # absorbed by parse_base_type into these flags
    if p->spec_static:
        is_static = True
    if p->spec_extern:
        is_extern = True
    if p->strict and is_static and is_extern:
        fatal_at(p->file, pos, "conflicting storage classes ('static' and 'extern')")
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

def c_parse(a: *Arena, file: const *char, bytes: const *char, nbytes: usize, strict: bool) -> *Module:
    cx: Cx = {0}
    cx.file = file
    cx.strict = strict
    cx.s = bytes
    cx.n = nbytes
    cx.line = 1
    cx.col = 1
    cx.a = a
    cx.toks.init()
    cx.tokenize()

    cp: Cp = {0}
    cp.file = file
    cp.strict = strict
    cp.t = cx.toks.data
    cp.nt = cx.toks.len
    cp.a = a
    cp.types.init()
    cp.tags.init()
    cp.typedefs.init()
    cp.enumvals.init()
    cp.enum_signed.init()
    cp.anon = 0
    # types the backend already understands (C builtins + P aliases)
    builtins: const *char[] = {"void", "char", "short", "int", "long",
        "float", "double", "signed", "unsigned", "_Bool", "size_t",
        "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t", "wchar_t",
        "va_list", "__builtin_va_list",
        "__int128", "__int128_t", "__uint128_t",
        "_Float16", "_Float32", "_Float32x", "_Float64", "_Float64x", "_Float128",
        "_Decimal32", "_Decimal64", "_Decimal128", None}
    bi = 0
    while builtins[bi] != None:
        cp.types.add(builtins[bi])
        bi += 1

    m: *Module = a->alloc(sizeof(Module))
    m->path = a->strdup(file)
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
    # export the typedef NAMES: P code referencing e.g. `va_list`/`off_t` from an
    # ingested header must see a known type (the underlying type was resolved
    # inline; only the name needs to exist for the semantic pass)
    if cp.typedefs.elen > 0:
        tdn: **char = a->alloc(usize(cp.typedefs.elen) * sizeof(*tdn))
        tdt: **Type = a->alloc(usize(cp.typedefs.elen) * sizeof(*tdt))
        ntd = 0
        for ti in range(cp.typedefs.elen):
            if not cp.typedefs.dead[ti]:
                # the StrMap owns its key strings (freed on deinit): copy into
                # the arena — the module outlives the parser
                tdn[ntd] = a->strdup(cp.typedefs.keys[ti])
                tdt[ntd] = cp.typedefs.vals[ti]
                ntd += 1
        m->tdnames = tdn
        m->tdtypes = tdt
        m->ntd = ntd
    cp.types.deinit()
    cp.typedefs.deinit()
    cp.tags.deinit()
    cp.used_cnames.deinit()
    return m
