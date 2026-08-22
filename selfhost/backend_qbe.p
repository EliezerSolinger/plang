# backend_qbe.p — emits QBE IL from the plang AST (milestone F1).
#
# Approach (see PLANO-QBE.md): no SSA of our own. Each local/param becomes a
# stack slot (alloc); reads=load, writes=store; QBE promotes to a register
# and does SSA/optimization/regalloc. Structured control flow is flattened
# into blocks (the easy direction).
#
# QBE is typed (classes w=int32, l=int64/ptr, s=float, d=double). Since the
# AST doesn't carry a type per expression, the backend infers it locally
# (qtype_of), mirroring sema. In F2 this is replaced by an annotated type.
#
# F1 slice: integers (w/l), char, pointers, arrays, arithmetic/relational/
# logical ops, if/elif/else/while/for/do, non-variadic calls, strings,
# return. Pending: floats, struct by value, variadics, match, defer.
include <stdio.h>
include <string.h>
include <stdlib.h>
import "backend.ph"
import "lexer.ph"
import "vecs.ph"
import "../stl/vec.ph"
import "../stl/map.ph"
import "../stl/set.ph"

def arena_qcmp(base: const *char, cls: char) -> const *char

def align_up(x: i32, a: i32) -> i32:
    if a <= 1:
        return x
    return (x + a - 1) & ~(a - 1)

# synthetic type nodes for _Generic inference (the backend has no arena;
# calloc is fine — few nodes, lifetime = the compiler's process)
# merges two initializer values into the same slot (C semantics for nested
# designators: `[0][a]=x, [0][b]=y` accumulates into sec[0] instead of
# replacing it). If both are lists, concatenates the args (the recursive
# data_fill resolves the lower level, override included); otherwise the new
# one wins.
def merge_init(old: *Expr, new: *Expr) -> *Expr:
    if old == None or old->kind != EX_INITLIST or new == None or new->kind != EX_INITLIST:
        return new
    m: *Expr = calloc(1, sizeof(Expr))
    m->kind = EX_INITLIST
    m->pos = new->pos
    tot: i32 = old->nargs + new->nargs
    a: **Expr = calloc(usize(tot), sizeof(old->args[0]))
    for i in range(old->nargs):
        a[i] = old->args[i]
    for i in range(new->nargs):
        a[old->nargs + i] = new->args[i]
    m->args = a
    m->nargs = tot
    return m

def mk_tyname(n: const *char) -> *Type:
    t: *Type = calloc(1, sizeof(Type))
    t->kind = TY_NAME
    t->name = n
    return t

def mk_typtr(inner: *Type) -> *Type:
    t: *Type = calloc(1, sizeof(Type))
    t->kind = TY_PTR
    t->inner = inner
    return t

# usual arithmetic promotion (approximate): double>float>u64>long>unsigned>int;
# types smaller than int promote to int. Pointer wins (pointer arithmetic).
def arith_rank(t: *Type) -> i32:
    if t == None or t->kind != TY_NAME or t->name == None:
        return 1
    n: const *char = t->name
    if n in {"double", "f64"}:
        return 6
    if n in {"float", "f32"}:
        return 5
    if n in {"u64", "usize", "unsigned long", "unsigned long long"}:
        return 4
    if n in {"long", "i64", "isize", "long long"}:
        return 3
    if n in {"unsigned", "u32"}:
        return 2
    return 1

def arith_promote(a: *Type, b: *Type) -> *Type:
    if a != None and a->kind == TY_PTR:
        return a
    if b != None and b->kind == TY_PTR:
        return b
    ra: i32 = arith_rank(a)
    rb: i32 = arith_rank(b)
    hi: *Type = a if ra >= rb else b
    if arith_rank(hi) <= 1:
        return mk_tyname("int")   # char/short/int -> int
    return hi

# decodes a C string literal (with quotes) into QBE ` b N,` items in buffer
# `out`, handling escapes (\n\t\r\\\"\' \a\b\f\v \?, octal \NNN, hex \xNN).
# Does NOT write the final nul nor the data{} wrapper. Returns the byte count.
# length of the literal prefix (L, u, U, u8) before the quote/apostrophe
def lit_prefix_len(lex: const *char) -> usize:
    if lex[0] == 'L' or lex[0] == 'U':
        return 1
    if lex[0] == 'u':
        return 2 if lex[1] == '8' else 1
    return 0

# wide element? L/u/U => yes (wchar_t/char16/char32); u8 and no prefix => byte
def lit_is_wide(lex: const *char) -> bool:
    return lex[0] == 'L' or lex[0] == 'U' or (lex[0] == 'u' and lex[1] != '8')

# pointer to the literal's body (after the prefix): points to the opening quote
def lit_body(lex: const *char) -> const *char:
    return lex + lit_prefix_len(lex)

# `limit` caps how many bytes are emitted (-1 = no cap): C truncates a string
# initializer to the declared array size, and the nul is dropped when it does
# not fit — `char x[3] = "abc"` is three bytes, not four.
def cstr_bytes(out: *StrBuf, lex: const *char, limit: i32) -> i32:
    lex = lit_body(lex)  # skip prefix (u8"...") — raw bytes
    count = 0
    i: usize = 1  # skip the opening quote
    n: usize = strlen(lex)
    while i < n - 1:
        c: char = lex[i]
        b: i32
        if c == '\\':
            i += 1
            e: char = lex[i]
            match e:
                case 'n':
                    b = 10
                case 't':
                    b = 9
                case 'r':
                    b = 13
                case 'b':
                    b = 8
                case 'f':
                    b = 12
                case 'v':
                    b = 11
                case 'a':
                    b = 7
                case '\\':
                    b = 92
                case '"':
                    b = 34
                case '\'':
                    b = 39
                case '?':
                    b = 63
                case 'x':
                    b = 0
                    while i + 1 < n - 1 and is_hexc(lex[i + 1]):
                        b = b * 16 + hexc(lex[i + 1])
                        i += 1
                case _:
                    if e >= '0' and e <= '7':
                        # AT MOST three digits (C11 6.4.4.4): a fourth one is
                        # DATA, not part of the escape. Reading further both
                        # produced a value beyond a byte and swallowed the byte
                        # that followed — which is how 263KB of embedded font
                        # came out shifted.
                        b = i32(e - '0')
                        od: i32 = 1
                        while od < 3 and i + 1 < n - 1 and lex[i + 1] >= '0' and lex[i + 1] <= '7':
                            b = b * 8 + i32(lex[i + 1] - '0')
                            od += 1
                            i += 1
                    else:
                        b = i32(e)
        else:
            b = i32(c) & 0xFF
        if limit >= 0 and count >= limit:
            break
        out->printf(" b %d,", b)
        count += 1
        i += 1
    return count

# emits the codepoints of a wide literal (L/u/U) as QBE `data` units
# (elem = 'w' for 4 bytes, 'h' for 2); decodes UTF-8 and escapes. Returns the
# unit count (without the terminator).
def wstr_data(out: *StrBuf, lex: const *char, elem: char) -> i32:
    cnt = 0
    i: usize = lit_prefix_len(lex) + 1
    n: usize = strlen(lex)
    while i < n - 1:
        cp: u32 = 0
        c: char = lex[i]
        if c == '\\':
            i += 1
            e: char = lex[i]
            match e:
                case 'n':
                    cp = 10
                    i += 1
                case 't':
                    cp = 9
                    i += 1
                case 'r':
                    cp = 13
                    i += 1
                case '0':
                    cp = 0
                    i += 1
                case '\\':
                    cp = 92
                    i += 1
                case '"':
                    cp = 34
                    i += 1
                case 'x':
                    cp = 0
                    i += 1
                    while i < n - 1 and is_hexc(lex[i]):
                        cp = cp * 16 + u32(hexc(lex[i]))
                        i += 1
                case _:
                    cp = u32(u8(e))
                    i += 1
        else:
            b0: u8 = u8(c)
            if b0 < 0x80:
                cp = u32(b0)
                i += 1
            elif b0 < 0xE0:
                cp = (u32(b0) & 0x1F) << 6 | (u32(u8(lex[i + 1])) & 0x3F)
                i += 2
            elif b0 < 0xF0:
                cp = (u32(b0) & 0xF) << 12 | (u32(u8(lex[i + 1])) & 0x3F) << 6 | (u32(u8(lex[i + 2])) & 0x3F)
                i += 3
            else:
                cp = (u32(b0) & 7) << 18 | (u32(u8(lex[i + 1])) & 0x3F) << 12 | (u32(u8(lex[i + 2])) & 0x3F) << 6 | (u32(u8(lex[i + 3])) & 0x3F)
                i += 4
        out->printf(" %c %u,", elem, cp)
        cnt += 1
    return cnt

# counts the UNITS of a string literal (WITHOUT the nul): bytes if narrow,
# codepoints if wide (UTF-8 grouped). Used to infer the size of `T x[]`.
def lit_unit_count(lex: const *char, wide: bool) -> i32:
    lex = lit_body(lex)  # skip prefix (L"...", u8"...")
    cnt = 0
    i: usize = 1
    n: usize = strlen(lex)
    while i < n - 1:
        if lex[i] == '\\':
            i += 1
            if lex[i] == 'x':
                i += 1
                while i < n - 1 and is_hexc(lex[i]):
                    i += 1
            elif lex[i] >= '0' and lex[i] <= '7':
                i += 1
                od2: i32 = 1
                while od2 < 3 and i < n - 1 and lex[i] >= '0' and lex[i] <= '7':
                    od2 += 1
                    i += 1
            else:
                i += 1
            cnt += 1
        elif wide and u8(lex[i]) >= 0x80:
            b0: u8 = u8(lex[i])
            i += usize(2 if b0 < 0xE0 else (3 if b0 < 0xF0 else 4))
            cnt += 1
        else:
            i += 1
            cnt += 1
    return cnt

# floating-point literal? has '.' OR a decimal exponent (not hex 0x...)
def is_float_lit(t: const *char) -> bool:
    if strchr(t, '.') != None:
        return True
    if t[0] == '0' and (t[1] == 'x' or t[1] == 'X'):
        return False
    return strchr(t, 'e') != None or strchr(t, 'E') != None

# QBE class of the float literal: 's' if suffix f/F, else 'd' (double)
def float_cls(t: const *char) -> char:
    n: usize = strlen(t)
    if n > 0 and (t[n - 1] == 'f' or t[n - 1] == 'F'):
        return 's'
    return 'd'

# numeric text of the float literal without the f/F suffix (for QBE's d_/s_)
g_fnum_buf: char[8][64]
g_fnum_idx: i32 = 0
def fnum(t: const *char) -> const *char:
    b: *char = g_fnum_buf[g_fnum_idx & 7]
    g_fnum_idx += 1
    n: usize = strlen(t)
    if n > 0 and (t[n - 1] == 'f' or t[n - 1] == 'F'):
        n -= 1
    if n > 63:
        n = 63
    memcpy(b, t, n)
    b[n] = '\0'
    return b

# arithmetic promotion of QBE classes: float wins over int, double wins over single
#
# NOTE: there is no hardcoded libc knowledge here anymore. A call with no known
# prototype defaults to class 'w' (C's implicit-int rule). Real signatures come
# from `include <header.h>` — the header is ingested (cpp + C front end) and its
# prototypes/macros flow through sema, so pointer/size_t/double returns and
# unsigned comparisons are all derived from the actual declarations.

def qpromote(a: char, b: char) -> char:
    if a == 'd' or b == 'd':
        return 'd'
    if a == 's' or b == 's':
        return 's'
    if a == 'l' or b == 'l':
        return 'l'
    return 'w'

struct QVar:
    name: const *char
    slot: i32       # id of the temp that holds the ADDRESS (alloc)
    cls: char       # 'w' 'l' 's' 'd'
    ty: *Type
    is_static: bool # static local: global storage $sl<sid>, no alloc
    sid: i32        # id of the static storage
    nbytes: i32     # explicit alloc size (0 = use size_of); for arrays []
    ext: bool       # block-scope extern: storage is the global symbol $name
    decl: *Stmt     # the ST_VAR/ST_WITH that declared it (None: param). Ties the
                    # collect pre-pass entry to its emission-time lexical binding —
                    # NAMES may repeat across blocks with different types.

# enum constant resolved to an integer value (QBE has no enum)
struct EnumConst:
    name: const *char
    val: i64

declare Vec<QVar>
implement Vec<QVar>
declare Vec<EnumConst>
implement Vec<EnumConst>
declare Vec<i32>
implement Vec<i32>
declare Vec<char>
implement Vec<char>
# StrMap<*Type>/<*Func>/<*Decl>: the implements live in sema.p (one per
# binary); here we just declare them so we link with those bodies
declare StrMap<*Type>
declare StrMap<*Func>
declare StrMap<*Decl>
declare StrMap<*Expr>

# does the last statement of a block unconditionally jump away? (defers already emitted)
def stmt_exits_q(s: *Stmt) -> bool:
    return s->kind in {ST_RETURN, ST_BREAK, ST_CONTINUE, ST_GOTO}

struct Qb:
    out: *StrBuf
    file: const *char   # module path (for line:col errors)
    data: StrBuf        # data defs (strings), emitted at the top
    ntmp: i32
    nlbl: i32
    nstr: i32
    nstatic: i32    # counter of static-local storages ($sl<sid>)
    vars: Vec<QVar>     # locals/params of the current function (ALL declarations)
    binds: Vec<i32>     # lexical scope: indices into vars, innermost binding last;
                        # emit_block saves/restores its length (shadowing correct)
    enumc: Vec<EnumConst>   # module's enum constants -> integer value
    globals: StrMap<*Type>
    funcs: StrMap<*Func>
    structs: StrMap<*Decl>
    tdsc: StrMap<*Type>      # typedef de header C -> escalar subjacente   # struct name -> DL_STRUCT (for layout/offsets)
    cdepth: i32              # const-folding recursion guard (see const_int)
    gconsts: StrMap<*Expr>   # module-level `const NAME = expr` -> its initializer.
                             #   QBE has no preprocessor, so a STATIC initializer
                             #   naming one has to be folded here (the C backend
                             #   just emits the name and lets C resolve it).
    brk: i32[64]        # stack of break labels
    brk_dm: i32[64]     # mark of the defer stack at each break level
    nbrk: i32
    cont: i32[64]       # stack of continue labels
    cont_dm: i32[64]    # mark of the defer stack at each continue level
    ncont: i32
    defers: Vec<*Stmt>  # pending defers (LIFO flush on block/loop exit)
    cur_ret_cls: char   # return class of the current function (0 = void)
    cur_ret_agg: bool   # is the return a struct by value (QBE aggregate)?
    cur_ret_name: const *char  # name of the aggregate return type (:Name)
    cur_fname: const *char     # name of the current function (for __func__)
    slots: *StrBuf             # prologue alloc buffer (None = emit into out)

    # prototypes: methods call each other mutually (rvalue<->addr<->binary...),
    # so we declare them first so the generated C has the forward declarations
    private def tmp(self: *Qb) -> i32
    private def lbl(self: *Qb) -> i32
    private def cls_of(self: *Qb, t: *Type) -> char
    private def td_resolve(self: *Qb, name: const *char) -> const *char
    private def size_of(self: *Qb, t: *Type) -> i32
    private def type_align(self: *Qb, t: *Type) -> i32
    private def struct_align(self: *Qb, d: *Decl) -> i32
    private def struct_size(self: *Qb, d: *Decl) -> i32
    private def slayout(self: *Qb, d: *Decl, fname: const *char, ref out_ty: *Type, ref out_boff: i32, ref out_bw: i32) -> i32
    private def field_offset(self: *Qb, d: *Decl, fname: const *char, ref out_ty: *Type) -> i32
    private def struct_of(self: *Qb, t: *Type) -> *Decl
    private def emit_anon_data(self: *Qb, ty: *Type, e: *Expr) -> const *char
    private def data_scalar(self: *Qb, db: *StrBuf, ty: *Type, e: *Expr) -> i32
    private def data_fill(self: *Qb, db: *StrBuf, ty: *Type, items: **Expr, nitems: i32, ref idx: i32) -> i32
    private def data_fill_body(self: *Qb, db: *StrBuf, ty: *Type, sd: *Decl, items: **Expr, nitems: i32, ref idx: i32) -> i32
    private def data_fill_slots_arr(self: *Qb, db: *StrBuf, ty: *Type, count: i32, esz: i32, items: **Expr, nitems: i32, ref idx: i32) -> i32
    private def data_fill_slots_struct(self: *Qb, db: *StrBuf, sd: *Decl, items: **Expr, nitems: i32, ref idx: i32) -> i32
    private def is_agg(self: *Qb, t: *Type) -> bool
    private def qtype_member(self: *Qb, out: *StrBuf, ft: *Type, count: i32) -> bool
    private def emit_qtype(self: *Qb, out: *StrBuf, name: const *char, done: *StrSet)
    private def is_valist(self: *Qb, t: *Type) -> bool
    private def is_signed(self: *Qb, t: *Type) -> bool
    private def op_signed(self: *Qb, e: *Expr) -> bool
    private def find_var(self: *Qb, name: const *char) -> *QVar
    private def bind_decl(self: *Qb, s: *Stmt)
    private def emit_block_body(self: *Qb, b: *Block)
    private def enum_lookup(self: *Qb, name: const *char, out: *i64) -> bool
    private def qtype_of(self: *Qb, e: *Expr) -> *Type
    private def gtype_of(self: *Qb, e: *Expr) -> *Type
    private def glvconv(self: *Qb, t: *Type) -> *Type
    private def type_eq_gen(self: *Qb, a: *Type, b: *Type) -> bool
    private def gen_select(self: *Qb, e: *Expr) -> *Expr
    private def ecls(self: *Qb, e: *Expr) -> char
    private def emit_string(self: *Qb, lex: const *char) -> i32
    private def emit_addr(self: *Qb, e: *Expr) -> i32
    private def load_op(self: *Qb, t: *Type) -> const *char
    private def store_op(self: *Qb, t: *Type) -> const *char
    private def store_cls(self: *Qb, t: *Type) -> char
    private def emit_coerce(self: *Qb, val: i32, frm: char, to: char) -> i32
    private def try_ptr_arith(self: *Qb, op: i32, l: i32, lt: *Type, lcls: char, r: i32, rt: *Type, rcls: char) -> i32
    private def bf_lookup(self: *Qb, e: *Expr, ref out_ft: *Type, ref out_bo: i32, ref out_bw: i32) -> bool
    private def emit_bf_load(self: *Qb, addr: i32, ft: *Type, bo: i32, bw: i32) -> i32
    private def emit_bf_store(self: *Qb, addr: i32, ft: *Type, bo: i32, bw: i32, val: i32, vcls: char)
    private def emit_rvalue(self: *Qb, e: *Expr) -> i32
    private def charval(self: *Qb, lex: const *char) -> i32
    private def emit_cast(self: *Qb, e: *Expr) -> i32
    private def emit_unary(self: *Qb, e: *Expr) -> i32
    private def binop_name(self: *Qb, op: i32, cls: char, sgn: bool) -> const *char
    private def cmp_name(self: *Qb, op: i32, cls: char, sgn: bool) -> const *char
    private def emit_binary(self: *Qb, e: *Expr) -> i32
    private def emit_cond(self: *Qb, e: *Expr) -> i32
    private def emit_logical(self: *Qb, e: *Expr) -> i32
    private def emit_ternary(self: *Qb, e: *Expr) -> i32
    private def emit_incdec(self: *Qb, e: *Expr) -> i32
    private def emit_call(self: *Qb, e: *Expr) -> i32
    private def emit_block(self: *Qb, b: *Block)
    private def emit_stmt(self: *Qb, s: *Stmt)
    private def emit_assign(self: *Qb, s: *Stmt)
    private def emit_store_to(self: *Qb, lhs: *Expr, op: i32, rhs: *Expr) -> i32
    private def emit_var_init(self: *Qb, v: *QVar, init: *Expr)
    private def emit_wstr_to_addr(self: *Qb, addr: i32, lex: const *char)
    private def emit_compound(self: *Qb, e: *Expr) -> i32
    private def emit_zero(self: *Qb, addr: i32, size: i32)
    private def emit_struct_copy(self: *Qb, dst: i32, src: i32, size: i32)
    private def emit_init_addr(self: *Qb, addr: i32, ty: *Type, init: *Expr)
    private def emit_fill(self: *Qb, addr: i32, ty: *Type, items: **Expr, nitems: i32, ref idx: i32)
    private def emit_fill_body(self: *Qb, addr: i32, ty: *Type, sd: *Decl, items: **Expr, nitems: i32, ref idx: i32)
    private def emit_str_to_addr(self: *Qb, addr: i32, lex: const *char, cap: i32)
    private def compound_base(self: *Qb, op: i32) -> i32
    private def emit_if(self: *Qb, s: *Stmt)
    private def emit_while(self: *Qb, s: *Stmt)
    private def emit_do(self: *Qb, s: *Stmt)
    private def emit_for(self: *Qb, s: *Stmt)
    private def emit_cfor(self: *Qb, s: *Stmt)
    private def collect_cases(self: *Qb, b: *Block, acc: *Vec<*Stmt>)
    private def collect_evars(self: *Qb, e: *Expr)
    private def emit_switch(self: *Qb, s: *Stmt)
    private def emit_match(self: *Qb, s: *Stmt)
    private def collect_vars(self: *Qb, b: *Block)
    private def add_var(self: *Qb, name: const *char, ty: *Type, decl: *Stmt)
    private def add_static_var(self: *Qb, name: const *char, ty: *Type, init: *Expr, decl: *Stmt)
    private def add_extern_var(self: *Qb, name: const *char, ty: *Type, decl: *Stmt)
    private def static_fix_len(self: *Qb, ty: *Type, total: i32)
    private def emit_func(self: *Qb, f: *Func)

    private def tmp(self: *Qb) -> i32:
        self->ntmp += 1
        return self->ntmp

    private def lbl(self: *Qb) -> i32:
        self->nlbl += 1
        return self->nlbl

    # ---------- type mapping ----------
    # A typedef from a C header names a type this back end has to LAY OUT, and
    # the name alone says nothing: `pthread_t` is an `unsigned long`, and taking
    # it for four bytes corrupts every offset after it in the struct. The C back
    # end never has this problem — it prints the typedef and the system header
    # answers — so the map is filled only for the back ends that need it.
    private def td_resolve(self: *Qb, name: const *char) -> const *char:
        if name == None:
            return None
        n: const *char = name
        d: i32 = 0
        while d < 8:
            u: *Type = self->tdsc.get_or(n, None)
            if u == None or u->name == None or strcmp(u->name, n) == 0:
                return n
            n = u->name
            d += 1
        return n

    private def cls_of(self: *Qb, t: *Type) -> char:
        if t == None:
            return 'w'
        if t->kind in {TY_PTR, TY_ARRAY, TY_FUNC}:
            return 'l'
        n: const *char = self->td_resolve(t->name)
        if n in {"long", "i64", "u64", "usize", "isize", "size_t", "ptrdiff_t", "long long", "unsigned long", "unsigned long long"}:
            return 'l'
        if n in {"double", "f64"}:
            return 'd'
        if n in {"float", "f32"}:
            return 's'
        return 'w'

    # evaluates a constant integer expression (array dimensions, e.g. 5*32,
    # N+1, enum). Returns the value; *ok=False if not reducible at compile time.
    private def const_int(self: *Qb, e: *Expr, ref ok: bool) -> i64:
        if e == None:
            ok = False
            return 0
        match e->kind:
            case EX_NUMBER:
                # literal text is non-negative; strtoull avoids LLONG_MAX saturation
                # for values >= 2^63 (the bit pattern fits i64).
                return i64(strtoull(e->text, None, 0))
            case EX_CHARLIT:
                return i64(self->charval(e->text))
            case EX_TRUE:
                return 1
            case EX_FALSE:
                return 0
            case EX_NONE:
                return 0        # the null pointer constant is a constant zero
            case EX_IDENT:
                ev: i64 = 0
                if self->enum_lookup(e->text, &ev):
                    return ev
                # a module-level `const NAME = <const expr>`: fold its initializer.
                # The depth guard stops a const that (illegally) names itself.
                gc: *Expr = self->gconsts.get_or(e->text, None)
                if gc != None and self->cdepth < 32:
                    self->cdepth += 1
                    gv: i64 = self->const_int(gc, ref ok)
                    self->cdepth -= 1
                    return gv
                ok = False
                return 0
            case EX_CAST:
                return self->const_int(e->lhs, ref ok)
            case EX_UNARY:
                v: i64 = self->const_int(e->lhs, ref ok)
                if e->op == TK_MINUS:
                    return -v
                if e->op == TK_TILDE:
                    return ~v
                if e->op == TK_NOT:
                    return 0 if v != 0 else 1
                if e->op == TK_PLUS:
                    return v
                ok = False
                return 0
            case EX_BINARY:
                a: i64 = self->const_int(e->lhs, ref ok)
                b: i64 = self->const_int(e->rhs, ref ok)
                match e->op:
                    case TK_PLUS:
                        return a + b
                    case TK_MINUS:
                        return a - b
                    case TK_STAR:
                        return a * b
                    case TK_SLASH:
                        return a / b if b != 0 else 0
                    case TK_PERCENT:
                        return a % b if b != 0 else 0
                    case TK_AMP:
                        return a & b
                    case TK_PIPE:
                        return a | b
                    case TK_CARET:
                        return a ^ b
                    case TK_SHL:
                        return a << b
                    case TK_SHR:
                        return a >> b
                    case TK_EQ:
                        return 1 if a == b else 0
                    case TK_NE:
                        return 1 if a != b else 0
                    case TK_LT:
                        return 1 if a < b else 0
                    case TK_LE:
                        return 1 if a <= b else 0
                    case TK_GT:
                        return 1 if a > b else 0
                    case TK_GE:
                        return 1 if a >= b else 0
                    case TK_AND:
                        return 1 if (a != 0 and b != 0) else 0
                    case TK_OR:
                        return 1 if (a != 0 or b != 0) else 0
                    case _:
                        ok = False
                        return 0
            case EX_TERNARY:
                c: i64 = self->const_int(e->cond, ref ok)
                return self->const_int(e->lhs, ref ok) if c != 0 else self->const_int(e->rhs, ref ok)
            case _:
                ok = False
                return 0

    private def size_of(self: *Qb, t: *Type) -> i32:
        if t == None:
            return 4
        if t->kind == TY_PTR or t->kind == TY_FUNC:
            return 8
        if t->kind == TY_ARRAY:
            # no dimension ([]: flex member / extern): contributes 0 to the layout
            count = 0
            if t->arr_len != None:
                ok: bool = True
                v: i64 = self->const_int(t->arr_len, ref ok)
                if ok and v > 0:
                    count = i32(v)
            return count * self->size_of(t->inner)
        n: const *char = self->td_resolve(t->name)
        if n in {"va_list", "__builtin_va_list"}:
            return 24   # va_list SysV: 24-byte region (treated as aggregate)
        if n in {"char", "bool", "i8", "u8"}:
            return 1
        if n in {"short", "i16", "u16"}:
            return 2
        if self->cls_of(t) == 'l' or self->cls_of(t) == 'd':
            return 8
        # struct by name: sum of the fields (with alignment)
        sd: *Decl = self->structs.get_or(n, None)
        if sd != None:
            return self->struct_size(sd)
        return 4

    # VLA (C99): local array with a NON-constant dimension at compile time.
    # Allocated dynamically on the stack (alloc with a runtime size) at the
    # declaration point, not in the @start prologue. (Under --std=c89 sema has
    # already lowered it to pointer+malloc.)
    private def is_vla_type(self: *Qb, t: *Type) -> bool:
        if t == None or t->kind != TY_ARRAY or t->arr_len == None:
            return False
        ok: bool = True
        self->const_int(t->arr_len, ref ok)
        return not ok

    private def type_align(self: *Qb, t: *Type) -> i32:
        if t == None:
            return 4
        if t->kind == TY_PTR:
            return 8
        if t->kind == TY_ARRAY:
            return self->type_align(t->inner)
        d: *Decl = self->structs.get_or(t->name, None)
        if d != None:
            return self->struct_align(d)
        return self->size_of(t)  # scalar: alignment == size

    private def struct_align(self: *Qb, d: *Decl) -> i32:
        a = 1
        i: i32
        for i in range(d->nfields):
            fa: i32 = self->type_align(d->fields[i].type)
            if fa > a:
                a = fa
        return a

    # single layout walker, with BITFIELDS (SysV packing: consecutive
    # bitfields share the declared type's unit as long as they fit;
    # `:0` closes the unit; a new unit starts when the type size changes).
    # fname != None: returns the field's UNIT offset and writes the type/
    # bit_off/bit_width (bw = -1 for a normal field), descending into
    # anonymous members. fname == None: returns the end of the struct
    # (without rounding).
    private def slayout(self: *Qb, d: *Decl, fname: const *char, ref out_ty: *Type, ref out_boff: i32, ref out_bw: i32) -> i32:
        off = 0
        ubase = -1   # open bitfield unit (-1 = none)
        usz = 0; ubits = 0
        i: i32
        for i in range(d->nfields):
            ft: *Type = d->fields[i].type
            bw: i32 = d->fields[i].bit_width
            if d->kind == DL_UNION:
                if fname != None and strcmp(d->fields[i].name, fname) == 0:
                    out_ty = ft
                    out_boff = 0
                    out_bw = bw
                    return 0
                if fname != None and d->fields[i].name[0] == '\0' and bw < 0:
                    ad0: *Decl = self->struct_of(ft)
                    if ad0 != None:
                        sub0: *Type = None
                        so0: i32 = self->slayout(ad0, fname, ref sub0, ref out_boff, ref out_bw)
                        if sub0 != None:
                            out_ty = sub0
                            return so0
                continue
            if bw >= 0:
                ts: i32 = self->size_of(ft)
                if bw == 0:
                    if ubase >= 0:
                        off = ubase + usz; ubase = -1
                    continue
                if ubase < 0 or ubits + bw > usz * 8 or ts != usz:
                    ubase = align_up(off, self->type_align(ft)); usz = ts
                    ubits = 0; off = ubase + usz
                if fname != None and d->fields[i].name[0] != '\0' and strcmp(d->fields[i].name, fname) == 0:
                    out_ty = ft
                    out_boff = ubits
                    out_bw = bw
                    return ubase
                ubits += bw
                continue
            if ubase >= 0:
                off = ubase + usz; ubase = -1
            fo: i32 = align_up(off, self->type_align(ft))
            if fname != None and strcmp(d->fields[i].name, fname) == 0:
                out_ty = ft
                out_boff = 0
                out_bw = -1
                return fo
            if fname != None and d->fields[i].name[0] == '\0':
                ad: *Decl = self->struct_of(ft)
                if ad != None:
                    sub: *Type = None
                    soff: i32 = self->slayout(ad, fname, ref sub, ref out_boff, ref out_bw)
                    if sub != None:
                        out_ty = sub
                        return fo + soff
            off = fo + self->size_of(ft)
        if ubase >= 0:
            off = ubase + usz
        if fname != None:
            out_ty = None
            return 0
        return off

    private def struct_size(self: *Qb, d: *Decl) -> i32:
        # union: all fields at offset 0; size = the largest field
        if d->kind == DL_UNION:
            mx = 0
            for u in range(d->nfields):
                fs: i32 = self->size_of(d->fields[u].type)
                if fs > mx:
                    mx = fs
            return align_up(mx, self->struct_align(d))
        db = 0; dw = 0
        dt: *Type = None
        end: i32 = self->slayout(d, None, ref dt, ref db, ref dw)
        return align_up(end, self->struct_align(d))

    # offset of field `fname` in `d` (unit, for bitfield); type in out_ty
    private def field_offset(self: *Qb, d: *Decl, fname: const *char, ref out_ty: *Type) -> i32:
        db = 0; dw = 0
        return self->slayout(d, fname, ref out_ty, ref db, ref dw)

    # ---------- static init of aggregates (emitted into `data`) ----------
    # A scalar `data` item for type `ty` from a constant expression.
    # Always emits with a trailing comma; returns bytes emitted or -1 if the
    # form isn't constant/supported (the caller falls back to zero-fill).
    # emits the bytes of `e` (aggregate) into an anonymous data in the
    # module's buffer and returns the symbol's name ($qadN). Used for an
    # array compound literal as a static POINTER value:
    # `uchar *m[] = { (uchar[]){...} }`.
    private def emit_anon_data(self: *Qb, ty: *Type, e: *Expr) -> const *char:
        adb: StrBuf = {0}
        one: *Expr = e
        ix = 0
        rr: i32 = self->data_fill(&adb, ty, &one, 1, ref ix)
        nm: *char = malloc(24)
        snprintf(nm, 24, "qad%d", self->nstatic)
        self->nstatic += 1
        if rr > 0 and adb.len > 0:
            if adb.data[adb.len - 1] == ',':
                adb.len -= 1
                adb.data[adb.len] = '\0'
            self->data.printf("data $%s = align %d {%s }\n", nm, self->type_align(ty), adb.data)
        else:
            self->data.printf("data $%s = { z %d }\n", nm, self->size_of(ty) if self->size_of(ty) > 0 else 1)
        adb.deinit()
        return nm

    private def data_scalar(self: *Qb, db: *StrBuf, ty: *Type, e: *Expr) -> i32:
        if e == None:
            return -1
        sz: i32 = self->size_of(ty)
        scls: char = self->cls_of(ty)
        # pointer = compound literal / aggregate list: materializes anonymous
        # object and references the address (uchar *m = (uchar[]){...})
        if ty != None and ty->kind == TY_PTR and (e->kind == EX_COMPOUND or e->kind == EX_INITLIST):
            aty: *Type = e->cast_type if e->kind == EX_COMPOUND else ty->inner
            anm: const *char = self->emit_anon_data(aty, e)
            db->printf(" l $%s,", anm)
            return 8
        if (scls == 'd' or scls == 's') and e->kind == EX_NUMBER:
            db->printf(" %c %c_%s,", scls, scls, fnum(e->text))
            return sz
        if e->kind == EX_UNARY and e->op == TK_AMP and e->lhs != None and e->lhs->kind == EX_IDENT:
            db->printf(" l $%s,", e->lhs->text)
            return 8
        if e->kind == EX_IDENT and self->funcs.get_or(e->text, None) != None:
            db->printf(" l $%s,", e->text)   # function decays to address
            return 8
        if e->kind == EX_IDENT:
            ga: *Type = self->globals.get_or(e->text, None)
            if ga != None and ga->kind == TY_ARRAY:
                db->printf(" l $%s,", e->text)   # global array decays
                return 8
        if e->kind == EX_STRING and ty != None and ty->kind == TY_PTR:
            sid: i32 = self->emit_string(e->text)
            db->printf(" l $qstr%d,", sid)
            return 8
        if e->kind == EX_NONE:
            db->printf(" l 0,")   # None = null pointer (8 bytes)
            return 8
        ok: bool = True
        v: i64 = self->const_int(e, ref ok)
        if not ok:
            return -1
        dt: const *char = "w"
        if sz == 1:
            dt = "b"
        elif sz == 2:
            dt = "h"
        elif sz == 8:
            dt = "l"
        db->printf(" %s %lld,", dt, v)
        return sz

    # Fills ONE value of `ty` consuming exprs from the flat stream items[idx..)
    # — C brace-elision semantics: sub-aggregate WITHOUT braces consumes from
    # the parent's stream; WITH braces opens its own stream. Returns bytes or -1.
    private def data_fill(self: *Qb, db: *StrBuf, ty: *Type, items: **Expr, nitems: i32, ref idx: i32) -> i32:
        sd: *Decl = None
        if ty != None and ty->kind == TY_NAME and ty->name != None:
            sd = self->structs.get_or(ty->name, None)
        aggr: bool = ty != None and (ty->kind == TY_ARRAY or sd != None)
        # pointer = compound literal / aggregate list -> anonymous object
        if not aggr and ty != None and ty->kind == TY_PTR and idx < nitems and items[idx] != None and (items[idx]->kind == EX_COMPOUND or (items[idx]->kind == EX_INITLIST and items[idx]->nargs != 1)):
            r: i32 = self->data_scalar(db, ty, items[idx])
            idx += 1
            return r
        if idx < nitems and items[idx] != None and (items[idx]->kind == EX_INITLIST or (items[idx]->kind == EX_COMPOUND and aggr)):
            sub: *Expr = items[idx]
            idx += 1
            if aggr:
                j = 0
                return self->data_fill_body(db, ty, sd, sub->args, sub->nargs, ref j)
            if sub->nargs != 1:
                return -1
            return self->data_scalar(db, ty, sub->args[0])
        # char arr[N] = "..." (field/element): bytes + nul + padding
        if aggr and ty->kind == TY_ARRAY and idx < nitems and items[idx] != None and items[idx]->kind == EX_STRING and self->size_of(ty->inner) == 1:
            se: *Expr = items[idx]
            idx += 1
            nb: i32 = cstr_bytes(db, se->text, -1)
            db->puts(" b 0,")
            sz2: i32 = self->size_of(ty)
            if sz2 > nb + 1:
                db->printf(" z %d,", sz2 - (nb + 1))
                return sz2
            return nb + 1
        if not aggr:
            if idx >= nitems:
                return -1
            e2: *Expr = items[idx]
            idx += 1
            return self->data_scalar(db, ty, e2)
        # aggregate without braces: consumes from the current stream (elision)
        return self->data_fill_body(db, ty, sd, items, nitems, ref idx)

    # Body of an aggregate: array = elements in sequence; struct = fields in
    # order with alignment padding (z); union = 1st field + padding.
    # With DESIGNATORS at this level ([i]=/.f=): slot-mode — resolves each
    # position (last write wins, as in C) and emits in order; positions with
    # no value become zero. Without designators: streaming (preserves brace elision).
    private def data_fill_body(self: *Qb, db: *StrBuf, ty: *Type, sd: *Decl, items: **Expr, nitems: i32, ref idx: i32) -> i32:
        # is there a designator at this level?
        has_desig: bool = False
        for di in range(idx, nitems):
            if items[di] != None and items[di]->kind == EX_DESIG:
                has_desig = True
                break
        if ty->kind == TY_ARRAY:
            count = -1   # -1 = size inferred from the initializer
            if ty->arr_len != None:
                cok: bool = True
                cv: i64 = self->const_int(ty->arr_len, ref cok)
                if cok and cv >= 0:
                    count = i32(cv)
            esz: i32 = self->size_of(ty->inner)
            if has_desig:
                return self->data_fill_slots_arr(db, ty, count, esz, items, nitems, ref idx)
            cnt = 0; emitted = 0
            while idx < nitems and (count < 0 or cnt < count):
                r: i32 = self->data_fill(db, ty->inner, items, nitems, ref idx)
                if r < 0:
                    return -1
                emitted += r
                cnt += 1
            if count >= 0 and count * esz > emitted:
                db->printf(" z %d,", count * esz - emitted)
                emitted = count * esz
            return emitted
        if sd == None:
            return -1
        if sd->kind == DL_UNION:
            if sd->nfields == 0:
                return -1
            if has_desig and idx < nitems and items[idx]->kind == EX_DESIG and items[idx]->field != None:
                # designator in union: finds the owning member (direct or inside
                # an anonymous member) and delegates the whole stream to it
                fname: const *char = items[idx]->field
                for ui in range(sd->nfields):
                    if strcmp(sd->fields[ui].name, fname) == 0:
                        # direct member: initializes only it with the value
                        one: *Expr = items[idx]->lhs
                        idx = nitems
                        j0 = 0
                        ru: i32 = self->data_fill(db, sd->fields[ui].type, &one, 1, ref j0)
                        if ru < 0:
                            return -1
                        usz0: i32 = self->struct_size(sd)
                        if usz0 > ru:
                            db->printf(" z %d,", usz0 - ru)
                        return usz0
                for ui in range(sd->nfields):
                    if sd->fields[ui].name[0] == '\0':
                        ad: *Decl = self->struct_of(sd->fields[ui].type)
                        sub: *Type = None
                        if ad != None:
                            self->field_offset(ad, fname, ref sub)
                        if sub != None:
                            ra: i32 = self->data_fill_body(db, sd->fields[ui].type, ad, items, nitems, ref idx)
                            if ra < 0:
                                return -1
                            usz1: i32 = self->struct_size(sd)
                            if usz1 > ra:
                                db->printf(" z %d,", usz1 - ra)
                            return usz1
                return -1
            r2: i32 = self->data_fill(db, sd->fields[0].type, items, nitems, ref idx)
            if r2 < 0:
                return -1
            usz: i32 = self->struct_size(sd)
            if usz > r2:
                db->printf(" z %d,", usz - r2)
            return usz
        if has_desig:
            return self->data_fill_slots_struct(db, sd, items, nitems, ref idx)
        off = 0; i = 0
        while i < sd->nfields:
            bwf: i32 = sd->fields[i].bit_width
            if bwf >= 0:
                # run of bitfields: packs the constants into a single unit
                if bwf == 0:
                    i += 1
                    continue
                ts: i32 = self->size_of(sd->fields[i].type)
                ub: i32 = align_up(off, self->type_align(sd->fields[i].type))
                ubits = 0
                uval: i64 = 0
                while i < sd->nfields:
                    bwi: i32 = sd->fields[i].bit_width
                    if bwi <= 0 or ubits + bwi > ts * 8 or self->size_of(sd->fields[i].type) != ts:
                        if bwi == 0:
                            i += 1   # `:0` closes the unit
                        break
                    if sd->fields[i].name[0] != '\0' and idx < nitems:
                        vok: bool = True
                        vv: i64 = self->const_int(items[idx], ref vok)
                        if not vok:
                            return -1
                        idx += 1
                        uval |= (vv & ((i64(1) << bwi) - 1)) << ubits
                    ubits += bwi
                    i += 1
                if ub > off:
                    db->printf(" z %d,", ub - off)
                dtn: const *char = "w"
                if ts == 1:
                    dtn = "b"
                elif ts == 2:
                    dtn = "h"
                elif ts == 8:
                    dtn = "l"
                db->printf(" %s %lld,", dtn, uval)
                off = ub + ts
                continue
            if idx >= nitems:
                break
            fo: i32 = align_up(off, self->type_align(sd->fields[i].type))
            if fo > off:
                db->printf(" z %d,", fo - off)
            r3: i32 = self->data_fill(db, sd->fields[i].type, items, nitems, ref idx)
            if r3 < 0:
                return -1
            off = fo + r3
            i += 1
        tot: i32 = self->struct_size(sd)
        if tot > off:
            db->printf(" z %d,", tot - off)
        return tot

    # slot-mode for array with designators: resolves positions (override = last
    # write wins), then emits each slot (empty -> z)
    private def data_fill_slots_arr(self: *Qb, db: *StrBuf, ty: *Type, count: i32, esz: i32, items: **Expr, nitems: i32, ref idx: i32) -> i32:
        # 1st pass: size (if inferred) = max(position) + 1
        cur = 0; mx = 0
        for k in range(idx, nitems):
            it: *Expr = items[k]
            if it != None and it->kind == EX_DESIG and it->rhs != None:
                ok: bool = True
                v: i64 = self->const_int(it->rhs, ref ok)
                if not ok:
                    return -1
                cur = i32(v)
            if cur + 1 > mx:
                mx = cur + 1
            cur += 1
        n: i32 = count if count >= 0 else mx
        slots: **Expr = calloc(usize(n), sizeof(items[0]))
        cur = 0
        for k in range(idx, nitems):
            it2: *Expr = items[k]
            val: *Expr = it2
            if it2 != None and it2->kind == EX_DESIG:
                ok2: bool = True
                cur = i32(self->const_int(it2->rhs, ref ok2)); val = it2->lhs
            if cur >= 0 and cur < n:
                slots[cur] = merge_init(slots[cur], val)
            cur += 1
        idx = nitems
        emitted = 0
        for k in range(n):
            if slots[k] == None:
                db->printf(" z %d,", esz)
                emitted += esz
            else:
                j = 0
                r: i32 = self->data_fill(db, ty->inner, &slots[k], 1, ref j)
                if r < 0:
                    free(slots)
                    return -1
                emitted += r
        free(slots)
        return emitted

    # slot-mode for struct with designators (.f=): resolves field by field
    private def data_fill_slots_struct(self: *Qb, db: *StrBuf, sd: *Decl, items: **Expr, nitems: i32, ref idx: i32) -> i32:
        slots: **Expr = calloc(usize(sd->nfields), sizeof(items[0]))
        cur = 0
        for k in range(idx, nitems):
            it: *Expr = items[k]
            val: *Expr = it
            if it != None and it->kind == EX_DESIG and it->field != None:
                fi = -1
                for f2 in range(sd->nfields):
                    if strcmp(sd->fields[f2].name, it->field) == 0:
                        fi = f2
                        break
                if fi < 0:
                    free(slots)
                    return -1
                cur = fi; val = it->lhs
            if cur >= 0 and cur < sd->nfields:
                slots[cur] = merge_init(slots[cur], val)
            cur += 1
        idx = nitems
        off = 0; k = 0
        while k < sd->nfields:
            bwk: i32 = sd->fields[k].bit_width
            if bwk >= 0:
                # run of designated bitfields: packs constants into the unit
                if bwk == 0:
                    k += 1
                    continue
                ts: i32 = self->size_of(sd->fields[k].type)
                ub: i32 = align_up(off, self->type_align(sd->fields[k].type))
                ubits = 0
                uval: i64 = 0
                while k < sd->nfields:
                    bwi: i32 = sd->fields[k].bit_width
                    if bwi <= 0 or ubits + bwi > ts * 8 or self->size_of(sd->fields[k].type) != ts:
                        if bwi == 0:
                            k += 1
                        break
                    if slots[k] != None:
                        vok: bool = True
                        vv: i64 = self->const_int(slots[k], ref vok)
                        if not vok:
                            free(slots)
                            return -1
                        uval |= (vv & ((i64(1) << bwi) - 1)) << ubits
                    ubits += bwi
                    k += 1
                if ub > off:
                    db->printf(" z %d,", ub - off)
                dtn: const *char = "w"
                if ts == 1:
                    dtn = "b"
                elif ts == 2:
                    dtn = "h"
                elif ts == 8:
                    dtn = "l"
                db->printf(" %s %lld,", dtn, uval)
                off = ub + ts
                continue
            fo: i32 = align_up(off, self->type_align(sd->fields[k].type))
            if fo > off:
                db->printf(" z %d,", fo - off)
            fsz: i32 = self->size_of(sd->fields[k].type)
            if slots[k] == None:
                if fsz > 0:
                    db->printf(" z %d,", fsz)
                off = fo + fsz
            else:
                j = 0
                r: i32 = self->data_fill(db, sd->fields[k].type, &slots[k], 1, ref j)
                if r < 0:
                    free(slots)
                    return -1
                off = fo + r
            k += 1
        free(slots)
        tot: i32 = self->struct_size(sd)
        if tot > off:
            db->printf(" z %d,", tot - off)
        return tot

    # ---------- emission of aggregate types (type :Name = ...) ----------
    # a type MEMBER: letter per size/class, :sub for struct, with array
    # count. Returns False if the shape is not representable (falls back to opaque).
    private def qtype_member(self: *Qb, out: *StrBuf, ft: *Type, count: i32) -> bool:
        while ft != None and ft->kind == TY_ARRAY:
            c = 0
            if ft->arr_len != None:
                aok: bool = True
                av: i64 = self->const_int(ft->arr_len, ref aok)
                if aok and av > 0:
                    c = i32(av)
            if c == 0:
                return True   # flex []: contributes no member
            count = count * c; ft = ft->inner
        if ft == None:
            return False
        if ft->kind == TY_PTR or ft->kind == TY_FUNC:
            out->printf(" l %d,", count)
            return True
        if ft->kind != TY_NAME:
            return False
        sub: *Decl = self->structs.get_or(ft->name, None)
        if sub != None:
            if sub->nfields == 0:
                return True   # empty struct: 0 bytes
            out->printf(" :%s %d,", ft->name, count)
            return True
        if self->is_valist(ft):
            return False
        cl: char = self->cls_of(ft)
        sz: i32 = self->size_of(ft)
        le: char = 'w'
        if cl == 'd':
            le = 'd'
        elif cl == 's':
            le = 's'
        elif sz == 1:
            le = 'b'
        elif sz == 2:
            le = 'h'
        elif sz == 8:
            le = 'l'
        out->printf(" %c %d,", le, count)
        return True

    # emits `type :Name` with dependencies FIRST (QBE requires subtypes defined)
    private def emit_qtype(self: *Qb, out: *StrBuf, name: const *char, done: *StrSet):
        if done->has(name):
            return
        done->add(name)
        d: *Decl = self->structs.get_or(name, None)
        if d == None or d->nfields == 0:
            return
        i: i32
        for i in range(d->nfields):
            bt: *Type = d->fields[i].type
            while bt != None and bt->kind == TY_ARRAY:
                bt = bt->inner
            if bt != None and bt->kind == TY_NAME and bt->name != None and self->structs.get_or(bt->name, None) != None and not done->has(bt->name):
                self->emit_qtype(out, bt->name, done)
        db: StrBuf = {0}
        ok: bool = True
        if d->kind == DL_UNION:
            # union: each field is a variant { {v1} {v2} ... }
            for i in range(d->nfields):
                db.puts(" {")
                if not self->qtype_member(&db, d->fields[i].type, 1):
                    ok = False
                    break
                if db.len > 0 and db.data[db.len - 1] == ',':
                    db.len -= 1
                    db.data[db.len] = '\0'
                db.puts(" }")
        else:
            i = 0
            while i < d->nfields and ok:
                bw: i32 = d->fields[i].bit_width
                if bw >= 0:
                    # bitfield run: ONE unit of the declared type
                    if bw == 0:
                        i += 1
                        continue
                    ts: i32 = self->size_of(d->fields[i].type)
                    ubits = 0
                    while i < d->nfields:
                        bwi: i32 = d->fields[i].bit_width
                        if bwi <= 0 or ubits + bwi > ts * 8 or self->size_of(d->fields[i].type) != ts:
                            if bwi == 0:
                                i += 1
                            break
                        ubits += bwi
                        i += 1
                    ul: char = 'w'
                    if ts == 1:
                        ul = 'b'
                    elif ts == 2:
                        ul = 'h'
                    elif ts == 8:
                        ul = 'l'
                    db.printf(" %c 1,", ul)
                    continue
                if not self->qtype_member(&db, d->fields[i].type, 1):
                    ok = False
                i += 1
        if ok and db.len > 0 and db.data[db.len - 1] == ',':
            db.len -= 1
            db.data[db.len] = '\0'
        if ok:
            out->printf("type :%s = align %d {%s }\n", name, self->struct_align(d), db.data if db.data != None else "")
        else:
            # shape not representable: opaque (memory class — conservative)
            out->printf("type :%s = align %d { %d }\n", name, self->struct_align(d), self->struct_size(d))
        db.deinit()

    # is t a struct/union passed BY VALUE (QBE aggregate)? (non-pointer)
    private def is_agg(self: *Qb, t: *Type) -> bool:
        if t == None or t->kind != TY_NAME:
            return False
        return self->structs.get_or(t->name, None) != None

    private def is_valist(self: *Qb, t: *Type) -> bool:
        if t == None or t->kind != TY_NAME:
            return False
        return t->name in {"va_list", "__builtin_va_list"}

    # if t (after deref) is a known struct, returns the DL_STRUCT; else None
    private def struct_of(self: *Qb, t: *Type) -> *Decl:
        if t == None:
            return None
        if t->kind == TY_PTR or t->kind == TY_ARRAY:
            t = t->inner
        if t == None or t->kind != TY_NAME:
            return None
        return self->structs.get_or(t->name, None)

    private def is_signed(self: *Qb, t: *Type) -> bool:
        # pointer/array (name == None) -> treated as signed (only matters
        # for div/rem/shift/comparison, where pointer behaves as signed)
        if t == None or t->kind != TY_NAME or t->name == None:
            return True
        n: const *char = t->name
        # any C spelling that STARTS with `unsigned` ("unsigned", "unsigned long",
        # "unsigned long long", "unsigned char"...) is unsigned
        if strncmp(n, "unsigned", 8) == 0:
            return False
        return not (n in {"u8", "u16", "u32", "u64", "usize", "bool"})

    # signedness of an operand (from its declared/ingested type; an unprototyped
    # call has no type and defaults to signed, like C's implicit int)
    private def op_signed(self: *Qb, e: *Expr) -> bool:
        return self->is_signed(self->qtype_of(e))

    # lexical name resolution: walk the ACTIVE bindings innermost-first. Two
    # declarations may share a name with different types (sibling/nested blocks);
    # a flat name search would fuse them — wrong offsets and store classes.
    private def find_var(self: *Qb, name: const *char) -> *QVar:
        k: i32
        for k in range(self->binds.len - 1, -1, -1):
            idx: i32 = self->binds.get(k)
            if strcmp(self->vars.data[idx].name, name) == 0:
                return &self->vars.data[idx]
        return None

    # activates the binding of a declaration at its emission point: ties the
    # emitted ST_VAR/ST_WITH to the QVar the collect pre-pass created for it
    # (identity by Stmt pointer, immune to name collisions)
    private def bind_decl(self: *Qb, s: *Stmt):
        i: i32
        for i in range(self->vars.len):
            if self->vars.data[i].decl == s:
                self->binds.push(i)
                return

    # enum constant -> integer value (QBE has no enum); *out receives the value
    private def enum_lookup(self: *Qb, name: const *char, out: *i64) -> bool:
        i: i32
        for i in range(self->enumc.len):
            if strcmp(self->enumc.data[i].name, name) == 0:
                *out = self->enumc.data[i].val
                return True
        return False

    # ---------- local type inference (mirrors sema, best-effort) ----------
    private def qtype_of(self: *Qb, e: *Expr) -> *Type:
        if e == None:
            return None
        match e->kind:
            case EX_IDENT:
                v: *QVar = self->find_var(e->text)
                if v != None:
                    return v->ty
                gty: *Type = self->globals.get_or(e->text, None)
                if gty != None:
                    return gty
                # function designator: function type (class l; indirect
                # call via ternary/assignment sees the return type)
                f0: *Func = self->funcs.get_or(e->text, None)
                if f0 != None:
                    ftn: *Type = calloc(1, sizeof(Type))
                    ftn->kind = TY_FUNC
                    ftn->inner = f0->ret
                    return ftn
                return None
            case EX_NUMBER:
                # L/l suffix or large value -> long; else int
                s: const *char = e->text
                while *s != '\0':
                    if *s == 'l' or *s == 'L':
                        return None  # handled as 'l' via cls; None=>w, so force:
                    s += 1
                return None
            case EX_STRING:
                return None  # pointer (handled specially in cls_of_expr)
            case EX_CHARLIT, EX_TRUE, EX_FALSE:
                return None
            case EX_CAST, EX_TYPEREF, EX_COMPOUND, EX_VAARG:
                return e->cast_type
            case EX_CALL:
                if e->lhs != None and e->lhs->kind == EX_IDENT:
                    f: *Func = self->funcs.get_or(e->lhs->text, None)
                    if f != None:
                        return f->ret
                # indirect call (`go()()`, `s->fp()`): the callee's type is
                # ptr-to-function (or function) — the result is its return type
                ct: *Type = self->qtype_of(e->lhs)
                if ct != None and ct->kind == TY_PTR:
                    ct = ct->inner
                if ct != None and ct->kind == TY_FUNC:
                    return ct->inner
                return None
            case EX_UNARY:
                if e->op == TK_STAR:
                    t: *Type = self->qtype_of(e->lhs)
                    if t != None and (t->kind == TY_PTR or t->kind == TY_ARRAY):
                        return t->inner
                    return None
                if e->op == TK_AMP:
                    # &x: pointer to the type of x ((&s)->field needs this)
                    it: *Type = self->qtype_of(e->lhs)
                    if it != None:
                        return mk_typtr(it)
                    return None
                if e->op == TK_NOT:
                    return None  # !x is int (size 4), not the operand's type
                return self->qtype_of(e->lhs)
            case EX_INDEX:
                t2: *Type = self->qtype_of(e->lhs)
                if t2 != None and (t2->kind == TY_PTR or t2->kind == TY_ARRAY):
                    return t2->inner
                return None
            case EX_BINARY:
                lt: *Type = self->qtype_of(e->lhs)
                if lt != None:
                    return lt
                return self->qtype_of(e->rhs)
            case EX_TERNARY:
                tt: *Type = self->qtype_of(e->lhs)
                if tt != None:
                    return tt
                return self->qtype_of(e->rhs)
            case EX_INCDEC:
                return self->qtype_of(e->lhs)
            case EX_ASSIGN:
                return self->qtype_of(e->lhs)
            case EX_COMMA:
                return self->qtype_of(e->rhs)
            case EX_FIELD:
                d: *Decl = self->struct_of(self->qtype_of(e->lhs))
                if d == None:
                    return None
                fty: *Type = None
                self->field_offset(d, e->field, ref fty)
                return fty
            case EX_GENERIC:
                return self->qtype_of(self->gen_select(e))
            case EX_STMTEXPR:
                return self->qtype_of(e->lhs)
            case _:
                return None

    # ---------- _Generic (C11): compile-time type-based selection ----------
    # type for matching: like qtype_of, but with literals, strings, functions
    # and arithmetic promotion resolved (the fidelity the dispatch requires)
    private def gtype_of(self: *Qb, e: *Expr) -> *Type:
        if e == None:
            return None
        match e->kind:
            case EX_NUMBER:
                if is_float_lit(e->text):
                    return mk_tyname("float" if float_cls(e->text) == 's' else "double")
                lsuf: bool = False
                usuf: bool = False
                s: const *char = e->text
                while *s != '\0':
                    if *s == 'l' or *s == 'L':
                        lsuf = True
                    elif *s == 'u' or *s == 'U':
                        usuf = True
                    s += 1
                if not lsuf and strtoull(e->text, None, 0) > 0x7FFFFFFF:
                    lsuf = True   # no suffix but doesn't fit in int
                if lsuf:
                    return mk_tyname("u64" if usuf else "long")
                return mk_tyname("unsigned" if usuf else "int")
            case EX_STRING:
                return mk_typtr(mk_tyname("char"))   # literal decays to char*
            case EX_CHARLIT:
                return mk_tyname("int")
            case EX_IDENT:
                if self->find_var(e->text) == None and self->globals.get_or(e->text, None) == None:
                    f: *Func = self->funcs.get_or(e->text, None)
                    if f != None:
                        ft: *Type = calloc(1, sizeof(Type))
                        ft->kind = TY_FUNC
                        ft->inner = f->ret
                        return ft
                    ev: i64 = 0
                    if self->enum_lookup(e->text, &ev):
                        return mk_tyname("int")
                return self->qtype_of(e)
            case EX_BINARY:
                op: i32 = e->op
                if op in {TK_EQ, TK_NE, TK_LT, TK_LE, TK_GT, TK_GE, TK_AND, TK_OR}:
                    return mk_tyname("int")
                return arith_promote(self->gtype_of(e->lhs), self->gtype_of(e->rhs))
            case EX_UNARY:
                if e->op == TK_NOT:
                    return mk_tyname("int")
                if e->op == TK_AMP:
                    return mk_typtr(self->gtype_of(e->lhs))
                if e->op == TK_STAR:
                    return self->qtype_of(e)
                return self->gtype_of(e->lhs)
            case EX_GENERIC:
                return self->gtype_of(self->gen_select(e))
            case _:
                return self->qtype_of(e)

    # C11 lvalue conversion on the controlling expr: drops the top qualifier;
    # array decays to pointer; function to function-pointer
    private def glvconv(self: *Qb, t: *Type) -> *Type:
        if t == None:
            return None
        if t->kind == TY_ARRAY:
            return mk_typtr(t->inner)
        if t->kind == TY_FUNC:
            return mk_typtr(t)
        if t->kind == TY_NAME and t->is_const:
            c: *Type = calloc(1, sizeof(Type))
            *c = *t
            c->is_const = False
            return c
        return t

    # structural equality for associations: const is significant (except at
    # the top level, already stripped by glvconv); function params ignored (F1)
    private def type_eq_gen(self: *Qb, a: *Type, b: *Type) -> bool:
        if a == None or b == None:
            return False
        if a->kind != b->kind:
            return False
        match a->kind:
            case TY_NAME:
                if a->is_const != b->is_const or a->name == None or b->name == None:
                    return False
                return strcmp(a->name, b->name) == 0
            case TY_PTR, TY_FUNC:
                return self->type_eq_gen(a->inner, b->inner)
            case TY_ARRAY:
                if not self->type_eq_gen(a->inner, b->inner):
                    return False
                if a->arr_len == None and b->arr_len == None:
                    return True
                if a->arr_len == None or b->arr_len == None:
                    return False
                ok1: bool = True
                ok2: bool = True
                va: i64 = self->const_int(a->arr_len, ref ok1)
                vb: i64 = self->const_int(b->arr_len, ref ok2)
                return ok1 and ok2 and va == vb
            case _:
                return False

    # picks the association's expression that matches the controlling type
    private def gen_select(self: *Qb, e: *Expr) -> *Expr:
        ct: *Type = self->glvconv(self->gtype_of(e->lhs))
        dflt: *Expr = None
        i: i32
        for i in range(e->nargs):
            if e->gen_types[i] == None:
                dflt = e->args[i]
            elif self->type_eq_gen(ct, e->gen_types[i]):
                return e->args[i]
        if dflt != None:
            return dflt
        fatal_at(self->file, e->pos, "_Generic: no association matches the controlling expression")
        return None

    # QBE class of an expression (with the special ptr/string cases)
    private def ecls(self: *Qb, e: *Expr) -> char:
        if e == None:
            return 'w'
        if e->kind == EX_GENERIC:
            return self->ecls(self->gen_select(e))
        if e->kind == EX_STMTEXPR:
            return self->ecls(e->lhs) if e->lhs != None else 'w'
        # the comma operator YIELDS its right side, so it has that side's class.
        # Without this the fallback asked qtype_of, which for a comparison
        # reports the OPERAND's type — `(t = x, a.f == b.f)` came out class 'd'
        # and the `not` around it compared a boolean against a double zero.
        if e->kind == EX_COMMA:
            return self->ecls(e->rhs)
        if e->kind == EX_STRING or e->kind == EX_NONE:
            return 'l'
        if e->kind == EX_UNARY and e->op == TK_AMP:
            return 'l'
        # sizeof(...) -> size_t (class 'l')
        if e->kind == EX_CALL and e->lhs != None and e->lhs->kind == EX_IDENT and e->lhs->text == "sizeof":
            return 'l'
        # direct call to a function WITHOUT a prototype: defaults to 'w' (C's
        # implicit-int rule). `include <header.h>` ingests the real signature.
        if e->kind == EX_CALL and e->lhs != None and e->lhs->kind == EX_IDENT and self->funcs.get_or(e->lhs->text, None) == None and self->find_var(e->lhs->text) == None and self->globals.get_or(e->lhs->text, None) == None:
            return 'w'
        # -x / +x / ~x preserve the operand's class (matters for float)
        if e->kind == EX_UNARY and (e->op in {TK_MINUS, TK_PLUS, TK_TILDE}):
            return self->ecls(e->lhs)
        if e->kind == EX_NUMBER:
            if is_float_lit(e->text):
                return float_cls(e->text)
            s: const *char = e->text
            while *s != '\0':
                if *s == 'l' or *s == 'L':
                    return 'l'
                s += 1
            # a value that doesn't fit in SIGNED int32 is 'l': this way
            # `0xffffffff` (unsigned int in C) promotes with zero-extend,
            # not the extsw a 'w' constant would undergo (0xFFFF...FFFF) — firstbit bug
            if strtoull(e->text, None, 0) > 0x7FFFFFFF:
                return 'l'
            return 'w'
        if e->kind == EX_BINARY:
            op: i32 = e->op
            if op in {TK_EQ, TK_NE, TK_LT, TK_LE, TK_GT, TK_GE, TK_AND, TK_OR}:
                return 'w'
            # mirrors emit_binary: shift preserves the lhs; the rest promotes both
            if op == TK_SHL or op == TK_SHR:
                return self->ecls(e->lhs)
            return qpromote(self->ecls(e->lhs), self->ecls(e->rhs))
        if e->kind == EX_TERNARY:
            # mirrors emit_ternary: common class of the two branches
            return qpromote(self->ecls(e->lhs), self->ecls(e->rhs))
        if e->kind == EX_UNARY and e->op == TK_NOT:
            return 'w'
        # Mirrors the IDENT value path of emit_expr: a name that is neither a
        # local, a global nor an enum constant is emitted with class 'l' — the
        # loaded FILE* for stderr/stdout/stdin, the address `$name` for anything
        # else (a function designator, an extern the headers didn't declare).
        # ecls MUST agree with what was emitted: reporting 'w' makes the caller
        # coerce w->l with `extsw`, which TRUNCATES the pointer to 32 bits.
        if e->kind == EX_IDENT and self->find_var(e->text) == None and self->globals.get_or(e->text, None) == None:
            eve: i64 = 0
            if not self->enum_lookup(e->text, &eve):
                return 'l'
        te: *Type = self->qtype_of(e)
        # aggregate/array as VALUE = address (class l)
        if self->is_agg(te) or (te != None and te->kind == TY_ARRAY) or self->is_valist(te):
            return 'l'
        return self->cls_of(te)

    # ---------- strings ----------
    # decodes ALL escapes into explicit bytes (b V, b V, ...) — robust and
    # without QBE escape ambiguity. Handles \n\t\r\\\"\' \a\b\f\v, octal
    # \NNN and hex \xNN.
    private def emit_string(self: *Qb, lex: const *char) -> i32:
        id: i32 = self->nstr
        self->nstr += 1
        if lit_is_wide(lex):
            # L"..."/U"..." => wchar_t/char32_t (4 bytes); u"..." => char16_t (2)
            elem: char = 'h' if lex[0] == 'u' else 'w'
            esz: i32 = 2 if lex[0] == 'u' else 4
            self->data.printf("data $qstr%d = align %d {", id, esz)
            wstr_data(&self->data, lex, elem)
            self->data.printf(" %c 0 }\n", elem)
            return id
        self->data.printf("data $qstr%d = {", id)
        cstr_bytes(&self->data, lex, -1)
        self->data.puts(" b 0 }\n")
        return id

    # ---------- lvalue: returns id of the temp holding the ADDRESS ----------
    private def emit_addr(self: *Qb, e: *Expr) -> i32:
        match e->kind:
            case EX_IDENT:
                v: *QVar = self->find_var(e->text)
                if v != None:
                    if v->ext:
                        te: i32 = self->tmp()
                        self->out->printf("\t%%t%d =l copy $%s\n", te, v->name)
                        return te
                    if v->is_static:
                        ts: i32 = self->tmp()
                        self->out->printf("\t%%t%d =l copy $sl%d\n", ts, v->sid)
                        return ts
                    return v->slot
                # global
                t: i32 = self->tmp()
                self->out->printf("\t%%t%d =l copy $%s\n", t, e->text)
                return t
            case EX_UNARY:
                if e->op == TK_STAR:
                    return self->emit_rvalue(e->lhs)
            case EX_COMPOUND:
                return self->emit_compound(e)
            case EX_FIELD:
                # p.field (value) -> address of p + offset;  q->field (ptr) ->
                # value of q + offset
                d: *Decl = self->struct_of(self->qtype_of(e->lhs))
                if d == None:
                    fatal_at(self->file, e->pos, "qbe backend: unknown struct type field")
                base: i32
                lk: i32 = e->lhs->kind
                if e->op == TK_ARROW:
                    base = self->emit_rvalue(e->lhs)
                elif lk in {EX_CALL, EX_COMPOUND, EX_STMTEXPR, EX_GENERIC, EX_CAST}:
                    # base is an aggregate RVALUE ((f()).field): the aggregate
                    # rvalue is already the address of the object (sret/anonymous slot)
                    base = self->emit_rvalue(e->lhs)
                else:
                    base = self->emit_addr(e->lhs)
                fty: *Type = None
                off: i32 = self->field_offset(d, e->field, ref fty)
                fa: i32 = self->tmp()
                self->out->printf("\t%%t%d =l add %%t%d, %d\n", fa, base, off)
                return fa
            case EX_COMMA:
                # `(a, b).f` — the comma is a sequence point: evaluate the left
                # for its effect, and the ADDRESS is the right one's. It is what
                # a lowering that binds operands to temporaries produces, and
                # what C says the value of a comma is.
                self->emit_rvalue(e->lhs)
                if e->rhs->kind in {EX_CALL, EX_COMPOUND, EX_STMTEXPR, EX_GENERIC, EX_CAST}:
                    # an aggregate RVALUE is already the address of the object
                    # it lives in (sret or an anonymous slot), exactly as the
                    # field case above treats it
                    return self->emit_rvalue(e->rhs)
                return self->emit_addr(e->rhs)
            case EX_INDEX:
                base: i32 = self->emit_rvalue(e->lhs)
                idx: i32 = self->emit_rvalue(e->rhs)
                # the index needs to be 'l' to add to the address; extend if 'w'
                if self->ecls(e->rhs) != 'l':
                    idxl: i32 = self->tmp()
                    self->out->printf("\t%%t%d =l extsw %%t%d\n", idxl, idx)
                    idx = idxl
                elem: *Type = self->qtype_of(e->lhs)
                esz = 4
                if elem != None and (elem->kind == TY_PTR or elem->kind == TY_ARRAY):
                    esz = self->size_of(elem->inner)
                off: i32 = self->tmp()
                self->out->printf("\t%%t%d =l mul %%t%d, %d\n", off, idx, esz)
                a: i32 = self->tmp()
                self->out->printf("\t%%t%d =l add %%t%d, %%t%d\n", a, base, off)
                return a
            case _:
                fatal_at(self->file, e->pos, "qbe backend: expression is not a valid lvalue (F1: struct fields pending)")
        return 0

    private def load_op(self: *Qb, t: *Type) -> const *char:
        sz: i32 = self->size_of(t)
        cls: char = self->cls_of(t)
        if cls == 'l':
            return "loadl"
        if cls == 'd':
            return "loadd"
        if cls == 's':
            return "loads"
        if sz == 1:
            return "loadsb" if self->is_signed(t) else "loadub"
        if sz == 2:
            return "loadsh" if self->is_signed(t) else "loaduh"
        return "loadw"

    private def store_op(self: *Qb, t: *Type) -> const *char:
        sz: i32 = self->size_of(t)
        cls: char = self->cls_of(t)
        if cls == 'l':
            return "storel"
        if cls == 'd':
            return "stored"
        if cls == 's':
            return "stores"
        if sz == 1:
            return "storeb"
        if sz == 2:
            return "storeh"
        return "storew"

    # QBE class of the operand expected by the store (b/h/w use 'w'; l uses 'l')
    private def store_cls(self: *Qb, t: *Type) -> char:
        c: char = self->cls_of(t)
        if c in {'l', 'd', 's'}:
            return c
        return 'w'

    # coerces a value from class `frm` to `to`. Covers int<->int, int<->float
    # (assumes signed — dominant case) and float<->float. Same class = no-op.
    private def emit_coerce(self: *Qb, val: i32, frm: char, to: char) -> i32:
        if frm == to:
            return val
        t: i32 = self->tmp()
        if frm == 'w' and to == 'l':
            self->out->printf("\t%%t%d =l extsw %%t%d\n", t, val)
        elif frm == 'l' and to == 'w':
            self->out->printf("\t%%t%d =w copy %%t%d\n", t, val)
        elif (frm == 'w' or frm == 'l') and (to == 's' or to == 'd'):
            conv: const *char = "swtof" if frm == 'w' else "sltof"
            self->out->printf("\t%%t%d =%c %s %%t%d\n", t, to, conv, val)
        elif (frm == 's' or frm == 'd') and (to == 'w' or to == 'l'):
            conv2: const *char = "stosi" if frm == 's' else "dtosi"
            self->out->printf("\t%%t%d =%c %s %%t%d\n", t, to, conv2, val)
        elif frm == 's' and to == 'd':
            self->out->printf("\t%%t%d =d exts %%t%d\n", t, val)
        elif frm == 'd' and to == 's':
            self->out->printf("\t%%t%d =s truncd %%t%d\n", t, val)
        else:
            self->out->printf("\t%%t%d =%c copy %%t%d\n", t, to, val)
        return t

    # ---------- rvalue: returns id of the temp holding the VALUE ----------
    private def emit_rvalue(self: *Qb, e: *Expr) -> i32:
        match e->kind:
            case EX_NUMBER:
                # float: QBE constant is <cls>_<number> (d_1.5 / s_1.5)
                if is_float_lit(e->text):
                    fc: char = float_cls(e->text)
                    tf: i32 = self->tmp()
                    self->out->printf("\t%%t%d =%c copy %c_%s\n", tf, fc, fc, fnum(e->text))
                    return tf
                # integer: normalize to decimal (QBE doesn't accept 0x... nor u/l/LL)
                nv: u64 = strtoull(e->text, None, 0)
                t: i32 = self->tmp()
                self->out->printf("\t%%t%d =%c copy %llu\n", t, self->ecls(e), nv)
                return t
            case EX_TRUE:
                t2: i32 = self->tmp()
                self->out->printf("\t%%t%d =w copy 1\n", t2)
                return t2
            case EX_FALSE, EX_NONE:
                t3: i32 = self->tmp()
                self->out->printf("\t%%t%d =%c copy 0\n", t3, self->ecls(e))
                return t3
            case EX_CHARLIT:
                t4: i32 = self->tmp()
                self->out->printf("\t%%t%d =w copy %d\n", t4, self->charval(e->text))
                return t4
            case EX_STRING:
                sid: i32 = self->emit_string(e->text)
                t5: i32 = self->tmp()
                self->out->printf("\t%%t%d =l copy $qstr%d\n", t5, sid)
                return t5
            case EX_IDENT:
                # __func__ (C99): string with the current function's name
                if e->text == "__func__" and self->cur_fname != None:
                    fq: *char = malloc(strlen(self->cur_fname) + 3)
                    sprintf(fq, "\"%s\"", self->cur_fname)
                    fsid: i32 = self->emit_string(fq)
                    free(fq)
                    tfq: i32 = self->tmp()
                    self->out->printf("\t%%t%d =l copy $qstr%d\n", tfq, fsid)
                    return tfq
                v: *QVar = self->find_var(e->text)
                if v != None:
                    # static local: address is $sl<sid>; array/struct decays,
                    # otherwise load
                    if v->is_static or v->ext:
                        sa: i32 = self->emit_addr(e)
                        if v->ty != None and (v->ty->kind == TY_ARRAY or self->is_agg(v->ty) or self->is_valist(v->ty)):
                            return sa
                        ts2: i32 = self->tmp()
                        self->out->printf("\t%%t%d =%c %s %%t%d\n", ts2, v->cls, self->load_op(v->ty), sa)
                        return ts2
                    # array/struct/va_list local decays to the base address (aggregate
                    # rvalue = its address; the ABI copies it on passing)
                    if v->ty != None and (v->ty->kind == TY_ARRAY or self->is_agg(v->ty) or self->is_valist(v->ty)):
                        tb: i32 = self->tmp()
                        self->out->printf("\t%%t%d =l copy %%t%d\n", tb, v->slot)
                        return tb
                    t6: i32 = self->tmp()
                    self->out->printf("\t%%t%d =%c %s %%t%d\n", t6, v->cls, self->load_op(v->ty), v->slot)
                    return t6
                gt: *Type = self->globals.get_or(e->text, None)
                if gt != None:
                    # array/struct global decays to the address ($name), no load
                    if gt->kind == TY_ARRAY or self->is_agg(gt) or self->is_valist(gt):
                        tg: i32 = self->tmp()
                        self->out->printf("\t%%t%d =l copy $%s\n", tg, e->text)
                        return tg
                    addr: i32 = self->emit_addr(e)
                    t7: i32 = self->tmp()
                    self->out->printf("\t%%t%d =%c %s %%t%d\n", t7, self->cls_of(gt), self->load_op(gt), addr)
                    return t7
                # enum constant -> integer value
                ev: i64 = 0
                if self->enum_lookup(e->text, &ev):
                    t8e: i32 = self->tmp()
                    self->out->printf("\t%%t%d =w copy %lld\n", t8e, ev)
                    return t8e
                # stderr/stdout/stdin: libc FILE* globals -> LOAD the pointer
                # (the value is the FILE*; passing the address $stderr would give a FILE**)
                if e->text in {"stderr", "stdout", "stdin"}:
                    tio: i32 = self->tmp()
                    self->out->printf("\t%%t%d =l loadl $%s\n", tio, e->text)
                    return tio
                # unknown symbol: literal name = ADDRESS (class l) —
                # covers function that decays to pointer (int (*f)() = a_f)
                t8: i32 = self->tmp()
                self->out->printf("\t%%t%d =l copy $%s\n", t8, e->text)
                return t8
            case EX_CAST:
                return self->emit_cast(e)
            case EX_UNARY:
                return self->emit_unary(e)
            case EX_BINARY:
                return self->emit_binary(e)
            case EX_CALL:
                return self->emit_call(e)
            case EX_INDEX:
                addr2: i32 = self->emit_addr(e)
                et: *Type = self->qtype_of(e)
                # aggregate element (arr[i] of structs / matrix row):
                # aggregate rvalue = address
                if self->is_agg(et) or (et != None and et->kind == TY_ARRAY):
                    return addr2
                t9: i32 = self->tmp()
                self->out->printf("\t%%t%d =%c %s %%t%d\n", t9, self->cls_of(et), self->load_op(et), addr2)
                return t9
            case EX_FIELD:
                # bitfield: extract from the unit (shift/mask)
                bft: *Type = None
                bo = 0; bw = -1
                if self->bf_lookup(e, ref bft, ref bo, ref bw):
                    ba: i32 = self->emit_addr(e)
                    return self->emit_bf_load(ba, bft, bo, bw)
                faddr: i32 = self->emit_addr(e)
                ft: *Type = self->qtype_of(e)
                # array/struct field decays to the address (aggregate rvalue);
                # otherwise load
                if ft != None and ft->kind == TY_ARRAY:
                    return faddr
                if self->is_agg(ft):
                    return faddr
                tf: i32 = self->tmp()
                self->out->printf("\t%%t%d =%c %s %%t%d\n", tf, self->cls_of(ft), self->load_op(ft), faddr)
                return tf
            case EX_TERNARY:
                return self->emit_ternary(e)
            case EX_INCDEC:
                return self->emit_incdec(e)
            case EX_ASSIGN:
                return self->emit_store_to(e->lhs, e->op, e->rhs)
            case EX_COMMA:
                self->emit_rvalue(e->lhs)   # evaluate and discard
                return self->emit_rvalue(e->rhs)
            case EX_GENERIC:
                # compile-time selection: emits ONLY the chosen branch
                return self->emit_rvalue(self->gen_select(e))
            case EX_STMTEXPR:
                # ({...}) becomes flow: the statements execute HERE in the CFG (correct
                # even inside a ternary/&&/|| branch), and the value is the last expression.
                # The VALUE expr is still inside the braces' scope, so the block's
                # bindings are only popped after it is emitted.
                semark: i32 = self->binds.len
                if e->xblock != None:
                    self->emit_block_body(e->xblock)
                seres: i32
                if e->lhs != None:
                    seres = self->emit_rvalue(e->lhs)
                else:
                    seres = self->tmp()
                    self->out->printf("\t%%t%d =w copy 0\n", seres)
                self->binds.len = semark
                return seres
            case EX_VAARG:
                apv: i32 = self->emit_rvalue(e->lhs)   # va_list address
                vcls: char = self->cls_of(e->cast_type)
                tv: i32 = self->tmp()
                self->out->printf("\t%%t%d =%c vaarg %%t%d\n", tv, vcls, apv)
                return tv
            case EX_COMPOUND:
                slot: i32 = self->emit_compound(e)
                ty: *Type = e->cast_type
                # struct/array: the value is the address; scalar: load
                if ty != None and (ty->kind == TY_ARRAY or (ty->kind == TY_NAME and self->structs.get_or(ty->name, None) != None)):
                    return slot
                tc: i32 = self->tmp()
                self->out->printf("\t%%t%d =%c %s %%t%d\n", tc, self->cls_of(ty), self->load_op(ty), slot)
                return tc
            case _:
                fatal_at(self->file, e->pos, "qbe backend: expression not supported in this phase (F1: floats/struct/initlist pending)")
        return 0

    # ++x / x++ : addr=lval; old=load; new=old±step; store new; returns
    # old (post) or new (pre). step = sizeof(*p) for pointer, else 1.
    private def emit_incdec(self: *Qb, e: *Expr) -> i32:
        ty: *Type = self->qtype_of(e->lhs)
        cls: char = self->cls_of(ty)
        addr: i32 = self->emit_addr(e->lhs)
        old: i32 = self->tmp()
        self->out->printf("\t%%t%d =%c %s %%t%d\n", old, cls, self->load_op(ty), addr)
        opn: const *char = "add" if e->op == TK_PLUS else "sub"
        nw: i32 = self->tmp()
        if cls == 's' or cls == 'd':
            # step 1.0 in the float class
            self->out->printf("\t%%t%d =%c %s %%t%d, %c_1\n", nw, cls, opn, old, cls)
        else:
            step = 1
            if ty != None and ty->kind == TY_PTR:
                step = self->size_of(ty->inner)
            self->out->printf("\t%%t%d =%c %s %%t%d, %d\n", nw, cls, opn, old, step)
        self->out->printf("\t%s %%t%d, %%t%d\n", self->store_op(ty), nw, addr)
        return old if e->incdec_post else nw

    private def charval(self: *Qb, lex: const *char) -> i32:
        # lex = 'x' with quotes; handles escapes (includes octal \NNN and hex \xNN)
        # wide/unicode prefix (L'x', u'x', U'x'): skip it (value = ASCII codepoint)
        if lex[0] in {'L', 'u', 'U'}:
            lex += 1
        if lex[1] != '\\':
            return i32(lex[1])
        c: char = lex[2]
        match c:
            case 'n':
                return 10
            case 't':
                return 9
            case 'r':
                return 13
            case 'b':
                return 8
            case 'f':
                return 12
            case 'v':
                return 11
            case 'a':
                return 7
            case '\\':
                return 92
            case '\'':
                return 39
            case '"':
                return 34
            case '?':
                return 63
            case 'x':
                v = 0
                j: usize = 3
                while True:
                    h: char = lex[j]
                    d = -1
                    if h >= '0' and h <= '9':
                        d = i32(h - '0')
                    elif h >= 'a' and h <= 'f':
                        d = i32(h - 'a') + 10
                    elif h >= 'A' and h <= 'F':
                        d = i32(h - 'A') + 10
                    if d < 0:
                        break
                    v = v * 16 + d
                    j += 1
                return v
            case _:
                if c >= '0' and c <= '7':
                    ov = 0
                    k: usize = 1
                    od3: i32 = 0
                    while od3 < 3 and lex[k + 1] >= '0' and lex[k + 1] <= '7':
                        ov = ov * 8 + i32(lex[k + 1] - '0')
                        od3 += 1
                        k += 1
                    return ov
                return i32(c)

    private def emit_cast(self: *Qb, e: *Expr) -> i32:
        # cast to struct type ((struct S)expr): reinterpretation — the rvalue of
        # an aggregate is the address, which stays unchanged
        if self->is_agg(e->cast_type):
            return self->emit_rvalue(e->lhs)
        v: i32 = self->emit_rvalue(e->lhs)
        dcls: char = self->cls_of(e->cast_type)
        scls: char = self->ecls(e->lhs)
        # extend/truncate int, int<->float and float<->float conversions
        r: i32 = self->emit_coerce(v, scls, dcls)
        # cast to SUB-WORD integer ((int8_t)x, (unsigned short)x): truncates to
        # the size and re-extends (C conversion semantics)
        if dcls == 'w' and e->cast_type != None and e->cast_type->kind == TY_NAME:
            csz: i32 = self->size_of(e->cast_type)
            if csz == 1 or csz == 2:
                xop: const *char
                if csz == 1:
                    xop = "extsb" if self->is_signed(e->cast_type) else "extub"
                else:
                    xop = "extsh" if self->is_signed(e->cast_type) else "extuh"
                tx: i32 = self->tmp()
                self->out->printf("\t%%t%d =w %s %%t%d\n", tx, xop, r)
                return tx
        return r

    private def emit_unary(self: *Qb, e: *Expr) -> i32:
        match e->op:
            case TK_STAR:
                addr: i32 = self->emit_rvalue(e->lhs)
                et: *Type = self->qtype_of(e)
                # deref of a function pointer is a function designator: decays
                # back to the pointer itself (there is no value to load)
                if et != None and et->kind == TY_FUNC:
                    return addr
                # deref whose result is an AGGREGATE (*ptr_struct): rvalue of
                # an aggregate = address — the pointer itself
                if self->is_agg(et) or (et != None and et->kind == TY_ARRAY):
                    return addr
                t: i32 = self->tmp()
                self->out->printf("\t%%t%d =%c %s %%t%d\n", t, self->cls_of(et), self->load_op(et), addr)
                return t
            case TK_AMP:
                return self->emit_addr(e->lhs)
            case TK_MINUS:
                v: i32 = self->emit_rvalue(e->lhs)
                c: char = self->ecls(e->lhs)
                t2: i32 = self->tmp()
                self->out->printf("\t%%t%d =%c neg %%t%d\n", t2, c, v)
                return t2
            case TK_TILDE:
                v2: i32 = self->emit_rvalue(e->lhs)
                c2: char = self->ecls(e->lhs)
                one: i32 = self->tmp()
                self->out->printf("\t%%t%d =%c copy -1\n", one, c2)
                t3: i32 = self->tmp()
                self->out->printf("\t%%t%d =%c xor %%t%d, %%t%d\n", t3, c2, v2, one)
                return t3
            case TK_NOT:
                # !x compares to 0 IN THE CLASS of the operand (ceqw on u64 would ignore
                # the high 32 bits — while (!b) with a 64-bit mask)
                v3: i32 = self->emit_rvalue(e->lhs)
                nc: char = self->ecls(e->lhs)
                t4: i32 = self->tmp()
                if nc == 'l':
                    self->out->printf("\t%%t%d =w ceql %%t%d, 0\n", t4, v3)
                elif nc == 'd':
                    self->out->printf("\t%%t%d =w ceqd %%t%d, d_0\n", t4, v3)
                elif nc == 's':
                    self->out->printf("\t%%t%d =w ceqs %%t%d, s_0\n", t4, v3)
                else:
                    self->out->printf("\t%%t%d =w ceqw %%t%d, 0\n", t4, v3)
                return t4
            case TK_PLUS:
                return self->emit_rvalue(e->lhs)
            case _:
                fatal_at(self->file, e->pos, "qbe backend: unsupported unary operator")
        return 0

    private def binop_name(self: *Qb, op: i32, cls: char, sgn: bool) -> const *char:
        match op:
            case TK_PLUS:
                return "add"
            case TK_MINUS:
                return "sub"
            case TK_STAR:
                return "mul"
            case TK_SLASH:
                return "div" if sgn else "udiv"
            case TK_PERCENT:
                return "rem" if sgn else "urem"
            case TK_AMP:
                return "and"
            case TK_PIPE:
                return "or"
            case TK_CARET:
                return "xor"
            case TK_SHL:
                return "shl"
            case TK_SHR:
                return "sar" if sgn else "shr"
            case _:
                return None

    # comparison: prefix c + (s/u)? + cmp + class
    private def cmp_name(self: *Qb, op: i32, cls: char, sgn: bool) -> const *char:
        # float: no sign prefix (cltd/cled/cgtd/cged/ceqd/cned)
        if cls == 's' or cls == 'd':
            match op:
                case TK_EQ:
                    return arena_qcmp("ceq", cls)
                case TK_NE:
                    return arena_qcmp("cne", cls)
                case TK_LT:
                    return arena_qcmp("clt", cls)
                case TK_LE:
                    return arena_qcmp("cle", cls)
                case TK_GT:
                    return arena_qcmp("cgt", cls)
                case TK_GE:
                    return arena_qcmp("cge", cls)
                case _:
                    return None
        match op:
            case TK_EQ:
                return arena_qcmp("ceq", cls)
            case TK_NE:
                return arena_qcmp("cne", cls)
            case TK_LT:
                return arena_qcmp("cslt" if sgn else "cult", cls)
            case TK_LE:
                return arena_qcmp("csle" if sgn else "cule", cls)
            case TK_GT:
                return arena_qcmp("csgt" if sgn else "cugt", cls)
            case TK_GE:
                return arena_qcmp("csge" if sgn else "cuge", cls)
            case _:
                return None

    # POINTER arithmetic (+/-): scales the integer side by the element
    # size; ptr-ptr divides by the width. Returns -1 if not applicable.
    private def try_ptr_arith(self: *Qb, op: i32, l: i32, lt: *Type, lcls: char, r: i32, rt: *Type, rcls: char) -> i32:
        if op != TK_PLUS and op != TK_MINUS:
            return -1
        lp: bool = lt != None and (lt->kind == TY_PTR or lt->kind == TY_ARRAY)
        rp: bool = rt != None and (rt->kind == TY_PTR or rt->kind == TY_ARRAY)
        if lp and rp:
            if op != TK_MINUS:
                return -1
            esz0: i32 = self->size_of(lt->inner)
            d: i32 = self->tmp()
            self->out->printf("\t%%t%d =l sub %%t%d, %%t%d\n", d, l, r)
            if esz0 > 1:
                q: i32 = self->tmp()
                self->out->printf("\t%%t%d =l div %%t%d, %d\n", q, d, esz0)
                return q
            return d
        if not lp and not rp:
            return -1
        pv: i32 = l if lp else r
        iv: i32 = r if lp else l
        icl: char = rcls if lp else lcls
        esz: i32 = self->size_of(lt->inner if lp else rt->inner)
        if op == TK_MINUS and rp:
            return -1   # int - ptr: invalid in C
        iv = self->emit_coerce(iv, icl, 'l')
        if esz != 1:
            sc: i32 = self->tmp()
            self->out->printf("\t%%t%d =l mul %%t%d, %d\n", sc, iv, esz)
            iv = sc
        res: i32 = self->tmp()
        self->out->printf("\t%%t%d =l %s %%t%d, %%t%d\n", res, "add" if op == TK_PLUS else "sub", pv, iv)
        return res

    # integer literal whose value fits in 32 bits (<= 0xffffffff), e.g. the
    # `unsigned int` 0xffffffff. (ecls classifies it 'l' to zero-extend when
    # widening, but in a comparison with a 32-bit value it should stay 32-bit.)
    private def is_u32_lit(self: *Qb, e: *Expr) -> bool:
        if e == None or e->kind != EX_NUMBER or is_float_lit(e->text):
            return False
        s: const *char = e->text
        while *s != '\0':
            if *s == 'l' or *s == 'L' or *s == 'u' or *s == 'U':
                return False   # explicit suffix: respects the requested width
            s += 1
        return strtoull(e->text, None, 0) <= 0xffffffff

    private def emit_binary(self: *Qb, e: *Expr) -> i32:
        op: i32 = e->op
        # short-circuit for and/or
        if op == TK_AND or op == TK_OR:
            return self->emit_logical(e)
        l: i32 = self->emit_rvalue(e->lhs)
        lcls: char = self->ecls(e->lhs)
        r: i32 = self->emit_rvalue(e->rhs)
        rcls: char = self->ecls(e->rhs)
        # pointer ± integer / pointer - pointer: with element SCALING
        pa: i32 = self->try_ptr_arith(op, l, self->qtype_of(e->lhs), lcls, r, self->qtype_of(e->rhs), rcls)
        if pa >= 0:
            return pa
        is_cmp: bool = op in {TK_EQ, TK_NE, TK_LT, TK_LE, TK_GT, TK_GE}
        is_shift: bool = op == TK_SHL or op == TK_SHR
        # promotes both operands to a common class (float beats int, l beats w);
        # shift preserves the lhs class and keeps the count as-is
        cls: char
        if is_shift:
            cls = lcls
        else:
            cls = qpromote(lcls, rcls)
            # comparison of a 32-bit value with a literal that fits in 32 bits:
            # compares in 'w' (C: int vs unsigned int -> 32 bits, raw bits), without
            # promoting to 'l' or sign-extending the 32-bit operand.
            if is_cmp and cls == 'l' and ((lcls == 'w' and self->is_u32_lit(e->rhs)) or (rcls == 'w' and self->is_u32_lit(e->lhs))):
                cls = 'w'
            l = self->emit_coerce(l, lcls, cls)
            r = self->emit_coerce(r, rcls, cls)
        sgn: bool = self->op_signed(e->lhs) and self->op_signed(e->rhs)
        t: i32 = self->tmp()
        if is_cmp:
            self->out->printf("\t%%t%d =w %s %%t%d, %%t%d\n", t, self->cmp_name(op, cls, sgn), l, r)
        else:
            self->out->printf("\t%%t%d =%c %s %%t%d, %%t%d\n", t, cls, self->binop_name(op, cls, sgn), l, r)
        return t

    # branch condition: rvalue normalized to 'w' (jnz requires word) —
    # pointer/long/float become compare != 0
    private def emit_cond(self: *Qb, e: *Expr) -> i32:
        v: i32 = self->emit_rvalue(e)
        c: char = self->ecls(e)
        if c == 'w':
            return v
        t: i32 = self->tmp()
        if c == 'l':
            self->out->printf("\t%%t%d =w cnel %%t%d, 0\n", t, v)
        elif c == 'd':
            self->out->printf("\t%%t%d =w cned %%t%d, d_0\n", t, v)
        else:
            self->out->printf("\t%%t%d =w cnes %%t%d, s_0\n", t, v)
        return t

    # emits an `alloc` in the PROLOGUE (@start block), not inline. Crucial: an
    # alloc inside a loop is re-executed every iteration (it's alloca in
    # QBE) and leaks the stack — ternary/&&/|| in a loop overflowed the stack.
    private def emit_slot(self: *Qb, res: i32, align: i32, bytes: i32):
        dst: *StrBuf = self->slots if self->slots != None else self->out
        dst->printf("\t%%r%d =l alloc%d %d\n", res, align, bytes)

    private def emit_logical(self: *Qb, e: *Expr) -> i32:
        # result in a temporary slot via blocks (short-circuit)
        res: i32 = self->tmp()
        self->emit_slot(res, 4, 4)
        l: i32 = self->emit_cond(e->lhs)
        rhs_lbl: i32 = self->lbl()
        end_lbl: i32 = self->lbl()
        set0: i32 = self->lbl()
        set1: i32 = self->lbl()
        if e->op == TK_AND:
            self->out->printf("\tjnz %%t%d, @l%d, @l%d\n", l, rhs_lbl, set0)
        else:
            self->out->printf("\tjnz %%t%d, @l%d, @l%d\n", l, set1, rhs_lbl)
        self->out->printf("@l%d\n", rhs_lbl)
        rb: i32 = self->emit_cond(e->rhs)
        self->out->printf("\tstorew %%t%d, %%r%d\n", rb, res)
        self->out->printf("\tjmp @l%d\n", end_lbl)
        self->out->printf("@l%d\n", set1)
        self->out->printf("\tstorew 1, %%r%d\n", res)
        self->out->printf("\tjmp @l%d\n", end_lbl)
        self->out->printf("@l%d\n", set0)
        self->out->printf("\tstorew 0, %%r%d\n", res)
        self->out->printf("\tjmp @l%d\n", end_lbl)
        self->out->printf("@l%d\n", end_lbl)
        t: i32 = self->tmp()
        self->out->printf("\t%%t%d =w loadw %%r%d\n", t, res)
        return t

    private def emit_ternary(self: *Qb, e: *Expr) -> i32:
        cls: char = qpromote(self->ecls(e->lhs), self->ecls(e->rhs))
        sop: const *char = "storew"
        lop: const *char = "loadw"
        if cls == 'l':
            sop = "storel"; lop = "loadl"
        elif cls == 'd':
            sop = "stored"; lop = "loadd"
        elif cls == 's':
            sop = "stores"; lop = "loads"
        res: i32 = self->tmp()
        self->emit_slot(res, 8, 8)
        c: i32 = self->emit_cond(e->cond)
        tl: i32 = self->lbl()
        fl: i32 = self->lbl()
        el: i32 = self->lbl()
        self->out->printf("\tjnz %%t%d, @l%d, @l%d\n", c, tl, fl)
        self->out->printf("@l%d\n", tl)
        tv: i32 = self->emit_rvalue(e->lhs)
        tv = self->emit_coerce(tv, self->ecls(e->lhs), cls)
        self->out->printf("\t%s %%t%d, %%r%d\n", sop, tv, res)
        self->out->printf("\tjmp @l%d\n", el)
        self->out->printf("@l%d\n", fl)
        fv: i32 = self->emit_rvalue(e->rhs)
        fv = self->emit_coerce(fv, self->ecls(e->rhs), cls)
        self->out->printf("\t%s %%t%d, %%r%d\n", sop, fv, res)
        self->out->printf("\tjmp @l%d\n", el)
        self->out->printf("@l%d\n", el)
        t: i32 = self->tmp()
        self->out->printf("\t%%t%d =%c %s %%r%d\n", t, cls, lop, res)
        return t

    private def emit_call(self: *Qb, e: *Expr) -> i32:
        fname: const *char = e->lhs->text if e->lhs->kind == EX_IDENT else None
        # sizeof: compile-time constant (size_t = class 'l')
        if fname != None and fname == "sizeof" and e->nargs == 1:
            arg: *Expr = e->args[0]
            st: *Type = arg->cast_type if arg->kind == EX_TYPEREF else self->qtype_of(arg)
            sz: i32 = self->size_of(st)
            rs: i32 = self->tmp()
            self->out->printf("\t%%t%d =l copy %d\n", rs, sz)
            return rs
        # __offsetof(T, a.b): layout constant (field path with '.')
        if fname != None and fname == "__offsetof" and e->nargs == 2:
            ot: *Type = e->args[0]->cast_type
            path: const *char = e->args[1]->text
            off = 0
            buf: char[128]
            while ot != None:
                od: *Decl = self->struct_of(ot)
                if od == None:
                    break
                dot: const *char = strchr(path, '.')
                n0: usize = usize(dot - path) if dot != None else strlen(path)
                if n0 >= 128:
                    break
                memcpy(buf, path, n0)
                buf[n0] = '\0'
                fty0: *Type = None
                off += self->field_offset(od, buf, ref fty0)
                if dot == None or fty0 == None:
                    break
                ot = fty0; path = dot + 1
            ro: i32 = self->tmp()
            self->out->printf("\t%%t%d =l copy %d\n", ro, off)
            return ro
        # varargs: va_start -> vastart; va_end -> no-op; va_copy -> 24B copy
        # (also the __builtin_* forms, which the system cpp leaves raw)
        if fname != None and (fname in {"va_start", "__builtin_va_start"}) and e->nargs >= 1:
            ap0: i32 = self->emit_rvalue(e->args[0])
            self->out->printf("\tvastart %%t%d\n", ap0)
            return ap0
        if fname != None and (fname in {"va_end", "__builtin_va_end"}):
            return self->tmp()   # no-op in QBE
        if fname != None and (fname in {"va_copy", "__builtin_va_copy"}) and e->nargs == 2:
            dstp: i32 = self->emit_rvalue(e->args[0])
            srcp: i32 = self->emit_rvalue(e->args[1])
            self->emit_struct_copy(dstp, srcp, 24)
            return dstp
        # indirect call (function pointer): when the callee is not a name,
        # or is the name of a VARIABLE (fn-ptr) instead of a function. Evaluates the
        # callee before the args; return class comes from the function type (TY_FUNC->ret).
        indirect: bool = fname == None
        if fname != None and self->funcs.get_or(fname, None) == None:
            if self->find_var(fname) != None or self->globals.get_or(fname, None) != None:
                indirect = True
        callee = 0
        rcls: char = 'w'
        f: *Func = None
        if indirect:
            callee = self->emit_rvalue(e->lhs)
            ct: *Type = self->qtype_of(e->lhs)
            if ct != None and ct->kind == TY_PTR and ct->inner != None:
                ct = ct->inner
            if ct != None and ct->kind == TY_FUNC:
                rcls = self->cls_of(ct->inner)
        else:
            f = self->funcs.get_or(fname, None)
            rcls = self->cls_of(f->ret) if f != None else 'w'
        # evaluates arguments
        argt: Vec<i32>
        argc: Vec<char>
        argt.init()
        argc.init()
        is_var: bool = f != None and f->is_varargs
        # number of fixed (named) parameters; in the variadic region there is no type
        nfixed: i32 = f->nparams if f != None else e->nargs
        i: i32
        for i in range(e->nargs):
            av: i32 = self->emit_rvalue(e->args[i])
            ac: char = self->ecls(e->args[i])
            if f != None and i < nfixed and (self->is_agg(f->params[i].type) or self->is_valist(f->params[i].type)):
                # struct by value / va_list: av is the address; no coercion
                ac = 'l'
            elif f != None and i < nfixed:
                # coerce to the declared parameter's class
                pc: char = self->cls_of(f->params[i].type)
                av = self->emit_coerce(av, ac, pc); ac = pc
            elif (is_var or (f == None and not indirect)) and ac == 's':
                # standard C promotion: float -> double in a variadic argument
                # OR in a call to a function without a prototype (e.g. printf from <stdio.h>)
                av = self->emit_coerce(av, 's', 'd'); ac = 'd'
            argt.push(av)
            argc.push(ac)
        # aggregate return (struct by value): =:Name instead of =class
        ragg: bool = not indirect and f != None and self->is_agg(f->ret)
        rt: i32 = self->tmp()
        if ragg:
            self->out->printf("\t%%t%d =:%s call $%s(", rt, f->ret->name, fname)
        elif indirect:
            self->out->printf("\t%%t%d =%c call %%t%d(", rt, rcls, callee)
        else:
            self->out->printf("\t%%t%d =%c call $%s(", rt, rcls, fname)
        # QBE requires the "..." marker after the fixed args in a variadic call
        # (it's what makes the generator set %al = number of SSE regs for the SysV ABI).
        wrote = 0
        # without a prototype (indirect call via fn-ptr OR a direct call to an
        # undeclared function, e.g. printf from <stdio.h>) we don't know which args are
        # fixed. We mark EVERYTHING as variadic with a leading "...": the SysV ABI
        # requires %al = number of SSE regs used, and with the "..." at the start QBE counts
        # all SSE args (needed for `printf("%f", x)`). Harmless for
        # non-variadic functions (which ignore %al).
        unknown_proto: bool = indirect or f == None
        if unknown_proto:
            self->out->puts("...")
            wrote += 1
        for i in range(e->nargs):
            if is_var and i == nfixed:
                if wrote != 0:
                    self->out->puts(", ")
                self->out->puts("...")
                wrote += 1
            if wrote != 0:
                self->out->puts(", ")
            # arg struct by value: :Name <address>; va_list: l <address>
            at: *Type = self->qtype_of(e->args[i])
            if self->is_agg(at):
                self->out->printf(":%s %%t%d", at->name, argt.data[i])
            elif self->is_valist(at):
                self->out->printf("l %%t%d", argt.data[i])
            else:
                self->out->printf("%c %%t%d", argc.data[i], argt.data[i])
            wrote += 1
        if is_var and e->nargs <= nfixed:
            if wrote != 0:
                self->out->puts(", ")
            self->out->puts("...")
        self->out->puts(")\n")
        argt.deinit()
        argc.deinit()
        return rt

    # ---------- statements ----------
    # emits the bodies of the defers from defers.len-1 down to `mark` (LIFO
    # order). Does not pop: the caller repositions defers.len (end of block)
    # or is at an exit (return/break/continue) where the rest of the block
    # is dead.
    private def emit_defers_downto(self: *Qb, mark: i32):
        i: i32
        for i in range(self->defers.len - 1, mark - 1, -1):
            self->emit_block(self->defers.data[i]->body)

    # statements + end-of-block defers WITHOUT closing the lexical scope — the
    # caller controls binds (emit_block pops; statement-expressions pop only
    # after emitting their value expression, which sees the block's names)
    private def emit_block_body(self: *Qb, b: *Block):
        mark: i32 = self->defers.len
        i: i32
        for i in range(b->n):
            self->emit_stmt(b->stmts[i])
        # end of block: run the defers registered in it (LIFO), unless the
        # last statement already exited (return/break/continue emitted them)
        exited: bool = b->n > 0 and stmt_exits_q(b->stmts[b->n - 1])
        if not exited:
            self->emit_defers_downto(mark)
        self->defers.len = mark

    private def emit_block(self: *Qb, b: *Block):
        bmark: i32 = self->binds.len   # lexical scope: bindings die with the block
        self->emit_block_body(b)
        self->binds.len = bmark        # allocas stay valid; only the NAMES go out of scope

    private def emit_stmt(self: *Qb, s: *Stmt):
        match s->kind:
            case ST_VAR:
                self->bind_decl(s)   # the name is visible from HERE to block end
                v: *QVar = self->find_var(s->name)
                if v != None and not v->is_static and self->is_vla_type(s->type):
                    # VLA C99: allocate on the stack with runtime size (n * sizeof(elem))
                    # at the declaration point — the slot becomes that address.
                    elem: *Type = s->type->inner
                    esz: i32 = self->size_of(elem)
                    nt: i32 = self->emit_rvalue(s->type->arr_len)
                    ntl: i32 = self->emit_coerce(nt, self->ecls(s->type->arr_len), 'l')
                    szt: i32 = self->tmp()
                    self->out->printf("\t%%t%d =l mul %%t%d, %d\n", szt, ntl, esz)
                    ea: i32 = self->type_align(elem)
                    qa: i32 = 16 if ea > 8 else (8 if ea > 4 else 4)
                    self->out->printf("\t%%t%d =l alloc%d %%t%d\n", v->slot, qa, szt)
                elif s->init != None and v != None and not v->is_static:
                    # static local: init is unique (in the data), not at runtime
                    self->emit_var_init(v, s->init)
            case ST_ASSIGN:
                self->emit_assign(s)
            case ST_EXPR:
                self->emit_rvalue(s->expr)
            case ST_RETURN:
                if s->expr != None:
                    val2: i32 = self->emit_rvalue(s->expr)
                    # aggregate return: val2 is the struct's ADDRESS (the ABI copies)
                    if not self->cur_ret_agg and self->cur_ret_cls != 0:
                        val2 = self->emit_coerce(val2, self->ecls(s->expr), self->cur_ret_cls)
                    # the value is evaluated BEFORE the defers (already in temp val2)
                    self->emit_defers_downto(0)
                    self->out->printf("\tret %%t%d\n", val2)
                else:
                    self->emit_defers_downto(0)
                    self->out->puts("\tret\n")
                # dead block after ret needs a label
                dead: i32 = self->lbl()
                self->out->printf("@l%d\n", dead)
            case ST_IF:
                self->emit_if(s)
            case ST_WHILE:
                self->emit_while(s)
            case ST_DO:
                self->emit_do(s)
            case ST_FOR:
                self->emit_for(s)
            case ST_CFOR:
                self->emit_cfor(s)
            case ST_BREAK:
                self->emit_defers_downto(self->brk_dm[self->nbrk - 1])
                self->out->printf("\tjmp @l%d\n", self->brk[self->nbrk - 1])
                d: i32 = self->lbl()
                self->out->printf("@l%d\n", d)
            case ST_CONTINUE:
                self->emit_defers_downto(self->cont_dm[self->ncont - 1])
                self->out->printf("\tjmp @l%d\n", self->cont[self->ncont - 1])
                d2: i32 = self->lbl()
                self->out->printf("@l%d\n", d2)
            case ST_LABEL:
                # ends the previous block (fallthrough) and opens the label's block.
                # prefix u_ avoids collision with the generated @l<n> labels.
                self->out->printf("\tjmp @u_%s\n", s->label)
                self->out->printf("@u_%s\n", s->label)
            case ST_GOTO:
                self->out->printf("\tjmp @u_%s\n", s->label)
                dg: i32 = self->lbl()
                self->out->printf("@l%d\n", dg)
            case ST_SWITCH:
                self->emit_switch(s)
            case ST_BLOCK:
                # bare block (C front end): QBE has flat per-function vars, so
                # the scope is emitted inline (shadowing not supported here)
                self->emit_block(s->body)
            case ST_PASS, ST_GLOBAL, ST_NONLOCAL, ST_CPROTO:
                return   # no-ops: nothing to emit (global/nonlocal are sema markers;
                         #   a block-scope proto only matters for the C backend)
            case ST_CASE:
                # case label (may be nested in a loop — Duff's device);
                # the label was assigned by the owning switch's dispatch
                self->out->printf("\tjmp @l%d\n", s->case_lbl)
                self->out->printf("@l%d\n", s->case_lbl)
            case ST_MATCH:
                self->emit_match(s)
            case ST_WITH:
                # initializes the hidden pointer (evaluated once) and emits the body
                self->bind_decl(s)
                wv: *QVar = self->find_var(s->name)
                if wv != None and s->init != None:
                    self->emit_var_init(wv, s->init)
                self->emit_block(s->body)
            case ST_DEFER:
                # registers; runs in LIFO order at exit of the block/loop/function
                self->defers.push(s)
            case _:
                fatal_at(self->file, s->pos, "qbe backend: statement not supported in this phase")

    private def emit_assign(self: *Qb, s: *Stmt):
        self->emit_store_to(s->lhs, s->op, s->rhs)

    # core shared by ST_ASSIGN (statement) and EX_ASSIGN (expression):
    # evaluates `lhs op= rhs`, stores it and returns the stored value.
    # is `e` an EX_FIELD naming a BITFIELD? writes unit type/bit_off/
    # width and returns True
    private def bf_lookup(self: *Qb, e: *Expr, ref out_ft: *Type, ref out_bo: i32, ref out_bw: i32) -> bool:
        if e == None or e->kind != EX_FIELD:
            return False
        d: *Decl = self->struct_of(self->qtype_of(e->lhs))
        if d == None:
            return False
        out_ft = None
        self->slayout(d, e->field, ref out_ft, ref out_bo, ref out_bw)
        return out_ft != None and out_bw > 0

    # reads a bitfield: loads the unit and extracts [bo, bo+bw) with shift/mask
    # (arithmetic for signed type)
    private def emit_bf_load(self: *Qb, addr: i32, ft: *Type, bo: i32, bw: i32) -> i32:
        usz: i32 = self->size_of(ft)
        ucl: char = 'l' if usz == 8 else 'w'
        bits: i32 = usz * 8
        lop: const *char = "loadl"
        if usz == 1:
            lop = "loadub"
        elif usz == 2:
            lop = "loaduh"
        elif usz == 4:
            lop = "loadw"
        u: i32 = self->tmp()
        self->out->printf("\t%%t%d =%c %s %%t%d\n", u, ucl, lop, addr)
        if self->is_signed(ft):
            a: i32 = self->tmp()
            self->out->printf("\t%%t%d =%c shl %%t%d, %d\n", a, ucl, u, bits - bo - bw)
            b: i32 = self->tmp()
            self->out->printf("\t%%t%d =%c sar %%t%d, %d\n", b, ucl, a, bits - bw)
            return b
        s: i32 = u
        if bo > 0:
            s = self->tmp()
            self->out->printf("\t%%t%d =%c shr %%t%d, %d\n", s, ucl, u, bo)
        if bw < bits:
            m: i32 = self->tmp()
            self->out->printf("\t%%t%d =%c and %%t%d, %lld\n", m, ucl, s, (i64(1) << bw) - 1)
            return m
        return s

    # writes a bitfield (RMW): clears [bo, bo+bw) in the unit and ORs the value
    private def emit_bf_store(self: *Qb, addr: i32, ft: *Type, bo: i32, bw: i32, val: i32, vcls: char):
        usz: i32 = self->size_of(ft)
        ucl: char = 'l' if usz == 8 else 'w'
        mask: i64 = (i64(1) << bw) - 1
        v: i32 = self->emit_coerce(val, vcls, ucl)
        m1: i32 = self->tmp()
        self->out->printf("\t%%t%d =%c and %%t%d, %lld\n", m1, ucl, v, mask)
        m2: i32 = m1
        if bo > 0:
            m2 = self->tmp()
            self->out->printf("\t%%t%d =%c shl %%t%d, %d\n", m2, ucl, m1, bo)
        lop: const *char = "loadl"
        sop: const *char = "storel"
        if usz == 1:
            lop = "loadub"; sop = "storeb"
        elif usz == 2:
            lop = "loaduh"; sop = "storeh"
        elif usz == 4:
            lop = "loadw"; sop = "storew"
        u: i32 = self->tmp()
        self->out->printf("\t%%t%d =%c %s %%t%d\n", u, ucl, lop, addr)
        c1: i32 = self->tmp()
        keep: i64 = ~(mask << bo)
        if usz < 8:
            keep = keep & 0xFFFFFFFF
        self->out->printf("\t%%t%d =%c and %%t%d, %lld\n", c1, ucl, u, keep)
        u2: i32 = self->tmp()
        self->out->printf("\t%%t%d =%c or %%t%d, %%t%d\n", u2, ucl, c1, m2)
        self->out->printf("\t%s %%t%d, %%t%d\n", sop, u2, addr)

    private def emit_store_to(self: *Qb, lhs: *Expr, op: i32, rhs: *Expr) -> i32:
        lt: *Type = self->qtype_of(lhs)
        # AGGREGATE assignment (s1 = s2, arr[i] = s, p->field = s): byte copy
        # (rvalue of an aggregate = address)
        if op == TK_ASSIGN and self->is_agg(lt) and not self->is_valist(lt):
            dst: i32 = self->emit_addr(lhs)
            src0: i32 = self->emit_rvalue(rhs)
            self->emit_struct_copy(dst, src0, self->size_of(lt))
            return src0
        scls: char = self->store_cls(lt)
        val: i32
        if op == TK_ASSIGN:
            val = self->emit_rvalue(rhs)
            val = self->emit_coerce(val, self->ecls(rhs), scls)
        else:
            cur: i32 = self->emit_rvalue(lhs)
            r: i32 = self->emit_rvalue(rhs)
            bop: i32 = self->compound_base(op)
            # p += n / p -= n: pointer arithmetic with scaling
            pa: i32 = self->try_ptr_arith(bop, cur, self->qtype_of(lhs), self->ecls(lhs), r, self->qtype_of(rhs), self->ecls(rhs))
            if pa >= 0:
                val = pa
            else:
                # a op= b  ==  a = a op b, with the op in the common promoted type (C:
                # e.g. float += double computes in double, then converts back to float)
                cls: char = qpromote(self->ecls(lhs), self->ecls(rhs))
                sgn: bool = self->is_signed(self->qtype_of(lhs))
                cur = self->emit_coerce(cur, self->ecls(lhs), cls)
                r = self->emit_coerce(r, self->ecls(rhs), cls); val = self->tmp()
                self->out->printf("\t%%t%d =%c %s %%t%d, %%t%d\n", val, cls, self->binop_name(bop, cls, sgn), cur, r)
                val = self->emit_coerce(val, cls, scls)
        # bitfield target: RMW on the unit (the rvalue of lhs above already decodes it)
        bft: *Type = None
        bo = 0; bw = -1
        if self->bf_lookup(lhs, ref bft, ref bo, ref bw):
            baddr: i32 = self->emit_addr(lhs)
            self->emit_bf_store(baddr, bft, bo, bw, val, scls)
            return val
        addr: i32 = self->emit_addr(lhs)
        self->out->printf("\t%s %%t%d, %%t%d\n", self->store_op(lt), val, addr)
        return val

    # initializes a local variable from its initializer (scalar,
    # string for char[], or a { } list of array/struct, recursively).
    private def emit_var_init(self: *Qb, v: *QVar, init: *Expr):
        ty: *Type = v->ty
        # char arr[] = "..."  -> copies the bytes to the slot
        if init->kind == EX_STRING and ty != None and ty->kind == TY_ARRAY:
            # wchar_t s[] = L"..." (4-byte element): decodes UTF-8 into
            # codepoints (4 bytes each). char[] = "...": copies bytes.
            if self->size_of(ty->inner) >= 4:
                self->emit_wstr_to_addr(v->slot, init->text)
            else:
                self->emit_str_to_addr(v->slot, init->text, v->nbytes if v->nbytes > 0 else self->size_of(ty))
            return
        # struct by value (e.g.: s = str_from(...)): rvalue is the ADDRESS of the
        # source struct; copies the bytes to the slot
        if self->is_agg(ty) and init->kind != EX_INITLIST:
            src: i32 = self->emit_rvalue(init)
            self->emit_struct_copy(v->slot, src, self->size_of(ty))
            return
        if init->kind != EX_INITLIST:
            val: i32 = self->emit_rvalue(init)
            val = self->emit_coerce(val, self->ecls(init), self->store_cls(ty))
            self->out->printf("\t%s %%t%d, %%t%d\n", self->store_op(ty), val, v->slot)
            return
        # aggregate (array/struct): zero everything, then fill
        self->emit_zero(v->slot, self->size_of(ty))
        self->emit_init_addr(v->slot, ty, init)

    # compound literal (type){...}: allocates an anonymous slot, zeroes it,
    # initializes it and returns the temp with the object's ADDRESS
    private def emit_compound(self: *Qb, e: *Expr) -> i32:
        ty: *Type = e->cast_type
        sz: i32 = self->size_of(ty)
        # (T[]){...}: array without a dimension — infers the size from the number of items
        if ty != None and ty->kind == TY_ARRAY and ty->arr_len == None:
            esz: i32 = self->size_of(ty->inner)
            if esz > 0 and e->nargs > 0:
                sz = e->nargs * esz
        a: i32 = self->type_align(ty)
        qa = 4
        if a > 8:
            qa = 16
        elif a > 4:
            qa = 8
        bytes: i32 = sz if sz > qa else qa
        slot: i32 = self->tmp()
        # the ALLOC goes in the prologue (otherwise it leaks in a loop); the
        # re-initialization (zero + init) stays inline, since the object is
        # recreated on each use
        adst: *StrBuf = self->slots if self->slots != None else self->out
        adst->printf("\t%%t%d =l alloc%d %d\n", slot, qa, bytes)
        self->emit_zero(slot, sz)
        self->emit_init_addr(slot, ty, e)
        return slot

    # zeroes `size` bytes starting from the address in temp `addr` (8/4/1-byte chunks)
    private def emit_zero(self: *Qb, addr: i32, size: i32):
        off = 0
        while off + 8 <= size:
            a: i32 = self->tmp()
            self->out->printf("\t%%t%d =l add %%t%d, %d\n", a, addr, off)
            self->out->printf("\tstorel 0, %%t%d\n", a)
            off += 8
        while off + 4 <= size:
            a4: i32 = self->tmp()
            self->out->printf("\t%%t%d =l add %%t%d, %d\n", a4, addr, off)
            self->out->printf("\tstorew 0, %%t%d\n", a4)
            off += 4
        while off + 1 <= size:
            a1: i32 = self->tmp()
            self->out->printf("\t%%t%d =l add %%t%d, %d\n", a1, addr, off)
            self->out->printf("\tstoreb 0, %%t%d\n", a1)
            off += 1

    # copies `size` bytes from src to dst (addresses in temps); 8/4/1-byte chunks
    private def emit_struct_copy(self: *Qb, dst: i32, src: i32, size: i32):
        off = 0
        while off + 8 <= size:
            sp: i32 = self->tmp()
            self->out->printf("\t%%t%d =l add %%t%d, %d\n", sp, src, off)
            ld: i32 = self->tmp()
            self->out->printf("\t%%t%d =l loadl %%t%d\n", ld, sp)
            dp: i32 = self->tmp()
            self->out->printf("\t%%t%d =l add %%t%d, %d\n", dp, dst, off)
            self->out->printf("\tstorel %%t%d, %%t%d\n", ld, dp)
            off += 8
        while off + 4 <= size:
            sp4: i32 = self->tmp()
            self->out->printf("\t%%t%d =l add %%t%d, %d\n", sp4, src, off)
            l4: i32 = self->tmp()
            self->out->printf("\t%%t%d =w loadw %%t%d\n", l4, sp4)
            dp4: i32 = self->tmp()
            self->out->printf("\t%%t%d =l add %%t%d, %d\n", dp4, dst, off)
            self->out->printf("\tstorew %%t%d, %%t%d\n", l4, dp4)
            off += 4
        while off + 1 <= size:
            sp1: i32 = self->tmp()
            self->out->printf("\t%%t%d =l add %%t%d, %d\n", sp1, src, off)
            l1: i32 = self->tmp()
            self->out->printf("\t%%t%d =w loadub %%t%d\n", l1, sp1)
            dp1: i32 = self->tmp()
            self->out->printf("\t%%t%d =l add %%t%d, %d\n", dp1, dst, off)
            self->out->printf("\tstoreb %%t%d, %%t%d\n", l1, dp1)
            off += 1

    # fills the value of `init` at address `addr` with type `ty` (recursive);
    # does NOT zero (the caller zeroes the top-level aggregate once).
    private def emit_init_addr(self: *Qb, addr: i32, ty: *Type, init: *Expr):
        one: *Expr = init
        ix = 0
        self->emit_fill(addr, ty, &one, 1, ref ix)

    # local mirror of data_fill: fills ONE value consuming exprs from the flat
    # stream (C brace elision); designators jump to the position and overrides
    # work by store order (the last one wins, as in C)
    private def emit_fill(self: *Qb, addr: i32, ty: *Type, items: **Expr, nitems: i32, ref idx: i32):
        if idx >= nitems or items[idx] == None:
            return
        sd: *Decl = None
        if ty != None and ty->kind == TY_NAME and ty->name != None:
            sd = self->structs.get_or(ty->name, None)
        aggr: bool = ty != None and (ty->kind == TY_ARRAY or sd != None)
        it: *Expr = items[idx]
        if it->kind == EX_INITLIST or (it->kind == EX_COMPOUND and aggr):
            idx += 1
            if aggr:
                j = 0
                self->emit_fill_body(addr, ty, sd, it->args, it->nargs, ref j)
                return
            if it->nargs > 0:   # scalar inside braces: { v }
                j2 = 0
                self->emit_fill(addr, ty, it->args, it->nargs, ref j2)
            return
        # char arr[N] = "..." (bytes; wide element = codepoints)
        if ty != None and ty->kind == TY_ARRAY and it->kind == EX_STRING:
            idx += 1
            if self->size_of(ty->inner) >= 4:
                self->emit_wstr_to_addr(addr, it->text)
            else:
                self->emit_str_to_addr(addr, it->text, self->size_of(ty))
            return
        if not aggr:
            idx += 1
            val: i32 = self->emit_rvalue(it)
            val = self->emit_coerce(val, self->ecls(it), self->store_cls(ty))
            self->out->printf("\t%s %%t%d, %%t%d\n", self->store_op(ty), val, addr)
            return
        # aggregate target with a struct-by-value (var, *ptr, field, cast,
        # call): copies the bytes (rvalue of an aggregate = address)
        if sd != None and self->is_agg(self->qtype_of(it)):
            idx += 1
            src: i32 = self->emit_rvalue(it)
            self->emit_struct_copy(addr, src, self->size_of(ty))
            return
        # aggregate without braces: consumes from the current stream (elision)
        self->emit_fill_body(addr, ty, sd, items, nitems, ref idx)

    # local aggregate body: array = positions (designator [i] jumps);
    # struct = fields in order (designator .f jumps); union = 1st member (or
    # the designated one, descending into an anonymous member)
    private def emit_fill_body(self: *Qb, addr: i32, ty: *Type, sd: *Decl, items: **Expr, nitems: i32, ref idx: i32):
        if ty != None and ty->kind == TY_ARRAY:
            elem: *Type = ty->inner
            esz: i32 = self->size_of(elem)
            count = -1
            if ty->arr_len != None:
                cok: bool = True
                cv: i64 = self->const_int(ty->arr_len, ref cok)
                if cok and cv >= 0:
                    count = i32(cv)
            pos = 0
            # a designator [i] jumps to any position (including backwards),
            # ignoring the count guard — only NON-designated elements
            # respect pos < count (avoids array overflow).
            while idx < nitems:
                prev: i32 = idx
                it: *Expr = items[idx]
                if it != None and it->kind == EX_DESIG and it->rhs != None:
                    dok: bool = True
                    pos = i32(self->const_int(it->rhs, ref dok))
                    fa: i32 = self->tmp()
                    self->out->printf("\t%%t%d =l add %%t%d, %d\n", fa, addr, pos * esz)
                    one: *Expr = it->lhs
                    j = 0
                    self->emit_fill(fa, elem, &one, 1, ref j)
                    idx += 1
                    pos += 1
                    continue
                if count >= 0 and pos >= count:
                    break   # non-designated element past the end: stop
                fa2: i32 = self->tmp()
                self->out->printf("\t%%t%d =l add %%t%d, %d\n", fa2, addr, pos * esz)
                self->emit_fill(fa2, elem, items, nitems, ref idx)
                pos += 1
                if idx == prev:   # nothing consumed (e.g. empty elem): avoids looping
                    break
            return
        if sd == None:
            return
        if sd->kind == DL_UNION:
            if sd->nfields == 0:
                return
            it0: *Expr = items[idx] if idx < nitems else None
            if it0 != None and it0->kind == EX_DESIG and it0->field != None:
                # direct member or inside an anonymous one
                for ui in range(sd->nfields):
                    if strcmp(sd->fields[ui].name, it0->field) == 0:
                        one0: *Expr = it0->lhs
                        idx += 1
                        j0 = 0
                        self->emit_fill(addr, sd->fields[ui].type, &one0, 1, ref j0)
                        return
                for ui in range(sd->nfields):
                    if sd->fields[ui].name[0] == '\0':
                        ad: *Decl = self->struct_of(sd->fields[ui].type)
                        sub: *Type = None
                        if ad != None:
                            self->field_offset(ad, it0->field, ref sub)
                        if sub != None:
                            self->emit_fill_body(addr, sd->fields[ui].type, ad, items, nitems, ref idx)
                            return
                return
            self->emit_fill(addr, sd->fields[0].type, items, nitems, ref idx)
            return
        fi = 0
        while idx < nitems:
            prev2: i32 = idx
            it2: *Expr = items[idx]
            if (it2 == None or it2->kind != EX_DESIG) and fi >= sd->nfields:
                break   # positional past the last field; a designator may go back
            if it2 != None and it2->kind == EX_DESIG and it2->field != None:
                k = -1
                for j2 in range(sd->nfields):
                    if strcmp(sd->fields[j2].name, it2->field) == 0:
                        k = j2
                        break
                if k < 0:
                    return   # unknown designator (anonymous member etc.)
                fi = k
                # designated BITFIELD field (.w = 1 in Rex): RMW on the unit
                if sd->fields[fi].bit_width >= 0:
                    dbft: *Type = None
                    dbo = 0; dbw = -1
                    duoff: i32 = self->slayout(sd, sd->fields[fi].name, ref dbft, ref dbo, ref dbw)
                    dfa: i32 = self->tmp()
                    self->out->printf("\t%%t%d =l add %%t%d, %d\n", dfa, addr, duoff)
                    dbv: i32 = self->emit_rvalue(it2->lhs)
                    self->emit_bf_store(dfa, dbft, dbo, dbw, dbv, self->ecls(it2->lhs))
                    idx += 1
                    fi += 1
                    continue
                fty0: *Type = None
                foff0: i32 = self->field_offset(sd, sd->fields[fi].name, ref fty0)
                fad: i32 = self->tmp()
                self->out->printf("\t%%t%d =l add %%t%d, %d\n", fad, addr, foff0)
                oned: *Expr = it2->lhs
                jd = 0
                self->emit_fill(fad, sd->fields[fi].type, &oned, 1, ref jd)
                idx += 1
                fi += 1
                continue
            # positional bitfield: unnamed doesn't consume an item; named writes
            # via RMW on the unit (the object was already zeroed by the caller)
            if sd->fields[fi].bit_width >= 0:
                if sd->fields[fi].name[0] == '\0':
                    fi += 1
                    continue
                bft: *Type = None
                bo = 0; bw = -1
                uoff: i32 = self->slayout(sd, sd->fields[fi].name, ref bft, ref bo, ref bw)
                bfa: i32 = self->tmp()
                self->out->printf("\t%%t%d =l add %%t%d, %d\n", bfa, addr, uoff)
                bv: i32 = self->emit_rvalue(items[idx])
                self->emit_bf_store(bfa, bft, bo, bw, bv, self->ecls(items[idx]))
                idx += 1
                fi += 1
                continue
            fty: *Type = None
            foff: i32 = self->field_offset(sd, sd->fields[fi].name, ref fty)
            fa3: i32 = self->tmp()
            self->out->printf("\t%%t%d =l add %%t%d, %d\n", fa3, addr, foff)
            self->emit_fill(fa3, sd->fields[fi].type, items, nitems, ref idx)
            fi += 1
            if idx == prev2:
                break

    # copies the bytes of string `lex` to the address in `addr`, limited to
    # `cap` bytes (including the nul if it fits). Decodes escapes (same logic
    # as cstr_bytes, but emitting storeb).
    private def emit_str_to_addr(self: *Qb, addr: i32, lex: const *char, cap: i32):
        off = 0
        i: usize = 1
        n: usize = strlen(lex)
        while i < n - 1 and off < cap:
            c: char = lex[i]
            b: i32
            if c == '\\':
                i += 1
                e: char = lex[i]
                match e:
                    case 'n':
                        b = 10
                    case 't':
                        b = 9
                    case 'r':
                        b = 13
                    case 'b':
                        b = 8
                    case 'f':
                        b = 12
                    case 'v':
                        b = 11
                    case 'a':
                        b = 7
                    case '\\':
                        b = 92
                    case '"':
                        b = 34
                    case '\'':
                        b = 39
                    case '?':
                        b = 63
                    case 'x':
                        b = 0
                        while i + 1 < n - 1 and is_hexc(lex[i + 1]):
                            b = b * 16 + hexc(lex[i + 1])
                            i += 1
                    case _:
                        if e >= '0' and e <= '7':
                            b = i32(e - '0')
                            od4: i32 = 1
                            while od4 < 3 and i + 1 < n - 1 and lex[i + 1] >= '0' and lex[i + 1] <= '7':
                                b = b * 8 + i32(lex[i + 1] - '0')
                                od4 += 1
                                i += 1
                        else:
                            b = i32(e)
            else:
                b = i32(c) & 0xFF
            a: i32 = self->tmp()
            self->out->printf("\t%%t%d =l add %%t%d, %d\n", a, addr, off)
            self->out->printf("\tstoreb %d, %%t%d\n", b, a)
            off += 1
            i += 1
        # nul terminator, if it fits
        if off < cap:
            az: i32 = self->tmp()
            self->out->printf("\t%%t%d =l add %%t%d, %d\n", az, addr, off)
            self->out->printf("\tstoreb 0, %%t%d\n", az)

    # wchar_t s[] = L"...": decode UTF-8 from the lexeme into codepoints (at compile
    # time) and store each one as a word (4 bytes) + codepoint 0 at the end.
    private def emit_wstr_to_addr(self: *Qb, addr: i32, lex: const *char):
        off = 0
        i: usize = lit_prefix_len(lex) + 1   # skip prefix (L/u/U) and the quote
        n: usize = strlen(lex)
        while i < n - 1:
            cp: u32 = 0
            c: char = lex[i]
            if c == '\\':
                i += 1
                e: char = lex[i]
                match e:
                    case 'n':
                        cp = 10
                        i += 1
                    case 't':
                        cp = 9
                        i += 1
                    case 'r':
                        cp = 13
                        i += 1
                    case '0':
                        cp = 0
                        i += 1
                    case '\\':
                        cp = 92
                        i += 1
                    case '"':
                        cp = 34
                        i += 1
                    case 'x':
                        cp = 0
                        i += 1
                        while i < n - 1 and is_hexc(lex[i]):
                            cp = cp * 16 + u32(hexc(lex[i]))
                            i += 1
                    case _:
                        cp = u32(u8(e))
                        i += 1
            else:
                b0: u8 = u8(c)
                if b0 < 0x80:
                    cp = u32(b0)
                    i += 1
                elif b0 < 0xE0:
                    cp = (u32(b0) & 0x1F) << 6 | (u32(u8(lex[i + 1])) & 0x3F)
                    i += 2
                elif b0 < 0xF0:
                    cp = (u32(b0) & 0xF) << 12 | (u32(u8(lex[i + 1])) & 0x3F) << 6 | (u32(u8(lex[i + 2])) & 0x3F)
                    i += 3
                else:
                    cp = (u32(b0) & 7) << 18 | (u32(u8(lex[i + 1])) & 0x3F) << 12 | (u32(u8(lex[i + 2])) & 0x3F) << 6 | (u32(u8(lex[i + 3])) & 0x3F)
                    i += 4
            a: i32 = self->tmp()
            self->out->printf("\t%%t%d =l add %%t%d, %d\n", a, addr, off)
            self->out->printf("\tstorew %u, %%t%d\n", cp, a)
            off += 4
        az: i32 = self->tmp()
        self->out->printf("\t%%t%d =l add %%t%d, %d\n", az, addr, off)
        self->out->printf("\tstorew 0, %%t%d\n", az)

    private def compound_base(self: *Qb, op: i32) -> i32:
        match op:
            case TK_PLUS_EQ:
                return TK_PLUS
            case TK_MINUS_EQ:
                return TK_MINUS
            case TK_STAR_EQ:
                return TK_STAR
            case TK_SLASH_EQ:
                return TK_SLASH
            case TK_PERCENT_EQ:
                return TK_PERCENT
            case TK_AMP_EQ:
                return TK_AMP
            case TK_PIPE_EQ:
                return TK_PIPE
            case TK_CARET_EQ:
                return TK_CARET
            case TK_SHL_EQ:
                return TK_SHL
            case TK_SHR_EQ:
                return TK_SHR
            case _:
                return TK_PLUS

    private def emit_if(self: *Qb, s: *Stmt):
        # folded at compile-time: emit only the live branch (no jumps)
        if s->if_sel != -1:
            if s->if_sel >= 0 and s->if_sel < s->nconds:
                self->emit_block(s->blocks[s->if_sel])
            elif s->if_sel == s->nconds:
                self->emit_block(s->else_block)
            return
        end: i32 = self->lbl()
        i: i32
        for i in range(s->nconds):
            c: i32 = self->emit_cond(s->conds[i])
            body: i32 = self->lbl()
            nxt: i32 = self->lbl()
            self->out->printf("\tjnz %%t%d, @l%d, @l%d\n", c, body, nxt)
            self->out->printf("@l%d\n", body)
            self->emit_block(s->blocks[i])
            self->out->printf("\tjmp @l%d\n", end)
            self->out->printf("@l%d\n", nxt)
        if s->else_block != None:
            self->emit_block(s->else_block)
        self->out->printf("\tjmp @l%d\n", end)
        self->out->printf("@l%d\n", end)

    private def emit_while(self: *Qb, s: *Stmt):
        cond: i32 = self->lbl()
        body: i32 = self->lbl()
        end: i32 = self->lbl()
        self->out->printf("\tjmp @l%d\n", cond)
        self->out->printf("@l%d\n", cond)
        c: i32 = self->emit_cond(s->cond)
        self->out->printf("\tjnz %%t%d, @l%d, @l%d\n", c, body, end)
        self->out->printf("@l%d\n", body)
        self->brk[self->nbrk] = end
        self->brk_dm[self->nbrk] = self->defers.len
        self->nbrk += 1
        self->cont[self->ncont] = cond
        self->cont_dm[self->ncont] = self->defers.len
        self->ncont += 1
        self->emit_block(s->body)
        self->nbrk -= 1
        self->ncont -= 1
        self->out->printf("\tjmp @l%d\n", cond)
        self->out->printf("@l%d\n", end)

    private def emit_do(self: *Qb, s: *Stmt):
        body: i32 = self->lbl()
        cond: i32 = self->lbl()
        end: i32 = self->lbl()
        self->out->printf("\tjmp @l%d\n", body)
        self->out->printf("@l%d\n", body)
        self->brk[self->nbrk] = end
        self->brk_dm[self->nbrk] = self->defers.len
        self->nbrk += 1
        self->cont[self->ncont] = cond
        self->cont_dm[self->ncont] = self->defers.len
        self->ncont += 1
        self->emit_block(s->body)
        self->nbrk -= 1
        self->ncont -= 1
        self->out->printf("@l%d\n", cond)
        c: i32 = self->emit_cond(s->cond)
        self->out->printf("\tjnz %%t%d, @l%d, @l%d\n", c, body, end)
        self->out->printf("@l%d\n", end)

    private def emit_for(self: *Qb, s: *Stmt):
        # counter is an already-declared variable (slot exists)
        v: *QVar = self->find_var(s->var)
        # init: i = from (or 0)
        if s->from != None:
            fv: i32 = self->emit_rvalue(s->from)
            fv = self->emit_coerce(fv, self->ecls(s->from), v->cls)
            self->out->printf("\t%s %%t%d, %%t%d\n", self->store_op(v->ty), fv, v->slot)
        else:
            z: i32 = self->tmp()
            self->out->printf("\t%%t%d =%c copy 0\n", z, v->cls)
            self->out->printf("\t%s %%t%d, %%t%d\n", self->store_op(v->ty), z, v->slot)
        cond: i32 = self->lbl()
        body: i32 = self->lbl()
        post: i32 = self->lbl()
        end: i32 = self->lbl()
        neg: bool = s->step != None and s->step->kind == EX_UNARY and s->step->op == TK_MINUS
        self->out->printf("\tjmp @l%d\n", cond)
        self->out->printf("@l%d\n", cond)
        iv: i32 = self->tmp()
        self->out->printf("\t%%t%d =%c %s %%t%d\n", iv, v->cls, self->load_op(v->ty), v->slot)
        tov: i32 = self->emit_rvalue(s->to)
        tov = self->emit_coerce(tov, self->ecls(s->to), v->cls)
        cc: i32 = self->tmp()
        cmp: const *char = arena_qcmp("csgt" if neg else "cslt", v->cls)
        self->out->printf("\t%%t%d =w %s %%t%d, %%t%d\n", cc, cmp, iv, tov)
        self->out->printf("\tjnz %%t%d, @l%d, @l%d\n", cc, body, end)
        self->out->printf("@l%d\n", body)
        self->brk[self->nbrk] = end
        self->brk_dm[self->nbrk] = self->defers.len
        self->nbrk += 1
        self->cont[self->ncont] = post
        self->cont_dm[self->ncont] = self->defers.len
        self->ncont += 1
        self->emit_block(s->body)
        self->nbrk -= 1
        self->ncont -= 1
        self->out->printf("\tjmp @l%d\n", post)
        self->out->printf("@l%d\n", post)
        iv2: i32 = self->tmp()
        self->out->printf("\t%%t%d =%c %s %%t%d\n", iv2, v->cls, self->load_op(v->ty), v->slot)
        stepv: i32
        if s->step != None:
            stepv = self->emit_rvalue(s->step)
            stepv = self->emit_coerce(stepv, self->ecls(s->step), v->cls)
        else:
            stepv = self->tmp()
            self->out->printf("\t%%t%d =%c copy 1\n", stepv, v->cls)
        nv: i32 = self->tmp()
        self->out->printf("\t%%t%d =%c add %%t%d, %%t%d\n", nv, v->cls, iv2, stepv)
        self->out->printf("\t%s %%t%d, %%t%d\n", self->store_op(v->ty), nv, v->slot)
        self->out->printf("\tjmp @l%d\n", cond)
        self->out->printf("@l%d\n", end)

    # for(init; cond; post) in C style — faithful: continue jumps to the post step
    private def emit_cfor(self: *Qb, s: *Stmt):
        fmark: i32 = self->binds.len   # C99: the for-init declaration scopes to the loop
        if s->for_init != None:
            self->emit_stmt(s->for_init)
        cond: i32 = self->lbl()
        body: i32 = self->lbl()
        post: i32 = self->lbl()
        end: i32 = self->lbl()
        self->out->printf("\tjmp @l%d\n", cond)
        self->out->printf("@l%d\n", cond)
        if s->cond != None:
            c: i32 = self->emit_cond(s->cond)
            self->out->printf("\tjnz %%t%d, @l%d, @l%d\n", c, body, end)
        else:
            self->out->printf("\tjmp @l%d\n", body)  # missing cond = infinite loop
        self->out->printf("@l%d\n", body)
        self->brk[self->nbrk] = end
        self->brk_dm[self->nbrk] = self->defers.len
        self->nbrk += 1
        self->cont[self->ncont] = post
        self->cont_dm[self->ncont] = self->defers.len
        self->ncont += 1
        self->emit_block(s->body)
        self->nbrk -= 1
        self->ncont -= 1
        self->out->printf("\tjmp @l%d\n", post)
        self->out->printf("@l%d\n", post)
        if s->for_post != None:
            self->emit_stmt(s->for_post)
        self->out->printf("\tjmp @l%d\n", cond)
        self->out->printf("@l%d\n", end)
        self->binds.len = fmark   # the for-init binding dies with the loop

    # faithful C switch (with fallthrough). Two passes: (1) chain of tests
    # subject==caseK -> jump to the case's label; (2) bodies in order, each
    # ST_CASE opens its block and the previous one falls into it (fallthrough). break -> end;
    # continue is NOT pushed (follows the outer loop).
    # collects the ST_CASE from a switch's body, descending into nested blocks
    # (if/while/do/for) — cases can live inside loops (Duff's device).
    # does NOT descend into ST_SWITCH: those cases belong to the inner switch.
    private def collect_cases(self: *Qb, b: *Block, acc: *Vec<*Stmt>):
        if b == None:
            return
        i: i32
        for i in range(b->n):
            st: *Stmt = b->stmts[i]
            if st->kind == ST_CASE:
                acc->push(st)
            elif st->kind != ST_SWITCH:
                for j in range(st->nconds):
                    self->collect_cases(st->blocks[j], acc)
                self->collect_cases(st->else_block, acc)
                self->collect_cases(st->body, acc)

    # C switch (faithful, with fallthrough and nested cases): dispatch as a chain
    # of tests -> jmp to the case's label (assigned in case_lbl); the body is
    # emitted as a normal block and each ST_CASE becomes its own inline label — jumping
    # into a loop is just a jmp (QBE accepts an arbitrary CFG).
    private def emit_switch(self: *Qb, s: *Stmt):
        subj: i32 = self->emit_rvalue(s->subject)
        scls: char = self->ecls(s->subject)
        end: i32 = self->lbl()
        cs: Vec<*Stmt>
        cs.init()
        self->collect_cases(s->body, &cs)
        default_lbl: i32 = end   # no default -> no match falls through to the end
        i: i32
        for i in range(cs.len):
            st: *Stmt = cs.data[i]
            st->case_lbl = self->lbl()
            if st->expr == None:
                default_lbl = st->case_lbl
            else:
                cv: i32 = self->emit_rvalue(st->expr)
                cv = self->emit_coerce(cv, self->ecls(st->expr), scls)
                t: i32 = self->tmp()
                self->out->printf("\t%%t%d =w %s %%t%d, %%t%d\n", t, self->cmp_name(TK_EQ, scls, True), subj, cv)
                nxt: i32 = self->lbl()
                self->out->printf("\tjnz %%t%d, @l%d, @l%d\n", t, st->case_lbl, nxt)
                self->out->printf("@l%d\n", nxt)
        self->out->printf("\tjmp @l%d\n", default_lbl)
        # dead block for any statement before the first case (unreachable)
        dead: i32 = self->lbl()
        self->out->printf("@l%d\n", dead)
        self->brk[self->nbrk] = end
        self->brk_dm[self->nbrk] = self->defers.len
        self->nbrk += 1
        self->emit_block(s->body)
        self->nbrk -= 1
        self->out->printf("\tjmp @l%d\n", end)
        self->out->printf("@l%d\n", end)
        cs.deinit()

    # P's match (WITHOUT fallthrough): each case has values (OR) and a body; after
    # the body, jump to the end. Two passes: chain of tests -> labeled bodies.
    private def emit_match(self: *Qb, s: *Stmt):
        # match type(x): resolved at compile-time — emit only the chosen block
        if s->is_typematch:
            if s->tm_sel >= 0:
                self->emit_block(s->cases[s->tm_sel]->body)
            return
        subj: i32 = self->emit_rvalue(s->subject)
        scls: char = self->ecls(s->subject)
        end: i32 = self->lbl()
        labels: Vec<i32>
        labels.init()
        i: i32
        for i in range(s->ncases):
            labels.push(self->lbl())
        default_lbl: i32 = end
        for i in range(s->ncases):
            mc: *MatchCase = s->cases[i]
            if mc->is_default:
                default_lbl = labels.data[i]
                continue
            for j in range(mc->nvals):
                cv: i32 = self->emit_rvalue(mc->vals[j])
                cv = self->emit_coerce(cv, self->ecls(mc->vals[j]), scls)
                t: i32 = self->tmp()
                self->out->printf("\t%%t%d =w %s %%t%d, %%t%d\n", t, self->cmp_name(TK_EQ, scls, True), subj, cv)
                nxt: i32 = self->lbl()
                self->out->printf("\tjnz %%t%d, @l%d, @l%d\n", t, labels.data[i], nxt)
                self->out->printf("@l%d\n", nxt)
        self->out->printf("\tjmp @l%d\n", default_lbl)
        # a `break` inside an arm ends the MATCH, which is what the C back end
        # gives (it prints a `switch`, and there `break` leaves it). Without
        # this the break stack was empty here and the jump went to a block that
        # does not exist — the two back ends have to agree, and a `match` is
        # breakable in both.
        self->brk[self->nbrk] = end
        self->brk_dm[self->nbrk] = self->defers.len
        self->nbrk += 1
        for i in range(s->ncases):
            mc2: *MatchCase = s->cases[i]
            self->out->printf("@l%d\n", labels.data[i])
            self->emit_block(mc2->body)
            self->out->printf("\tjmp @l%d\n", end)
        self->nbrk -= 1
        self->out->printf("@l%d\n", end)
        labels.deinit()

    # ---------- collect locals (params + ST_VAR) ----------
    # descends into expressions behind EX_STMTEXPR: the inner block's ST_VAR
    # need a slot like any local (otherwise they become an unknown symbol)
    private def collect_evars(self: *Qb, e: *Expr):
        if e == None:
            return
        if e->kind == EX_STMTEXPR:
            if e->xblock != None:
                self->collect_vars(e->xblock)
            self->collect_evars(e->lhs)
            return
        for j in range(expr_nexprs(e)):
            self->collect_evars(expr_expr_at(e, j))

    private def collect_vars(self: *Qb, b: *Block):
        i: i32
        for i in range(b->n):
            st: *Stmt = b->stmts[i]
            # every *Expr child, via the canonical list in ast.ph. The hand
            # written list this replaces was missing `from`/`to`/`step` and the
            # case values — a statement expression in a range bound or a case
            # label would have had its declarations left without a slot.
            for ci in range(stmt_nexprs(st)):
                self->collect_evars(stmt_expr_at(st, ci))
            match st->kind:
                case ST_VAR:
                    if st->is_extern:
                        self->add_extern_var(st->name, st->type, st)
                    elif st->is_static:
                        self->add_static_var(st->name, st->type, st->init, st)
                    else:
                        self->add_var(st->name, st->type, st)
                        # infer the alloc size of `T x[] = init` (otherwise the
                        # alloc ends up too small -> overflow): string -> number of
                        # units + 1; list -> number of elements. Applies to the var
                        # JUST added (the last one — never search by name here:
                        # homonyms in other blocks would hijack the fix).
                        if st->type != None and st->type->kind == TY_ARRAY and st->type->arr_len == None and st->init != None:
                            esz: i32 = self->size_of(st->type->inner)
                            units = -1
                            if st->init->kind == EX_STRING:
                                units = lit_unit_count(st->init->text, esz >= 4) + 1
                            elif st->init->kind == EX_INITLIST:
                                units = st->init->nargs
                            if units >= 0:
                                self->vars.data[self->vars.len - 1].nbytes = units * esz
                case ST_IF:
                    # folded at compile-time: only the live branch has real locals
                    if st->if_sel != -1:
                        if st->if_sel >= 0 and st->if_sel < st->nconds:
                            self->collect_vars(st->blocks[st->if_sel])
                        elif st->if_sel == st->nconds:
                            self->collect_vars(st->else_block)
                    else:
                        for j in range(st->nconds):
                            self->collect_vars(st->blocks[j])
                        if st->else_block != None:
                            self->collect_vars(st->else_block)
                case ST_WHILE, ST_DO, ST_FOR, ST_DEFER:
                    self->collect_vars(st->body)
                case ST_BLOCK:
                    # a bare block's declarations are still function-scope slots
                    # here (QBE vars are flat per function). Missing this case
                    # left them undeclared: the emitted code then referenced the
                    # name as a GLOBAL symbol and the link failed.
                    self->collect_vars(st->body)
                case ST_WITH:
                    self->add_var(st->name, st->type, st)
                    self->collect_vars(st->body)
                case ST_CFOR:
                    if st->for_init != None and st->for_init->kind == ST_VAR:
                        self->add_var(st->for_init->name, st->for_init->type, st->for_init)
                    self->collect_vars(st->body)
                case ST_SWITCH:
                    self->collect_vars(st->body)
                case ST_MATCH:
                    if st->is_typematch:
                        if st->tm_sel >= 0:
                            self->collect_vars(st->cases[st->tm_sel]->body)
                    else:
                        for mj in range(st->ncases):
                            self->collect_vars(st->cases[mj]->body)
                # No `case _:` ON PURPOSE. These kinds declare nothing and hold
                # no block whose declarations are function-scope here, so there
                # is genuinely nothing to collect — but they are LISTED, because
                # this match is the one that once dropped ST_BLOCK into a
                # catch-all and left its declarations without a slot (the
                # emitted code then named them as GLOBAL symbols and the link
                # failed). Without a default, -Wswitch reports the next kind
                # somebody adds instead of silently ignoring it.
                case ST_ASSIGN, ST_EXPR, ST_RETURN, ST_BREAK, ST_CONTINUE, ST_GOTO, ST_LABEL, ST_CASE, ST_PASS, ST_GLOBAL, ST_NONLOCAL, ST_CPROTO:
                    continue

    # EVERY declaration gets its own slot — no name dedup: homonyms in
    # sibling/nested blocks are DISTINCT variables (types may differ); fusing
    # them corrupts field offsets and store classes. Resolution is lexical,
    # via the binds stack (see find_var/bind_decl).
    private def add_var(self: *Qb, name: const *char, ty: *Type, decl: *Stmt):
        slot: i32 = self->tmp()
        qv: QVar = {name, slot, self->cls_of(ty), ty, False, 0, 0, False, decl}
        self->vars.push(qv)

    # block-scope `extern T x;`: no storage of its own — addressing uses the
    # global symbol $name (the object with external linkage)
    private def add_extern_var(self: *Qb, name: const *char, ty: *Type, decl: *Stmt):
        qv: QVar = {name, 0, self->cls_of(ty), ty, False, 0, 0, True, decl}
        self->vars.push(qv)

    # static local: global storage $sl<sid> with a single init (data), no alloc.
    # No dedup either: two same-named statics in different blocks are distinct
    # objects in C — each gets its own storage.
    private def add_static_var(self: *Qb, name: const *char, ty: *Type, init: *Expr, decl: *Stmt):
        sid: i32 = self->nstatic
        self->nstatic += 1
        qv: QVar = {name, 0, self->cls_of(ty), ty, True, sid, 0, False, decl}
        self->vars.push(qv)
        # emits the storage (constant init or zero) into the module's data buffer
        sz: i32 = self->size_of(ty)
        scls: char = self->cls_of(ty)
        # static local float with constant init (the TYPE decides, not the spelling:
        # `static double x = 100` stores 100.0, not the integer's bits)
        if init != None and init->kind == EX_NUMBER and (scls == 's' or scls == 'd'):
            self->data.printf("data $sl%d = { %c %c_%s }\n", sid, scls, scls, fnum(init->text))
            return
        # static char *p = "...": pointer to anonymous string
        if init != None and init->kind == EX_STRING and ty != None and ty->kind == TY_PTR:
            sps: i32 = self->emit_string(init->text)
            self->data.printf("data $sl%d = { l $qstr%d }\n", sid, sps)
            return
        # static char[] = "...": bytes + nul (size inferred when [])
        if init != None and init->kind == EX_STRING and ty != None and ty->kind == TY_ARRAY:
            dbs: StrBuf = {0}
            nb: i32 = cstr_bytes(&dbs, init->text, sz if sz > 0 else -1)
            # the nul only goes in when the declared array has room for it
            nul: bool = sz <= 0 or nb < sz
            total: i32 = sz if sz > 0 else nb + 1
            self->data.printf("data $sl%d = {%s", sid, dbs.data if dbs.data != None else "")
            if nul:
                self->data.puts(" b 0")
                nb += 1
            else:
                self->data.trim_comma()
            if total > nb:
                self->data.printf("%s z %d", "" if not nul else ",", total - nb)
            self->data.puts(" }\n")
            dbs.deinit()
            self->static_fix_len(ty, total)
            return
        # list/compound: general aggregate walker (elision, designators...)
        if init != None and (init->kind == EX_INITLIST or init->kind == EX_COMPOUND):
            dbl: StrBuf = {0}
            one: *Expr = init
            ix = 0
            rr: i32 = self->data_fill(&dbl, ty, &one, 1, ref ix)
            if rr > 0 and dbl.len > 0:
                if dbl.data[dbl.len - 1] == ',':
                    dbl.len -= 1
                    dbl.data[dbl.len] = '\0'
                self->data.printf("data $sl%d = align %d {%s }\n", sid, self->type_align(ty), dbl.data)
                self->static_fix_len(ty, rr)
            else:
                self->data.printf("data $sl%d = { z %d }\n", sid, sz if sz > 0 else rr)
            dbl.deinit()
            return
        # constant scalar (number/char/enum/expression)
        svok: bool = True
        sval: i64 = self->const_int(init, ref svok) if init != None else 0
        if init != None and svok and scls != 's' and scls != 'd':
            dt: const *char = "w"
            if sz == 1:
                dt = "b"
            elif sz == 2:
                dt = "h"
            elif self->cls_of(ty) == 'l' or sz == 8:
                dt = "l"
            self->data.printf("data $sl%d = { %s %lld }\n", sid, dt, sval)
        elif init != None and init->kind == EX_IDENT and self->globals.get_or(init->text, None) != None and self->globals.get_or(init->text, None)->kind == TY_ARRAY:
            # static ptr = global array (decays to address)
            self->data.printf("data $sl%d = { l $%s }\n", sid, init->text)
        elif init != None and init->kind == EX_UNARY and init->op == TK_AMP and init->lhs != None and init->lhs->kind == EX_IDENT:
            self->data.printf("data $sl%d = { l $%s }\n", sid, init->lhs->text)
        else:
            self->data.printf("data $sl%d = { z %d }\n", sid, sz)

    # records the real size of an inferred ([]) array static local:
    # nbytes for decay and synthetic arr_len for sizeof
    private def static_fix_len(self: *Qb, ty: *Type, total: i32):
        # applies to the var JUST registered by add_static_var (the last one) —
        # this runs during collect, before any lexical binding exists
        if self->vars.len > 0:
            self->vars.data[self->vars.len - 1].nbytes = total
        if ty != None and ty->kind == TY_ARRAY and ty->arr_len == None:
            esz: i32 = self->size_of(ty->inner)
            if esz > 0:
                ne: *Expr = calloc(1, sizeof(Expr))
                ne->kind = EX_NUMBER
                nt: *char = malloc(16)
                snprintf(nt, 16, "%d", total / esz)
                ne->text = nt
                ty->arr_len = ne

    private def emit_func(self: *Qb, f: *Func):
        if f->body == None:
            return  # prototype: nothing to emit in QBE
        self->vars.init()
        self->binds.init()
        self->defers.init()
        self->ntmp = 0
        self->nlbl = 0
        self->nbrk = 0
        self->ncont = 0
        rcls: char = self->cls_of(f->ret)
        is_void: bool = f->ret != None and f->ret->kind == TY_NAME and f->ret->name == "void"
        ret_agg: bool = self->is_agg(f->ret)
        self->cur_ret_cls = 0 if is_void else rcls
        self->cur_ret_agg = ret_agg
        self->cur_ret_name = f->ret->name if ret_agg else None
        self->cur_fname = f->cname

        if f->cname == "main" or not f->is_static:
            self->out->puts("export ")
        if ret_agg:
            self->out->printf("function :%s $%s(", f->ret->name, f->cname)
        elif is_void:
            self->out->printf("function $%s(", f->cname)
        else:
            self->out->printf("function %c $%s(", rcls, f->cname)
        # params: struct by value -> :Name (pointer to copy); else the class
        i: i32
        for i in range(f->nparams):
            if i != 0:
                self->out->puts(", ")
            if self->is_agg(f->params[i].type):
                self->out->printf(":%s %%a%d", f->params[i].type->name, i)
            elif self->is_valist(f->params[i].type):
                self->out->printf("l %%a%d", i)   # va_list passed by pointer
            else:
                self->out->printf("%c %%a%d", self->cls_of(f->params[i].type), i)
        if f->is_varargs:
            if f->nparams != 0:
                self->out->puts(", ")
            self->out->puts("...")
        self->out->puts(") {\n@start\n")

        # slots for params. An array-typed parameter decays to a pointer
        # (C ABI): the slot holds the pointer received in %a<i>, not the bytes.
        for i in range(f->nparams):
            pt: *Type = f->params[i].type
            if pt != None and pt->kind == TY_ARRAY:
                pt = mk_typtr(pt->inner)
            self->add_var(f->params[i].name, pt, None)
            self->binds.push(i)   # params: bound for the whole function (indices 0..n-1)
        # slots for locals
        self->collect_vars(f->body)
        # emits the allocs (REAL size; arrays allocate all the bytes). Aggregate
        # params (struct by value) do NOT alloc: they use the pointer %a<i>.
        for i in range(self->vars.len):
            qv: *QVar = &self->vars.data[i]
            if qv->is_static:
                continue   # static local uses global storage, not alloc
            if i < f->nparams and (self->is_agg(f->params[i].type) or self->is_valist(f->params[i].type)):
                continue
            if self->is_vla_type(qv->ty):
                continue   # VLA: allocated at the declaration point (runtime size)
            sz: i32 = qv->nbytes if qv->nbytes > 0 else self->size_of(qv->ty)
            align: i32 = 8 if (sz > 4 or qv->cls == 'l' or qv->cls == 'd') else 4
            bytes: i32 = sz if sz > align else align
            self->out->printf("\t%%t%d =l alloc%d %d\n", qv->slot, align, bytes)
        # zeroes scalar locals: QBE rejects "slot read but never stored"
        # (reading uninitialized, which C allows). Zeroing gives defined
        # behavior and satisfies the verifier. (arrays/structs aren't read via
        # the slot directly, so they don't need it.)
        for i in range(self->vars.len):
            zv: *QVar = &self->vars.data[i]
            if zv->is_static or i < f->nparams:
                continue
            if zv->ty != None and (zv->ty->kind == TY_ARRAY or self->is_agg(zv->ty)):
                continue
            self->out->printf("\t%s 0, %%t%d\n", self->store_op(zv->ty), zv->slot)
        # initializes params: scalar -> store %a<i> in the slot; aggregate ->
        # the slot IS the pointer %a<i> (the copy was already done by the call's ABI)
        for i in range(f->nparams):
            pv: *QVar = self->find_var(f->params[i].name)
            if self->is_agg(f->params[i].type) or self->is_valist(f->params[i].type):
                self->out->printf("\t%%t%d =l copy %%a%d\n", pv->slot, i)
            else:
                self->out->printf("\t%s %%a%d, %%t%d\n", self->store_op(pv->ty), i, pv->slot)

        # emits the body into a separate buffer, capturing inline allocs
        # (ternary/&&/||/compound) into a prologue buffer — then inserts the
        # allocs BEFORE the body (once, in @start), never inside loops
        slotbuf: StrBuf = {0}
        bodybuf: StrBuf = {0}
        saved_out: *StrBuf = self->out
        self->slots = &slotbuf
        self->out = &bodybuf
        self->emit_block(f->body)
        if is_void:
            self->out->puts("\tret\n")
        else:
            self->out->printf("\tret 0\n")
        self->out = saved_out
        self->slots = None
        if slotbuf.data != None:
            self->out->puts(slotbuf.data)
        if bodybuf.data != None:
            self->out->puts(bodybuf.data)
        slotbuf.deinit()
        bodybuf.deinit()
        self->out->puts("}\n\n")
        self->vars.deinit()

# rotating buffer for concatenating comparison mnemonic + class
g_qcmp_buf: char[8][16]
g_qcmp_idx: i32 = 0

def arena_qcmp(base: const *char, cls: char) -> const *char:
    # concatenates "cslt" + 'w' -> "csltw"
    b: *char = g_qcmp_buf[g_qcmp_idx & 7]
    g_qcmp_idx += 1
    snprintf(b, 16, "%s%c", base, cls)
    return b

def emit_module_qbe(m: *Module, out: *StrBuf):
    qb: Qb = {0}
    qb.out = out
    qb.file = m->path
    qb.globals.init()
    qb.funcs.init()
    qb.structs.init()
    qb.tdsc.init()
    for i in range(m->ntdsc):
        qb.tdsc.put(m->tdsc_names[i], m->tdsc_types[i])
    qb.gconsts.init()
    qb.enumc.init()
    defer:
        qb.globals.deinit()
        qb.funcs.deinit()
        qb.structs.deinit()
        qb.gconsts.deinit()
        qb.enumc.deinit()
        qb.data.deinit()
    # (macro constants like EOF/SEEK_SET are no longer hardcoded here: with
    # `include <header.h>` sema ingests the real #defines and folds them to
    # literals before the backend ever sees the names)

    # collects function signatures and global types
    for i in range(m->ndecls):
        d: *Decl = m->decls[i]
        if d->kind == DL_FUNC:
            if d->func->ntparams == 0:   # skip generic template (def foo<T>)
                qb.funcs.put(d->func->cname, d->func)
        elif d->kind == DL_VAR:
            qb.globals.put(d->name, d->type)
            # `NAME: const T = v` puts the qualifier on the TYPE, `const NAME = v`
            # on the declaration — both are consts to fold
            if d->init != None and (d->is_const or (d->type != None and d->type->is_const)):
                qb.gconsts.put(d->name, d->init)
        elif d->kind == DL_STRUCT or d->kind == DL_UNION:
            # registers the layout (union too); EMPTY struct ({} GNU, size 0)
            # too — but never shadowing a real layout that has fields
            if d->nfields > 0 or qb.structs.get_or(d->name, None) == None:
                qb.structs.put(d->name, d)
            for j in range(d->nmethods):
                qb.funcs.put(d->methods[j]->cname, d->methods[j])
        elif d->kind == DL_ENUM:
            # registers each constant with its value (auto-increment; an
            # explicit number/char value repositions the counter)
            next_val: i64 = 0
            for k in range(d->nitems):
                iv: *EnumItem = &d->items[k]
                if iv->value != None and iv->value->kind == EX_NUMBER:
                    next_val = strtoll(iv->value->text, None, 0)
                elif iv->value != None and iv->value->kind == EX_CHARLIT:
                    next_val = i64(qb.charval(iv->value->text))
                ec: EnumConst = {iv->name, next_val}
                qb.enumc.push(ec)
                next_val += 1

    # emits the aggregate types (structs/unions with fields) for pass/return
    # by value, with FAITHFUL MEMBERS (letters/subtypes, in dependency order):
    # QBE classifies the aggregate for the SysV ABI from its members — an
    # OPAQUE type is always MEMORY class and would break interop with code
    # from other compilers (e.g. a 4-byte Ref would come back in %eax, not via sret)
    seen_ty: StrSet
    seen_ty.init()
    for ti in range(m->ndecls):
        dt: *Decl = m->decls[ti]
        if (dt->kind == DL_STRUCT or dt->kind == DL_UNION) and dt->nfields > 0:
            qb.emit_qtype(out, dt->name, &seen_ty)
    seen_ty.deinit()

    # C tentative definitions: `int x; int x = 3; int x;` are the SAME object.
    # Collects the names that have init and emits each global ONCE (preferring
    # the version with an initializer), otherwise minias complains about a
    # duplicate symbol.
    ginit: StrSet
    gdone: StrSet
    ginit.init()
    gdone.init()
    for gi in range(m->ndecls):
        gd: *Decl = m->decls[gi]
        if gd->kind == DL_VAR and gd->init != None:
            ginit.add(gd->name)
    # emits globals as data, with the scalar initializer when there is one
    for i in range(m->ndecls):
        d2: *Decl = m->decls[i]
        if d2->kind == DL_VAR:
            # extern without init: defined elsewhere (libc, e.g. stdout) — don't
            # emit data (else it would create a zero symbol that shadows the
            # real one -> NULL)
            if d2->is_extern and d2->init == None:
                continue
            # dedup of tentative definitions
            if gdone.has(d2->name):
                continue
            if d2->init == None and ginit.has(d2->name):
                continue   # wait for the version with an initializer
            gdone.add(d2->name)
            # top-level `static`: local symbol of the TU; else export (C global)
            xp: const *char = "" if d2->is_static else "export "
            sz: i32 = qb.size_of(d2->type)
            gcls: char = qb.cls_of(d2->type)
            # scalar float initializer -> data { d d_val } / { s s_val }.
            # The TYPE decides (not the literal's spelling): `double x = 100`
            # stores the IEEE-754 pattern for 100.0, not the integer 100's bits.
            if d2->init != None and d2->init->kind == EX_NUMBER and (gcls == 's' or gcls == 'd'):
                out->printf("%sdata $%s = { %c %c_%s }\n", xp, d2->name, gcls, gcls, fnum(d2->init->text))
                continue
            # constant scalar initializer (number/char) -> emits the value
            lit: bool = d2->init != None and (d2->init->kind in {EX_NUMBER, EX_CHARLIT, EX_TRUE, EX_FALSE})
            if lit:
                dcls: char = qb.cls_of(d2->type)
                val: i64 = 0
                if d2->init->kind == EX_NUMBER:
                    val = i64(strtoull(d2->init->text, None, 0))   # full u64 range; bits fit i64
                elif d2->init->kind == EX_CHARLIT:
                    val = i64(qb.charval(d2->init->text))
                elif d2->init->kind == EX_TRUE:
                    val = 1
                # QBE data type: b/h/w/l according to the size
                dt: const *char = "w"
                if sz == 1:
                    dt = "b"
                elif sz == 2:
                    dt = "h"
                elif dcls == 'l' or sz == 8:
                    dt = "l"
                out->printf("%sdata $%s = { %s %lld }\n", xp, d2->name, dt, val)
            elif d2->init != None and (d2->init->kind == EX_INITLIST or d2->init->kind == EX_COMPOUND) and (d2->type->kind == TY_ARRAY or qb.struct_of(d2->type) != None):
                # global aggregate (array/struct/union, nested, with brace
                # elision): flattens against the layout; padding/tail become `z`
                db: StrBuf = {0}
                one: *Expr = d2->init
                ix = 0
                rr: i32 = qb.data_fill(&db, d2->type, &one, 1, ref ix)
                if rr > 0 and db.len > 0:
                    if db.data[db.len - 1] == ',':
                        db.len -= 1
                        db.data[db.len] = '\0'
                    # array without declared size: records the inferred size on
                    # the type (for sizeof(arr) in functions, emitted later)
                    if d2->type->kind == TY_ARRAY and d2->type->arr_len == None:
                        esz2: i32 = qb.size_of(d2->type->inner)
                        if esz2 > 0:
                            ne: *Expr = calloc(1, sizeof(Expr))
                            ne->kind = EX_NUMBER
                            nt: *char = malloc(16)
                            snprintf(nt, 16, "%d", rr / esz2)
                            ne->text = nt
                            d2->type->arr_len = ne
                    out->printf("%sdata $%s = align %d {%s }\n", xp, d2->name, qb.type_align(d2->type), db.data)
                else:
                    # NEVER zero-fill silently: that once produced a compiler
                    # whose `backends[]` table was all zeros, so it could not
                    # find its own backends. Better a loud stop than wrong data.
                    fatal_at(m->path, d2->pos, "qbe backend: cannot build the static initializer of '%s' (a value here is not a compile-time constant this backend can fold)", d2->name)
                db.deinit()
            elif d2->init != None and d2->init->kind == EX_UNARY and d2->init->op == TK_AMP and d2->init->lhs != None and d2->init->lhs->kind == EX_IDENT:
                # global pointer = &symbol (e.g. fn-ptr = &function)
                out->printf("%sdata $%s = { l $%s }\n", xp, d2->name, d2->init->lhs->text)
            elif d2->init != None and d2->init->kind == EX_IDENT and qb.funcs.get_or(d2->init->text, None) != None:
                # global pointer = function (decays to address)
                out->printf("%sdata $%s = { l $%s }\n", xp, d2->name, d2->init->text)
            elif d2->init != None and d2->init->kind == EX_IDENT and qb.globals.get_or(d2->init->text, None) != None and qb.globals.get_or(d2->init->text, None)->kind == TY_ARRAY:
                # global pointer = global array (decays to address)
                out->printf("%sdata $%s = { l $%s }\n", xp, d2->name, d2->init->text)
            elif d2->init != None and d2->init->kind == EX_STRING and d2->type->kind == TY_PTR:
                # char *p = "...": pointer to anonymous string
                sidp: i32 = qb.emit_string(d2->init->text)
                out->printf("%sdata $%s = { l $qstr%d }\n", xp, d2->name, sidp)
            elif d2->init != None and d2->init->kind == EX_STRING and d2->type->kind == TY_ARRAY:
                # char arr[] = "..." (or fixed size): bytes + nul, with padding
                # if the declared array is larger than the string
                out->printf("%sdata $%s = {", xp, d2->name)
                nb: i32 = cstr_bytes(out, d2->init->text, sz if sz > 0 else -1)
                gnul: bool = sz <= 0 or nb < sz
                if gnul:
                    out->puts(" b 0")
                    nb += 1
                else:
                    out->trim_comma()
                pad: i32 = sz - nb
                if pad > 0:
                    out->printf("%s z %d", "" if not gnul else ",", pad)
                out->puts(" }\n")
            elif d2->init != None and gcls != 's' and gcls != 'd':
                # general constant scalar (enum, expression): evaluate; else zero
                cvok: bool = True
                cvv: i64 = qb.const_int(d2->init, ref cvok)
                if cvok:
                    cdt: const *char = "w"
                    if sz == 1:
                        cdt = "b"
                    elif sz == 2:
                        cdt = "h"
                    elif gcls == 'l' or sz == 8:
                        cdt = "l"
                    out->printf("%sdata $%s = { %s %lld }\n", xp, d2->name, cdt, cvv)
                else:
                    # NEVER zero-fill silently: that once produced a compiler
                    # whose `backends[]` table was all zeros, so it could not
                    # find its own backends. Better a loud stop than wrong data.
                    fatal_at(m->path, d2->pos, "qbe backend: cannot build the static initializer of '%s' (a value here is not a compile-time constant this backend can fold)", d2->name)
            else:
                # no initializer (or non-constant form) -> zero
                out->printf("%sdata $%s = { z %d }\n", xp, d2->name, sz)
    ginit.deinit()
    gdone.deinit()

    # emits functions (dedup of duplicate definitions: the 1st wins — only
    # happens with malformed input, e.g. two `int main`s, which would
    # otherwise be a link error)
    fdone: StrSet
    fdone.init()
    for i in range(m->ndecls):
        d3: *Decl = m->decls[i]
        if d3->kind == DL_FUNC:
            if d3->func->is_comptime:
                continue   # `const def`: evaluated at compile time, not emitted
            if d3->func->ntparams > 0:
                continue   # generic template (def foo<T>): only monomorphizations emitted
            if d3->func->body != None:
                if fdone.has(d3->func->cname):
                    continue
                fdone.add(d3->func->cname)
            qb.emit_func(d3->func)
        elif d3->kind == DL_STRUCT:
            if d3->ntparams > 0:
                continue   # generic template: only the instances (declare/
                           # implement) get emitted; T is abstract here
            for j2 in range(d3->nmethods):
                mth: *Func = d3->methods[j2]
                if mth->body != None:
                    if fdone.has(mth->cname):
                        continue
                    fdone.add(mth->cname)
                qb.emit_func(mth)
    fdone.deinit()

    # appends the data defs (strings) at the end
    if qb.data.data != None:
        out->puts(qb.data.data)
