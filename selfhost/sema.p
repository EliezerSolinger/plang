# sema.p — symbols, "best effort" inference and AST rewrites
# (port of src/sema.c)
#
# Philosophy (from the spec): execution semantics are 100% C, so deep type
# checking is left to the C compiler. Sema only does what's necessary for
# the TRANSLATION to be correct. Unknown symbols (printf, FILE, ...)
# are tolerated: they come from C headers.
include <string.h>
include <stdlib.h>
include <stdio.h>
include <ctype.h>
include <time.h>
import "sema.ph"
import "lexer.ph"
import "parser.ph"
import "cfront.ph"
import "embed.ph"
import <stl/map.ph>
import <stl/set.ph>

struct Sym:
    name: const *char
    type: *Type
    is_extern: bool   # block-scope `extern`: re-declarable in the same scope
    used: bool        # referenced after the declaration (-Wunused-variable)
    written: bool     # target of an assignment/++ (-Wunused-but-set-variable)
    read: bool        # value actually READ somewhere
    assigned: bool    # has a value: initializer seen, or address escaped (&x)
    uninit_warned: bool
    byref: i32        # out/ref/in parameter: uses of the name auto-deref (*name)
                      #   — and a LOCAL `r: ref T` (69.1) rides the same rail
    nn: i32           # null fact for a pointer local, per flow position (69.7):
                      #   0 = unknown, 1 = proven non-None, 2 = proven None
    nn_off: bool      # address escaped (&x): the fact could be changed from
                      #   anywhere, so this local never carries one again
    for_iter: bool    # iterator injected by `for`: a later explicit
                      #   declaration REUSES it (and becomes an assignment)
    for_decl: *Stmt   # that injected declaration: a later loop over a NEGATIVE
                      #   range promotes it to `isize` (see lower_for_iter)
    pos: Pos          # declaration site; line 0 = untracked (params, with, ...)

struct SInfo:
    name: const *char
    is_union: bool
    c_tag: bool     # ingested C TAG without a typedef (struct stat, struct
                    #   dirent...): P references emit the `struct X` spelling
    defined: bool   # saw a DEFINITION (not just a forward `struct S;`)
    is_record: bool # declared with `record` (65.1): the compiler has CHECKED that
                    #   no pointer lives anywhere inside, so values of it are safe
                    #   to memcpy, to write to disk and to compare by content
    fields: *Field
    nfields: i32
    cfields: i32
    methods: **Func
    nmethods: i32
    cmethods: i32

# compile-time value (CTFE): primitives only — int/float/const char*
enum CValKind:
    CV_BAD = 0
    CV_INT
    CV_FLOAT
    CV_STR

struct CVal:
    kind: CValKind
    ival: i64
    fval: f64
    sval: const *char   # text of the string literal (with quotes), for EX_STRING

# symbol tables use the compiler's own STL
implement StrSet
declare StrMap<*SInfo>
implement StrMap<*SInfo>
declare StrMap<*Func>
implement StrMap<*Func>
declare StrMap<*Type>
implement StrMap<*Type>
declare StrMap<*Decl>
implement StrMap<*Decl>
# declare only: cfront.p already IMPLEMENTS this instance, and a second set of
# bodies would collide at link time
declare StrMap<*char>
# the QBE backend folds module-level consts through a map of their initializers
declare StrMap<*Expr>
implement StrMap<*Expr>
declare StrMap<i64>
implement StrMap<i64>
declare StrMap<*CVal>
implement StrMap<*CVal>

# substitution of type parameters during monomorphization (T -> int)
struct Subst:
    names: **char
    types: **Type
    n: i32

# forward declarations of the module-level helpers (the methods below
# come first in the file, inside the struct)
private def ends_with(s: const *char, suf: const *char) -> bool
def cc_load_module(cc: *Cc, path: const *char) -> *Module
private def sinfo_method(si: *SInfo, name: const *char) -> *Func
private def sinfo_field(si: *SInfo, name: const *char) -> *Field
# ---------- scopes ----------
private def is_arith_type(t: *Type) -> bool
private def mangle_type_into(sb: *StrBuf, t: *Type)
private def subst_lookup(sub: *Subst, name: const *char) -> *Type
private def is_void_val(t: *Type) -> bool
private def strip_ptr_or_array(t: *Type) -> *Type
private def ceval_char(lex: const *char) -> i64
private def names_own_type(t: *Type, init: *Expr) -> bool
private def is_designator(e: *Expr) -> bool
private def decl_in_module(m: *Module, name: const *char) -> bool
private def cv_int(v: i64) -> CVal
private def cv_flt(v: f64) -> CVal
private def cv_str(v: const *char) -> CVal
private def cv_asf(v: CVal) -> f64
private def cfloat_text(a: *Arena, v: f64) -> const *char
private def ceval_num(txt: const *char) -> CVal
private def ctype_width(n: const *char) -> i32
private def ctype_unsigned(n: const *char) -> bool
private def ctype_width(n: const *char) -> i32
private def ctype_unsigned(n: const *char) -> bool
private def render_type_p(a: *Arena, t: *Type) -> const *char   # p/ typestr comptime
private def edit_dist(a: const *char, b: const *char) -> i32
private def is_c_arith_words(n: const *char) -> bool
private def is_lvalue(e: *Expr) -> bool
private def mk_ident(a: *Arena, name: const *char, pos: Pos) -> *Expr
private def mk_call1(a: *Arena, fn: const *char, arg: *Expr, pos: Pos) -> *Expr
private def is_byref_deref(x: *Expr) -> bool
private def take_addr(a: *Arena, x: *Expr) -> *Expr
private def render_type_p(a: *Arena, t: *Type) -> const *char
private def is_void_val(t: *Type) -> bool
private def is_float_type(t: *Type) -> bool
private def is_arith_type(t: *Type) -> bool
private def is_float_type(t: *Type) -> bool
private def init_str_units(lex: const *char) -> i32
private def init_skip_field(f: *Field) -> bool
private def unify_tparam(pt: *Type, at: *Type, tname: const *char) -> *Type
private def block_find_kind(b: *Block, k: StmtKind) -> *Stmt
private def block_terminates(b: *Block) -> bool
private def type_eq_p(a: *Type, b: *Type) -> bool
private def trait_sub(a: *Arena, t: *Type, trait: const *char, forty: const *char, assoc: const *char, at: *Type) -> *Type
private def expr_is_negative(e: *Expr) -> bool
private def type_is_unsigned(t: *Type) -> bool
# ---------- C header ingestion (`include <h>` / `include "h"`) ----------
# `include` is transparent: the header's declarations (types, prototypes) become
# known to P via register_module, while the backend still emits a plain #include.
# We use the system C preprocessor (`cc -E`) — already required to turn P's C
# output into a binary — then feed the result to the C front end (c_parse).
# popen/pclose are POSIX, not declared by <stdio.h> under strict -std=c11, so we
# prototype them here — otherwise C assumes an int return and truncates the FILE*.
# Spelled with libc's OWN types (`FILE`, `int`), never the underlying tag: on a
# platform whose <stdio.h> does declare them, a mismatched spelling is a hard
# "conflicting types" error, and `struct _IO_FILE` is glibc-only.
def popen(cmd: const *char, mode: const *char) -> *FILE
def pclose(stream: *FILE) -> int
# exported: pscript's boundary reads the same #define literals (72.4)
def macro_int_val(txt: const *char, out: *i64) -> bool
private def inject_inline_runtime(cc: *Cc, m: *Module)
def sema_run(cc: *Cc, m: *Module)

# ---------- compile-time interpreter (CTFE) ----------
# call frame of a `const def`: name->value bindings (params + locals)
struct CFrame:
    names: **char
    vals: *CVal
    n: i32
    cap: i32

    # constructor: the bindings live in the compiler's arena, so the frame is
    # just a window over it — nothing to free when the call returns
    def init(out self: CFrame, a: *Arena, cap: i32):
        self.cap = cap
        self.names = a->alloc(usize(cap) * sizeof(*self.names))
        self.vals = a->alloc(usize(cap) * sizeof(*self.vals))
        self.n = 0

    # a POINTER receiver: the env of an expression evaluated outside any
    # `const def` is None, and looking a name up in it must simply say no
    private def find(self: *CFrame, name: const *char, out val: CVal) -> bool:
        if self == None:
            return False
        for i in range(self->n):
            if strcmp(self->names[i], name) == 0:
                val = self->vals[i]
                return True
        return False

    def set(ref self: CFrame, name: const *char, v: CVal):
        for i in range(self.n):
            if strcmp(self.names[i], name) == 0:
                self.vals[i] = v
                return
        if self.n < self.cap:
            self.names[self.n] = name
            self.vals[self.n] = v
            self.n += 1

# accumulates the closest candidate to `name`: construct it with the name that
# was not found, feed it every name in scope, then ask for the text
struct Sugg:
    name: const *char
    best: const *char
    bestd: i32

    def init(out self: Sugg, name: const *char):
        self.name = name
        self.best = None
        self.bestd = 999

    def feed(ref self: Sugg, cand: const *char):
        if cand == None or cand[0] == '\0':
            return
        d: i32 = edit_dist(self.name, cand)
        if d < self.bestd:
            self.bestd = d
            self.best = cand

builtins: const *char[] = {
    "int", "char", "float", "double", "void",
    "bool", "long", "short", "unsigned", "signed",
    "va_list", "__builtin_va_list",   # varargs is a language feature, not a header type
    # GCC builtin types that appear in preprocessed system headers
    "__int128", "__int128_t", "__uint128_t",
    "_Float16", "_Float32", "_Float32x", "_Float64", "_Float64x", "_Float128",
    "_Decimal32", "_Decimal64", "_Decimal128",
    "size_t", "ssize_t", "ptrdiff_t",
    "int8_t", "int16_t", "int32_t", "int64_t",
    "uint8_t", "uint16_t", "uint32_t", "uint64_t",
    "intptr_t", "uintptr_t",
    "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64",
    "f32", "f64", "usize", "isize", None}

# --inline-runtime: the P source of the self-contained helpers. Parsed and
# PREPENDED to the module, so both backends emit them like ordinary code and
# the output carries no libc dependency for compiler-injected calls.
INLINE_RUNTIME_SRC: const *char = "private def __plang_strcmp(a: const *char, b: const *char) -> i32:\n    i: usize = 0\n    while a[i] != '\\0' and a[i] == b[i]:\n        i += 1\n    return i32(u8(a[i])) - i32(u8(b[i]))\n"

# The same, without a Sema: pscript's own front end ingests C headers too (45.5),
# and it has no reason to build a P sema to do it.
def cpp_capture_ex(a: *Arena, cpp_cmd: const *char, flags: const *char, path: const *char, is_sys: bool, dir: const *char) -> const *char:
    cpp: const *char = cpp_cmd if cpp_cmd != None else "cc"
    cmd: const *char
    if is_sys:
        cmd = a->printf("printf '#include <%s>\\n' | %s %s -I%s -x c - 2>/dev/null", path, cpp, flags, dir)
    else:
        cmd = a->printf("printf '#include \"%s\"\\n' | %s %s -I%s -x c - 2>/dev/null", path, cpp, flags, dir)
    f: *FILE = popen(cmd, "r")
    if f == None:
        fatal("could not run '%s -E' to ingest C header '%s' (see --cpp / PLANGC_CPP)", cpp, path)
    b: StrBuf = {0}
    chunk: char[4097]
    while True:
        n: usize = fread(&chunk[0], 1, 4096, f)
        if n == 0:
            break
        chunk[n] = '\0'
        b.puts(&chunk[0])
    rc: i32 = pclose(f)
    if rc != 0:
        fatal("'%s' failed to preprocess header '%s' (not found? see --cpp / PLANGC_CPP)", cpp, path)
    out: const *char = a->strdup(b.data if b.data != None else "")
    b.deinit()
    return out


# A literal chunk of an f-string goes into the FORMAT, so a `%` in the text has
# to be doubled or printf would read it as a conversion of its own.
private def fstr_put_lit(b: *StrBuf, s: const *char, n: usize):
    for i in range(n):
        if s[i] == '%':
            b->putc('%')
        b->putc(s[i])

struct Sema:
    cc: *Cc
    a: *Arena
    file: const *char        # file being analyzed (for errors)
    templates: StrMap<*Decl> # generic structs (not emitted)
    func_templates: StrMap<*Func>  # generic free functions (def foo<T>): not emitted
    implemented: StrSet      # instances already implemented
    types: StrSet            # names of known types (builtins + user)
    structs: StrMap<*SInfo>
    funcs: StrMap<*Func>
    globals: StrMap<*Type>
    macroalias: StrMap<*char>  # `#define NAME OTHER` from an ingested C header
                               #   where OTHER is a declared OBJECT, not a constant:
                               #   macOS spells stderr `#define stderr __stderrp`,
                               #   so P must follow the rename (see ingest_macros)
    enumconsts: StrSet
    enums: StrMap<*Decl>     # enum TYPE name -> its declaration, for -Wswitch:
                             #   exhaustiveness needs the enumerator list, which
                             #   `enumconsts` (a flat set) cannot give back
    constvals: StrMap<*CVal>   # constants known at compile time (int/float/str)
    gstatics: StrSet         # file-scope names declared 'static' (internal
                             #   linkage) — a later extern/non-static conflicts
    gexterns: StrSet         # names given EXTERNAL linkage by block-scope
                             #   'extern' declarations (a later static conflicts)
    gdefs: StrSet            # file-scope objects already DEFINED (initialized):
                             #   a second initialized definition is an error
    macroconsts: StrSet      # constvals that came from ingested C headers (#define):
                             #   folded to literals in expressions (QBE has no cpp)
    cur_mod: *Module         # module being registered/checked: its `import ... as`
                             #   aliases are visible ONLY while it is current
    in_chdr: bool            # registering an ingested C header (relaxed checks)
    for_ctr: i32             # hidden index counter for `for v in xs` (__fiN)
    in_ctr: i32              # hidden temporaries for `in` receivers (__inN)
    co_ctr: i32              # hidden temporaries for `a ?? b` (__coN)
    uneval: i32              # depth inside sizeof/_Alignof: the operand is NOT
                             #   evaluated, so no null fact can fire there (69.7)
    traits: StrMap<*Decl>    # `trait X:` — the signatures it names (67.1)
    timpls: StrSet           # "Trait/Type" pairs already implemented (67.3)
    tdalias: StrMap<*Type>   # typedef de header C -> tipo do TAG subjacente
    tdscalar: StrMap<*Type>  # typedef de header C -> tipo ESCALAR subjacente
                             #   (`regex_t` -> `struct re_pattern_buffer`)
    c_mod: bool              # checking a C module: no Python-style inference
                             #   (`a = 1` does NOT declare in C)
    fn_globals: StrSet       # names pinned by `global x` in the current function
    fn_nonlocals: StrSet     # names marked by `nonlocal x` (declare at fn scope)
    fn_hoisted: StrMap<*Type>  # nonlocal names already declared (hoisted): they
                               #   stay visible for the REST of the function
    rc_ctr: i32              # counter of the hidden record temporaries C89 needs
    in_complit_init: bool    # checking an initializer that DIRECTLY names its own
                             #   type (`v: Vec = Vec(...)`): the record constructor
                             #   collapses to a brace list there, so C89 is fine
    in_wlhs: bool            # checking the LHS of a plain assignment: the ident
                             #   is written, not read (-Wuninitialized suppressed)
    in_callee: bool          # checking a call's callee: an unknown name is an
                             #   implicit C function (interop), not an error
    csteps: i32              # CTFE interpreter step budget
    cur_fname: const *char   # cname of the function being checked (for __func__)
    cur_ret: *Type           # return type of the function being checked
    loop_depth: i32          # nesting of while/do/for around the current stmt
    sw_depth: i32            # nesting of switch/match (break targets)
    vla_ctr: i32             # --std=c89: counter of hidden VLA pointers (__vlaN)
    lam_ctr: i32             # 65.4: counter for the lifted lambdas' names
    lam_pend: **Func         # lifted lambdas whose body is still to check
    nlam_pend: i32
    clam_pend: i32
    vla_hoist: **Stmt        # statements to hoist to the function entry (decls + defers)
    vla_nhoist: i32
    vla_choist: i32
    counter: i32             # __COUNTER__: increments on each use
    locals: *Sym             # scope stack (order + shadowing)
    nlocals: i32
    clocals: i32
    scopes: *i32             # marks the start of each scope in locals
    nscopes: i32
    cscopes: i32
    done: StrSet             # modules already registered (avoids cycle/duplicate)
    # every free function THIS module defines, mapped to the line it is defined
    # on. Declarations are registered as the file is walked, so a call to a name
    # that appears later has nothing to resolve against — this map is what lets
    # the diagnostic say "it is right there, below" instead of "no such thing".
    later_defs: StrMap<i64>
    # A complex statement expression `({ decl; ...; v })` in a NESTED position
    # (a call argument, say) has no standard-C spelling. It is hoisted here: the
    # block becomes a real statement in front of the enclosing one, and the
    # expression becomes a temporary. `se_pend` carries the blocks waiting to be
    # inserted (check_stmts drains them); `lazy_depth` marks the positions where
    # hoisting would be WRONG — a short-circuit's right operand or a ternary arm
    # must not run before the branch is taken.
    se_ctr: i32
    se_pend: **Stmt
    se_npend: i32
    se_cpend: i32
    lazy_depth: i32
    with_names: **char       # stack of hidden pointers of the active `with`s
    nwith: i32
    cwith: i32

    private def is_type_name(self: *Sema, n: const *char) -> bool
    private def add_type(self: *Sema, n: const *char)
    private def find_struct(self: *Sema, n: const *char) -> *SInfo
    private def find_func(self: *Sema, cname: const *char) -> *Func
    private def is_enum_const(self: *Sema, n: const *char) -> bool
    private def scope_push(self: *Sema)
    private def scope_pop(self: *Sema)
    private def scope_add_x(self: *Sema, name: const *char, t: *Type, is_extern: bool)
    private def deny_c_keyword(self: *Sema, name: const *char, pos: Pos)
    private def scope_add(self: *Sema, name: const *char, t: *Type)
    private def scope_find_cur(self: *Sema, name: const *char, was_extern: *bool) -> bool
    private def sym_index(self: *Sema, name: const *char) -> i32
    private def scope_find(self: *Sema, name: const *char) -> *Type
    private def find_template(self: *Sema, n: const *char) -> *Decl
    private def mangle_instance(self: *Sema, g: *Type) -> *char
    private def resolve_type(self: *Sema, t: *Type)
    private def check_pure_bytes(self: *Sema, si: *SInfo, d: *Decl)
    private def record_ctor(self: *Sema, e: *Expr, si: *SInfo)
    private def flatten_complit(self: *Sema, t: *Type, init: *Expr)
    private def complit_to_temp(self: *Sema, e: *Expr, si: *SInfo)
    private def fill_field(self: *Sema, dst: *Expr, t: *Type, src: *Expr, pos: Pos) -> *Expr
    private def comma_join(self: *Sema, acc: *Expr, one: *Expr, pos: Pos) -> *Expr
    private def record_eq(self: *Sema, e: *Expr) -> bool
    private def eq_operand(self: *Sema, e: *Expr, ref pre: *Expr) -> *Expr
    private def record_eq_chain(self: *Sema, si: *SInfo, a: *Expr, b: *Expr, pos: Pos) -> *Expr
    private def record_eq_value(self: *Sema, t: *Type, a: *Expr, b: *Expr, pos: Pos) -> *Expr
    private def eq_join(self: *Sema, acc: *Expr, one: *Expr, pos: Pos) -> *Expr
    private def mk_field(self: *Sema, base: *Expr, name: const *char, pos: Pos) -> *Expr
    private def const_len(self: *Sema, e: *Expr, ref out_n: i64) -> bool
    private def ns_module(self: *Sema, name: const *char) -> *Module
    private def ns_shadowed(self: *Sema, name: const *char) -> bool
    private def ns_has(self: *Sema, m: *Module, member: const *char) -> bool
    private def ns_plain(self: *Sema, dotted: const *char, pos: Pos) -> const *char
    private def try_ns_ref(self: *Sema, e: *Expr) -> bool
    private def clone_type(self: *Sema, sub: *Subst, t: *Type) -> *Type
    private def clone_expr(self: *Sema, sub: *Subst, e: *Expr) -> *Expr
    private def clone_stmt(self: *Sema, sub: *Subst, st: *Stmt) -> *Stmt
    private def clone_block(self: *Sema, sub: *Subst, b: *Block) -> *Block
    private def clone_func(self: *Sema, sub: *Subst, f: *Func, owner: const *char, with_body: bool) -> *Func
    private def type_of(self: *Sema, e: *Expr) -> *Type
    private def czero_expr(self: *Sema, t: *Type, pos: Pos) -> *Expr
    private def lower_designators(self: *Sema, e: *Expr, t: *Type)
    private def ceval_cast(self: *Sema, t: *Type, v: CVal) -> CVal
    private def ceval_val(self: *Sema, e: *Expr, env: *CFrame, ref ok: bool) -> CVal
    private def ccall(self: *Sema, f: *Func, e: *Expr, env: *CFrame, ref ok: bool) -> CVal
    private def cexec_block(self: *Sema, b: *Block, env: *CFrame, out ret: CVal, ref returned: bool, ref ok: bool)
    private def ceval(self: *Sema, e: *Expr, ref ok: bool) -> i64
    private def infer_type(self: *Sema, e: *Expr) -> *Type
    private def sugg_text(self: *Sema, sg: *Sugg) -> const *char
    private def hasfield_of(self: *Sema, e: *Expr) -> bool
    private def macro_alias_rewrite(self: *Sema, e: *Expr) -> bool
    private def known_type_name(self: *Sema, n: const *char) -> bool
    private def is_check_ptr(self: *Sema, e: *Expr)
    private def is_wrap_voidp(self: *Sema, e: *Expr) -> *Expr
    private def infer_array_len(self: *Sema, t: *Type, init: *Expr)
    private def require_complete(self: *Sema, t: *Type, pos: Pos)
    private def fold_const_dims(self: *Sema, t: *Type)
    private def vla_hoist_add(self: *Sema, st: *Stmt)
    private def materialize_temp(self: *Sema, e: *Expr, what: const *char) -> *Expr
    private def ensure_libc_proto(self: *Sema, name: const *char, ret: *Type)
    private def lower_vla_c89(self: *Sema, st: *Stmt) -> bool
    private def lam_fix(self: *Sema, e: *Expr, want: *Type)
    private def lam_pre_init(self: *Sema, t: *Type, init: *Expr)
    private def lam_no_capture(self: *Sema, b: *Expr, lam: *Expr)
    private def fstr_expand(self: *Sema, e: *Expr)
    private def fstr_conv(self: *Sema, hole: *Expr, spec: const *char, b: *StrBuf) -> *Expr
    private def fstr_is_str(self: *Sema, t: *Type) -> bool
    private def fold_predefined(self: *Sema, e: *Expr)
    private def fix_field_op(self: *Sema, e: *Expr)
    private def val_struct(self: *Sema, t: *Type) -> *SInfo
    private def check_void_array(self: *Sema, t: *Type, pos: Pos)
    private def require_scalar(self: *Sema, e: *Expr, what: const *char)
    private def static_const_ok(self: *Sema, e: *Expr) -> bool
    private def type_compat(self: *Sema, a: *Type, b: *Type) -> bool
    private def sinfo_field_deep(self: *Sema, si: *SInfo, name: const *char, depth: i32) -> bool
    private def check_cond_assign(self: *Sema, cond: *Expr)
    private def expr_no_effect(self: *Sema, e: *Expr) -> bool
    private def stmt_exits_c(self: *Sema, st: *Stmt) -> bool
    private def in_one_cmp(self: *Sema, needle: *Expr, elt: *Expr, str_needle: bool, pos: Pos) -> *Expr
    private def type_is_string(self: *Sema, t: *Type) -> bool
    private def in_or_chain(self: *Sema, cmps: **Expr, n: i32, pos: Pos) -> *Expr
    private def lower_in(self: *Sema, e: *Expr)
    private def lower_match_strings(self: *Sema, st: *Stmt)
    private def resolve_call_args(self: *Sema, e: *Expr, fn: *Func, skip: i32)
    private def check_byref_kw(self: *Sema, a: *Expr, fn: *Func, pi: i32)
    private def byref_write_base(self: *Sema, e: *Expr) -> i32
    private def func_designator(self: *Sema, e: *Expr) -> *Func
    private def nn_save(self: *Sema) -> *i32
    private def nn_restore(self: *Sema, snap: *i32)
    private def nn_clear_all(self: *Sema)
    private def nn_of_expr(self: *Sema, e: *Expr) -> i32
    private def nn_assign(self: *Sema, lhs: *Expr, v: i32)
    private def apply_cond_facts(self: *Sema, e: *Expr, branch_true: bool)
    private def nn_kill_writes(self: *Sema, b: *Block)
    private def null_deref_check(self: *Sema, base: *Expr, pos: Pos)
    private def bind_ref(self: *Sema, e: *Expr, reft: *Type, pos: Pos, what: const *char) -> *Expr
    private def check_ref_var(self: *Sema, st: *Stmt)
    private def lower_coalesce(self: *Sema, e: *Expr)
    private def check_assign_types(self: *Sema, pos: Pos, lt: *Type, rt: *Type, rhs: *Expr)
    private def init_leaf(self: *Sema, t: *Type, e: *Expr)
    private def init_arg_class(self: *Sema, e: *Expr) -> i32
    private def init_walkable(self: *Sema, t: *Type) -> bool
    private def init_fill_flat(self: *Sema, t: *Type, args: **Expr, nargs: i32, ref idx: i32)
    private def check_init(self: *Sema, t: *Type, init: *Expr, pos: Pos)
    private def require_defined(self: *Sema, t: *Type, pos: Pos)
    private def check_compound_types(self: *Sema, pos: Pos, op: i32, lhs: *Expr, rhs: *Expr)
    private def check_binop_types(self: *Sema, e: *Expr)
    private def resolve_gcall(self: *Sema, e: *Expr)
    private def check_expr(self: *Sema, e: *Expr)
    private def check_defer_body(self: *Sema, b: *Block, loop_depth: i32, break_depth: i32)
    private def tm_decay(self: *Sema, t: *Type) -> *Type
    private def resolve_typematch(self: *Sema, st: *Stmt)
    private def check_stmt(self: *Sema, st: *Stmt)
    private def block_prepend(self: *Sema, b: *Block, st: *Stmt)
    private def lower_for_iter(self: *Sema, st: *Stmt, d1: **Stmt, d2: **Stmt)
    private def lower_for_iterable(self: *Sema, st: *Stmt, at: *Type, d1: **Stmt, d2: **Stmt)
    private def check_stmts(self: *Sema, b: *Block)
    private def check_block(self: *Sema, b: *Block)
    private def walk_labels(self: *Sema, b: *Block, ref names: **char, ref n: i32, ref cap: i32, ref poss: *Pos, ref cap2: i32)
    private def walk_gotos(self: *Sema, b: *Block, names: **char, n: i32)
    private def switch_collect_cases(self: *Sema, b: *Block, ref vals: *i64, ref n: i32, ref cap: i32, ref poss: *Pos, ref cap2: i32, ref ndef: i32, ref defpos: Pos, mask: u64)
    private def check_switch_dups(self: *Sema, b: *Block)
    private def check_enum_exhaustive(self: *Sema, pos: Pos, subj: *Type, vals: *i64, n: i32, has_default: bool, what: const *char)
    private def check_func_body(self: *Sema, f: *Func)
    private def register_func(self: *Sema, f: *Func)
    private def cpp_capture(self: *Sema, flags: const *char, path: const *char, is_sys: bool, dir: const *char) -> const *char
    private def macro_put(self: *Sema, name: const *char, v: CVal)
    private def ingest_macros(self: *Sema, path: const *char, is_sys: bool, dir: const *char)
    private def ingest_c_header(self: *Sema, m: *Module, d: *Decl)
    private def instantiate(self: *Sema, m: *Module, d: *Decl, check_bodies: bool)
    private def trait_impl(self: *Sema, m: *Module, d: *Decl, check_bodies: bool)
    private def check_bound(self: *Sema, t: *Type, trait: const *char, tparam: const *char, pos: Pos)
    private def register_decl(self: *Sema, m: *Module, d: *Decl, check_bodies: bool)
    private def register_module(self: *Sema, m: *Module, check_bodies: bool)
    private def reg_builtin(self: *Sema, name: const *char, v: CVal)
    private def inject_predefined(self: *Sema, cc: *Cc)
    private def inject_defines(self: *Sema, cc: *Cc, m: *Module)

    # ---------- tables ----------
    private def is_type_name(self: *Sema, n: const *char) -> bool:
        return self->types.has(n)

    private def add_type(self: *Sema, n: const *char):
        self->types.add(n)

    private def find_struct(self: *Sema, n: const *char) -> *SInfo:
        return self->structs.get_or(n, None)

    private def find_func(self: *Sema, cname: const *char) -> *Func:
        return self->funcs.get_or(cname, None)

    private def is_enum_const(self: *Sema, n: const *char) -> bool:
        return self->enumconsts.has(n)

    private def scope_push(self: *Sema):
        self->scopes = vec_grow(self->scopes, self->nscopes, ref self->cscopes, sizeof(*self->scopes))
        self->scopes[self->nscopes] = self->nlocals
        self->nscopes += 1

    private def scope_pop(self: *Sema):
        self->nscopes -= 1
        base: i32 = self->scopes[self->nscopes]
        # -Wunused-variable (-Wall): tracked locals (pos set by ST_VAR) that were
        # never referenced. The C name-in-scope-from-declarator rule adds a var
        # TWICE — only the LAST entry for a name counts. (P and C alike)
        if not self->in_chdr:
            for ui in range(base, self->nlocals):
                if not self->locals[ui].used and self->locals[ui].pos.line != 0 and not self->locals[ui].is_extern and self->locals[ui].name != None and self->locals[ui].type != None and self->locals[ui].type->kind != TY_FUNC:
                    dup: bool = False
                    for uj in range(ui + 1, self->nlocals):
                        if strcmp(self->locals[uj].name, self->locals[ui].name) == 0:
                            dup = True
                            break
                    if not dup:
                        cdiag_at(self->file, self->locals[ui].pos, "unused-variable", WD_WALL, "unused variable '%s'", self->locals[ui].name)
                elif self->locals[ui].written and not self->locals[ui].read and self->locals[ui].pos.line != 0 and not self->locals[ui].is_extern and self->locals[ui].type != None and (is_arith_type(self->locals[ui].type) or self->locals[ui].type->kind == TY_PTR):
                    dup2: bool = False
                    for uk in range(ui + 1, self->nlocals):
                        if strcmp(self->locals[uk].name, self->locals[ui].name) == 0:
                            dup2 = True
                            break
                    if not dup2:
                        cdiag_at(self->file, self->locals[ui].pos, "unused-but-set-variable", WD_WALL, "variable '%s' set but not used", self->locals[ui].name)
        self->nlocals = base

    private def scope_add_x(self: *Sema, name: const *char, t: *Type, is_extern: bool):
        sym: Sym = {name, t, is_extern}
        self->locals = vec_grow(self->locals, self->nlocals, ref self->clocals, sizeof(*self->locals))
        self->locals[self->nlocals] = sym
        self->nlocals += 1

    private def scope_add(self: *Sema, name: const *char, t: *Type):
        self->scope_add_x(name, t, False)

    # is `name` declared in the CURRENT (innermost) scope? Used to reject
    # same-scope redeclaration; *was_extern reports the found decl's linkage.
    private def scope_find_cur(self: *Sema, name: const *char, was_extern: *bool) -> bool:
        lo: i32 = self->scopes[self->nscopes - 1] if self->nscopes > 0 else 0
        i: i32
        for i in range(self->nlocals - 1, lo - 1, -1):
            if strcmp(self->locals[i].name, name) == 0:
                *was_extern = self->locals[i].is_extern
                return True
        return False

    private def sym_index(self: *Sema, name: const *char) -> i32:
        j: i32
        for j in range(self->nlocals - 1, -1, -1):
            if strcmp(self->locals[j].name, name) == 0:
                return j
        return -1

    private def scope_find(self: *Sema, name: const *char) -> *Type:
        i: i32
        for i in range(self->nlocals - 1, -1, -1):
            if strcmp(self->locals[i].name, name) == 0:
                self->locals[i].used = True
                return self->locals[i].type
        # `nonlocal` names hoisted to function scope survive their block
        h: *Type = self->fn_hoisted.get_or(name, None)
        if h != None:
            return h
        return self->globals.get_or(name, None)

    # ---------- generics: mangling, resolution and cloning ----------
    private def find_template(self: *Sema, n: const *char) -> *Decl:
        return self->templates.get_or(n, None)

    # Vec<int> -> "Vec_int"; Vec<*char> -> "Vec_pchar"; Map<int, u32> -> "Map_int_u32"
    private def mangle_instance(self: *Sema, g: *Type) -> *char:
        sb: StrBuf = {0}
        defer sb.deinit()
        sb.puts(g->name)
        for i in range(g->ntargs):
            sb.puts("_")
            mangle_type_into(&sb, g->targs[i])
        return self->a->strdup(sb.data)

    # resolves generic references in types: Vec<int> becomes the mangled name
    # Vec_int (which must have been instantiated with declare)
    private def resolve_type(self: *Sema, t: *Type):
        if t == None:
            return
        if t->kind == TY_PTR or t->kind == TY_ARRAY:
            self->resolve_type(t->inner)
            return
        if t->kind == TY_FUNC:
            # function pointer: resolves return (inner) and param types
            # (kept in targs); does NOT mangle — TY_FUNC is never generic
            self->resolve_type(t->inner)
            for i0 in range(t->ntargs):
                self->resolve_type(t->targs[i0])
            return
        # `ns.Point` (42.4): strip the alias once it has been checked, and the
        # plain name goes on to resolve exactly as it always did
        if t->ns_qual and t->name != None:
            zp: Pos = {0}
            t->name = self->ns_plain(t->name, zp)
            t->ns_qual = False
        if t->ntargs == 0:
            if t->kind == TY_NAME and t->tag_kind == TAG_NONE and t->name != None:
                # a C-header typedef of a TAG (`regex_t`): switch to the TAG's
                # spelling — the layout is known under that name in both backends
                # (this is the only way QBE learns the real size).
                #
                # The type system stays CANONICAL on the tag: one spelling, so
                # comparison, layout and the round-trip all keep working. What
                # the C backend PRINTS is a separate question — for a P module it
                # prints the typedef again (see Module.tdrev), because that is
                # the spelling the emitted `#include` declares and the tag is
                # libc-internal (`struct _IO_FILE` is glibc's; macOS has no such
                # tag, so printing it made the output non-portable).
                ta: *Type = self->tdalias.get_or(t->name, None)
                if ta != None:
                    t->name = ta->name
                    t->tag_kind = ta->tag_kind
                    return
                tsi: *SInfo = self->find_struct(t->name)
                if tsi != None and tsi->c_tag:
                    # (with a same-named typedef around, `struct X` is still valid C)
                    t->tag_kind = TAG_UNION if tsi->is_union else TAG_STRUCT
            return
        for i in range(t->ntargs):
            self->resolve_type(t->targs[i])
        mangled: *char = self->mangle_instance(t)
        if not self->is_type_name(mangled):
            fatal("generic type '%s' not instantiated — 'declare' it before use", mangled)
        t->name = mangled
        t->targs = None
        t->ntargs = 0

    private def clone_type(self: *Sema, sub: *Subst, t: *Type) -> *Type:
        if t == None:
            return None
        if t->kind == TY_PTR:
            cpt: *Type = ty_ptr(self->a, self->clone_type(sub, t->inner))
            cpt->is_ref = t->is_ref   # `-> ref T` in a template stays a ref
            return cpt
        if t->kind == TY_ARRAY:
            return ty_array(self->a, self->clone_type(sub, t->inner), self->clone_expr(sub, t->arr_len))
        rep: *Type = subst_lookup(sub, t->name)
        if rep != None and t->ntargs == 0:
            return rep
        nt: *Type = ty_name(self->a, t->name)
        nt->is_const = t->is_const
        nt->is_volatile = t->is_volatile
        nt->is_restrict = t->is_restrict
        nt->tag_kind = t->tag_kind   # preserve `struct`/`union`/`enum` spelling
        if t->ntargs > 0:
            args: **Type = self->a->alloc(usize(t->ntargs) * sizeof(*args))
            for i in range(t->ntargs):
                args[i] = self->clone_type(sub, t->targs[i])
            nt->targs = args
            nt->ntargs = t->ntargs
        return nt

    private def clone_expr(self: *Sema, sub: *Subst, e: *Expr) -> *Expr:
        if e == None:
            return None
        # the name of a type parameter used as an expression (sizeof(T), T(x))
        # becomes a direct reference to the concrete type
        if e->kind == EX_IDENT:
            rep: *Type = subst_lookup(sub, e->text)
            if rep != None:
                tr: *Expr = ex_new(self->a, EX_TYPEREF, e->pos)
                tr->cast_type = rep
                return tr
        ne: *Expr = ex_new(self->a, e->kind, e->pos)
        with ne:
            .text = e->text
            .op = e->op
            .lhs = self->clone_expr(sub, e->lhs)
            .rhs = self->clone_expr(sub, e->rhs)
            .cond = self->clone_expr(sub, e->cond)
            .nargs = e->nargs
            if e->args != None:
                args: **Expr = self->a->alloc(usize(e->nargs) * sizeof(*args))
                for i in range(e->nargs):
                    args[i] = self->clone_expr(sub, e->args[i])
                .args = args
            .field = e->field
            .cast_type = self->clone_type(sub, e->cast_type)
            .cast_tentative = e->cast_tentative
        return ne

    private def clone_stmt(self: *Sema, sub: *Subst, st: *Stmt) -> *Stmt:
        ns: *Stmt = st_new(self->a, st->kind, st->pos)
        with ns:
            .name = st->name
            .type = self->clone_type(sub, st->type)
            .init = self->clone_expr(sub, st->init)
            .is_const = st->is_const
            .lhs = self->clone_expr(sub, st->lhs)
            .op = st->op
            .rhs = self->clone_expr(sub, st->rhs)
            .expr = self->clone_expr(sub, st->expr)
            if st->conds != None:
                nc: **Expr = self->a->alloc(usize(st->nconds) * sizeof(*nc))
                nb: **Block = self->a->alloc(usize(st->nconds) * sizeof(*nb))
                for i in range(st->nconds):
                    nc[i] = self->clone_expr(sub, st->conds[i])
                    nb[i] = self->clone_block(sub, st->blocks[i])
                .conds = nc
                .blocks = nb
            .nconds = st->nconds
            .else_block = self->clone_block(sub, st->else_block)
            .if_sel = st->if_sel
            .cond = self->clone_expr(sub, st->cond)
            .body = self->clone_block(sub, st->body)
            .var = st->var
            .from = self->clone_expr(sub, st->from)
            .to = self->clone_expr(sub, st->to)
            .step = self->clone_expr(sub, st->step)
            .subject = self->clone_expr(sub, st->subject)
            if st->cases != None:
                cs: **MatchCase = self->a->alloc(usize(st->ncases) * sizeof(*cs))
                for j in range(st->ncases):
                    oc: *MatchCase = st->cases[j]
                    mc: *MatchCase = self->a->alloc(sizeof(MatchCase))
                    with mc:
                        .is_default = oc->is_default
                        .nvals = oc->nvals
                        if oc->vals != None:
                            vs: **Expr = self->a->alloc(usize(oc->nvals) * sizeof(*vs))
                            for k in range(oc->nvals):
                                vs[k] = self->clone_expr(sub, oc->vals[k])
                            .vals = vs
                        .type_pat = self->clone_type(sub, oc->type_pat)   # match type: type of the case
                        .body = self->clone_block(sub, oc->body)
                    cs[j] = mc
                .cases = cs
            .ncases = st->ncases
            .is_typematch = st->is_typematch
            .tm_sel = st->tm_sel
            .label = st->label
        return ns

    private def clone_block(self: *Sema, sub: *Subst, b: *Block) -> *Block:
        if b == None:
            return None
        nb: *Block = self->a->alloc(sizeof(Block))
        stmts: **Stmt = self->a->alloc(usize(b->n) * sizeof(*stmts))
        for i in range(b->n):
            stmts[i] = self->clone_stmt(sub, b->stmts[i])
        nb->stmts = stmts
        nb->n = b->n
        return nb

    private def clone_func(self: *Sema, sub: *Subst, f: *Func, owner: const *char, with_body: bool) -> *Func:
        nf: *Func = self->a->alloc(sizeof(Func))
        *nf = *f
        nf->owner = owner
        nf->cname = self->a->printf("%s_%s", owner, f->name) if owner != None else f->name
        nf->tparams = None
        nf->ntparams = 0
        params: *Param = self->a->alloc(usize(f->nparams) * sizeof(*params))
        for i in range(f->nparams):
            params[i].name = f->params[i].name
            params[i].type = self->clone_type(sub, f->params[i].type)
            params[i].pos = f->params[i].pos
            params[i].dflt = f->params[i].dflt   # comptime constant: shareable
            params[i].byref = f->params[i].byref
        nf->params = params
        nf->ret = self->clone_type(sub, f->ret)
        nf->body = self->clone_block(sub, f->body) if with_body else None
        return nf

    private def type_of(self: *Sema, e: *Expr) -> *Type:
        if e == None:
            return None
        match e->kind:
            case EX_LAMBDA:
                fatal_at(self->file, e->pos, "a lambda needs a function type from what receives it (65.4/68.7): annotate the variable, the parameter or the return, as in `f: def(i32) -> i32 = lambda x: x * 2`")
            case EX_FSTRING:
                fatal_at(self->file, e->pos, "an f-string only works as the format argument of a variadic call (65.2): it is resolved at COMPILE TIME into a format plus arguments, and P has no runtime to build a string with")
            case EX_ASSIGN:
                return self->type_of(e->lhs)
            case EX_COMPOUND:
                return e->cast_type    # `(T){...}` IS a value of T
            case EX_COMMA:
                return self->type_of(e->rhs)   # the comma operator yields its RIGHT side
            case EX_IN:
                return ty_name(self->a, "bool")
            case EX_WALRUS:
                return self->type_of(e->lhs)
            case EX_IDENT:
                t: *Type = self->scope_find(e->text)
                if t != None:
                    return t
                if self->is_enum_const(e->text):
                    return ty_name(self->a, "int")
                return None
            case EX_NUMBER:
                txt: const *char = e->text
                ishex: bool = txt[0] == '0' and (txt[1] == 'x' or txt[1] == 'X')
                isflt: bool = False
                if not ishex:
                    c: const *char = txt
                    while *c != '\0':
                        if *c == '.' or *c == 'e' or *c == 'E':
                            isflt = True
                            break
                        c += 1
                # suffix from the end (in hex, f/F is a digit, not a float suffix)
                hasf: bool = False
                hasu: bool = False
                nl = 0
                i: i32 = i32(strlen(txt))
                while i > 0:
                    ch: char = txt[i - 1]
                    if ch == 'l' or ch == 'L':
                        nl += 1
                        i -= 1
                    elif ch == 'u' or ch == 'U':
                        hasu = True
                        i -= 1
                    elif not ishex and (ch == 'f' or ch == 'F'):
                        hasf = True
                        i -= 1
                    else:
                        break
                if isflt or hasf:
                    return ty_name(self->a, "float" if hasf else "double")
                base: const *char = "int"
                if nl >= 2:
                    base = "long long"
                elif nl == 1:
                    base = "long"
                if hasu:
                    base = "unsigned" if base == "int" else self->a->printf("unsigned %s", base)
                return ty_name(self->a, base)
            case EX_STRING:
                return ty_ptr(self->a, ty_name(self->a, "char"))
            case EX_CHARLIT:
                return ty_name(self->a, "char")
            case EX_TRUE, EX_FALSE:
                return ty_name(self->a, "int")
            case EX_NONE:
                return ty_ptr(self->a, ty_name(self->a, "void"))
            case EX_UNARY:
                if e->op == TK_STAR:
                    return strip_ptr_or_array(self->type_of(e->lhs))
                if e->op == TK_AMP:
                    t2: *Type = self->type_of(e->lhs)
                    return ty_ptr(self->a, t2) if t2 != None else None
                if e->op == TK_NOT:
                    return ty_name(self->a, "int")
                return self->type_of(e->lhs)
            case EX_BINARY:
                match e->op:
                    case TK_EQ, TK_NE, TK_LT, TK_LE, TK_GT, TK_GE, TK_AND, TK_OR:
                        return ty_name(self->a, "int")
                    case _:
                        t3: *Type = self->type_of(e->lhs)
                        tr3: *Type = self->type_of(e->rhs)
                        bl: bool = t3 != None and (t3->kind == TY_PTR or t3->kind == TY_ARRAY)
                        br: bool = tr3 != None and (tr3->kind == TY_PTR or tr3->kind == TY_ARRAY)
                        # ptr - ptr is a POINTER DIFFERENCE: an integer (ptrdiff)
                        if e->op == TK_MINUS and bl and br:
                            return ty_name(self->a, "isize")
                        # ptr ± int: the pointer wins, whichever side it is on
                        if bl:
                            return t3
                        if br:
                            return tr3
                        # for +/- an UNKNOWN side poisons the result: the other
                        # operand might be the pointer (unknown_call() + 1)
                        if (e->op == TK_PLUS or e->op == TK_MINUS) and (t3 == None or tr3 == None):
                            return None
                        return t3 if t3 != None else tr3
            case EX_TERNARY:
                t4: *Type = self->type_of(e->lhs)
                t4r: *Type = self->type_of(e->rhs)
                # one arm pointer, the other a null constant (or plain int): the
                # result is the POINTER type (C ternary conversion)
                if t4 != None and t4->kind == TY_PTR and t4r != None and t4r->kind == TY_PTR:
                    # one arm void*: the composite result IS void* (C11 6.5.15p6)
                    if is_void_val(t4->inner):
                        return t4
                    if is_void_val(t4r->inner):
                        return t4r
                if t4 != None and (t4->kind == TY_PTR or t4->kind == TY_ARRAY):
                    return t4
                if t4r != None and (t4r->kind == TY_PTR or t4r->kind == TY_ARRAY):
                    return t4r
                return t4 if t4 != None else t4r
            case EX_CALL:
                if e->lhs != None and e->lhs->kind == EX_IDENT:
                    fu: *Func = self->find_func(e->lhs->text)
                    if fu != None:
                        return fu->ret
                # callee is an expression of function-pointer type (a variable or a
                # struct field): the result type is the function type's return (inner).
                ct: *Type = self->type_of(e->lhs)
                if ct != None and ct->kind == TY_PTR and ct->inner != None and ct->inner->kind == TY_FUNC:
                    return ct->inner->inner
                if ct != None and ct->kind == TY_FUNC:
                    return ct->inner
                return None
            case EX_CAST, EX_VAARG:
                return e->cast_type
            case EX_INDEX:
                return strip_ptr_or_array(self->type_of(e->lhs))
            case EX_FIELD:
                t5: *Type = self->type_of(e->lhs)
                if t5 != None and (t5->kind == TY_PTR or t5->kind == TY_ARRAY):
                    t5 = t5->inner
                if t5 == None or t5->kind != TY_NAME:
                    return None
                si: *SInfo = self->find_struct(t5->name)
                if si == None:
                    return None
                fl: *Field = sinfo_field(si, e->field)
                return fl->type if fl != None else None
            case EX_WITHSELF:
                if self->nwith > 0:
                    return self->scope_find(self->with_names[self->nwith - 1])
                return None
            case _:
                return None

    # ---------- --std=c89: designators -> positional ----------
    # Designators in an initializer are C99. Under --std=c89 sema lowers them to
    # positional form: values in layout order, with zeros in the gaps that
    # PRECEDE explicit values (C89 already zeroes the rest). "{0}" zeroes aggregates.
    private def czero_expr(self: *Sema, t: *Type, pos: Pos) -> *Expr:
        z: *Expr = ex_new(self->a, EX_NUMBER, pos)
        z->text = "0"
        if t != None and (t->kind == TY_ARRAY or (t->kind == TY_NAME and self->find_struct(t->name) != None)):
            w: *Expr = ex_new(self->a, EX_INITLIST, pos)
            wa: **Expr = self->a->alloc(sizeof(*wa))
            wa[0] = z
            w->args = wa; w->nargs = 1
            return w
        return z

    private def lower_designators(self: *Sema, e: *Expr, t: *Type):
        if e == None or e->kind != EX_INITLIST or t == None:
            return
        if t->kind == TY_ARRAY:
            elem: *Type = t->inner
            has_desig: bool = False
            maxp: i32 = -1
            pos = 0
            for i in range(e->nargs):
                it: *Expr = e->args[i]
                val: *Expr = it
                if it != None and it->kind == EX_DESIG and it->rhs != None:
                    has_desig = True
                    pos = i32(strtoll(it->rhs->text, None, 0))   # index already folded to a literal
                    val = it->lhs
                self->lower_designators(val, elem)
                if pos > maxp:
                    maxp = pos
                pos += 1
            if not has_desig:
                return
            n: i32 = maxp + 1
            args: **Expr = self->a->alloc(usize(n) * sizeof(*args))
            for k in range(n):
                args[k] = None
            pos = 0
            for i in range(e->nargs):
                it2: *Expr = e->args[i]
                val2: *Expr = it2
                if it2 != None and it2->kind == EX_DESIG and it2->rhs != None:
                    pos = i32(strtoll(it2->rhs->text, None, 0))
                    val2 = it2->lhs
                args[pos] = val2
                pos += 1
            for k in range(n):
                if args[k] == None:
                    args[k] = self->czero_expr(elem, e->pos)
            e->args = args; e->nargs = n
            return
        if t->kind != TY_NAME:
            return
        si: *SInfo = self->find_struct(t->name)
        if si == None:
            return
        if si->is_union:
            # C89 only initializes the FIRST member of the union: a designator for
            # another member has no equivalent positional form
            for u in range(e->nargs):
                ud: *Expr = e->args[u]
                if ud != None and ud->kind == EX_DESIG and ud->field != None:
                    if si->nfields > 0 and strcmp(ud->field, si->fields[0].name) == 0:
                        self->lower_designators(ud->lhs, si->fields[0].type)
                        e->args[u] = ud->lhs   # .first = v  ->  v
                    else:
                        fatal_at(self->file, ud->pos, "union designated initializer for a non-first member requires C99 (not available under --std=c89)")
            return
        has_f: bool = False
        maxf: i32 = -1
        fi = 0
        for i2 in range(e->nargs):
            it3: *Expr = e->args[i2]
            val3: *Expr = it3
            if it3 != None and it3->kind == EX_DESIG and it3->field != None:
                has_f = True
                fl: *Field = sinfo_field(si, it3->field)
                if fl == None:
                    return   # unknown field: leave as is (error further ahead)
                fi = i32(fl - si->fields)
                val3 = it3->lhs
            ft: *Type = si->fields[fi].type if fi < si->nfields else None
            self->lower_designators(val3, ft)
            if fi > maxf:
                maxf = fi
            fi += 1
        if not has_f:
            return
        nf: i32 = maxf + 1
        fargs: **Expr = self->a->alloc(usize(nf) * sizeof(*fargs))
        for k2 in range(nf):
            fargs[k2] = None
        fi = 0
        for i2 in range(e->nargs):
            it4: *Expr = e->args[i2]
            val4: *Expr = it4
            if it4 != None and it4->kind == EX_DESIG and it4->field != None:
                fl2: *Field = sinfo_field(si, it4->field)
                fi = i32(fl2 - si->fields)
                val4 = it4->lhs
            fargs[fi] = val4
            fi += 1
        for k2 in range(nf):
            if fargs[k2] == None:
                fargs[k2] = self->czero_expr(si->fields[k2].type if k2 < si->nfields else None, e->pos)
        e->args = fargs; e->nargs = nf

    # constant-fold a cast: an integer cast to a narrower type must TRUNCATE
    # ((char)300 == 44), and int<->float conversions must round toward zero, or a
    # compile-time `if ((char)300 != 44)` prunes the wrong branch (00216, chars).
    private def ceval_cast(self: *Sema, t: *Type, v: CVal) -> CVal:
        if t == None or t->kind != TY_NAME:
            return v   # cast to pointer/array/etc: value unchanged
        n: const *char = t->name
        isflt: bool = n in {"float", "double", "f32", "f64", "long double"}
        if isflt:
            return cv_flt(cv_asf(v))
        # target is integral: start from the integer value (truncate a float)
        iv: i64 = v.ival if v.kind == CV_INT else i64(v.fval)
        w: i32 = ctype_width(n)      # bytes of the target integer type (0 = unknown)
        uns: bool = ctype_unsigned(n)
        if w == 1:
            return cv_int(i64(u8(iv)) if uns else i64(i8(iv)))
        if w == 2:
            return cv_int(i64(u16(iv)) if uns else i64(i16(iv)))
        if w == 4:
            return cv_int(i64(u32(iv)) if uns else i64(i32(iv)))
        return cv_int(iv)            # 8 bytes or unknown: no truncation

    # evaluates `e` to a compile-time value. *ok=False if not computable.
    private def ceval_val(self: *Sema, e: *Expr, env: *CFrame, ref ok: bool) -> CVal:
        self->csteps += 1
        if self->csteps > 8000000:
            fatal_at(self->file, e->pos, "const evaluation exceeded step budget (infinite loop in a 'const def'?)")
        if e == None:
            ok = False
            return cv_int(0)
        match e->kind:
            case EX_NUMBER:
                return ceval_num(e->text)
            case EX_CHARLIT:
                return cv_int(ceval_char(e->text))
            case EX_STRING:
                return cv_str(e->text)
            case EX_TRUE:
                return cv_int(1)
            case EX_FALSE:
                return cv_int(0)
            case EX_IDENT:
                fv: CVal
                if env->find(e->text, out fv):
                    return fv
                cp: *CVal = self->constvals.get_or(e->text, None)
                if cp != None:
                    return *cp
                # positional predefined identifiers are also valid in a constant context
                if e->text == "__LINE__":
                    return cv_int(i64(e->pos.line))
                if e->text == "__FILE__":
                    return cv_str(self->a->printf("\"%s\"", self->file))
                ok = False
                return cv_int(0)
            case EX_CAST:
                if is_void_val(e->cast_type):
                    ok = False   # a (void) cast has no value
                    return cv_int(0)
                cvv: CVal = self->ceval_val(e->lhs, env, ref ok)
                return self->ceval_cast(e->cast_type, cvv)
            case EX_UNARY:
                v: CVal = self->ceval_val(e->lhs, env, ref ok)
                if v.kind == CV_STR:
                    # a string literal's address is never null: !"..." == 0;
                    # any other unary op on a string is not a constant
                    if e->op == TK_NOT:
                        return cv_int(0)
                    ok = False
                    return cv_int(0)
                if e->op == TK_MINUS:
                    return cv_flt(-v.fval) if v.kind == CV_FLOAT else cv_int(-v.ival)
                if e->op == TK_PLUS:
                    return v
                if e->op == TK_NOT:
                    return cv_int(0 if cv_asf(v) != 0.0 else 1)
                if e->op == TK_TILDE and v.kind == CV_INT:
                    return cv_int(~v.ival)
                ok = False
                return cv_int(0)
            case EX_BINARY:
                a: CVal = self->ceval_val(e->lhs, env, ref ok)
                b: CVal = self->ceval_val(e->rhs, env, ref ok)
                # strings: equality only
                if a.kind == CV_STR or b.kind == CV_STR:
                    if a.kind == CV_STR and b.kind == CV_STR and (e->op == TK_EQ or e->op == TK_NE):
                        eq: bool = strcmp(a.sval, b.sval) == 0
                        return cv_int(1 if (eq == (e->op == TK_EQ)) else 0)
                    ok = False
                    return cv_int(0)
                usef: bool = a.kind == CV_FLOAT or b.kind == CV_FLOAT
                if usef:
                    fa: f64 = cv_asf(a)
                    fb: f64 = cv_asf(b)
                    match e->op:
                        case TK_PLUS:
                            return cv_flt(fa + fb)
                        case TK_MINUS:
                            return cv_flt(fa - fb)
                        case TK_STAR:
                            return cv_flt(fa * fb)
                        case TK_SLASH:
                            return cv_flt(fa / fb if fb != 0.0 else 0.0)
                        case TK_EQ:
                            return cv_int(1 if fa == fb else 0)
                        case TK_NE:
                            return cv_int(1 if fa != fb else 0)
                        case TK_LT:
                            return cv_int(1 if fa < fb else 0)
                        case TK_LE:
                            return cv_int(1 if fa <= fb else 0)
                        case TK_GT:
                            return cv_int(1 if fa > fb else 0)
                        case TK_GE:
                            return cv_int(1 if fa >= fb else 0)
                        case _:
                            ok = False
                            return cv_int(0)
                ia: i64 = a.ival
                ib: i64 = b.ival
                match e->op:
                    case TK_PLUS:
                        return cv_int(ia + ib)
                    case TK_MINUS:
                        return cv_int(ia - ib)
                    case TK_STAR:
                        return cv_int(ia * ib)
                    case TK_SLASH:
                        return cv_int(ia / ib if ib != 0 else 0)
                    case TK_PERCENT:
                        return cv_int(ia % ib if ib != 0 else 0)
                    case TK_AMP:
                        return cv_int(ia & ib)
                    case TK_PIPE:
                        return cv_int(ia | ib)
                    case TK_CARET:
                        return cv_int(ia ^ ib)
                    case TK_SHL:
                        return cv_int(ia << ib)
                    case TK_SHR:
                        return cv_int(ia >> ib)
                    case TK_EQ:
                        return cv_int(1 if ia == ib else 0)
                    case TK_NE:
                        return cv_int(1 if ia != ib else 0)
                    case TK_LT:
                        return cv_int(1 if ia < ib else 0)
                    case TK_LE:
                        return cv_int(1 if ia <= ib else 0)
                    case TK_GT:
                        return cv_int(1 if ia > ib else 0)
                    case TK_GE:
                        return cv_int(1 if ia >= ib else 0)
                    case TK_AND:
                        return cv_int(1 if (ia != 0 and ib != 0) else 0)
                    case TK_OR:
                        return cv_int(1 if (ia != 0 or ib != 0) else 0)
                    case _:
                        ok = False
                        return cv_int(0)
            case EX_TERNARY:
                c: CVal = self->ceval_val(e->cond, env, ref ok)
                return self->ceval_val(e->lhs, env, ref ok) if cv_asf(c) != 0.0 else self->ceval_val(e->rhs, env, ref ok)
            case EX_CALL:
                if e->lhs != None and e->lhs->kind == EX_IDENT:
                    # is_defined(NAME): known const? (for pruning `if is_defined(...)`)
                    if e->lhs->text == "is_defined" and e->nargs == 1 and e->args[0]->kind == EX_IDENT:
                        return cv_int(1 if self->constvals.has(e->args[0]->text) else 0)
                    # typestr(x): static type as a string — comptime-foldable, so
                    # `if typestr(x) == "*char":` prunes at compile time (like match type)
                    if e->lhs->text == "typestr" and e->nargs == 1:
                        return cv_str(self->a->printf("\"%s\"", render_type_p(self->a, self->type_of(e->args[0]))))
                    # hasfield(x, "name"): member present? This is the path the
                    # ST_IF pruning takes, and it runs BEFORE check_expr folds the
                    # node — so the answer has to be available here too
                    if e->lhs->text == "hasfield" and e->nargs == 2:
                        return cv_int(1 if self->hasfield_of(e) else 0)
                    # len(arr): element count of a fixed array T[N]. In a comptime
                    # context (e.g. an array dimension) it folds straight to N; in a
                    # value context check_expr already lowered it to sizeof/sizeof.
                    if e->lhs->text == "len" and e->nargs == 1 and self->find_func(e->lhs->text) == None:
                        at: *Type = self->type_of(e->args[0])
                        if at != None and at->kind == TY_ARRAY and at->arr_len != None:
                            return self->ceval_val(at->arr_len, env, ref ok)
                        ok = False
                        return cv_int(0)
                    cf: *Func = self->find_func(e->lhs->text)
                    if cf != None and cf->is_comptime:
                        return self->ccall(cf, e, env, ref ok)
                ok = False
                return cv_int(0)
            case _:
                ok = False
                return cv_int(0)

    # executes a `const def`: binds params to args (evaluated by the caller) and runs
    # the body in a new frame. Returns the return value.
    private def ccall(self: *Sema, f: *Func, e: *Expr, env: *CFrame, ref ok: bool) -> CVal:
        if f->body == None or e->nargs != f->nparams:
            ok = False
            return cv_int(0)
        fr: CFrame
        fr.init(self->a, f->nparams + 128)
        for i in range(f->nparams):
            av: CVal = self->ceval_val(e->args[i], env, ref ok)
            fr.set(f->params[i].name, av)
        ret: CVal = cv_int(0)
        returned: bool = False
        self->cexec_block(f->body, &fr, out ret, ref returned, ref ok)
        return ret

    # executes a block of statements in a CTFE frame
    private def cexec_block(self: *Sema, b: *Block, env: *CFrame, out ret: CVal, ref returned: bool, ref ok: bool):
        if b == None:
            return
        for i in range(b->n):
            if returned or not ok:
                return
            st: *Stmt = b->stmts[i]
            self->csteps += 1
            if self->csteps > 8000000:
                fatal_at(self->file, st->pos, "const evaluation exceeded step budget (infinite loop in a 'const def'?)")
            match st->kind:
                case ST_VAR:
                    env->set(st->name, self->ceval_val(st->init, env, ref ok) if st->init != None else cv_int(0))
                case ST_ASSIGN:
                    if st->lhs == None or st->lhs->kind != EX_IDENT:
                        ok = False
                        return
                    cur: CVal = cv_int(0)
                    cur_ok: bool = env->find(st->lhs->text, out cur)
                    rv: CVal = self->ceval_val(st->rhs, env, ref ok)
                    if st->op == TK_ASSIGN:
                        env->set(st->lhs->text, rv)
                    elif cur_ok:
                        # compound op (+=, -=, ...): applies over int/float
                        if cur.kind == CV_FLOAT or rv.kind == CV_FLOAT:
                            fa: f64 = cv_asf(cur)
                            fb: f64 = cv_asf(rv)
                            nf: f64 = fa
                            if st->op == TK_PLUS_EQ:
                                nf = fa + fb
                            elif st->op == TK_MINUS_EQ:
                                nf = fa - fb
                            elif st->op == TK_STAR_EQ:
                                nf = fa * fb
                            elif st->op == TK_SLASH_EQ:
                                nf = fa / fb if fb != 0.0 else 0.0
                            else:
                                ok = False
                                return
                            env->set(st->lhs->text, cv_flt(nf))
                        else:
                            ni: i64 = cur.ival
                            rb: i64 = rv.ival
                            if st->op == TK_PLUS_EQ:
                                ni = ni + rb
                            elif st->op == TK_MINUS_EQ:
                                ni = ni - rb
                            elif st->op == TK_STAR_EQ:
                                ni = ni * rb
                            elif st->op == TK_SLASH_EQ:
                                ni = ni / rb if rb != 0 else 0
                            elif st->op == TK_PERCENT_EQ:
                                ni = ni % rb if rb != 0 else 0
                            elif st->op == TK_AMP_EQ:
                                ni = ni & rb
                            elif st->op == TK_PIPE_EQ:
                                ni = ni | rb
                            elif st->op == TK_CARET_EQ:
                                ni = ni ^ rb
                            elif st->op == TK_SHL_EQ:
                                ni = ni << rb
                            elif st->op == TK_SHR_EQ:
                                ni = ni >> rb
                            else:
                                ok = False
                                return
                            env->set(st->lhs->text, cv_int(ni))
                    else:
                        ok = False
                        return
                case ST_RETURN:
                    ret = self->ceval_val(st->expr, env, ref ok) if st->expr != None else cv_int(0)
                    returned = True
                    return
                case ST_EXPR:
                    self->ceval_val(st->expr, env, ref ok)
                case ST_IF:
                    j: i32
                    done: bool = False
                    for j in range(st->nconds):
                        cvj: CVal = self->ceval_val(st->conds[j], env, ref ok)
                        if cv_asf(cvj) != 0.0:
                            self->cexec_block(st->blocks[j], env, out ret, ref returned, ref ok)
                            done = True
                            break
                    if not done and st->else_block != None:
                        self->cexec_block(st->else_block, env, out ret, ref returned, ref ok)
                case ST_WHILE:
                    while cv_asf(self->ceval_val(st->cond, env, ref ok)) != 0.0 and ok and not returned:
                        self->cexec_block(st->body, env, out ret, ref returned, ref ok)
                case ST_FOR:
                    lo: CVal = self->ceval_val(st->from, env, ref ok) if st->from != None else cv_int(0)
                    hi: CVal = self->ceval_val(st->to, env, ref ok)
                    stp: CVal = self->ceval_val(st->step, env, ref ok) if st->step != None else cv_int(1)
                    iv: i64 = lo.ival
                    while iv < hi.ival and ok and not returned:
                        env->set(st->var, cv_int(iv))
                        self->cexec_block(st->body, env, out ret, ref returned, ref ok)
                        iv += stp.ival
                case _:
                    ok = False
                    return

    # evaluates `e` as a constant integer (context requiring int: dim, case, if).
    private def ceval(self: *Sema, e: *Expr, ref ok: bool) -> i64:
        v: CVal = self->ceval_val(e, None, ref ok)
        if v.kind == CV_FLOAT:
            return i64(v.fval)
        if v.kind == CV_STR:
            ok = False
            return 0
        return v.ival

    # type inferred for an initializer; an integer-constant expression (refs to
    # `const`) that type_of can't resolve falls back to `int`.
    private def infer_type(self: *Sema, e: *Expr) -> *Type:
        t: *Type = self->type_of(e)
        if t != None:
            return t
        cok: bool = True
        self->ceval(e, ref cok)
        if cok:
            return ty_name(self->a, "int")
        return None

    # " (did you mean 'X'?)" when a candidate is close enough, else ""
    private def sugg_text(self: *Sema, sg: *Sugg) -> const *char:
        lim: i32 = 1 + i32(strlen(sg->name)) / 4
        if lim > 3:
            lim = 3
        if sg->best != None and sg->bestd > 0 and sg->bestd <= lim:
            return self->a->printf(" (did you mean '%s'?)", sg->best)
        return ""

    # hasfield(x, "name") — does x's struct/union declare that member? Answered at
    # compile time, so `if hasfield(...)` prunes and the DEAD branch is never
    # type-checked (ST_IF, check_stmt): a branch may legitimately name a member
    # this platform's libc does not have.
    #
    # Called from BOTH check_expr (which folds the node to True/False) and ceval
    # (which is what the ST_IF pruning consults) — the fold in ST_IF runs before
    # check_expr ever sees the condition, so handling only one is not enough.
    private def hasfield_of(self: *Sema, e: *Expr) -> bool:
        ht: *Type = e->args[0]->cast_type if e->args[0]->kind == EX_TYPEREF else self->type_of(e->args[0])
        while ht != None and ht->kind == TY_PTR:   # hasfield(p, "x") asks about *p
            ht = ht->inner
        if ht == None or ht->kind != TY_NAME:
            fatal_at(self->file, e->pos, "hasfield: first argument must be a struct or union (or a pointer to one)")
        if e->args[1]->kind != EX_STRING or e->args[1]->text == None:
            fatal_at(self->file, e->pos, "hasfield: second argument must be a string literal naming the member")
        hsi: *SInfo = self->find_struct(ht->name)
        if hsi == None:
            fatal_at(self->file, e->pos, "hasfield: '%s' is not a known struct or union", ht->name)
        for hi in range(hsi->nfields):
            # the literal still carries its quotes: compare against the quoted
            # spelling rather than unquoting it
            if hsi->fields[hi].name != None and strcmp(e->args[1]->text, self->a->printf("\"%s\"", hsi->fields[hi].name)) == 0:
                return True
        return False

    # `#define NAME OTHER` from a C header, where OTHER is a declared object or
    # function: rewrite the identifier to OTHER in place. True if it rewrote.
    # Only ever consulted for a name that resolves nowhere else, so it cannot
    # shadow a real declaration. Both a plain reference and a CALL need it — the
    # call path checks its callee separately and would otherwise report an
    # implicit function declaration.
    private def macro_alias_rewrite(self: *Sema, e: *Expr) -> bool:
        if e == None or e->kind != EX_IDENT or e->text == None:
            return False
        # follows a CHAIN (`#define a b` / `#define b c`), bounded the same way the
        # constant-alias passes above are: real chains are one or two links, and a
        # bound means a cyclic #define cannot spin here
        cur: *char = (*char)(e->text)
        hop: i32 = 0
        while hop < 4:
            nxt: *char = self->macroalias.get_or(cur, None)
            if nxt == None:
                break
            cur = nxt
            if self->globals.get_or(cur, None) != None or self->find_func(cur) != None:
                e->text = cur
                return True
            hop += 1
        return False

    private def known_type_name(self: *Sema, n: const *char) -> bool:
        if self->types.has(n):
            return True
        return is_c_arith_words(n)

    # `is` operates on POINTERS (identity): a value operand of a known non-pointer
    # type gets a friendly error steering to ==
    private def is_check_ptr(self: *Sema, e: *Expr):
        if e == None or e->kind == EX_NONE or e->kind == EX_STRING:
            return
        t: *Type = self->type_of(e)
        if t == None:
            return   # unknown (opaque/C interop): trust the user
        if t->kind in {TY_PTR, TY_ARRAY, TY_FUNC}:
            return
        tn: const *char = t->name if t->name != None else "?"
        fatal_at(self->file, e->pos, "'is' compares pointer IDENTITY, but this operand is a value of type '%s' — use == for value equality (or compare &addresses)", tn)

    private def is_wrap_voidp(self: *Sema, e: *Expr) -> *Expr:
        if e == None or e->kind == EX_NONE:
            return e   # None is already the untyped null pointer
        c: *Expr = ex_new(self->a, EX_CAST, e->pos)
        c->cast_type = ty_ptr(self->a, ty_name(self->a, "void"))
        c->lhs = e
        return c

    # `xs: T[] = {a, b, c}` — the element COUNT is right there in the initializer:
    # fill in arr_len so the type is complete (len(xs), comptime sizes). Skipped
    # when a designator is present (the count is not simply nargs).
    private def infer_array_len(self: *Sema, t: *Type, init: *Expr):
        if t == None or t->kind != TY_ARRAY or t->arr_len != None:
            return
        if init == None:
            return
        # `X: const u8[] = embed_bytes("f")` — the file's own size IS the length.
        # C would give size+1 here (the literal's nul), which is right for text
        # and wrong for bytes, so embed_bytes drops it: `len(X)` is the file size.
        # A hand-written `char x[] = "abc"` keeps its C behaviour (no arr_len,
        # the target sizes it) — this infers only what embed introduced.
        if init->kind == EX_STRING and init->embed_path != None:
            sel: *Type = t->inner
            if sel == None or sel->kind != TY_NAME or ctype_width(sel->name) != 1:
                return
            units: i32 = init_str_units(init->text)
            if units < 0:
                return
            slit: *Expr = ex_new(self->a, EX_NUMBER, init->pos)
            slit->text = self->a->printf("%d", units if init->embed_bin else units + 1)
            t->arr_len = slit
            return
        if init->kind != EX_INITLIST:
            return
        # aggregate elements (struct/array) may use C brace ELISION — a flat scalar
        # list where nargs is NOT the element count. Only infer when the element is
        # scalar, or when every element is explicitly braced.
        elem: *Type = t->inner
        agg: bool = elem != None and (elem->kind == TY_ARRAY or (elem->kind == TY_NAME and self->find_struct(elem->name) != None))
        for i in range(init->nargs):
            if init->args[i] != None and init->args[i]->kind == EX_DESIG:
                return
            if agg and (init->args[i] == None or init->args[i]->kind != EX_INITLIST):
                return
        lit: *Expr = ex_new(self->a, EX_NUMBER, init->pos)
        lit->text = self->a->printf("%d", init->nargs)
        t->arr_len = lit

    private def require_complete(self: *Sema, t: *Type, pos: Pos):
        if self->in_chdr or t == None:
            return
        self->check_void_array(t, pos)
        tt: *Type = t
        while tt != None and tt->kind == TY_ARRAY:
            tt = tt->inner
        if tt == None or tt->kind != TY_NAME or tt->name == None:
            return
        if tt->ntargs > 0:
            return   # generic instance: resolve_type already validated it
        if self->known_type_name(tt->name):
            return
        sg: Sugg
        sg.init(tt->name)
        for i in range(self->types.elen):
            if not self->types.dead[i]:
                sg.feed(self->types.keys[i])
        fatal_at(self->file, pos, "unknown type '%s'%s", tt->name, self->sugg_text(&sg))

    # folds array dimensions that reference constants to literals — this way the
    # C backend emits `a[4]` (fixed array) instead of `a[N]` (VLA). Recursive on
    # the element type (multi-dim arrays / pointer to array).
    private def fold_const_dims(self: *Sema, t: *Type):
        while t != None:
            if t->kind == TY_ARRAY and t->arr_len != None and t->arr_len->kind != EX_NUMBER:
                cok: bool = True
                v: i64 = self->ceval(t->arr_len, ref cok)
                if cok:
                    # an enum constant is already an ICE in C — keep it readable (a[MAX])
                    # instead of folding to a number. `const` is not an ICE: fold it (avoids VLA).
                    if not (t->arr_len->kind == EX_IDENT and self->is_enum_const(t->arr_len->text)):
                        lit: *Expr = ex_new(self->a, EX_NUMBER, t->arr_len->pos)
                        lit->text = self->a->printf("%lld", v)
                        t->arr_len = lit
                elif self->cc->std_version == 89:
                    # non-constant dim = VLA (C99); C89 doesn't support it
                    fatal("array has a runtime dimension (VLA), which requires C99 — not available under --std=c89")
            if t->kind == TY_ARRAY and t->arr_len != None and t->arr_len->kind == EX_NUMBER and not self->in_chdr:
                dtx: const *char = t->arr_len->text
                if dtx[0] == '-':
                    fatal_at(self->file, t->arr_len->pos, "array declared with a negative size (%s)", dtx)
                di2 = 0
                while dtx[di2] != '\0':
                    if dtx[di2] == '.':
                        fatal_at(self->file, t->arr_len->pos, "array dimension is not an integer (%s)", dtx)
                    di2 += 1
            if t->kind == TY_PTR or t->kind == TY_ARRAY:
                t = t->inner
            else:
                break

    private def vla_hoist_add(self: *Sema, st: *Stmt):
        self->vla_hoist = vec_grow(self->vla_hoist, self->vla_nhoist, ref self->vla_choist, sizeof(*self->vla_hoist))
        self->vla_hoist[self->vla_nhoist] = st
        self->vla_nhoist += 1

    # Evaluates `e` ONCE into a hoisted temporary and yields its ADDRESS. Used
    # wherever the language hands a by-reference construct an rvalue: `in self`
    # on a call result, `with` on one. Taking `&expr` directly is invalid C —
    # the C backend used to emit it and only the C compiler complained.
    # `({ ... })` whose block holds anything other than expressions: there is no
    # standard-C form for it (the comma operator only sequences expressions)
    private def stmtexpr_needs_hoist(self: *Sema, e: *Expr) -> bool:
        if e == None or e->kind != EX_STMTEXPR or e->xblock == None or e->lhs == None:
            return False
        for i in range(e->xblock->n):
            if e->xblock->stmts[i]->kind != ST_EXPR:
                return True
        return False

    # hoists `e`'s block in front of the enclosing statement and rewrites `e`
    # into the temporary that receives its value. Must be called with `e`'s own
    # scope still pushed: the value expression refers to the block's locals.
    private def hoist_stmtexpr(self: *Sema, e: *Expr):
        t: *Type = self->type_of(e->lhs)
        if t == None:
            t = self->infer_type(e->lhs)
        if t == None or is_void_val(t):
            return          # no value to carry: statement position handles it
        name: const *char = self->a->printf("__se%d", self->se_ctr)
        self->se_ctr += 1
        hd: *Stmt = st_new(self->a, ST_VAR, e->pos)
        hd->name = name
        hd->type = t
        self->resolve_type(hd->type)
        self->vla_hoist_add(hd)
        hp: *Type = self->a->alloc(sizeof(Type))
        *hp = *t
        self->fn_hoisted.put(name, hp)
        # the block, with the value assigned to the temporary at the end
        asn: *Stmt = st_new(self->a, ST_ASSIGN, e->pos)
        asn->op = TK_ASSIGN
        asn->lhs = mk_ident(self->a, name, e->pos)
        asn->rhs = e->lhs
        nb: *Block = self->a->alloc(sizeof(Block))
        nn: i32 = e->xblock->n
        nb->stmts = self->a->alloc(usize(nn + 1) * sizeof(*nb->stmts))
        for i in range(nn):
            nb->stmts[i] = e->xblock->stmts[i]
        nb->stmts[nn] = asn
        nb->n = nn + 1
        blk: *Stmt = st_new(self->a, ST_BLOCK, e->pos)
        blk->body = nb
        self->se_pend = vec_grow(self->se_pend, self->se_npend, ref self->se_cpend, sizeof(*self->se_pend))
        self->se_pend[self->se_npend] = blk
        self->se_npend += 1
        # and the expression itself becomes the temporary
        idn: *Expr = mk_ident(self->a, name, e->pos)
        *e = *idn

    private def materialize_temp(self: *Sema, e: *Expr, what: const *char) -> *Expr:
        t: *Type = self->type_of(e)
        if t == None:
            t = self->infer_type(e)
        if t == None:
            fatal_at(self->file, e->pos, "cannot infer the type of the %s", what)
        name: const *char = self->a->printf("__in%d", self->in_ctr)
        self->in_ctr += 1
        hd: *Stmt = st_new(self->a, ST_VAR, e->pos)
        hd->name = name
        hd->type = t
        self->resolve_type(hd->type)
        self->vla_hoist_add(hd)
        hp: *Type = self->a->alloc(sizeof(Type))
        *hp = *t
        self->fn_hoisted.put(name, hp)
        asn: *Expr = ex_new(self->a, EX_ASSIGN, e->pos)
        asn->op = TK_ASSIGN
        asn->lhs = mk_ident(self->a, name, e->pos)
        asn->rhs = e
        adr: *Expr = ex_new(self->a, EX_UNARY, e->pos)
        adr->op = TK_AMP
        adr->lhs = mk_ident(self->a, name, e->pos)
        cma: *Expr = ex_new(self->a, EX_COMMA, e->pos)
        cma->lhs = asn
        cma->rhs = adr
        return cma

    # --std=c89: a LOCAL array with a non-constant dimension (VLA) doesn't exist in C89.
    # Lowers `a: T[n]` (no initializer) reusing malloc/free, in a way that is SAFE
    # with goto:
    #   - a hidden pointer `__vlaN: *void = None` is hoisted to the function's ENTRY
    #     (before any label -> no goto skips over the declaration);
    #   - `defer free(__vlaN)` also at the entry (function scope) -> runs on every
    #     `return`, immune to goto (a defer in the outermost scope is never "skipped");
    #   - at the declaration point: `a: *T = (__vlaN = (free(__vlaN), malloc(n*sizeof T)))`
    #     — `a` stays block-scoped (no name collisions between sibling scopes) and
    #     `__vlaN` holds the pointer to free; the `free` before the `malloc` avoids
    #     a leak when the declaration is revisited (loop / goto backwards).
    # Returns True if it was lowered.
    # the c89 VLA lowering INJECTS malloc/free calls — make sure the sema knows
    # them (the emitted C includes <stdlib.h> for this), or the injected calls
    # would trip -Wimplicit-function-declaration in modules without stdlib
    private def ensure_libc_proto(self: *Sema, name: const *char, ret: *Type):
        if self->funcs.has(name):
            return
        lf: *Func = self->a->alloc(sizeof(Func))
        with lf:
            .name = name
            .cname = name
            .ret = ret
            .nparams = 0
            .sig_empty = True   # signature left open
        self->funcs.put(name, lf)




    # 65.4, one step before the ordinary check: a lambda inside a BRACE list has
    # its context in the field (or element) it initializes, and the ordinary
    # walk (`check_init`) runs after `check_expr`, which is too late for a node
    # that has to disappear first. So the brace list is walked here, against the
    # declared type, and only to lift lambdas — everything else is left to the
    # real initializer check.
    private def lam_pre_init(self: *Sema, t: *Type, init: *Expr):
        if init == None or t == None:
            return
        if init->kind != EX_INITLIST:
            self->lam_fix(init, t)
            return
        si: *SInfo = self->val_struct(t)
        for i in range(init->nargs):
            it: *Expr = init->args[i]
            if it == None:
                continue
            if it->kind == EX_DESIG:
                # `.name = value` / `[i] = value`: the designator names the target
                if it->field != None and si != None:
                    for fj in range(si->nfields):
                        if si->fields[fj].name != None and strcmp(si->fields[fj].name, it->field) == 0:
                            self->lam_pre_init(si->fields[fj].type, it->lhs)
                            break
                elif t->kind == TY_ARRAY:
                    self->lam_pre_init(t->inner, it->lhs)
                continue
            if si != None:
                if i < si->nfields:
                    self->lam_pre_init(si->fields[i].type, it)
            elif t->kind == TY_ARRAY:
                self->lam_pre_init(t->inner, it)

    # ---------- 65.4: a lambda is a function pointer, lifted ----------
    # P has no closure and wants none: with no capture a lambda IS a function
    # pointer, which P already has. So sema gives it a name, moves it to the top
    # level as `private`, and leaves an identifier behind — and the backends
    # never learn that a lambda existed.
    #
    # `want` is the context (68.7): the type of the parameter, the variable or
    # the return that receives it. Without one there is nothing to type the
    # parameters with, and the message says so rather than guessing.
    private def lam_fix(self: *Sema, e: *Expr, want: *Type):
        if e == None or e->kind != EX_LAMBDA:
            return
        ft: *Type = want
        if ft != None and ft->kind == TY_PTR:
            ft = ft->inner
        if ft == None or ft->kind != TY_FUNC:
            fatal_at(self->file, e->pos, "the type of this lambda cannot be inferred here: what receives it has to be a function pointer, as in `f: def(i32) -> i32 = lambda x: x * 2`")
        for i in range(ft->ntargs):
            if ft->targs[i] != None and ft->targs[i]->kind == TY_NAME and ft->targs[i]->name != None and strcmp(ft->targs[i]->name, "...") == 0:
                fatal_at(self->file, e->pos, "a lambda cannot be variadic: it has no `va_list` to read, and the context asks for one")
        if e->nargs != ft->ntargs:
            fatal_at(self->file, e->pos, "this lambda takes %d parameter(s) and the context wants %d", e->nargs, ft->ntargs)
        # NO CAPTURE, and this is where it is proved: a name in the body that is
        # a local of the enclosing function would have to be captured, and P
        # does not capture. Saying which name it was is the whole point of the
        # message — the fix is to pass it as a parameter.
        self->lam_no_capture(e->lhs, e)
        f: *Func = self->a->alloc(sizeof(Func))
        f->pos = e->pos
        f->name = self->a->printf("__lambda_%d", self->lam_ctr)
        f->cname = f->name
        self->lam_ctr += 1
        f->is_static = True
        f->ret = ft->inner
        if e->nargs > 0:
            ps: *Param = self->a->alloc(usize(e->nargs) * sizeof(Param))
            for i in range(e->nargs):
                # the arena zeroes, so `dflt` and `byref` are already 0
                ps[i].name = e->args[i]->text
                ps[i].type = ft->targs[i]
                ps[i].pos = e->args[i]->pos
            f->params = ps
            f->nparams = e->nargs
        bd: *Block = self->a->alloc(sizeof(Block))
        st: *Stmt = self->a->alloc(sizeof(Stmt))
        st->pos = e->pos
        if f->ret != None and is_void_val(f->ret):
            st->kind = ST_EXPR       # `-> void` context: the body is the effect
            st->expr = e->lhs
        else:
            st->kind = ST_RETURN
            st->expr = e->lhs
        sts: **Stmt = self->a->alloc(sizeof(*sts))
        sts[0] = st
        bd->stmts = sts
        bd->n = 1
        f->body = bd
        self->register_func(f)
        # the BODY is checked at the end of the pass, not here: check_func_body
        # resets the per-function `global`/`nonlocal` state, and doing that in
        # the middle of the enclosing function would lose it
        self->lam_pend = vec_grow(self->lam_pend, self->nlam_pend, ref self->clam_pend, sizeof(*self->lam_pend))
        self->lam_pend[self->nlam_pend] = f
        self->nlam_pend += 1
        # what is left where the lambda was: its name. A function name in C is
        # already a pointer to it, so there is nothing to take the address of.
        with e:
            .kind = EX_IDENT
            .text = f->name
            .lhs = None
            .args = None
            .nargs = 0

    # a name in the body that is a LOCAL of the enclosing function would need
    # capture. The lambda's own parameters shadow, so they are excluded.
    private def lam_no_capture(self: *Sema, b: *Expr, lam: *Expr):
        if b == None:
            return
        if b->kind == EX_IDENT and b->text != None:
            own: bool = False
            for i in range(lam->nargs):
                if lam->args[i]->text != None and strcmp(lam->args[i]->text, b->text) == 0:
                    own = True
                    break
            if not own and self->sym_index(b->text) >= 0:
                fatal_at(self->file, b->pos, "a lambda in P captures nothing: '%s' is a local of the enclosing function, so it cannot be read here — pass it as a parameter of the lambda, or use a named function", b->text)
        self->lam_no_capture(b->lhs, lam)
        self->lam_no_capture(b->rhs, lam)
        self->lam_no_capture(b->cond, lam)
        for i in range(b->nargs):
            self->lam_no_capture(b->args[i], lam)

    # ---------- 65.2: an f-string is a printf format, resolved here ----------
    # It is expanded at the CALL because that is the only place where both
    # halves are known: the callee's signature (is it variadic? is this the
    # format slot?) and the TYPE of every hole, which is what decides `%ld` over
    # `%s` over `%p`. That is also why the rule and the implementation are the
    # same thing — an f-string that is not a variadic call's format has nowhere
    # to expand into, and says so.
    private def fstr_expand(self: *Sema, e: *Expr):
        fi: i32 = -1
        for i in range(e->nargs):
            if e->args[i] != None and e->args[i]->kind == EX_FSTRING:
                if fi >= 0:
                    fatal_at(self->file, e->args[i]->pos, "two f-strings in one call: only the format argument can be one")
                fi = i
        if fi < 0:
            return
        fe: *Expr = e->args[fi]
        if fi != e->nargs - 1:
            fatal_at(self->file, fe->pos, "an f-string has to be the LAST argument of the call: its holes BECOME the arguments after it")
        callee: *Expr = e->lhs
        fn: *Func = None
        nself: i32 = 0
        if callee != None and callee->kind == EX_IDENT:
            fn = self->find_func(callee->text)
        elif callee != None and callee->kind == EX_FIELD and callee->field != None:
            # a METHOD can be variadic too — `b.printf(f"{x}")` is the call this
            # feature is for as much as `printf` is. The receiver occupies the
            # first parameter, so the format slot moves by one.
            rt: *Type = self->type_of(callee->lhs)
            sn: const *char = None
            if rt != None and rt->kind == TY_NAME:
                sn = rt->name
            elif rt != None and rt->kind == TY_PTR and rt->inner != None and rt->inner->kind == TY_NAME:
                sn = rt->inner->name
            si: *SInfo = self->find_struct(sn) if sn != None else None
            if si != None:
                fn = sinfo_method(si, callee->field)
                nself = 1
        if fn == None or not fn->is_varargs:
            fatal_at(self->file, fe->pos, "an f-string in P only works as the format argument of a variadic function (printf, snprintf, fatal_at...): it is resolved at COMPILE TIME into a format plus arguments, and there is no runtime to build a string with")
        if fn->nparams != fi + 1 + nself:
            fatal_at(self->file, fe->pos, "an f-string belongs in the format position of '%s' (argument %d), not in the variadic tail", fn->name, fn->nparams - nself)
        parts: *FStrParts = fe->fstr
        b: StrBuf = {0}
        defer b.deinit()
        holes: **Expr = self->a->alloc(usize(parts->n + 1) * sizeof(*holes))
        nh: i32 = 0
        for i in range(parts->n):
            fstr_put_lit(&b, parts->lits[i], parts->lit_lens[i])
            self->check_expr(fe->args[i])
            holes[nh] = self->fstr_conv(fe->args[i], parts->specs[i], &b)
            nh += 1
        fstr_put_lit(&b, parts->lits[parts->n], parts->lit_lens[parts->n])
        # the format takes the f-string's place and the holes follow it
        fmt: *Expr = ex_new(self->a, EX_STRING, fe->pos)
        fmt->text = c_string_literal(self->a, b.data if b.data != None else "", b.len)
        nargs: **Expr = self->a->alloc(usize(fi + 1 + nh) * sizeof(*nargs))
        for i in range(fi):
            nargs[i] = e->args[i]
        nargs[fi] = fmt
        for i in range(nh):
            nargs[fi + 1 + i] = holes[i]
        e->args = nargs
        e->nargs = fi + 1 + nh

    # ONE hole: appends its printf conversion to `b` and returns the argument to
    # pass, wrapped in the cast that makes the conversion exact in both C
    # standards (`long long`/`%lld` normally, `long`/`%ld` under --std=c89,
    # where 64-bit integers are the backend's policy and not ours).
    private def fstr_conv(self: *Sema, hole: *Expr, spec: const *char, b: *StrBuf) -> *Expr:
        pos: Pos = hole->pos
        t: *Type = self->type_of(hole)
        # ---- the spec, in Python's mini-language (45.1), parsed once ----
        align: char = '\0'
        zero: bool = False
        width: i32 = 0
        prec: i32 = -1
        ty: char = '\0'
        k: usize = 0
        m: usize = strlen(spec)
        if m > 0 and spec[0] in {'<', '>', '^'}:
            align = spec[0]
            k = 1
        if k < m and spec[k] == '0':
            zero = True
            k += 1
        while k < m and spec[k] >= '0' and spec[k] <= '9':
            width = width * 10 + i32(spec[k] - '0')
            k += 1
        if k < m and spec[k] == '.':
            k += 1
            prec = 0
            while k < m and spec[k] >= '0' and spec[k] <= '9':
                prec = prec * 10 + i32(spec[k] - '0')
                k += 1
        if k < m:
            ty = spec[k]
            k += 1
        if k < m:
            fatal_at(self->file, pos, "unsupported format spec '%s' (align, zero, width, .precision and one of d/x/X/o/f/e/g/c/s)", spec)
        if align == '^':
            fatal_at(self->file, pos, "'^' (centre) has no printf conversion: P's f-string IS a printf format, so only '<' and '>' exist here")
        if ty == 'b':
            fatal_at(self->file, pos, "'b' (binary) has no printf conversion: P's f-string IS a printf format")
        # ---- what the hole IS, which decides the cast and the conversion ----
        is_str: bool = self->fstr_is_str(t)
        is_flt: bool = is_float_type(t)
        is_bool: bool = t != None and t->kind == TY_NAME and t->name != None and t->name in {"bool", "_Bool"}
        is_ptr: bool = t != None and t->kind == TY_PTR and not is_str
        is_uns: bool = type_is_unsigned(t)
        conv: char = '\0'
        cast: const *char = None
        arg: *Expr = hole
        if ty in {'f', 'e', 'g'}:
            conv = ty; cast = "double"
        elif ty in {'x', 'X', 'o'}:
            conv = ty; cast = "unsigned long" if self->cc->std_version == 89 else "unsigned long long"
        elif ty == 'd':
            conv = 'd'; cast = "long" if self->cc->std_version == 89 else "long long"
        elif ty == 'c':
            conv = 'c'; cast = "int"
        elif ty == 's':
            if not is_str:
                fatal_at(self->file, pos, "'{...:s}' needs a string (`const *char`); this hole is not one, and P has no runtime to turn it into one")
            conv = 's'
        elif is_str:
            conv = 's'
        elif is_bool:
            # `True`/`False`, the way both languages print it — a ternary over
            # two literals, which costs nothing at run time
            conv = 's'
            tern: *Expr = ex_new(self->a, EX_TERNARY, pos)
            tern->cond = hole
            tern->lhs = ex_new(self->a, EX_STRING, pos)
            tern->lhs->text = "\"True\""
            tern->rhs = ex_new(self->a, EX_STRING, pos)
            tern->rhs->text = "\"False\""
            tern->parened = True
            arg = tern
        elif is_flt:
            conv = 'g'; cast = "double"
        elif is_ptr:
            conv = 'p'
        elif is_uns:
            conv = 'u'; cast = "unsigned long" if self->cc->std_version == 89 else "unsigned long long"
        elif t != None and t->kind == TY_NAME and t->name != None and t->name in {"char", "signed char"}:
            conv = 'c'; cast = "int"
        else:
            conv = 'd'; cast = "long" if self->cc->std_version == 89 else "long long"
        if is_ptr and ty == '\0':
            cst: *Expr = ex_new(self->a, EX_CAST, pos)
            cst->cast_type = ty_ptr(self->a, ty_name(self->a, "void"))
            cst->lhs = hole
            arg = cst
        elif cast != None:
            cst2: *Expr = ex_new(self->a, EX_CAST, pos)
            cst2->cast_type = ty_name(self->a, cast)
            cst2->lhs = hole
            arg = cst2
        # ---- and now the conversion itself ----
        b->putc('%')
        if align == '<':
            b->putc('-')
        if zero:
            b->putc('0')
        if width > 0:
            b->printf("%d", width)
        if prec >= 0:
            b->printf(".%d", prec)
        if cast != None and conv not in {'c', 's', 'p'}:
            if conv in {'f', 'e', 'g'}:
                pass                      # double needs no length modifier
            elif self->cc->std_version == 89:
                b->putc('l')
            else:
                b->puts("ll")
        b->putc(conv)
        return arg

    private def fstr_is_str(self: *Sema, t: *Type) -> bool:
        if t == None:
            return False
        if t->kind == TY_PTR and t->inner != None and t->inner->kind == TY_NAME and t->inner->name != None:
            return t->inner->name in {"char", "signed char"}
        if t->kind == TY_ARRAY and t->inner != None and t->inner->kind == TY_NAME and t->inner->name != None:
            return t->inner->name in {"char", "signed char"}
        return False

    private def lower_vla_c89(self: *Sema, st: *Stmt) -> bool:
        if self->cc->std_version != 89 or st->type == None:
            return False
        if st->type->kind != TY_ARRAY or st->type->arr_len == None or st->init != None:
            return False
        cok: bool = True
        self->ceval(st->type->arr_len, ref cok)
        if cok:
            return False   # constant dim (literal/const/enum) — not a VLA
        self->ensure_libc_proto("malloc", ty_ptr(self->a, ty_name(self->a, "void")))
        self->ensure_libc_proto("free", ty_name(self->a, "void"))
        elem: *Type = st->type->inner
        dim: *Expr = st->type->arr_len
        hidden: const *char = self->a->printf("__vla%d", self->vla_ctr)
        self->vla_ctr += 1
        # entry: `__vlaN: *void = None`
        decl: *Stmt = st_new(self->a, ST_VAR, st->pos)
        decl->name = hidden
        decl->type = ty_ptr(self->a, ty_name(self->a, "void"))
        decl->init = ex_new(self->a, EX_NONE, st->pos)
        self->vla_hoist_add(decl)
        self->scope_add(hidden, decl->type)   # visible when checking the init below
        # entry: `defer free(__vlaN)`
        fx: *Stmt = st_new(self->a, ST_EXPR, st->pos)
        fx->expr = mk_call1(self->a, "free", mk_ident(self->a, hidden, st->pos), st->pos)
        blk: *Block = self->a->alloc(sizeof(Block))
        dstmts: **Stmt = self->a->alloc(sizeof(*dstmts))
        dstmts[0] = fx
        blk->stmts = dstmts
        blk->n = 1
        dfr: *Stmt = st_new(self->a, ST_DEFER, st->pos)
        dfr->body = blk
        self->vla_hoist_add(dfr)
        # decl: `a: *T = (__vlaN = (free(__vlaN), malloc(dim * sizeof(elem))))`
        szof: *Expr = ex_new(self->a, EX_TYPEREF, st->pos)
        szof->cast_type = elem
        mul: *Expr = ex_new(self->a, EX_BINARY, st->pos)
        mul->op = TK_STAR
        mul->lhs = dim
        mul->rhs = mk_call1(self->a, "sizeof", szof, st->pos)
        freecall: *Expr = mk_call1(self->a, "free", mk_ident(self->a, hidden, st->pos), st->pos)
        comma: *Expr = ex_new(self->a, EX_COMMA, st->pos)
        comma->lhs = freecall
        comma->rhs = mk_call1(self->a, "malloc", mul, st->pos)
        asn: *Expr = ex_new(self->a, EX_ASSIGN, st->pos)
        asn->lhs = mk_ident(self->a, hidden, st->pos)
        asn->op = TK_ASSIGN
        asn->rhs = comma
        st->type = ty_ptr(self->a, elem)
        st->init = asn
        return True

    # predefined identifiers (C-style, without a preprocessor): folded to a
    # literal in sema. Positional: __FILE__/__LINE__ (node position), __func__/
    # __FUNCTION__ (current function), __COUNTER__ (increments on each use). The
    # other dunders (__DATE__/__TIME__/__PLANG__*/-D __X) come from constvals.
    private def fold_predefined(self: *Sema, e: *Expr):
        n: const *char = e->text
        if n == None or n[0] != '_' or n[1] != '_':
            return
        if n == "__FILE__":
            e->kind = EX_STRING
            e->text = self->a->printf("\"%s\"", self->file)
        elif n == "__LINE__":
            e->kind = EX_NUMBER
            e->text = self->a->printf("%d", e->pos.line)
        elif n in {"__func__", "__FUNCTION__"}:
            if self->cur_fname != None:
                e->kind = EX_STRING
                e->text = self->a->printf("\"%s\"", self->cur_fname)
        elif n == "__COUNTER__":
            e->kind = EX_NUMBER
            e->text = self->a->printf("%d", self->counter)
            self->counter += 1
        else:
            cp: *CVal = self->constvals.get_or(n, None)
            if cp == None:
                return
            if cp->kind == CV_STR:
                e->kind = EX_STRING; e->text = cp->sval
            elif cp->kind == CV_FLOAT:
                e->kind = EX_NUMBER; e->text = cfloat_text(self->a, cp->fval)
            elif cp->kind == CV_INT:
                e->kind = EX_NUMBER; e->text = self->a->printf("%lld", cp->ival)

    # normalizes . / -> depending on whether the receiver is a value or a pointer
    private def fix_field_op(self: *Sema, e: *Expr):
        # `(*p).f` IS `p->f` — the auto-deref on a byref parameter would otherwise
        # surface in the output for every field it touches (take_addr is the twin
        # of this fold for the address-of side)
        if is_byref_deref(e->lhs):
            e->lhs = e->lhs->lhs
            e->op = TK_ARROW
            return
        t: *Type = self->type_of(e->lhs)
        if t == None:
            return  # unknown type: keep it as the user wrote it
        if t->kind == TY_PTR and t->inner != None and t->inner->kind == TY_NAME:
            e->op = TK_ARROW
        elif t->kind == TY_NAME:
            e->op = TK_DOT

    # the struct/union SInfo when `t` is a struct/union VALUE type (not ptr/array).
    # Unresolved generic references (Vec<T> with targs) are skipped — only the
    # monomorphized instances behave as concrete struct values here.
    private def val_struct(self: *Sema, t: *Type) -> *SInfo:
        if t == None or t->kind != TY_NAME or t->ntargs > 0:
            return None
        return self->find_struct(t->name)

    # an ARRAY may never have void elements, at any nesting/pointer level:
    # void a[3], void (*p)[3], void *x[2][2] is fine (pointer elem), void x[2][2] not
    private def check_void_array(self: *Sema, t: *Type, pos: Pos):
        w: *Type = t
        while w != None and (w->kind == TY_PTR or w->kind == TY_ARRAY):
            if w->kind == TY_ARRAY:
                el: *Type = w->inner
                while el != None and el->kind == TY_ARRAY:
                    el = el->inner
                if el != None and el->kind == TY_NAME and el->name != None and el->name == "void":
                    fatal_at(self->file, pos, "declaration of an array of voids")
                if el != None and el->kind == TY_FUNC:
                    fatal_at(self->file, pos, "declaration of an array of functions")
                # array elements must be COMPLETE at the declaration (C11 6.2.5p20)
                if True:
                    sel: *SInfo = self->val_struct(el)
                    if sel != None and not sel->defined:
                        fatal_at(self->file, pos, "array of incomplete type '%s %s'", "union" if sel->is_union else "struct", sel->name)
            w = w->inner

    # rejects a struct/union/void VALUE where C/P require a scalar (conditions,
    # arithmetic operands, ++/--). Pointers and unknown types pass.
    private def require_scalar(self: *Sema, e: *Expr, what: const *char):
        if e == None:
            return
        t: *Type = self->type_of(e)
        si: *SInfo = self->val_struct(t)
        if si != None:
            fatal_at(self->file, e->pos, "%s '%s' value used where a scalar is required (%s)", "union" if si->is_union else "struct", si->name, what)
        if is_void_val(t):
            fatal_at(self->file, e->pos, "void value used where a scalar is required (%s)", what)

    # assignment/initialization compatibility for struct/union VALUES: both sides
    # known and aggregate -> the tags must match; aggregate on one side only (with
    # the other positively scalar) -> incompatible. Unknowns stay permissive.
    # is `e` usable as a STATIC-storage initializer (a constant expression or an
    # address constant, C11 6.7.9p4)? Conservative on unknown node kinds.
    private def static_const_ok(self: *Sema, e: *Expr) -> bool:
        if e == None:
            return True
        match e->kind:
            case EX_NUMBER, EX_CHARLIT, EX_STRING, EX_TRUE, EX_FALSE, EX_NONE, EX_TYPEREF:
                return True
            case EX_IDENT:
                if self->is_enum_const(e->text):
                    return True
                scok: bool = True
                self->ceval(e, ref scok)
                if scok:
                    return True   # folds to a constant (const/macro const)
                gt2: *Type = self->globals.get_or(e->text, None)
                if gt2 != None and gt2->kind == TY_ARRAY:
                    return True   # global array decays to an address constant
                if self->find_func(e->text) != None and self->scope_find(e->text) == None:
                    return True   # function designator: address constant
                return False
            case EX_UNARY:
                if e->op == TK_AMP:
                    return True   # &obj: address constant (operand storage unchecked)
                return self->static_const_ok(e->lhs)
            case EX_BINARY:
                return self->static_const_ok(e->lhs) and self->static_const_ok(e->rhs)
            case EX_TERNARY:
                return self->static_const_ok(e->cond) and self->static_const_ok(e->lhs) and self->static_const_ok(e->rhs)
            case EX_CAST:
                return self->static_const_ok(e->lhs)
            case EX_INITLIST, EX_COMPOUND:
                for sci in range(e->nargs):
                    if not self->static_const_ok(e->args[sci]):
                        return False
                return True
            case EX_DESIG:
                return self->static_const_ok(e->lhs)
            case EX_CALL:
                # sizeof/_Alignof of anything is a constant; real calls are not
                if e->lhs != None and e->lhs->kind == EX_IDENT and (e->lhs->text in {"sizeof", "_Alignof"}):
                    return True
                return False
            case EX_INDEX, EX_FIELD, EX_INCDEC, EX_ASSIGN, EX_STMTEXPR:
                return False
            case _:
                return True

    # STRUCTURAL compatibility of two resolved types (canonical arith names,
    # struct identities, pointee recursion, array dims when both are literal).
    # Unknown parts are permissive.
    private def type_compat(self: *Sema, a: *Type, b: *Type) -> bool:
        if a == None or b == None:
            return True
        if a->kind == TY_NAME and b->kind == TY_NAME:
            if a->name == None or b->name == None:
                return True
            if strcmp(a->name, b->name) == 0:
                return True
            wca: i32 = ctype_width(a->name)
            wcb: i32 = ctype_width(b->name)
            if wca > 0 and wca == wcb and not is_float_type(a) and not is_float_type(b):
                ach: bool = a->name == "char"
                bch: bool = b->name == "char"
                if ach == bch and ctype_unsigned(a->name) == ctype_unsigned(b->name):
                    return True   # i32 vs int, u64 vs unsigned long long, ...
            # distinct spellings of the same width/signedness class still conflict
            # in C (char vs signed char; unsigned int vs unsigned long) — the
            # canonical names differ, so plain name inequality is the answer; only
            # unresolved typedef spellings (unknown to ctype_width) stay permissive
            if ctype_width(a->name) == 0 and self->val_struct(a) == None and not is_float_type(a):
                return True
            if ctype_width(b->name) == 0 and self->val_struct(b) == None and not is_float_type(b):
                return True
            return False
        if a->kind != b->kind:
            return False
        if a->kind == TY_PTR:
            return self->type_compat(a->inner, b->inner)
        if a->kind == TY_ARRAY:
            if a->arr_len != None and b->arr_len != None and a->arr_len->kind == EX_NUMBER and b->arr_len->kind == EX_NUMBER:
                if strtoll(a->arr_len->text, None, 0) != strtoll(b->arr_len->text, None, 0):
                    return False
            return self->type_compat(a->inner, b->inner)
        if a->kind == TY_FUNC:
            return self->type_compat(a->inner, b->inner)
        return True

    # does the struct have this member, INCLUDING inside C11 anonymous
    # struct/union members (fields named "" whose type is the nested tag)?
    private def sinfo_field_deep(self: *Sema, si: *SInfo, name: const *char, depth: i32) -> bool:
        if si == None or depth > 8:
            return False
        if sinfo_field(si, name) != None:
            return True
        for fdi in range(si->nfields):
            fnm: const *char = si->fields[fdi].name
            if (fnm == None or fnm[0] == '\0') and si->fields[fdi].type != None and si->fields[fdi].type->kind == TY_NAME:
                sub: *SInfo = self->find_struct(si->fields[fdi].type->name)
                if sub != None and sub != si and self->sinfo_field_deep(sub, name, depth + 1):
                    return True
        return False

    # -Wparentheses: a bare assignment used as a condition (`if (x = 3)`) — an
    # extra set of parens (`if ((x = y))`) is the idiomatic "yes, I mean it"
    private def check_cond_assign(self: *Sema, cond: *Expr):
        if cond != None and cond->kind == EX_ASSIGN and not cond->parened:
            cdiag_at(self->file, cond->pos, "parentheses", WD_WARN, "using the result of an assignment as a condition without parentheses")

    # -Wunused-value: does evaluating this expression have NO side effect?
    private def expr_no_effect(self: *Sema, e: *Expr) -> bool:
        if e == None:
            return False
        match e->kind:
            case EX_IDENT, EX_NUMBER, EX_CHARLIT, EX_STRING, EX_TRUE, EX_FALSE:
                return True
            case EX_FIELD:
                return self->expr_no_effect(e->lhs)
            case EX_INDEX, EX_BINARY:
                return self->expr_no_effect(e->lhs) and self->expr_no_effect(e->rhs)
            case EX_TERNARY:
                return self->expr_no_effect(e->lhs) and self->expr_no_effect(e->rhs)
            case EX_UNARY:
                return self->expr_no_effect(e->lhs)
            case EX_CAST:
                if is_void_val(e->cast_type):
                    return False   # (void)x: the idiomatic "discard on purpose"
                return self->expr_no_effect(e->lhs)
            case EX_COMMA:
                return self->expr_no_effect(e->rhs)
            case _:
                return False   # calls, assignments, ++/--, statement exprs, ...

    # missing return (-Wreturn-type warning): does the block END by leaving the
    # function? Conservative — anything uncertain counts as exiting (never a
    # false warning; a switch or a while(1) is trusted).
    private def stmt_exits_c(self: *Sema, st: *Stmt) -> bool:
        if st == None:
            return False
        match st->kind:
            case ST_RETURN, ST_GOTO:
                return True
            case ST_BLOCK:
                return st->body != None and st->body->n > 0 and self->stmt_exits_c(st->body->stmts[st->body->n - 1])
            case ST_IF:
                if st->else_block == None:
                    return False
                for bi in range(st->nconds):
                    if st->blocks[bi] == None or st->blocks[bi]->n == 0 or not self->stmt_exits_c(st->blocks[bi]->stmts[st->blocks[bi]->n - 1]):
                        return False
                return st->else_block->n > 0 and self->stmt_exits_c(st->else_block->stmts[st->else_block->n - 1])
            case ST_SWITCH, ST_MATCH:
                return True   # trusted (all-arms analysis not attempted)
            case ST_WHILE, ST_DO:
                wok: bool = True
                wv: i64 = self->ceval(st->cond, ref wok)
                return wok and wv != 0   # while(1): only leaves via return/goto
            case ST_CFOR:
                if st->cond == None:
                    return True          # for(;;)
                fok: bool = True
                fv: i64 = self->ceval(st->cond, ref fok)
                return fok and fv != 0
            case ST_EXPR:
                # a call that never returns
                if st->expr != None and st->expr->kind == EX_CALL and st->expr->lhs != None and st->expr->lhs->kind == EX_IDENT:
                    cn: const *char = st->expr->lhs->text
                    return cn in {"exit", "_exit", "_Exit", "abort", "quick_exit"}
                return False
            case _:
                return False

    # builds one comparison of the chain: needle == elt, or strcmp(needle, elt) == 0
    # when both sides are strings (CONTENT equality — never pointer comparison)
    private def in_one_cmp(self: *Sema, needle: *Expr, elt: *Expr, str_needle: bool, pos: Pos) -> *Expr:
        elt_str: bool = elt->kind == EX_STRING
        if elt_str or (str_needle and elt != None and self->type_is_string(self->type_of(elt))):
            cmpfn: const *char = "strcmp"
            if self->cc->inline_runtime:
                cmpfn = "__plang_strcmp"   # self-contained inline helper (no libc)
            else:
                self->ensure_libc_proto("strcmp", ty_name(self->a, "int"))
            c: *Expr = ex_new(self->a, EX_CALL, pos)
            c->lhs = mk_ident(self->a, cmpfn, pos)
            cargs: **Expr = self->a->alloc(2 * sizeof(*cargs))
            cargs[0] = needle
            cargs[1] = elt
            c->args = cargs
            c->nargs = 2
            z: *Expr = ex_new(self->a, EX_NUMBER, pos)
            z->text = "0"
            eqc: *Expr = ex_new(self->a, EX_BINARY, pos)
            eqc->op = TK_EQ
            eqc->lhs = c
            eqc->rhs = z
            return eqc
        eq: *Expr = ex_new(self->a, EX_BINARY, pos)
        eq->op = TK_EQ
        eq->lhs = needle
        eq->rhs = elt
        return eq

    private def type_is_string(self: *Sema, t: *Type) -> bool:
        if t == None or (t->kind != TY_PTR and t->kind != TY_ARRAY) or t->inner == None:
            return False
        return t->inner->kind == TY_NAME and t->inner->name != None and (t->inner->name == "char" or ctype_width(t->inner->name) == 1)

    private def in_or_chain(self: *Sema, cmps: **Expr, n: i32, pos: Pos) -> *Expr:
        if n == 0:
            return ex_new(self->a, EX_FALSE, pos)
        acc: *Expr = cmps[0]
        for i in range(1, n):
            o: *Expr = ex_new(self->a, EX_BINARY, pos)
            o->op = TK_OR
            o->lhs = acc
            o->rhs = cmps[i]
            acc = o
        return acc

    # lowers EX_IN in place: `x in {a,b}` -> x==a or x==b (strings via strcmp);
    # `c in "aeiou"` unrolls the literal's bytes; `x in arr[N]` unrolls the array.
    private def lower_in(self: *Sema, e: *Expr):
        needle: *Expr = e->lhs
        hay: *Expr = e->rhs
        negated: bool = e->op == TK_NOT
        self->check_expr(needle)
        if not self->expr_no_effect(needle):
            fatal_at(self->file, e->pos, "the left side of 'in' is expanded into multiple comparisons — assign it to a variable first")
        nt: *Type = self->type_of(needle)
        str_needle: bool = self->type_is_string(nt)
        cmps: **Expr = None
        n = 0; cap = 0
        if hay != None and hay->kind == EX_INITLIST:
            for i in range(hay->nargs):
                self->check_expr(hay->args[i])
                cmps = vec_grow(cmps, n, ref cap, sizeof(*cmps))
                cmps[n] = self->in_one_cmp(needle, hay->args[i], str_needle, e->pos)
                n += 1
        elif hay != None and hay->kind == EX_STRING and not str_needle:
            # each BYTE of the literal becomes a comparison (escapes decoded;
            # ASCII only — multi-byte codepoints cannot equal one char)
            txt: const *char = hay->text
            ti: usize = 1                      # skip opening quote
            tl: usize = strlen(txt)
            while ti + 1 < tl:                 # stop before closing quote
                bv: i64 = 0
                if txt[ti] == '\\':
                    esc: char[8]
                    el = 0
                    esc[el] = '\\'; el += 1
                    ti += 1
                    esc[el] = txt[ti]; el += 1
                    ti += 1
                    # \xHH / octal: absorb up to 3 more
                    while el < 6 and ti + 1 < tl:
                        hexd: bool = (txt[ti] >= '0' and txt[ti] <= '9') or (txt[ti] >= 'a' and txt[ti] <= 'f') or (txt[ti] >= 'A' and txt[ti] <= 'F')
                        octd: bool = txt[ti] >= '0' and txt[ti] <= '7'
                        if not ((esc[1] == 'x' and hexd) or (esc[1] >= '0' and esc[1] <= '7' and octd)):
                            break
                        esc[el] = txt[ti]; el += 1
                        ti += 1
                    lex: char[12]
                    lex[0] = '\''
                    for k in range(el):
                        lex[k + 1] = esc[k]
                    lex[el + 1] = '\''
                    lex[el + 2] = '\0'
                    bv = ceval_char(lex)
                else:
                    bv = i64(u8(txt[ti]))
                    if bv >= 128:
                        fatal_at(self->file, e->pos, "'in' on a string literal requires ASCII (a multi-byte codepoint never equals one char)")
                    ti += 1
                lit: *Expr = ex_new(self->a, EX_NUMBER, e->pos)
                lit->text = self->a->printf("%lld", bv)
                cmps = vec_grow(cmps, n, ref cap, sizeof(*cmps))
                cmps[n] = self->in_one_cmp(needle, lit, False, e->pos)
                n += 1
        elif hay != None and self->type_of(hay) != None and self->type_of(hay)->kind == TY_ARRAY and self->type_of(hay)->arr_len != None and self->type_of(hay)->arr_len->kind == EX_NUMBER:
            ht0: *Type = self->type_of(hay)
            self->check_expr(hay)
            if not self->expr_no_effect(hay):
                fatal_at(self->file, e->pos, "the right side of 'in' is expanded into multiple comparisons — assign it to a variable first")
            alen: i64 = strtoll(ht0->arr_len->text, None, 0)
            if alen > 64:
                fatal_at(self->file, e->pos, "'in' unrolls the array into comparisons — %lld elements is too many (limit 64)", alen)
            for ai in range(alen):
                ix: *Expr = ex_new(self->a, EX_INDEX, e->pos)
                ix->lhs = hay
                ix->rhs = ex_new(self->a, EX_NUMBER, e->pos)
                ix->rhs->text = self->a->printf("%lld", i64(ai))
                cmps = vec_grow(cmps, n, ref cap, sizeof(*cmps))
                cmps[n] = self->in_one_cmp(needle, ix, str_needle, e->pos)
                n += 1
        else:
            fatal_at(self->file, e->pos, "the right side of 'in' must be a {...} list, a string literal or a fixed-size array")
        chain: *Expr = self->in_or_chain(cmps, n, e->pos)
        free(cmps)
        if negated:
            nn: *Expr = ex_new(self->a, EX_UNARY, e->pos)
            nn->op = TK_NOT
            nn->lhs = chain
            chain = nn
        *e = *chain   # replace the EX_IN node in place
        self->check_expr(e)

    # `match` over a STRING subject: C's switch can't take strings, so the match
    # becomes an if/elif chain of strcmp comparisons (content equality — the same
    # rule as `in`). The subject is duplicated per case: it must be pure.
    private def lower_match_strings(self: *Sema, st: *Stmt):
        if not self->expr_no_effect(st->subject):
            fatal_at(self->file, st->pos, "'match' on a string expands into strcmp comparisons — assign the subject to a variable first")
        conds: **Expr = None
        blocks: **Block = None
        nc = 0; cc1 = 0; cc2 = 0
        els: *Block = None
        for i in range(st->ncases):
            mc: *MatchCase = st->cases[i]
            if mc->is_default:
                if els != None:
                    fatal_at(self->file, st->pos, "duplicate default case in match")
                els = mc->body
                continue
            cmps: **Expr = None
            n2 = 0; c2 = 0
            for k in range(mc->nvals):
                v: *Expr = mc->vals[k]
                if v == None or v->kind != EX_STRING:
                    fatal_at(self->file, v->pos if v != None else st->pos, "match on a string subject requires string literal cases")
                # duplicate case detection (by CONTENT)
                for pi in range(i):
                    pm: *MatchCase = st->cases[pi]
                    for pk2 in range(pm->nvals):
                        if pm->vals[pk2] != None and pm->vals[pk2]->kind == EX_STRING and strcmp(pm->vals[pk2]->text, v->text) == 0:
                            fatal_at(self->file, v->pos, "duplicate case %s in match", v->text)
                cmps = vec_grow(cmps, n2, ref c2, sizeof(*cmps))
                cmps[n2] = self->in_one_cmp(st->subject, v, True, v->pos)
                n2 += 1
            conds = vec_grow(conds, nc, ref cc1, sizeof(*conds))
            blocks = vec_grow(blocks, nc, ref cc2, sizeof(*blocks))
            conds[nc] = self->in_or_chain(cmps, n2, st->pos)
            blocks[nc] = mc->body
            free(cmps)
            nc += 1
        with st:
            .kind = ST_IF
            .conds = conds
            .blocks = blocks
            .nconds = nc
            .else_block = els
            .subject = None
            .cases = None
            .ncases = 0
            .if_sel = -1

    # resolves NAMED arguments (EX_DESIG markers from `f(x, cap=8)`) and fills
    # omitted trailing parameters from their comptime DEFAULTS — the call leaves
    # here in plain positional form (zero runtime cost). `skip` = leading params
    # not present in e->args (a method's self).
    private def resolve_call_args(self: *Sema, e: *Expr, fn: *Func, skip: i32):
        want: i32 = fn->nparams - skip
        named: bool = False
        for ci in range(e->nargs):
            if e->args[ci] != None and e->args[ci]->kind == EX_DESIG and e->args[ci]->field != None:
                named = True
        needs_fill: bool = e->nargs < want and want > 0 and fn->params[fn->nparams - 1].dflt != None
        if not named and not needs_fill:
            return
        if fn->is_varargs:
            fatal_at(self->file, e->pos, "named/default arguments cannot be used with a variadic function ('%s')", fn->name)
        if e->nargs > want:
            return   # too many: the arity check reports it
        slots: **Expr = self->a->alloc(usize(want) * sizeof(*slots))
        for si in range(want):
            slots[si] = None
        seen_named: bool = False
        pos_i = 0
        for ai in range(e->nargs):
            a: *Expr = e->args[ai]
            if a != None and a->kind == EX_DESIG and a->field != None:
                seen_named = True
                found = -1
                for pi in range(skip, fn->nparams):
                    if fn->params[pi].name != None and strcmp(fn->params[pi].name, a->field) == 0:
                        found = pi - skip
                        break
                if found < 0:
                    fatal_at(self->file, a->pos, "'%s' has no parameter named '%s'", fn->name, a->field)
                if slots[found] != None:
                    fatal_at(self->file, a->pos, "duplicate argument for parameter '%s'", a->field)
                slots[found] = a->lhs
            else:
                if seen_named:
                    fatal_at(self->file, a->pos, "positional argument after a named argument")
                if pos_i >= want:
                    return   # excess positional: arity check reports
                if slots[pos_i] != None:
                    fatal_at(self->file, a->pos, "duplicate argument for parameter '%s'", fn->params[skip + pos_i].name)
                slots[pos_i] = a
                pos_i += 1
        for fi in range(want):
            if slots[fi] == None:
                if fn->params[skip + fi].dflt == None:
                    fatal_at(self->file, e->pos, "missing argument for parameter '%s' of '%s' (it has no default)", fn->params[skip + fi].name, fn->name)
                slots[fi] = fn->params[skip + fi].dflt
        e->args = slots
        e->nargs = want

    # a call-site byref keyword (`out x`/`ref x`/`in x`) must match the parameter
    # it lands on. Raw `&x` (no keyword) stays valid — C-interop compatibility.
    private def check_byref_kw(self: *Sema, a: *Expr, fn: *Func, pi: i32):
        if a == None or a->kind != EX_UNARY or a->op != TK_AMP or a->byref == PK_NONE:
            return
        kw: const *char = "out" if a->byref == PK_OUT else ("ref" if a->byref == PK_REF else "in")
        want: i32 = fn->params[pi].byref
        if want == PK_NONE:
            fatal_at(self->file, a->pos, "'%s %s' passed, but parameter '%s' of '%s' is a plain pointer (use '&')", kw, a->lhs->text if a->lhs != None and a->lhs->kind == EX_IDENT else "...", fn->params[pi].name, fn->name)
        if want != a->byref:
            wkw: const *char = "out" if want == PK_OUT else ("ref" if want == PK_REF else "in")
            fatal_at(self->file, a->pos, "'%s' passed where parameter '%s' of '%s' is declared '%s'", kw, fn->params[pi].name, fn->name, wkw)

    # the byref-parameter SYM this lvalue writes into (or -1). Walks value hops
    # only: .field on the deref'd param, [i] on value arrays. A hop through a
    # LOADED pointer (p.next.x) leaves the pointee — not a write into the param.
    private def byref_write_base(self: *Sema, e: *Expr) -> i32:
        w: *Expr = e
        while w != None:
            if w->kind == EX_FIELD and w->op == TK_DOT:
                w = w->lhs
                continue
            # `p->f` on a byref PARAMETER is the folded `(*p).f` (see fix_field_op):
            # still a hop INTO the parameter, unlike `->` through a loaded pointer
            if w->kind == EX_FIELD and w->op == TK_ARROW and w->lhs != None and w->lhs->kind == EX_IDENT:
                ai: i32 = self->sym_index(w->lhs->text)
                if ai >= 0 and self->locals[ai].byref != PK_NONE:
                    w = w->lhs
                    continue
            if w->kind == EX_INDEX and self->type_of(w->lhs) != None and self->type_of(w->lhs)->kind == TY_ARRAY:
                w = w->lhs
                continue
            break
        if w != None and w->kind == EX_UNARY and w->op == TK_STAR and w->lhs != None and w->lhs->kind == EX_IDENT:
            wi: i32 = self->sym_index(w->lhs->text)
            if wi >= 0 and self->locals[wi].byref != PK_NONE:
                return wi
        if w != None and w->kind == EX_IDENT:
            wi2: i32 = self->sym_index(w->text)
            if wi2 >= 0 and self->locals[wi2].byref != PK_NONE:
                return wi2
        return -1

    # a FUNCTION DESIGNATOR: an identifier that names a function and is not
    # shadowed by any variable — it only carries a value DECAYED to a function
    # pointer, so arithmetic on it or assigning it to a non-pointer is an error
    private def func_designator(self: *Sema, e: *Expr) -> *Func:
        if e == None or e->kind != EX_IDENT or e->text == None:
            return None
        if self->scope_find(e->text) != None or self->globals.get_or(e->text, None) != None:
            return None
        return self->find_func(e->text)

    # ---------- null facts (69.7) and ref binding (69.1) ----------
    # A tiny flow analysis over pointer LOCALS: locals[i].nn holds what this
    # point of the flow has PROVEN about the pointer (nothing / non-None /
    # None). Facts are snapshotted around branches, killed by writes that a
    # loop could replay, and dropped entirely at labels and escaped addresses.
    # Two consumers only: -Wnull-dereference (fires on a proven None) and the
    # proof `ref T` demands before stealing the place behind a pointer.
    private def nn_save(self: *Sema) -> *i32:
        snap: *i32 = self->a->alloc(usize(self->nlocals + 1) * sizeof(i32))
        snap[0] = self->nlocals
        for i in range(self->nlocals):
            snap[i + 1] = self->locals[i].nn
        return snap

    private def nn_restore(self: *Sema, snap: *i32):
        for i in range(self->nlocals):
            self->locals[i].nn = snap[i + 1] if i < snap[0] else 0

    private def nn_clear_all(self: *Sema):
        for i in range(self->nlocals):
            self->locals[i].nn = 0

    # what a fresh value proves about the pointer it lands in
    private def nn_of_expr(self: *Sema, e: *Expr) -> i32:
        if e == None:
            return 0
        if e->kind == EX_NONE:
            return 2
        if e->kind == EX_UNARY and e->op == TK_AMP:
            return 1
        if e->kind == EX_STRING:
            return 1
        if e->kind == EX_CAST:
            return self->nn_of_expr(e->lhs)
        if e->kind == EX_IDENT:
            ni: i32 = self->sym_index(e->text)
            if ni >= 0 and not self->locals[ni].nn_off:
                return self->locals[ni].nn
            return 0
        nt: *Type = self->type_of(e)
        if nt != None and nt->kind == TY_PTR and nt->is_ref:
            return 1
        return 0

    # record a fact on a pointer local being assigned (idents only: a fact on
    # p->f or a[i] would need an alias analysis this deliberately isn't)
    private def nn_assign(self: *Sema, lhs: *Expr, v: i32):
        if lhs == None or lhs->kind != EX_IDENT:
            return
        ai: i32 = self->sym_index(lhs->text)
        if ai < 0 or self->locals[ai].nn_off or self->locals[ai].byref != PK_NONE:
            return
        if self->locals[ai].type == None or self->locals[ai].type->kind != TY_PTR:
            return
        self->locals[ai].nn = v

    # facts a condition proves inside the branch where it was `branch_true`
    private def apply_cond_facts(self: *Sema, e: *Expr, branch_true: bool):
        if e == None:
            return
        if e->kind == EX_UNARY and e->op == TK_NOT:
            self->apply_cond_facts(e->lhs, not branch_true)
            return
        if e->kind == EX_BINARY and e->op == TK_AND and branch_true:
            # both conjuncts hold; the FALSE side of an `and` proves nothing
            self->apply_cond_facts(e->lhs, True)
            self->apply_cond_facts(e->rhs, True)
            return
        if e->kind == EX_BINARY and e->op == TK_OR and not branch_true:
            self->apply_cond_facts(e->lhs, False)
            self->apply_cond_facts(e->rhs, False)
            return
        if e->kind == EX_BINARY and (e->op == TK_EQ or e->op == TK_NE):
            oth: *Expr = None
            if e->lhs != None and e->lhs->kind == EX_NONE:
                oth = e->rhs
            elif e->rhs != None and e->rhs->kind == EX_NONE:
                oth = e->lhs
            if oth != None and oth->kind == EX_IDENT:
                isnull: bool = (e->op == TK_EQ) == branch_true
                self->nn_assign(oth, 2 if isnull else 1)
            return
        if e->kind == EX_IDENT:
            # pointer truthiness: `if p:` proves non-None inside the branch
            ti: i32 = self->sym_index(e->text)
            if ti >= 0 and self->locals[ti].type != None and self->locals[ti].type->kind == TY_PTR:
                self->nn_assign(e, 1 if branch_true else 2)

    # a loop body runs again after its own writes: any local it assigns cannot
    # keep a fact from BEFORE the loop (the back edge would smuggle it in)
    private def nn_kill_writes(self: *Sema, b: *Block):
        if b == None:
            return
        for i in range(b->n):
            s: *Stmt = b->stmts[i]
            if s == None:
                continue
            if s->kind == ST_ASSIGN:
                self->nn_assign(s->lhs, 0)
            elif s->kind == ST_EXPR and s->expr != None and (s->expr->kind == EX_ASSIGN or s->expr->kind == EX_INCDEC):
                self->nn_assign(s->expr->lhs, 0)
            elif s->kind == ST_IF:
                for j in range(s->nconds):
                    self->nn_kill_writes(s->blocks[j])
                self->nn_kill_writes(s->else_block)
            elif s->kind == ST_WHILE or s->kind == ST_DO or s->kind == ST_FOR or s->kind == ST_CFOR or s->kind == ST_BLOCK or s->kind == ST_DEFER or s->kind == ST_WITH:
                self->nn_kill_writes(s->body)
            elif s->kind == ST_MATCH:
                for j in range(s->ncases):
                    if s->cases[j] != None:
                        self->nn_kill_writes(s->cases[j]->body)

    # -Wnull-dereference (69.7): only a PROVEN fact fires — the pointer was
    # None on every path that reaches this dereference, so it always crashes
    private def null_deref_check(self: *Sema, base: *Expr, pos: Pos):
        if self->in_chdr or self->uneval > 0 or base == None or base->kind != EX_IDENT or base->out_done:
            return
        di: i32 = self->sym_index(base->text)
        if di < 0 or self->locals[di].nn_off or self->locals[di].nn != 2:
            return
        if self->locals[di].type == None or self->locals[di].type->kind != TY_PTR:
            return
        cdiag_at(self->file, pos, "null-dereference", WD_WARN, "'%s' is None here: this dereference will crash", base->text)

    # turns a CHECKED place expression into the pointer a `ref T` stores,
    # demanding the flow's proof when the place lives behind a raw pointer.
    # Returns the expression the declaration/return actually keeps.
    private def bind_ref(self: *Sema, e: *Expr, reft: *Type, pos: Pos, what: const *char) -> *Expr:
        it: *Type = self->type_of(e)
        # a value that is already a ref (another ref, a ref-returning call):
        # the pointer it carries is non-None by construction — copy it
        if it != None and it->kind == TY_PTR and it->is_ref:
            self->check_assign_types(pos, reft, it, e)
            return e
        # `*p`: stealing the place behind a raw pointer takes proof (69.2)
        if e->kind == EX_UNARY and e->op == TK_STAR and e->lhs != None:
            if not is_byref_deref(e):
                proven: bool = False
                if e->lhs->kind == EX_IDENT:
                    pi: i32 = self->sym_index(e->lhs->text)
                    proven = pi >= 0 and not self->locals[pi].nn_off and self->locals[pi].nn == 1
                if not proven:
                    cdiag_at(self->file, pos, "nullability", WD_ERR, "cannot prove this pointer is not None: bind the %s inside `if p != None:` (69.2)", what)
            self->check_assign_types(pos, reft, self->type_of(e->lhs), e->lhs)
            return e->lhs
        if not is_lvalue(e):
            fatal_at(self->file, pos, "a ref aliases a PLACE: the %s must be a variable, field, element or *pointer — not a temporary value", what)
        at: *Expr = take_addr(self->a, e)
        self->check_assign_types(pos, reft, self->type_of(at), at)
        return at

    # `a ?? b` (69.3): b when a is None. Lowered to a hoisted temp + comma so
    # `a` is evaluated exactly once and `b` stays behind the branch — plain
    # C89 (?:), identical in both backends.
    private def lower_coalesce(self: *Sema, e: *Expr):
        self->check_expr(e->lhs)
        clt: *Type = self->type_of(e->lhs)
        if clt == None or clt->kind != TY_PTR:
            fatal_at(self->file, e->pos, "the left side of '??' must be a pointer: '??' is the None test (69.3)")
        if clt->is_ref:
            fatal_at(self->file, e->pos, "the left side of '??' is a ref — it is never None, the right side would be dead (69.1)")
        tname: const *char = self->a->printf("__co%d", self->co_ctr)
        self->co_ctr += 1
        cot: *Type = self->a->alloc(sizeof(Type))
        *cot = *clt
        cot->is_ref = False
        hd: *Stmt = st_new(self->a, ST_VAR, e->pos)
        hd->name = tname
        hd->type = cot
        self->resolve_type(hd->type)
        self->vla_hoist_add(hd)
        chp: *Type = self->a->alloc(sizeof(Type))
        *chp = *cot
        self->fn_hoisted.put(tname, chp)
        asn: *Expr = ex_new(self->a, EX_ASSIGN, e->pos)
        asn->op = TK_ASSIGN
        asn->lhs = mk_ident(self->a, tname, e->pos)
        asn->rhs = e->lhs
        cnd: *Expr = ex_new(self->a, EX_BINARY, e->pos)
        cnd->op = TK_NE
        cnd->lhs = mk_ident(self->a, tname, e->pos)
        cnd->rhs = ex_new(self->a, EX_NONE, e->pos)
        tern: *Expr = ex_new(self->a, EX_TERNARY, e->pos)
        tern->cond = cnd
        tern->lhs = mk_ident(self->a, tname, e->pos)
        tern->rhs = e->rhs
        cma: *Expr = ex_new(self->a, EX_COMMA, e->pos)
        cma->lhs = asn
        cma->rhs = tern
        *e = *cma
        self->check_expr(e)

    # `r: ref T = <place>` (69.1): binds once, auto-derefs forever after — the
    # same rail a `ref v: T` parameter rides. The local's stored type is the
    # pointer; byref=PK_REF makes every later use of the name a load/store
    # through the referent, which is exactly why a rebind cannot be spelled.
    private def check_ref_var(self: *Sema, st: *Stmt):
        if st->is_extern or st->is_static:
            fatal_at(self->file, st->pos, "a ref cannot have a storage class: it binds at a moment in the flow")
        self->resolve_type(st->type)
        if st->init == None:
            fatal_at(self->file, st->pos, "'%s' is a ref and binds at its declaration: `%s: ref T = <place>`", st->name, st->name)
        if st->init->kind == EX_NONE:
            fatal_at(self->file, st->pos, "a ref is never None — if absence is a state, hold a pointer (*T) instead (69.1)")
        self->check_expr(st->init)
        st->init = self->bind_ref(st->init, st->type, st->pos, "ref")
        self->scope_add_x(st->name, st->type, False)
        self->locals[self->nlocals - 1].pos = st->pos
        self->locals[self->nlocals - 1].assigned = True
        self->locals[self->nlocals - 1].byref = PK_REF
        self->locals[self->nlocals - 1].nn = 1

    private def check_assign_types(self: *Sema, pos: Pos, lt: *Type, rt: *Type, rhs: *Expr):
        # a ref where a VALUE of T is expected: load through it (69.1) — the
        # pointer is non-None by construction, so the load is always safe
        if rt != None and rt->kind == TY_PTR and rt->is_ref and lt != None and lt->kind != TY_PTR and lt->kind != TY_ARRAY and rhs != None and type_eq_p(lt, rt->inner):
            rin: *Expr = self->a->alloc(sizeof(Expr))
            *rin = *rhs
            with rhs:
                .kind = EX_UNARY
                .op = TK_STAR
                .lhs = rin
                .rhs = None
                .out_done = True
                .text = None
            rt = rt->inner
        lsi: *SInfo = self->val_struct(lt)
        rsi: *SInfo = self->val_struct(rt)
        if lsi != None and rsi != None:
            if strcmp(lsi->name, rsi->name) != 0:
                fatal_at(self->file, pos, "incompatible types in assignment ('%s' from '%s')", lsi->name, rsi->name)
            return
        if lsi != None and (is_arith_type(rt) or (rt != None and rt->kind == TY_PTR)):
            fatal_at(self->file, pos, "incompatible types in assignment ('%s' from a scalar)", lsi->name)
        if rsi != None and (is_arith_type(lt) or (lt != None and lt->kind == TY_PTR)):
            fatal_at(self->file, pos, "incompatible types in assignment (scalar from '%s')", rsi->name)
        if is_void_val(rt) and lt != None:
            fatal_at(self->file, pos, "void value cannot be assigned")
        if rhs != None and lt != None and self->func_designator(rhs) != None and (is_arith_type(lt) or is_float_type(lt) or lsi != None):
            fatal_at(self->file, pos, "cannot assign a function to a value of non-pointer type")
        if lt != None and is_arith_type(lt) and rt != None and (rt->kind == TY_PTR or rt->kind == TY_ARRAY):
            cdiag_at(self->file, pos, "int-conversion", WD_ERR, "incompatible pointer to integer conversion")
        if lt != None and lt->kind == TY_PTR:
            if is_float_type(rt):
                fatal_at(self->file, pos, "cannot assign a floating value to a pointer")
            # an integer into a pointer without a cast: only the null constant (a
            # literal 0) converts implicitly
            if is_arith_type(rt):
                nullc: bool = rhs != None and rhs->kind == EX_NUMBER and strtoll(rhs->text, None, 0) == 0
                if not nullc:
                    cdiag_at(self->file, pos, "int-conversion", WD_ERR, "incompatible integer to pointer conversion")
            # pointees crossing the integer/floating families never convert
            # implicitly (double* -> long*): both positively arithmetic
            if rt != None and rt->kind == TY_PTR:
                lin: *Type = lt->inner
                rin: *Type = rt->inner
                if is_arith_type(lin) and is_arith_type(rin) and is_float_type(lin) != is_float_type(rin):
                    cdiag_at(self->file, pos, "incompatible-pointer-types", WD_EXTWARN, "incompatible pointer types in assignment")
                # any other pointee mismatch — void* converts freely. Same-width
                # integer pointees differing only in signedness are clang's
                # -Wpointer-sign; everything else -Wincompatible-pointer-types
                elif not is_void_val(lin) and not is_void_val(rin) and not self->type_compat(lin, rin):
                    signish: bool = lin != None and rin != None and lin->kind == TY_NAME and rin->kind == TY_NAME and ctype_width(lin->name) > 0 and ctype_width(lin->name) == ctype_width(rin->name) and not is_float_type(lin) and not is_float_type(rin)
                    if signish:
                        cdiag_at(self->file, pos, "pointer-sign", WD_EXTWARN, "converts between pointers to integer types with different sign")
                    else:
                        cdiag_at(self->file, pos, "incompatible-pointer-types", WD_EXTWARN, "incompatible pointer types in assignment")
                # pointers to DISTINCT struct/union identities (block-scoped tags
                # get distinct cnames), or struct* vs arith* — no implicit conversion
                lps: *SInfo = self->val_struct(lin)
                rps: *SInfo = self->val_struct(rin)
                if lps != None and rps != None and strcmp(lps->name, rps->name) != 0:
                    cdiag_at(self->file, pos, "incompatible-pointer-types", WD_EXTWARN, "incompatible pointer types in assignment ('%s *' from '%s *')", lps->name, rps->name)
                if (lps != None and rps == None and is_arith_type(rin)) or (rps != None and lps == None and is_arith_type(lin)):
                    cdiag_at(self->file, pos, "incompatible-pointer-types", WD_EXTWARN, "incompatible pointer types in assignment")

    # a scalar LEAF of an initializer: assignment compatibility applies
    private def init_leaf(self: *Sema, t: *Type, e: *Expr):
        if e == None:
            return
        self->check_assign_types(e->pos, t, self->type_of(e), e)

    # is this ARG a complete aggregate VALUE (compound literal, cast, struct-typed
    # expression)? It initializes the whole field — elision is for plain scalars.
    # None = unknowable (untyped expr): the caller bails out permissive.
    private def init_arg_class(self: *Sema, e: *Expr) -> i32:
        if e == None:
            return 0
        if e->kind == EX_COMPOUND or e->kind == EX_CAST:
            # the CLASS comes from the cast/literal TYPE: (long)x is a scalar,
            # (struct S){...} is an aggregate value
            ct: *Type = e->cast_type
            if ct == None:
                return -1
            if ct->kind == TY_ARRAY or self->val_struct(ct) != None:
                return 1
            if is_arith_type(ct) or ct->kind == TY_PTR:
                return 0
            return -1
        at: *Type = self->type_of(e)
        if at == None:
            return -1   # unknown: ambiguous between value and elision start
        if at->kind == TY_ARRAY or self->val_struct(at) != None:
            return 1
        return 0        # positively scalar: brace elision applies

    # aggregate we can WALK for elision purposes (defined struct/union or array)
    private def init_walkable(self: *Sema, t: *Type) -> bool:
        if t == None:
            return False
        if t->kind == TY_ARRAY:
            return True
        si: *SInfo = self->val_struct(t)
        return si != None and si->defined

    # consume from a FLAT stream (brace elision): fills `t` from args[idx..]
    private def init_fill_flat(self: *Sema, t: *Type, args: **Expr, nargs: i32, ref idx: i32):
        if idx >= nargs or t == None:
            return
        if t->kind == TY_ARRAY:
            if t->arr_len == None or t->arr_len->kind != EX_NUMBER:
                idx = nargs   # unknown length: bail permissive
                return
            alen: i64 = strtoll(t->arr_len->text, None, 0)
            k: i64 = 0
            while k < alen and idx < nargs:
                fa: *Expr = args[idx]
                if fa != None and fa->kind == EX_DESIG:
                    return   # designator mid-elision: reposition handled above
                in_scalar: bool = is_arith_type(t->inner) or (t->inner != None and t->inner->kind == TY_PTR)
                if fa != None and fa->kind == EX_INITLIST:
                    self->check_init(t->inner, fa, fa->pos)
                    idx += 1
                elif fa != None and fa->kind == EX_STRING and (in_scalar or (t->inner != None and t->inner->kind == TY_ARRAY)):
                    self->check_init(t->inner, fa, fa->pos)
                    idx += 1
                elif self->init_walkable(t->inner):
                    fcl: i32 = self->init_arg_class(fa)
                    if fcl < 0:
                        idx = nargs
                        return
                    if fcl == 1:
                        self->init_leaf(t->inner, fa)
                        idx += 1
                    else:
                        self->init_fill_flat(t->inner, args, nargs, ref idx)
                elif in_scalar:
                    self->init_leaf(t->inner, fa)
                    idx += 1
                else:
                    idx = nargs   # unknown element type: bail permissive
                    return
                k += 1
            return
        fsi: *SInfo = self->val_struct(t)
        if fsi != None and fsi->defined:
            for ff in range(fsi->nfields):
                if idx >= nargs:
                    return
                if init_skip_field(&fsi->fields[ff]):
                    continue
                fb: *Expr = args[idx]
                fbt: *Type = fsi->fields[ff].type
                fb_scalar: bool = is_arith_type(fbt) or (fbt != None and fbt->kind == TY_PTR)
                if fb != None and fb->kind == EX_DESIG:
                    return
                if fb != None and fb->kind == EX_INITLIST:
                    self->check_init(fbt, fb, fb->pos)
                    idx += 1
                elif fb != None and fb->kind == EX_STRING and (fb_scalar or (fbt != None and fbt->kind == TY_ARRAY)):
                    self->check_init(fbt, fb, fb->pos)
                    idx += 1
                elif self->init_walkable(fbt):
                    gcl: i32 = self->init_arg_class(fb)
                    if gcl < 0:
                        idx = nargs
                        return
                    if gcl == 1:
                        self->init_leaf(fbt, fb)
                        idx += 1
                    else:
                        self->init_fill_flat(fbt, args, nargs, ref idx)
                elif fb_scalar:
                    self->init_leaf(fbt, fb)
                    idx += 1
                else:
                    idx = nargs   # unknown field type: bail permissive
                    return
                if fsi->is_union:
                    return   # a union consumes ONE member
            return
        if is_arith_type(t) or t->kind == TY_PTR:
            fc: *Expr = args[idx]
            if fc != None and fc->kind != EX_DESIG:
                self->init_leaf(t, fc)
            idx += 1
            return
        idx = nargs   # unknown type: bail permissive

    # `t` initialized by its own initializer (brace list, string or expression)
    private def check_init(self: *Sema, t: *Type, init: *Expr, pos: Pos):
        if init == None or t == None or self->in_chdr:
            return
        if init->kind == EX_STRING:
            if True:
                # a narrow string only initializes char-width elements; a WIDE
                # literal (L"...") initializes wchar_t — a glibc typedef for int,
                # so any 2/4-byte integer element is accepted for L-strings.
                # Unknown element widths stay permissive.
                wide: bool = init->text != None and init->text[0] == 'L'
                if t->kind == TY_ARRAY and t->inner != None:
                    if t->inner->kind != TY_NAME:
                        fatal_at(self->file, pos, "cannot initialize this array from a string literal (element type is not a character type)")
                    elif t->inner->name != "wchar_t":
                        ew: i32 = ctype_width(t->inner->name)
                        if ew != 0 and ((not wide and ew != 1) or (wide and ew == 1)):
                            fatal_at(self->file, pos, "cannot initialize this array from a string literal (element type width mismatch)")
                if self->val_struct(t) != None:
                    fatal_at(self->file, pos, "cannot initialize a struct/union from a string literal")
                if t->kind == TY_PTR:
                    self->init_leaf(t, init)   # char* vs signed char*: assignment rules
            # string into a char/wchar array: units must fit (== len drops the
            # NUL, which is legal C)
            if t->kind == TY_ARRAY and t->arr_len != None and t->arr_len->kind == EX_NUMBER and t->inner != None and t->inner->kind == TY_NAME:
                en: const *char = t->inner->name
                if ctype_width(en) == 1 or en == "wchar_t":
                    salen: i64 = strtoll(t->arr_len->text, None, 0)
                    units: i32 = init_str_units(init->text)
                    if salen > 0 and units >= 0 and i64(units) > salen:
                        cdiag_at(self->file, pos, "excess-initializers", WD_EXTWARN, "initializer-string for char array is too long (%d units > %lld)", units, salen)
            return
        if init->kind != EX_INITLIST:
            if t->kind == TY_ARRAY:
                fatal_at(self->file, pos, "invalid initializer (an array cannot be initialized from a scalar expression)")
            self->init_leaf(t, init)
            return
        # ----- brace list -----
        if init->nargs == 0:
            return   # {} — GNU/C23: permissive
        if t->kind == TY_ARRAY:
            elem: *Type = t->inner
            aal: i64 = -1
            if t->arr_len != None and t->arr_len->kind == EX_NUMBER:
                aal = strtoll(t->arr_len->text, None, 0)
            cur: i64 = 0
            maxp: i64 = 0
            ai: i32 = 0
            while ai < init->nargs:
                a: *Expr = init->args[ai]
                if a == None:
                    ai += 1
                    cur += 1
                elif a->kind == EX_DESIG:
                    if a->field != None:
                        fatal_at(self->file, a->pos, "'.%s' designator in an ARRAY initializer (use [index])", a->field)
                    if a->rhs == None or a->rhs->kind != EX_NUMBER:
                        return   # non-literal index: bail permissive
                    cur = strtoll(a->rhs->text, None, 0)
                    if aal > 0 and cur >= aal:
                        fatal_at(self->file, a->pos, "array designator index %lld out of bounds (array of %lld)", cur, aal)
                    self->check_init(elem, a->lhs, a->pos)
                    cur += 1
                    ai += 1
                elif a->kind == EX_INITLIST:
                    self->check_init(elem, a, a->pos)
                    ai += 1
                    cur += 1
                elif a->kind == EX_STRING and (elem == None or elem->kind != TY_NAME or is_arith_type(elem) or self->val_struct(elem) == None):
                    self->check_init(elem, a, a->pos)   # string as an element value
                    ai += 1
                    cur += 1
                elif self->init_walkable(elem):
                    acl: i32 = self->init_arg_class(a)
                    if acl < 0:
                        return
                    if acl == 1:
                        self->init_leaf(elem, a)
                        ai += 1
                    else:
                        self->init_fill_flat(elem, init->args, init->nargs, ref ai)
                    cur += 1
                elif is_arith_type(elem) or (elem != None and elem->kind == TY_PTR):
                    self->init_leaf(elem, a)
                    ai += 1
                    cur += 1
                else:
                    return   # unknown element type: bail permissive
                if cur > maxp:
                    maxp = cur
            if aal > 0 and maxp > aal:
                cdiag_at(self->file, pos, "excess-initializers", WD_EXTWARN, "excess elements in array initializer (%lld > %lld)", maxp, aal)
            return
        si: *SInfo = self->val_struct(t)
        if si != None and si->defined:
            # anonymous members make designator paths ambiguous for us: bail on
            # designators into structs that have them
            has_anon: bool = False
            for hf in range(si->nfields):
                if si->fields[hf].anon != None:
                    has_anon = True
            fi: i32 = 0
            ai2: i32 = 0
            while ai2 < init->nargs:
                b: *Expr = init->args[ai2]
                if b == None:
                    ai2 += 1
                    fi += 1
                    continue
                if b->kind == EX_DESIG:
                    if b->field == None:
                        fatal_at(self->file, b->pos, "[index] designator in a struct/union initializer (use .field)")
                    if has_anon:
                        return   # .x may live inside an anonymous member: bail
                    nf: i32 = -1
                    for sf in range(si->nfields):
                        if si->fields[sf].name != None and strcmp(si->fields[sf].name, b->field) == 0:
                            nf = sf
                    if nf < 0:
                        sgf: Sugg
                        sgf.init(b->field)
                        for sg in range(si->nfields):
                            sgf.feed(si->fields[sg].name)
                        fatal_at(self->file, b->pos, "%s '%s' has no member named '%s'%s", "union" if si->is_union else "struct", si->name, b->field, self->sugg_text(&sgf))
                    self->check_init(si->fields[nf].type, b->lhs, b->pos)
                    fi = nf + 1
                    ai2 += 1
                    continue
                while fi < si->nfields and init_skip_field(&si->fields[fi]):
                    fi += 1
                if fi >= si->nfields:
                    cdiag_at(self->file, pos, "excess-initializers", WD_EXTWARN, "excess elements in %s initializer ('%s')", "union" if si->is_union else "struct", si->name)
                    return
                ft: *Type = si->fields[fi].type
                ft_scalar: bool = is_arith_type(ft) or (ft != None and ft->kind == TY_PTR)
                if b->kind == EX_INITLIST:
                    self->check_init(ft, b, b->pos)
                    ai2 += 1
                elif b->kind == EX_STRING and (ft_scalar or (ft != None and ft->kind == TY_ARRAY)):
                    self->check_init(ft, b, b->pos)   # string fills a char array/pointer
                    ai2 += 1
                elif self->init_walkable(ft):
                    bcl: i32 = self->init_arg_class(b)
                    if bcl < 0:
                        return   # untyped expr against an aggregate field: bail
                    if bcl == 1:
                        self->init_leaf(ft, b)   # complete aggregate value
                        ai2 += 1
                    else:
                        self->init_fill_flat(ft, init->args, init->nargs, ref ai2)
                elif ft_scalar:
                    self->init_leaf(ft, b)
                    ai2 += 1
                else:
                    return   # unknown/incomplete field type: bail permissive
                if si->is_union:
                    if ai2 < init->nargs:
                        cdiag_at(self->file, pos, "excess-initializers", WD_EXTWARN, "excess elements in union initializer ('%s')", si->name)
                    return
                fi += 1
            return
        # scalar/pointer with braces: a single (optionally braced) element
        if is_arith_type(t) or t->kind == TY_PTR:
            if init->nargs > 1:
                fatal_at(self->file, pos, "too many elements in scalar initializer")
            if init->args[0] != None and init->args[0]->kind != EX_DESIG:
                self->check_init(t, init->args[0], pos)
        return

    # a VALUE of a forward-declared-but-never-defined struct/union cannot exist.
    # Arrays of it either (walks to the base). Pointers stay opaque (legal), and
    # ingested headers are skipped (in_chdr) like the rest of the strict checks.
    private def require_defined(self: *Sema, t: *Type, pos: Pos):
        if self->in_chdr:
            return
        base: *Type = t
        while base != None and base->kind == TY_ARRAY:
            base = base->inner
        if base == None or base->kind != TY_NAME:
            return
        si: *SInfo = self->find_struct(base->name)
        if si != None and not si->defined:
            fatal_at(self->file, pos, "variable has incomplete type '%s %s' (forward-declared but never defined)", "union" if si->is_union else "struct", si->name)

    # pointer-aware binary operator validity (only when BOTH types are known):
    # *, /, %, bitwise and shifts take no pointers; ptr+ptr is invalid; pointer
    # arithmetic needs an integer (not float) on the other side; scalar - ptr is
    # invalid. Comparisons are left alone (p == 0 is idiomatic).
    # compound assignment (+=, -=, *=, ...) shares the binary operators' typing
    # rules: pointer arithmetic only via ptr +=/-= integer; the rest scalar-only
    private def check_compound_types(self: *Sema, pos: Pos, op: i32, lhs: *Expr, rhs: *Expr):
        self->require_scalar(lhs, "compound assignment")
        self->require_scalar(rhs, "compound assignment")
        lt: *Type = self->type_of(lhs)
        rt: *Type = self->type_of(rhs)
        if (lt != None and lt->kind == TY_FUNC) or (rt != None and rt->kind == TY_FUNC) or self->func_designator(lhs) != None or self->func_designator(rhs) != None:
            fatal_at(self->file, pos, "a function is not a valid operand of compound assignment")
        lp: bool = lt != None and lt->kind == TY_PTR
        rp: bool = rt != None and (rt->kind == TY_PTR or rt->kind == TY_ARRAY)
        if op == TK_PLUS_EQ or op == TK_MINUS_EQ:
            if lp:
                if rp:
                    fatal_at(self->file, pos, "invalid pointer operands of compound assignment (cannot add/subtract two pointers in place)")
                if is_float_type(rt):
                    fatal_at(self->file, pos, "pointer arithmetic requires an integer operand")
                if is_void_val(lt->inner):
                    cdiag_at(self->file, pos, "pointer-arith", wd_pedantic(), "arithmetic on a pointer to void is a GNU extension")
            elif rp:
                fatal_at(self->file, pos, "invalid pointer operand of compound assignment")
        else:
            if lp or rp:
                fatal_at(self->file, pos, "invalid pointer operand of compound assignment (only += and -= apply to pointers)")
            if (op in {TK_PERCENT_EQ, TK_AMP_EQ, TK_PIPE_EQ, TK_CARET_EQ, TK_SHL_EQ, TK_SHR_EQ}) and (is_float_type(lt) or is_float_type(rt)):
                fatal_at(self->file, pos, "operator requires integer operands (floating value given)")

    private def check_binop_types(self: *Sema, e: *Expr):
        if self->func_designator(e->lhs) != None or self->func_designator(e->rhs) != None:
            # functions decay to pointers: comparisons are fine, arithmetic is not
            if e->op in {TK_PLUS, TK_MINUS, TK_STAR, TK_SLASH, TK_PERCENT, TK_AMP, TK_PIPE, TK_CARET, TK_SHL, TK_SHR}:
                fatal_at(self->file, e->pos, "invalid operands of binary operator (a function used as a value)")
        lt: *Type = self->type_of(e->lhs)
        rt: *Type = self->type_of(e->rhs)
        if lt == None or rt == None:
            return
        if is_void_val(lt) or is_void_val(rt):
            fatal_at(self->file, e->pos, "void value used in a binary expression")
        lp: bool = lt->kind == TY_PTR or lt->kind == TY_ARRAY
        rp: bool = rt->kind == TY_PTR or rt->kind == TY_ARRAY
        # +/- over a pointer needs a COMPLETE pointee (sizeof is the stride)
        if (e->op == TK_PLUS or e->op == TK_MINUS) and not self->in_chdr:
            bsl: *SInfo = self->val_struct(lt->inner) if lt->kind == TY_PTR else None
            bsr: *SInfo = self->val_struct(rt->inner) if rt->kind == TY_PTR else None
            if (bsl != None and not bsl->defined) or (bsr != None and not bsr->defined):
                fatal_at(self->file, e->pos, "pointer arithmetic on an incomplete struct/union type")
        lvp: bool = lt->kind == TY_PTR and is_void_val(lt->inner)
        rvp: bool = rt->kind == TY_PTR and is_void_val(rt->inner)
        match e->op:
            case TK_PERCENT, TK_AMP, TK_PIPE, TK_CARET, TK_SHL, TK_SHR:
                if lp or rp:
                    fatal_at(self->file, e->pos, "invalid pointer operand of binary operator (only +, - and comparisons apply to pointers)")
                if is_float_type(lt) or is_float_type(rt):
                    fatal_at(self->file, e->pos, "operator requires integer operands (floating value given)")
            case TK_STAR, TK_SLASH:
                if lp or rp:
                    fatal_at(self->file, e->pos, "invalid pointer operand of binary operator (only +, - and comparisons apply to pointers)")
            case TK_PLUS:
                if lp and rp:
                    fatal_at(self->file, e->pos, "cannot add two pointers")
                if (lp or rp) and is_float_type(rt if lp else lt):
                    fatal_at(self->file, e->pos, "pointer arithmetic requires an integer operand")
                if lvp or rvp:
                    cdiag_at(self->file, e->pos, "pointer-arith", wd_pedantic(), "arithmetic on a pointer to void is a GNU extension")
            case TK_MINUS:
                if rp and not lp:
                    fatal_at(self->file, e->pos, "cannot subtract a pointer from a scalar")
                if lp and rp and not self->type_compat(lt->inner, rt->inner):
                    fatal_at(self->file, e->pos, "subtraction of incompatible pointer types")
                if lp and not rp and is_float_type(rt):
                    fatal_at(self->file, e->pos, "pointer arithmetic requires an integer operand")
                if lvp or rvp:
                    cdiag_at(self->file, e->pos, "pointer-arith", wd_pedantic(), "arithmetic on a pointer to void is a GNU extension")
            case TK_EQ, TK_NE, TK_LT, TK_LE, TK_GT, TK_GE:
                # pointer vs positively-arithmetic value: only the null constant
                # (literal 0) compares with ==/!=
                if lp != rp and is_arith_type(rt if lp else lt):
                    cmpo: *Expr = e->rhs if lp else e->lhs
                    nullok: bool = (e->op == TK_EQ or e->op == TK_NE) and cmpo != None and cmpo->kind == EX_NUMBER and strtoll(cmpo->text, None, 0) == 0
                    if not nullok:
                        cdiag_at(self->file, e->pos, "pointer-integer-compare", WD_EXTWARN, "comparison between pointer and integer")
                # relational (<, >, <=, >=) between void* and an OBJECT pointer is
                # a constraint violation (equality with void* is fine)
                if (e->op in {TK_LT, TK_GT, TK_LE, TK_GE}) and lp and rp:
                    lvq: bool = lt->kind == TY_PTR and is_void_val(lt->inner)
                    rvq: bool = rt->kind == TY_PTR and is_void_val(rt->inner)
                    if lvq != rvq:
                        cdiag_at(self->file, e->pos, "compare-distinct-pointer-types", WD_EXTWARN, "ordered comparison between 'void *' and an object pointer")
                # pointers to DISTINCT struct/union identities never compare
                if lp and rp and lt->kind == TY_PTR and rt->kind == TY_PTR:
                    lqs: *SInfo = self->val_struct(lt->inner)
                    rqs: *SInfo = self->val_struct(rt->inner)
                    if lqs != None and rqs != None and strcmp(lqs->name, rqs->name) != 0:
                        cdiag_at(self->file, e->pos, "compare-distinct-pointer-types", WD_EXTWARN, "comparison of distinct pointer types ('%s *' vs '%s *')", lqs->name, rqs->name)
                # incompatible pointees never compare (void* is the wildcard for
                # ==/!=; arrays compare through their decayed element type)
                if lp and rp:
                    cpl: *Type = lt->inner
                    cpr: *Type = rt->inner
                    lvd: bool = lt->kind == TY_PTR and is_void_val(cpl)
                    rvd: bool = rt->kind == TY_PTR and is_void_val(cpr)
                    eqop: bool = e->op == TK_EQ or e->op == TK_NE
                    if not (eqop and (lvd or rvd)) and not lvd and not rvd and not self->type_compat(cpl, cpr):
                        cdiag_at(self->file, e->pos, "compare-distinct-pointer-types", WD_EXTWARN, "comparison of incompatible pointer types")
            case _:
                return

    private def resolve_gcall(self: *Sema, e: *Expr):
        callee: *Expr = e->lhs
        if callee == None or callee->kind != EX_IDENT:
            return
        ftpl: *Func = self->func_templates.get_or(callee->text, None)
        if ftpl == None:
            return
        for ai in range(e->nargs):
            self->check_expr(e->args[ai])
        targs: **Type = self->a->alloc(usize(ftpl->ntparams) * sizeof(*targs))
        for ti in range(ftpl->ntparams):
            found: *Type = None
            for pj in range(ftpl->nparams):
                if pj >= e->nargs:
                    break
                found = unify_tparam(ftpl->params[pj].type, self->type_of(e->args[pj]), ftpl->tparams[ti])
                if found != None:
                    break
            if found == None:
                fatal_at(self->file, e->pos, "cannot infer type parameter '%s' of generic function '%s' (no argument constrains it)", ftpl->tparams[ti], callee->text)
            targs[ti] = found
            # `def sort<T: Comparable>` (67.1): the bound is checked HERE, where
            # the concrete type is known. That is what makes the calls inside the
            # body direct — the trait never becomes a vtable, it becomes a
            # promise the compiler verified before monomorphizing.
            if ftpl->tbounds != None and ftpl->tbounds[ti] != None:
                self->check_bound(found, ftpl->tbounds[ti], ftpl->tparams[ti], e->pos)
        g: *Type = ty_name(self->a, callee->text)
        g->targs = targs
        g->ntargs = ftpl->ntparams
        mangled: *char = self->mangle_instance(g)
        if not self->funcs.has(mangled):
            fatal_at(self->file, e->pos, "generic function '%s' not instantiated for these types — 'declare %s<...>' and 'implement %s<...>' before use", callee->text, callee->text, callee->text)
        callee->text = mangled

    private def check_expr(self: *Sema, e: *Expr):
        if e == None:
            return
        match e->kind:
            case EX_LAMBDA:
                # a legitimate one never gets here: `lam_fix` replaces it the
                # moment the context type is known
                fatal_at(self->file, e->pos, "a lambda needs a function type from what receives it (65.4/68.7): annotate the variable, the parameter or the return, as in `f: def(i32) -> i32 = lambda x: x * 2`")
            case EX_FSTRING:
                # a legitimate one never gets here: `fstr_expand` replaces it in
                # the argument list before any argument is checked
                fatal_at(self->file, e->pos, "an f-string only works as the format argument of a variadic call (65.2): it is resolved at COMPILE TIME into a format plus arguments, and P has no runtime to build a string with")
            case EX_CALL:
                self->resolve_gcall(e)   # def foo<T> template call -> foo_int
                # `ns.f(...)` is a QUALIFIED call, never a method call: resolve
                # the alias first, so everything below sees the plain name
                self->try_ns_ref(e->lhs)
                callee: *Expr = e->lhs
                # a callee that is a C-header alias macro (`#define ma_fn ma_real_fn`)
                # resolves to its target BEFORE anything downstream looks the name
                # up — otherwise this reads as an implicit function declaration
                if callee != None and callee->kind == EX_IDENT and self->find_func(callee->text) == None and self->scope_find(callee->text) == None and self->globals.get_or(callee->text, None) == None:
                    self->macro_alias_rewrite(callee)
                # 65.2: an f-string argument becomes a format plus arguments
                # BEFORE anything downstream counts arguments or checks types
                self->fstr_expand(e)
                # call to a `const def`: evaluated at compile time and folded to a literal.
                # Comptime-only: args must be constants, otherwise it's an error.
                if callee->kind == EX_IDENT:
                    cfn: *Func = self->find_func(callee->text)
                    if cfn != None and cfn->is_comptime:
                        for ci in range(e->nargs):
                            self->check_expr(e->args[ci])
                        cok: bool = True
                        rv: CVal = self->ccall(cfn, e, None, ref cok)
                        if not cok:
                            fatal_at(self->file, e->pos, "'const def %s' must be called with constant arguments (compile-time only)", callee->text)
                        if rv.kind == CV_STR:
                            e->kind = EX_STRING
                            e->text = rv.sval
                        elif rv.kind == CV_FLOAT:
                            e->kind = EX_NUMBER
                            e->text = cfloat_text(self->a, rv.fval)
                        else:
                            e->kind = EX_NUMBER
                            e->text = self->a->printf("%lld", rv.ival)
                        return
                # is_defined(NAME): 1 if NAME is a const known at compile time
                # (including the ones injected by the driver via -D), 0 otherwise. The
                # argument is a NAME (not evaluated) — resolves to a literal, feeds the `if`.
                if callee->kind == EX_IDENT and callee->text == "is_defined" and e->nargs == 1 and e->args[0]->kind == EX_IDENT:
                    with e:
                        .kind = EX_NUMBER
                        .text = "1" if self->constvals.has(e->args[0]->text) else "0"
                        .lhs = None
                        .args = None
                        .nargs = 0
                    return
                # len(arr): compile-time element count of a fixed array T[N]. Lowered
                # to the idiomatic `sizeof(arr)/sizeof(arr[0])` — a C constant expr the
                # target evaluates (QBE folds it), and sizeof(elem) cancels, so the
                # result is N regardless of the target's struct layout. `len` is
                # contextual: a user function named `len` takes precedence.
                if callee->kind == EX_IDENT and callee->text == "len" and e->nargs == 1 and self->find_func(callee->text) == None:
                    arr: *Expr = e->args[0]
                    self->check_expr(arr)
                    at: *Type = self->type_of(arr)
                    if at == None or at->kind != TY_ARRAY or at->arr_len == None:
                        fatal_at(self->file, e->pos, "len(x) requires a fixed-size array (T[N])")
                    zero: *Expr = ex_new(self->a, EX_NUMBER, e->pos)
                    zero->text = "0"
                    idx0: *Expr = ex_new(self->a, EX_INDEX, e->pos)
                    idx0->lhs = arr
                    idx0->rhs = zero
                    with e:
                        .kind = EX_BINARY
                        .op = TK_SLASH
                        .lhs = mk_call1(self->a, "sizeof", arr, e->pos)
                        .rhs = mk_call1(self->a, "sizeof", idx0, e->pos)
                        .args = None
                        .nargs = 0
                    return
                # sizeof(T): an argument that is a type name becomes a type reference,
                # so the backend can translate aliases (sizeof(u32) -> sizeof(uint32_t))
                if callee->kind == EX_IDENT and callee->text == "sizeof" and e->nargs == 1 and e->args[0]->kind == EX_IDENT and self->is_type_name(e->args[0]->text):
                    if e->args[0]->text == "void":
                        cdiag_at(self->file, e->pos, "pointer-arith", wd_pedantic(), "invalid application of 'sizeof' to a void type (GNU: sizeof(void) == 1)")
                    e->args[0]->kind = EX_TYPEREF
                    e->args[0]->cast_type = ty_name(self->a, e->args[0]->text)
                    # resolved like any other type: without this, `sizeof(x)`
                    # where x is a C TAG (`struct pollfd`, with no typedef)
                    # emitted a bare `pollfd`, which is not C
                    self->resolve_type(e->args[0]->cast_type)
                    return
                # sizeof of a FUNCTION designator, of void, or of a never-defined
                # struct tag — all incomplete (checked only with positive knowledge)
                if callee->kind == EX_IDENT and callee->text == "sizeof" and e->nargs == 1 and self->find_func(callee->text) == None:
                    sza: *Expr = e->args[0]
                    if sza->kind == EX_IDENT and self->scope_find(sza->text) == None and self->globals.get_or(sza->text, None) == None and self->find_func(sza->text) != None:
                        fatal_at(self->file, e->pos, "invalid application of 'sizeof' to a function")
                    if sza->kind == EX_TYPEREF and sza->cast_type != None and not self->in_chdr:
                        self->check_void_array(sza->cast_type, e->pos)
                    if sza->kind != EX_TYPEREF and not self->in_chdr:
                        szet: *Type = self->type_of(sza)
                        szes: *SInfo = self->val_struct(szet)
                        if szes != None and not szes->defined:
                            fatal_at(self->file, e->pos, "invalid application of 'sizeof' to incomplete type '%s'", szes->name)
                        if is_void_val(szet):
                            cdiag_at(self->file, e->pos, "pointer-arith", wd_pedantic(), "invalid application of 'sizeof' to a void type (GNU: sizeof(void) == 1)")
                    if sza->kind == EX_TYPEREF and sza->cast_type != None and sza->cast_type->kind == TY_NAME and not self->in_chdr:
                        if is_void_val(sza->cast_type):
                            cdiag_at(self->file, e->pos, "pointer-arith", wd_pedantic(), "invalid application of 'sizeof' to a void type (GNU: sizeof(void) == 1)")
                        szsi: *SInfo = self->find_struct(sza->cast_type->name)
                        if szsi != None and not szsi->defined:
                            fatal_at(self->file, e->pos, "invalid application of 'sizeof' to incomplete type '%s'", szsi->name)
                # typestr(x): static type of x as a string literal, at compile time.
                # Rewrites the node to EX_STRING (P spelling). In a template it's
                # resolved per instance (the clone is checked with a concrete T).
                if callee->kind == EX_IDENT and callee->text == "typestr" and e->nargs == 1:
                    tn: const *char = render_type_p(self->a, self->type_of(e->args[0]))
                    with e:
                        .kind = EX_STRING
                        .text = self->a->printf("\"%s\"", tn)
                        .lhs = None
                        .args = None
                        .nargs = 0
                    return
                # hasfield(x, "name"): does x's struct/union declare that member?
                # Folded to True/False at compile time, so `if hasfield(...)` prunes
                # and the DEAD branch is never type-checked (see ST_IF above) — the
                # branch may name a field that does not exist on this platform.
                #
                # This is the answer to a C-struct shape that differs per libc, of
                # which the modification time is the standard example: glibc's
                # `struct stat` carries `st_mtim` (POSIX.1-2008), macOS carries
                # `st_mtimespec`, and the portable `st_mtime` is a MACRO on both, so
                # it vanishes on header ingest and P cannot spell it. Consistent with
                # never abstracting libc: adapt to the shape libc actually has.
                if callee->kind == EX_IDENT and callee->text == "hasfield" and e->nargs == 2:
                    hf: bool = self->hasfield_of(e)
                    with e:
                        .kind = EX_TRUE if hf else EX_FALSE
                        .text = None
                        .lhs = None
                        .args = None
                        .nargs = 0
                    return
                # T(x) where T was a type parameter (monomorphized to EX_TYPEREF)
                if callee->kind == EX_TYPEREF:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "cast requires exactly 1 argument")
                    targ: *Expr = e->args[0]
                    self->check_expr(targ)
                    with e:
                        .kind = EX_CAST
                        .cast_type = callee->cast_type
                        .lhs = targ
                        .args = None
                        .nargs = 0
                    return
                # Python-style cast: T(x) when T is a known type — a FUNCTION with
                # the same name wins (C tags live in their own namespace)
                if callee->kind == EX_IDENT and self->is_type_name(callee->text) and self->find_func(callee->text) == None:
                    # `Vec(1.0, 2.0)` on a RECORD builds a value (65.1). It is not
                    # ambiguous with the cast above: casting a scalar to an
                    # aggregate is meaningless in C, so on a record a call is
                    # always construction, whatever the argument count.
                    csi: *SInfo = self->find_struct(callee->text)
                    if csi != None and csi->is_record:
                        self->record_ctor(e, csi)
                        return
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "cast %s(...) requires exactly 1 argument", callee->text)
                    arg: *Expr = e->args[0]
                    self->check_expr(arg)
                    with e:
                        .kind = EX_CAST
                        .cast_type = ty_name(self->a, callee->text)
                        .lhs = arg
                        .args = None
                        .nargs = 0
                    return
                # method sugar: recv.m(a) / recv->m(a)
                if callee->kind == EX_FIELD:
                    recv: *Expr = callee->lhs
                    self->check_expr(recv)
                    rt: *Type = self->type_of(recv)
                    sname: const *char = None
                    recv_is_ptr: bool = False
                    if rt != None and rt->kind == TY_NAME:
                        sname = rt->name
                    elif rt != None and rt->kind == TY_PTR and rt->inner != None and rt->inner->kind == TY_NAME:
                        sname = rt->inner->name; recv_is_ptr = True
                    si: *SInfo = self->find_struct(sname) if sname != None else None
                    if si != None:
                        mth: *Func = sinfo_method(si, callee->field)
                        if mth != None:
                            self->resolve_call_args(e, mth, 1)
                            # receiver adapts to the METHOD's self: a `self: *T`
                            # takes the address of a value receiver; a by-value
                            # `self: T` (read-only intent) takes the value — and
                            # dereferences a pointer receiver.
                            self_by_val: bool = mth->nparams > 0 and mth->params[0].type != None and mth->params[0].type->kind != TY_PTR
                            # byref self: `out self` DEFINITELY ASSIGNS the receiver
                            # (v.init() counts as initialization); ref/in read it
                            if mth->nparams > 0 and mth->params[0].byref != PK_NONE and recv != None and recv->kind == EX_IDENT:
                                rvi: i32 = self->sym_index(recv->text)
                                if rvi >= 0:
                                    if mth->params[0].byref == PK_OUT:
                                        self->locals[rvi].assigned = True
                                        self->locals[rvi].written = True
                                    else:
                                        self->locals[rvi].read = True
                            selfx: *Expr = recv
                            if self_by_val and recv_is_ptr:
                                selfx = ex_new(self->a, EX_UNARY, recv->pos)
                                selfx->op = TK_STAR
                                selfx->lhs = recv
                            elif not self_by_val and not recv_is_ptr:
                                if not is_lvalue(recv) and recv->kind != EX_STRING:
                                    # rvalue: only `in self` (read-only) may materialize a temporary
                                    if mth->nparams > 0 and mth->params[0].byref == PK_IN:
                                        selfx = self->materialize_temp(recv, "'in' receiver expression")
                                    else:
                                        kwn: const *char = "ref" if mth->nparams > 0 and mth->params[0].byref == PK_REF else ("out" if mth->nparams > 0 and mth->params[0].byref == PK_OUT else "*")
                                        fatal_at(self->file, recv->pos, "method '%s' takes '%s self' (it may write through it), so the receiver must be an lvalue (a variable, field, array element or *pointer)", callee->field, kwn)
                                else:
                                    selfx = take_addr(self->a, recv)
                            args: **Expr = None
                            n = 0; cn = 0
                            args = vec_grow(args, n, ref cn, sizeof(*args))
                            args[n] = selfx
                            n += 1
                            for i in range(e->nargs):
                                if i + 1 < mth->nparams:
                                    self->check_byref_kw(e->args[i], mth, i + 1)
                                    self->lam_fix(e->args[i], mth->params[i + 1].type)   # 65.4
                                self->check_expr(e->args[i])
                                args = vec_grow(args, n, ref cn, sizeof(*args))
                                args[n] = e->args[i]
                                n += 1
                            fn: *Expr = ex_new(self->a, EX_IDENT, callee->pos)
                            fn->text = mth->cname
                            e->lhs = fn
                            e->args = args
                            e->nargs = n
                            return
                        if sinfo_field(si, callee->field) == None:
                            sgm: Sugg
                            sgm.init(callee->field)
                            for mi in range(si->nmethods):
                                sgm.feed(si->methods[mi]->name)
                            for fi in range(si->nfields):
                                sgm.feed(si->fields[fi].name)
                            fatal_at(self->file, callee->pos, "struct %s has no method or field '%s'%s", sname, callee->field, self->sugg_text(&sgm))
                        # field that is a function pointer: normal call
                        self->fix_field_op(callee)
                    # unknown type: pass it through as is
                    for j in range(e->nargs):
                        self->check_expr(e->args[j])
                    return
                # calling a plain variable that is positively NOT a function pointer
                # ('int x = 2; x();'). Unknown callees stay: implicit C fn (interop).
                if callee->kind in {EX_NUMBER, EX_CHARLIT, EX_STRING}:
                    fatal_at(self->file, e->pos, "called object is not a function or function pointer")
                if callee->kind == EX_IDENT:
                    cvt: *Type = self->scope_find(callee->text)
                    if cvt == None and self->find_func(callee->text) == None:
                        cvt = self->globals.get_or(callee->text, None)
                    # a VARIABLE in scope shadows any function of the same name
                    if cvt != None and (is_arith_type(cvt) or self->val_struct(cvt) != None):
                        fatal_at(self->file, e->pos, "called object '%s' is not a function or function pointer", callee->text)
                    # C99: calling a name declared NOWHERE is an implicit function
                    # declaration — an error in user C code (headers stay tolerant)
                    if cvt == None and self->find_func(callee->text) == None and not self->in_chdr and not self->is_type_name(callee->text) and not self->is_enum_const(callee->text) and callee->text not in {"sizeof", "_Alignof", "__alignof__"} and strncmp(callee->text, "__builtin_", 10) != 0 and strncmp(callee->text, "va_", 3) != 0 and callee->text not in {"offsetof", "assert", "static_assert", "_Static_assert"}:
                        # the name may be perfectly well defined — just further
                        # down. That is an ORDERING problem, and saying so beats
                        # sending the reader off to look for a missing function.
                        dl: i64 = self->later_defs.get_or(callee->text, 0)
                        if dl > i64(e->pos.line):
                            cdiag_at(self->file, e->pos, "implicit-function-declaration", WD_ERR,
                                     "'%s' is only declared further down in this file (line %lld): move it above this call, or add a forward 'def' line (no body) before this point",
                                     callee->text, dl)
                        cdiag_at(self->file, e->pos, "implicit-function-declaration", WD_ERR, "implicit declaration of function '%s'", callee->text)
                # arity: a call through the function NAME with a KNOWN signature
                # must pass the right number of arguments ('()' protos stay open)
                if callee->kind == EX_IDENT and self->scope_find(callee->text) == None and self->globals.get_or(callee->text, None) == None:
                    afn: *Func = self->find_func(callee->text)
                    if afn != None and afn->ntparams == 0 and afn->owner == None and not self->in_chdr:
                        self->resolve_call_args(e, afn, 0)
                        rvs: *SInfo = self->val_struct(afn->ret)
                        if rvs != None and not rvs->defined:
                            fatal_at(self->file, e->pos, "calling '%s', which returns the incomplete type '%s'", callee->text, rvs->name)
                        if afn->nparams > 0 or afn->is_varargs or not afn->sig_empty:
                            if e->nargs < afn->nparams:
                                fatal_at(self->file, e->pos, "too few arguments to function '%s' (%d given, %d expected)", callee->text, e->nargs, afn->nparams)
                            if e->nargs > afn->nparams and not afn->is_varargs:
                                fatal_at(self->file, e->pos, "too many arguments to function '%s' (%d given, %d expected)", callee->text, e->nargs, afn->nparams)
                            # each argument converts to its parameter as if by
                            # assignment (C11 6.5.2.2p7) — P calls are held to the
                            # same standard
                            if True:
                                for pai in range(e->nargs):
                                    if pai >= afn->nparams:
                                        break
                                    self->check_byref_kw(e->args[pai], afn, pai)
                                    self->lam_fix(e->args[pai], afn->params[pai].type)   # 65.4
                                    self->check_expr(e->args[pai])
                                    self->check_assign_types(e->args[pai]->pos, afn->params[pai].type, self->type_of(e->args[pai]), e->args[pai])
                prevcal: bool = self->in_callee
                self->in_callee = True
                self->check_expr(callee)
                self->in_callee = prevcal
                unev: bool = callee->kind == EX_IDENT and callee->text != None and (callee->text in {"sizeof", "_Alignof", "__alignof__", "alignof"})
                if unev:
                    self->uneval += 1
                for k in range(e->nargs):
                    if e->args[k] != None and e->args[k]->kind == EX_DESIG and e->args[k]->field != None:
                        fatal_at(self->file, e->args[k]->pos, "named argument '%s=' in a call the compiler cannot resolve (unknown or indirect function)", e->args[k]->field)
                    self->check_expr(e->args[k])
                    if not self->in_chdr:
                        cat: *Type = self->type_of(e->args[k])
                        cas: *SInfo = self->val_struct(cat)
                        if cas != None and not cas->defined:
                            fatal_at(self->file, e->pos, "argument %d has incomplete type '%s'", k + 1, cas->name)
                if unev:
                    self->uneval -= 1
                return
            case EX_CAST:
                if e->cast_tentative:
                    base: *Type = e->cast_type
                    stars = 0
                    while base->kind == TY_PTR:
                        stars += 1
                        base = base->inner
                    if not self->is_type_name(base->name):
                        # (*p)(x) wasn't a cast: becomes a call through dereference
                        fn2: *Expr = ex_new(self->a, EX_IDENT, e->pos)
                        fn2->text = base->name
                        deref: *Expr = fn2
                        for k2 in range(stars):
                            u: *Expr = ex_new(self->a, EX_UNARY, e->pos)
                            u->op = TK_STAR
                            u->lhs = deref
                            deref = u
                        args2: **Expr = None
                        n2 = 0; cn2 = 0
                        args2 = vec_grow(args2, n2, ref cn2, sizeof(*args2))
                        args2[n2] = e->lhs
                        n2 += 1
                        with e:
                            .kind = EX_CALL
                            .lhs = deref
                            .args = args2
                            .nargs = n2
                            .cast_type = None
                            .cast_tentative = False
                        self->check_expr(e)
                        return
                    e->cast_tentative = False
                self->check_expr(e->lhs)
                # the cast TYPE is resolved too: a C tag with no typedef has to
                # be spelled `struct X` in the cast, exactly as in a declaration
                if e->cast_type != None:
                    self->resolve_type(e->cast_type)
                cct: *Type = e->cast_type
                cet: *Type = self->type_of(e->lhs)
                if cct != None and not self->in_chdr:
                    self->check_void_array(cct, e->pos)
                    if cct->kind == TY_ARRAY:
                        fatal_at(self->file, e->pos, "cast specifies array type")
                    if cct->kind == TY_FUNC:
                        fatal_at(self->file, e->pos, "cast specifies a function type")
                    if True:
                        cets: *Type = self->type_of(e->lhs)
                        if is_void_val(cets) and not is_void_val(cct):
                            fatal_at(self->file, e->pos, "cannot cast a void value to a non-void type")
                        csrc: *SInfo = self->val_struct(cets)
                        ctgt: *SInfo = self->val_struct(cct)
                        if csrc != None and not csrc->defined:
                            fatal_at(self->file, e->pos, "cast uses a value of incomplete type '%s'", csrc->name)
                        if csrc != None and ctgt == None and (is_arith_type(cct) or cct->kind == TY_PTR):
                            fatal_at(self->file, e->pos, "cannot cast a struct/union value to a scalar type")
                        if ctgt != None and not ctgt->defined and e->lhs != None and (e->lhs->kind == EX_INITLIST or e->lhs->kind == EX_COMPOUND):
                            fatal_at(self->file, e->pos, "compound literal of incomplete type '%s'", ctgt->name)
                # conversion to a non-scalar type: (struct s)x is invalid C — a
                # struct value only comes from a compound literal (struct s){...}
                if cct != None and cct->kind == TY_NAME and self->c_mod and (cct->tag_kind != TAG_NONE or self->val_struct(cct) != None):
                    # (struct S){...} is a COMPOUND LITERAL, not a conversion; and
                    # GNU accepts the no-op self-cast (struct S)expr_of_struct_S
                    is_complit: bool = e->lhs != None and (e->lhs->kind == EX_INITLIST or e->lhs->kind == EX_COMPOUND)
                    cslhs: *SInfo = self->val_struct(self->type_of(e->lhs))
                    self_cast: bool = cslhs != None and strcmp(cslhs->name, cct->name) == 0
                    # the GNU no-op self-cast `(struct S)expr_of_S` (and cast-to-
                    # union) is accepted by default; -pedantic flags the constraint
                    # violation C11 6.5.4p2 says it is (clang: [-Wpedantic])
                    if not is_complit and not self_cast:
                        fatal_at(self->file, e->pos, "conversion to non-scalar struct/union type")
                    if not is_complit and self_cast:
                        cdiag_at(self->file, e->pos, "pedantic", wd_pedantic(), "cast to a struct/union type of the same type is a GNU extension")
                if cct != None and cet != None:
                    if cct->kind == TY_PTR and is_float_type(cet):
                        fatal_at(self->file, e->pos, "cannot cast a floating value to a pointer")
                    if is_float_type(cct) and (cet->kind == TY_PTR or cet->kind == TY_ARRAY):
                        fatal_at(self->file, e->pos, "cannot cast a pointer to a floating type")
                return
            case EX_VAARG:
                self->resolve_type(e->cast_type)
                self->check_expr(e->lhs)
                return
            case EX_WITHSELF:
                # implicit receiver of `.field`: resolves to the hidden pointer of the
                # innermost `with`. Rewrites the node as EX_IDENT (backends/clone
                # never see EX_WITHSELF).
                if self->nwith == 0:
                    fatal_at(self->file, e->pos, "'.field' used outside a 'with' block")
                e->kind = EX_IDENT
                e->text = self->with_names[self->nwith - 1]
                return
            case EX_IDENT:
                self->fold_predefined(e)   # __FILE__/__LINE__/__func__/... -> literal
                # ingested C macro constant (EOF, BUFSIZ...): folds to its literal —
                # QBE has no preprocessor to resolve the name. Any real symbol with
                # the same name (local, global, enum, function) takes precedence.
                if e->kind == EX_IDENT and self->macroconsts.has(e->text) and self->scope_find(e->text) == None and self->globals.get_or(e->text, None) == None and not self->is_enum_const(e->text) and self->find_func(e->text) == None:
                    mcp: *CVal = self->constvals.get_or(e->text, None)
                    if mcp != None:
                        if mcp->kind == CV_STR:
                            e->kind = EX_STRING
                            e->text = mcp->sval
                        elif mcp->kind == CV_INT:
                            e->kind = EX_NUMBER
                            e->text = self->a->printf("%lld", mcp->ival)
                # use of an undeclared identifier — only when every name is knowable
                # (no legacy `import <h>` in this module) and not a callee (an
                # unknown callee is an implicit C function: interop)
                if e->kind == EX_IDENT and not e->out_done:
                    odi: i32 = self->sym_index(e->text)
                    if odi >= 0 and self->locals[odi].byref != PK_NONE:
                        self->locals[odi].used = True
                        self->locals[odi].read = True
                        oin: *Expr = mk_ident(self->a, e->text, e->pos)
                        oin->out_done = True
                        with e:
                            .kind = EX_UNARY
                            .op = TK_STAR
                            .lhs = oin
                            .text = None
                        self->check_expr(e)
                        return
                if e->kind == EX_IDENT and not self->in_wlhs:
                    rsi0: i32 = self->sym_index(e->text)
                    if rsi0 >= 0:
                        self->locals[rsi0].read = True
                        # aggregates get written per element/field — only a SCALAR
                        # read-before-any-assignment is a definite uninitialized use
                        if not self->in_chdr and not self->in_callee and self->locals[rsi0].pos.line != 0 and not self->locals[rsi0].assigned and not self->locals[rsi0].uninit_warned and self->locals[rsi0].type != None and (is_arith_type(self->locals[rsi0].type) or self->locals[rsi0].type->kind == TY_PTR):
                            self->locals[rsi0].uninit_warned = True
                            cdiag_at(self->file, e->pos, "uninitialized", WD_WALL, "variable '%s' is uninitialized when used here", e->text)
                if e->kind == EX_IDENT and not self->in_callee and not self->in_chdr:
                    if self->scope_find(e->text) == None and self->globals.get_or(e->text, None) == None and not self->is_enum_const(e->text) and self->find_func(e->text) == None and not self->constvals.has(e->text) and not self->types.has(e->text):
                        # a C-header `#define NAME OTHER` renaming a declared object
                        # (macOS: stderr -> __stderrp). Follow it and re-resolve.
                        if self->macro_alias_rewrite(e):
                            self->check_expr(e)
                            return
                        sgu: Sugg
                        sgu.init(e->text)
                        for li in range(self->nlocals):
                            sgu.feed(self->locals[li].name)
                        for gi in range(self->globals.elen):
                            if not self->globals.dead[gi]:
                                sgu.feed(self->globals.keys[gi])
                        for fi2 in range(self->funcs.elen):
                            if not self->funcs.dead[fi2]:
                                sgu.feed(self->funcs.keys[fi2])
                        fatal_at(self->file, e->pos, "use of undeclared identifier '%s'%s", e->text, self->sugg_text(&sgu))
                return
            case EX_FIELD:
                # `ns.name` from a namespaced import (42.4): not a member access
                # at all — the alias is a spelling, so this collapses to the
                # plain identifier. Anything really declared as `ns` wins.
                if self->try_ns_ref(e):
                    self->check_expr(e)
                    return
                self->check_expr(e->lhs)
                ft0: *Type = self->type_of(e->lhs)
                if ft0 != None:
                    if ft0->kind == TY_PTR:
                        self->null_deref_check(e->lhs, e->pos)
                    if ft0->kind == TY_NAME and is_arith_type(ft0):
                        fatal_at(self->file, e->pos, "request for member '%s' in something not a structure or union", e->field)
                    if ft0->kind == TY_NAME and not self->in_chdr:
                        fvs: *SInfo = self->val_struct(ft0)
                        if fvs != None and not fvs->defined:
                            fatal_at(self->file, e->pos, "member access into incomplete type '%s %s'", "union" if fvs->is_union else "struct", fvs->name)
                    if ft0->kind == TY_PTR and ft0->inner != None and ft0->inner->kind == TY_NAME and is_arith_type(ft0->inner):
                        fatal_at(self->file, e->pos, "member access through pointer to non-struct ('%s')", e->field)
                    if ft0->kind == TY_PTR and not self->in_chdr:
                        fsi: *SInfo = self->val_struct(ft0->inner)
                        if fsi != None and not fsi->defined:
                            fatal_at(self->file, e->pos, "member access into incomplete type '%s %s'", "union" if fsi->is_union else "struct", fsi->name)
                    # unknown member of a positively-known, COMPLETE struct
                    if not self->in_chdr:
                        fmt: *Type = ft0->inner if ft0->kind == TY_PTR else ft0
                        fms: *SInfo = self->val_struct(fmt)
                        if fms != None and fms->defined and fms->nfields > 0 and not self->sinfo_field_deep(fms, e->field, 0) and sinfo_method(fms, e->field) == None:
                            fatal_at(self->file, e->pos, "'%s %s' has no member named '%s'", "union" if fms->is_union else "struct", fms->name, e->field)
                    # C is strict about the member operator (P keeps the sugar:
                    # fix_field_op silently adapts . and -> for P code)
                    if self->c_mod:
                        if e->op == TK_DOT and ft0->kind == TY_PTR:
                            fatal_at(self->file, e->pos, "'.' applied to a pointer (use '->')")
                        if e->op == TK_ARROW and ft0->kind == TY_NAME and self->val_struct(ft0) != None:
                            fatal_at(self->file, e->pos, "'->' applied to a non-pointer (use '.')")
                self->fix_field_op(e)
                return
            case EX_UNARY:
                if e->op == TK_AMP and e->lhs != None and e->lhs->kind == EX_IDENT:
                    awsi: i32 = self->sym_index(e->lhs->text)
                    if awsi >= 0:
                        # `ref x`/`in x` READ the variable: passing one that was
                        # never assigned is a definite uninitialized use (C# rule)
                        if (e->byref == PK_REF or e->byref == PK_IN) and not self->locals[awsi].assigned and self->locals[awsi].pos.line != 0 and not self->locals[awsi].uninit_warned:
                            self->locals[awsi].uninit_warned = True
                            cdiag_at(self->file, e->pos, "uninitialized", WD_WALL, "variable '%s' is uninitialized but passed as '%s' (which reads it)", e->lhs->text, "ref" if e->byref == PK_REF else "in")
                        self->locals[awsi].assigned = True
                        self->locals[awsi].read = True
                        self->locals[awsi].written = True   # the address escapes: writes may happen through it
                        self->locals[awsi].nn_off = True    # ... so no null fact survives it (69.7)
                        self->locals[awsi].nn = 0
                self->check_expr(e->lhs)
                if e->op == TK_STAR:
                    # dereferencing a positively-non-pointer value; deref of a
                    # FUNCTION designator is legal C ((*fnptr)(...)), so TY_FUNC passes
                    udt: *Type = self->type_of(e->lhs)
                    if udt != None and udt->kind == TY_NAME and (is_arith_type(udt) or self->val_struct(udt) != None):
                        fatal_at(self->file, e->pos, "invalid operand of unary '*' (not a pointer: %s)", render_type_p(self->a, udt))
                    if udt != None and udt->kind == TY_PTR and is_void_val(udt->inner):
                        cdiag_at(self->file, e->pos, "void-ptr-dereference", wd_pedantic(), "ISO C does not allow indirection on operand of type 'void *'")
                    if udt != None and udt->kind == TY_PTR and not self->in_chdr:
                        uds: *SInfo = self->val_struct(udt->inner)
                        if uds != None and not uds->defined:
                            fatal_at(self->file, e->pos, "dereferencing a pointer to incomplete type '%s %s'", "union" if uds->is_union else "struct", uds->name)
                    self->null_deref_check(e->lhs, e->pos)
                elif e->op == TK_AMP:
                    # `&*p` IS `p` (see take_addr): forwarding a received byref
                    # parameter to another byref call would otherwise spell `& *p`
                    if is_byref_deref(e->lhs):
                        inner: *Expr = e->lhs->lhs
                        inner->pos = e->pos
                        *e = *inner
                        return
                    # &x needs an lvalue (string literals are addressable arrays)
                    if not is_lvalue(e->lhs) and e->lhs->kind != EX_STRING:
                        fatal_at(self->file, e->pos, "cannot take the address of a non-lvalue expression")
                elif e->op in {TK_MINUS, TK_TILDE, TK_NOT}:
                    self->require_scalar(e->lhs, "unary operand")
                    if e->op != TK_NOT:
                        unt: *Type = self->type_of(e->lhs)
                        if unt != None and (unt->kind == TY_PTR or unt->kind == TY_ARRAY):
                            fatal_at(self->file, e->pos, "invalid pointer operand of unary '%s'", "-" if e->op == TK_MINUS else "~")
                        if e->op == TK_TILDE and is_float_type(unt):
                            fatal_at(self->file, e->pos, "'~' requires an integer operand")
                return
            case EX_BINARY:
                if e->op == TK_COALESCE:
                    self->lower_coalesce(e)
                    return
                # P: comparing a string-typed value with a string LITERAL compares
                # CONTENT (strcmp) — pointer identity is spelled `is`. Conservative:
                # only when one side is a literal (var == var stays a pointer test).
                if not self->c_mod and (e->op == TK_EQ or e->op == TK_NE):
                    slit: *Expr = None
                    soth: *Expr = None
                    if e->lhs != None and e->lhs->kind == EX_STRING:
                        slit = e->lhs
                        soth = e->rhs
                    elif e->rhs != None and e->rhs->kind == EX_STRING:
                        slit = e->rhs
                        soth = e->lhs
                    if slit != None and soth != None and soth->kind != EX_STRING:
                        self->check_expr(soth)
                        if self->type_is_string(self->type_of(soth)):
                            sc: *Expr = self->in_one_cmp(soth, slit, True, e->pos)
                            # in_one_cmp yields strcmp(a,b) == 0; flip for !=
                            sc->op = e->op
                            *e = *sc
                            self->check_expr(e)
                            return
                self->check_expr(e->lhs)
                # the right operand of and/or runs only if the left allowed it:
                # hoisting out of there would evaluate it unconditionally
                if e->op == TK_AND or e->op == TK_OR:
                    self->lazy_depth += 1
                    self->check_expr(e->rhs)
                    self->lazy_depth -= 1
                else:
                    self->check_expr(e->rhs)
                # `a is b` / `a is not b`: POINTER identity, regardless of type.
                # Desugars to (void*)a ==/!= (void*)b — no backend work needed.
                if e->op == TK_IS or e->op == TK_ISNOT:
                    self->is_check_ptr(e->lhs)
                    self->is_check_ptr(e->rhs)
                    nop: i32 = TK_EQ if e->op == TK_IS else TK_NE
                    e->op = nop
                    e->lhs = self->is_wrap_voidp(e->lhs)
                    e->rhs = self->is_wrap_voidp(e->rhs)
                elif e->op in {TK_EQ, TK_NE} and self->record_eq(e):
                    return   # `a == b` between records: rewritten field by field
                else:
                    # every remaining binary operator needs scalar operands: a
                    # struct/union/void VALUE is invalid on either side (C and P)
                    self->require_scalar(e->lhs, "binary operand")
                    self->require_scalar(e->rhs, "binary operand")
                    self->check_binop_types(e)
                return
            case EX_TERNARY:
                self->check_expr(e->cond)
                # only ONE arm runs: neither may be hoisted in front of the test
                self->lazy_depth += 1
                self->check_expr(e->lhs)
                self->check_expr(e->rhs)
                self->lazy_depth -= 1
                self->require_scalar(e->cond, "ternary condition")
                tva: *Type = self->type_of(e->lhs)
                tvb: *Type = self->type_of(e->rhs)
                if (is_void_val(tva) and tvb != None and not is_void_val(tvb)) or (is_void_val(tvb) and tva != None and not is_void_val(tva)):
                    fatal_at(self->file, e->pos, "ternary arms mix void and a value")
                if tva != None and tvb != None and tva->kind == TY_PTR and tvb->kind == TY_PTR:
                    if not is_void_val(tva->inner) and not is_void_val(tvb->inner) and not self->type_compat(tva->inner, tvb->inner):
                        fatal_at(self->file, e->pos, "ternary arms have incompatible pointer types")
                tsa: *SInfo = self->val_struct(tva)
                tsb: *SInfo = self->val_struct(tvb)
                if tsa != None and not tsa->defined and not self->in_chdr:
                    fatal_at(self->file, e->pos, "ternary arm has incomplete type '%s'", tsa->name)
                if tsb != None and not tsb->defined and not self->in_chdr:
                    fatal_at(self->file, e->pos, "ternary arm has incomplete type '%s'", tsb->name)
                if tsa != None and tsb != None and strcmp(tsa->name, tsb->name) != 0:
                    fatal_at(self->file, e->pos, "ternary arms have incompatible struct types ('%s' vs '%s')", tsa->name, tsb->name)
                if (tsa != None and tvb != None and tsb == None and not is_void_val(tvb)) or (tsb != None and tva != None and tsa == None and not is_void_val(tva)):
                    fatal_at(self->file, e->pos, "ternary arms mix a struct value and a scalar")
                return
            case EX_INDEX:
                self->check_expr(e->lhs)
                self->check_expr(e->rhs)
                ixnt: *Type = self->type_of(e->lhs)
                if ixnt != None and ixnt->kind == TY_PTR:
                    self->null_deref_check(e->lhs, e->pos)
                if not self->in_chdr:
                    ixt: *Type = self->type_of(e->lhs)
                    ixr: *Type = self->type_of(e->rhs)
                    if ixt != None and (ixt->kind == TY_PTR or ixt->kind == TY_ARRAY):
                        ixs: *SInfo = self->val_struct(ixt->inner)
                        if ixs != None and not ixs->defined:
                            fatal_at(self->file, e->pos, "subscript of a pointer to incomplete type '%s'", ixs->name)
                    if ixt != None and ixr != None and (ixt->kind == TY_PTR or ixt->kind == TY_ARRAY) and (ixr->kind == TY_PTR or ixr->kind == TY_ARRAY):
                        fatal_at(self->file, e->pos, "array subscript is not an integer (both operands are pointers)")
                    if ixt != None and (ixt->kind == TY_PTR or ixt->kind == TY_ARRAY) and is_float_type(ixr):
                        fatal_at(self->file, e->pos, "array subscript is not an integer")
                # C allows a[i] and i[a] — invalid only when NEITHER side is a
                # pointer/array (both positively plain values: struct or scalar)
                xtl: *Type = self->type_of(e->lhs)
                xtr: *Type = self->type_of(e->rhs)
                if xtl != None and xtr != None:
                    if xtl->kind == TY_NAME and xtr->kind == TY_NAME:
                        lok: bool = is_arith_type(xtl) or self->val_struct(xtl) != None
                        rok: bool = is_arith_type(xtr) or self->val_struct(xtr) != None
                        if lok and rok:
                            fatal_at(self->file, e->pos, "subscripted value is not a pointer or array (%s)", render_type_p(self->a, xtl))
                    xlp: bool = xtl->kind == TY_PTR or xtl->kind == TY_ARRAY
                    xrp: bool = xtr->kind == TY_PTR or xtr->kind == TY_ARRAY
                    if xlp and (is_float_type(xtr) or is_void_val(xtr)):
                        fatal_at(self->file, e->pos, "array index must be an integer")
                    if xrp and (is_float_type(xtl) or is_void_val(xtl)):
                        fatal_at(self->file, e->pos, "array index must be an integer")
                    if xlp and xtl->kind == TY_PTR and is_void_val(xtl->inner):
                        cdiag_at(self->file, e->pos, "pointer-arith", wd_pedantic(), "subscript of a pointer to void is a GNU extension")
                    if xrp and xtr->kind == TY_PTR and is_void_val(xtr->inner):
                        cdiag_at(self->file, e->pos, "pointer-arith", wd_pedantic(), "subscript of a pointer to void is a GNU extension")
                return
            case EX_ASSIGN:
                xwsi: i32 = self->sym_index(e->lhs->text) if e->lhs != None and e->lhs->kind == EX_IDENT else -1
                if xwsi >= 0 and self->locals[xwsi].byref == PK_IN:
                    fatal_at(self->file, e->pos, "cannot assign to '%s': it is an 'in' (read-only) parameter", e->lhs->text)
                if xwsi >= 0:
                    self->in_wlhs = True
                self->check_expr(e->lhs)
                self->in_wlhs = False
                self->check_expr(e->rhs)
                if xwsi >= 0:
                    self->locals[xwsi].written = True
                    self->locals[xwsi].assigned = True
                if not is_lvalue(e->lhs):
                    fatal_at(self->file, e->pos, "cannot assign to this expression (not an lvalue — assign to a variable, array element, field or *pointer)")
                xbwi: i32 = self->byref_write_base(e->lhs)
                if xbwi >= 0:
                    if self->locals[xbwi].byref == PK_IN:
                        fatal_at(self->file, e->pos, "cannot modify '%s' through the 'in' (read-only) parameter", self->locals[xbwi].name)
                    self->locals[xbwi].written = True
                    self->locals[xbwi].assigned = True
                xalt: *Type = self->type_of(e->lhs)
                if xalt != None and xalt->kind == TY_ARRAY:
                    fatal_at(self->file, e->pos, "assignment to expression with array type")
                if self->func_designator(e->lhs) != None or (xalt != None and xalt->kind == TY_FUNC):
                    fatal_at(self->file, e->pos, "cannot assign to a function")
                if e->op == TK_ASSIGN:
                    self->check_assign_types(e->pos, xalt, self->type_of(e->rhs), e->rhs)
                    self->nn_assign(e->lhs, self->nn_of_expr(e->rhs))
                else:
                    self->check_compound_types(e->pos, e->op, e->lhs, e->rhs)
                    self->nn_assign(e->lhs, 0)
                return
            case EX_INCDEC:
                iwsi: i32 = self->sym_index(e->lhs->text) if e->lhs != None and e->lhs->kind == EX_IDENT else -1
                if iwsi >= 0 and self->locals[iwsi].byref == PK_IN:
                    fatal_at(self->file, e->pos, "cannot apply '++'/'--' to '%s': it is an 'in' (read-only) parameter", e->lhs->text)
                if iwsi >= 0:
                    self->locals[iwsi].written = True
                    self->locals[iwsi].assigned = True
                    self->in_wlhs = True
                self->check_expr(e->lhs)
                self->in_wlhs = False
                ibwi: i32 = self->byref_write_base(e->lhs)
                if ibwi >= 0:
                    if self->locals[ibwi].byref == PK_IN:
                        fatal_at(self->file, e->pos, "cannot modify '%s' through the 'in' (read-only) parameter", self->locals[ibwi].name)
                    self->locals[ibwi].written = True
                    self->locals[ibwi].assigned = True
                self->require_scalar(e->lhs, "'++'/'--' operand")
                idt: *Type = self->type_of(e->lhs)
                if idt != None and idt->kind == TY_ARRAY:
                    fatal_at(self->file, e->pos, "'++'/'--' operand has array type (not a modifiable lvalue)")
                if idt != None and idt->kind == TY_PTR and not self->in_chdr:
                    if is_void_val(idt->inner):
                        cdiag_at(self->file, e->pos, "pointer-arith", wd_pedantic(), "arithmetic on a pointer to void is a GNU extension")
                    idsi: *SInfo = self->val_struct(idt->inner)
                    if idsi != None and not idsi->defined:
                        fatal_at(self->file, e->pos, "'++'/'--' on a pointer to incomplete type '%s'", idsi->name)
                if self->func_designator(e->lhs) != None:
                    fatal_at(self->file, e->pos, "'++'/'--' operand is a function")
                if not is_lvalue(e->lhs):
                    fatal_at(self->file, e->pos, "operand of '%s' must be an lvalue (a variable, array element, field or *pointer)", "++" if e->op == TK_PLUS else "--")
                return
            case EX_WALRUS:
                self->check_expr(e->lhs)
                wty: *Type = self->scope_find(e->text)
                if wty == None:
                    wty = self->infer_type(e->lhs)
                    if wty == None:
                        fatal_at(self->file, e->pos, "cannot infer the type of '%s' in the walrus expression; declare it first ('%s: T')", e->text, e->text)
                    # like `nonlocal`: the declaration is hoisted to FUNCTION scope
                    # (Python's := semantics), the walrus stays a plain assignment
                    whd: *Stmt = st_new(self->a, ST_VAR, e->pos)
                    whd->name = e->text
                    whd->type = wty
                    self->resolve_type(whd->type)
                    self->vla_hoist_add(whd)
                    whp: *Type = self->a->alloc(sizeof(Type))
                    *whp = *wty
                    self->fn_hoisted.put(e->text, whp)
                else:
                    self->check_assign_types(e->pos, wty, self->type_of(e->lhs), e->lhs)
                wid: *Expr = mk_ident(self->a, e->text, e->pos)
                with e:
                    .kind = EX_ASSIGN
                    .op = TK_ASSIGN
                    .rhs = e->lhs
                    .lhs = wid
                    .text = None
                return
            case EX_IN:
                self->lower_in(e)
                return
            case EX_COMMA:
                self->check_expr(e->lhs)
                self->check_expr(e->rhs)
                return
            case EX_STMTEXPR:
                self->scope_push()
                if e->xblock != None:
                    self->check_stmts(e->xblock)
                self->check_expr(e->lhs)
                # nested and complex: hoist the block out (see hoist_stmtexpr).
                # In a lazy position the block must stay where it is — the C
                # backend restructures the ternary instead.
                if self->lazy_depth == 0 and self->stmtexpr_needs_hoist(e):
                    self->hoist_stmtexpr(e)
                self->scope_pop()
                return
            case EX_INITLIST:
                for i2 in range(e->nargs):
                    self->check_expr(e->args[i2])
                return
            case _:
                return

    # defer body: no return; break/continue only in a loop/match of the body itself
    private def check_defer_body(self: *Sema, b: *Block, loop_depth: i32, break_depth: i32):
        for i in range(b->n):
            st: *Stmt = b->stmts[i]
            match st->kind:
                case ST_RETURN:
                    fatal_at(self->file, st->pos, "return is not allowed inside defer")
                case ST_BREAK:
                    if break_depth == 0:
                        fatal_at(self->file, st->pos, "break inside defer must be within a loop/match of the defer itself")
                case ST_CONTINUE:
                    if loop_depth == 0:
                        fatal_at(self->file, st->pos, "continue inside defer must be within a loop of the defer itself")
                case ST_WHILE, ST_DO, ST_FOR, ST_CFOR:
                    self->check_defer_body(st->body, loop_depth + 1, break_depth + 1)
                case ST_IF:
                    for j in range(st->nconds):
                        self->check_defer_body(st->blocks[j], loop_depth, break_depth)
                    if st->else_block != None:
                        self->check_defer_body(st->else_block, loop_depth, break_depth)
                case ST_MATCH:
                    for j2 in range(st->ncases):
                        self->check_defer_body(st->cases[j2]->body, loop_depth, break_depth + 1)
                case ST_DEFER:
                    self->check_defer_body(st->body, 0, 0)
                case _:
                    continue

    # lvalue conversion of the match type subject: array decays to pointer
    private def tm_decay(self: *Sema, t: *Type) -> *Type:
        if t != None and t->kind == TY_ARRAY:
            return ty_ptr(self->a, t->inner)
        return t

    # chooses, at compile time, the case whose type matches the static type of the
    # subject. In a template, runs at instantiation (T already concrete). tm_sel = index.
    private def resolve_typematch(self: *Sema, st: *Stmt):
        subj: *Type = self->tm_decay(self->type_of(st->subject))
        dflt = -1
        for i in range(st->ncases):
            c: *MatchCase = st->cases[i]
            if c->is_default:
                dflt = i
                continue
            self->resolve_type(c->type_pat)
            if type_eq_p(subj, self->tm_decay(c->type_pat)):
                st->tm_sel = i
                return
        if dflt >= 0:
            st->tm_sel = dflt
            return
        fatal_at(self->file, st->pos, "match type: no case matches the subject's static type")

    # Um nome que é PALAVRA-CHAVE DO C não pode ser declarado: o C que sai daqui
    # não compilaria, e o erro chegaria como uma linha do arquivo gerado em vez
    # do lugar onde a pessoa escreveu. A lista é a das palavras que o C reserva e
    # o P não — as que o P também reserva (`if`, `struct`, `const`) o lexer já
    # não deixa passar como nome, e as que o P usa como TIPO (`int`, `char`,
    # `void`) valem como nome de tipo mas não como nome de variável.
    #
    # Achado ao escrever `signed: bool = ...` no runtime do pscript: saiu
    # `int signed = ...;` e o cc reclamou de um arquivo que ninguém escreveu.
    private def deny_c_keyword(self: *Sema, name: const *char, pos: Pos):
        if name == None:
            return
        C_KW: const *char[] = {"auto", "register", "signed", "unsigned", "extern",
                               "typedef", "union", "volatile", "restrict", "goto",
                               "switch", "default", "do", "short", "long", "double",
                               "float", "inline", "int", "char", "void", "_Bool",
                               "_Complex", "_Imaginary", "_Atomic", "_Generic",
                               "_Noreturn", "_Static_assert", "_Thread_local",
                               "complex", "imaginary", "noreturn", "thread_local",
                               "static_assert", "alignas", "alignof", "bool"}
        for i in range(i32(sizeof(C_KW) / sizeof(C_KW[0]))):
            if strcmp(name, C_KW[i]) == 0:
                fatal_at(self->file, pos, "'%s' is a keyword in C, so a declaration with that name would emit C that does not compile: pick another name", name)

    private def check_stmt(self: *Sema, st: *Stmt):
        match st->kind:
            case ST_VAR:
                if not self->c_mod:
                    self->deny_c_keyword(st->name, st->pos)
                # 65.4: `f: def(i32) -> i32 = lambda x: x * 2` — the declared
                # type IS the context the lambda needs, and inside a brace list
                # it is the field's
                if st->type != None and st->init != None:
                    self->lam_pre_init(st->type, st->init)
                # same-scope redeclaration: C and P both forbid it (shadowing needs
                # a NEW block). `extern` after `extern` is a redeclaration — legal.
                rex: bool = False
                if st->name != None and self->scope_find_cur(st->name, &rex):
                    # an iterator injected by `for` plus a redeclaration of the
                    # SAME type: reuse the variable — the declaration becomes just
                    # the assignment of the initial value
                    fdx: i32 = self->sym_index(st->name)
                    if fdx >= 0 and self->locals[fdx].for_iter and not st->is_extern and not st->is_static:
                        rt: *Type = st->type
                        if rt == None and st->init != None:
                            rt = self->type_of(st->init)
                        if type_eq_p(rt, self->locals[fdx].type):
                            self->locals[fdx].for_iter = False   # it is an explicit declaration now
                            self->locals[fdx].pos = st->pos
                            if st->init != None:
                                st->kind = ST_ASSIGN
                                st->lhs = mk_ident(self->a, st->name, st->pos)
                                st->op = TK_ASSIGN
                                st->rhs = st->init
                                st->init = None
                                self->check_stmt(st)
                            else:
                                st->kind = ST_PASS
                            return
                    if not (st->is_extern and rex):
                        fatal_at(self->file, st->pos, "redefinition of '%s' in the same scope", st->name)
                if self->fn_globals.has(st->name):
                    fatal_at(self->file, st->pos, "'%s' was pinned by `global %s` in this function — a local declaration would shadow the module global", st->name, st->name)
                if st->is_extern and self->c_mod and not self->in_chdr:
                    if self->funcs.has(st->name) and self->globals.get_or(st->name, None) == None:
                        fatal_at(self->file, st->pos, "'%s' redeclared as a different kind of symbol (it is a function)", st->name)
                    # C11 6.2.2p4: with a file-scope declaration VISIBLE the extern
                    # adopts its linkage (even a static's internal one) — legal.
                    # With none visible it declares EXTERNAL linkage; a later
                    # file-scope static then conflicts (checked at that decl).
                    gvt: *Type = self->globals.get_or(st->name, None)
                    if gvt == None:
                        self->gexterns.add(st->name)
                    elif st->type != None and not self->type_compat(gvt, st->type):
                        fatal_at(self->file, st->pos, "conflicting types for '%s' (block-scope extern vs the file-scope declaration)", st->name)
                # `nonlocal x` then `x: T = e` — the TYPED first assignment. The
                # inferred form (`x = e`, handled in the ST_ASSIGN path) already
                # hoisted; without this the typed one declared a fresh variable
                # INSIDE the block, shadowing the hoisted one, and the code read
                # a value that was never written.
                if st->type != None and st->name != None and self->fn_nonlocals.has(st->name) and self->fn_hoisted.get_or(st->name, None) == None and not st->is_static and not st->is_extern:
                    if st->type->is_ref:
                        fatal_at(self->file, st->pos, "a ref cannot be 'nonlocal': it binds at one moment of one flow (69.1)")
                    self->resolve_type(st->type)
                    self->infer_array_len(st->type, st->init)
                    self->require_complete(st->type, st->pos)
                    nhd: *Stmt = st_new(self->a, ST_VAR, st->pos)
                    nhd->name = st->name
                    nhd->type = st->type
                    self->vla_hoist_add(nhd)     # prepended at function entry
                    nhp: *Type = self->a->alloc(sizeof(Type))
                    *nhp = *st->type
                    self->fn_hoisted.put(st->name, nhp)
                    if st->init == None:
                        st->kind = ST_PASS
                        return
                    st->kind = ST_ASSIGN
                    st->lhs = mk_ident(self->a, st->name, st->pos)
                    st->op = TK_ASSIGN
                    st->rhs = st->init
                    st->init = None
                    st->type = None
                    self->check_stmt(st)
                    return
                if st->type != None and st->type->is_ref:
                    self->check_ref_var(st)
                    return
                if st->type != None:
                    # C rule: the name is in scope from its own declarator onward —
                    # `p: **char = alloc(sizeof(*p))` is idiomatic and must see `p`
                    self->resolve_type(st->type)
                    self->infer_array_len(st->type, st->init)
                    self->require_complete(st->type, st->pos)
                    self->scope_add_x(st->name, st->type, st->is_extern)
                    self->locals[self->nlocals - 1].pos = st->pos
                    self->locals[self->nlocals - 1].assigned = True   # visible-from-declarator copy
                    prevci: bool = self->in_complit_init
                    self->in_complit_init = names_own_type(st->type, st->init)
                    self->check_expr(st->init)
                    self->in_complit_init = prevci
                else:
                    self->check_expr(st->init)
                    if st->init != None:
                        st->type = self->infer_type(st->init)   # `name = value` / `const N = value`
                    if st->type == None:
                        fatal_at(self->file, st->pos, "cannot infer type of '%s'; add an explicit type", st->name)
                    # inferring from a ref-returning call yields the POINTER, not
                    # a new ref: a ref is opted into by spelling it (69.1)
                    if st->type->kind == TY_PTR and st->type->is_ref:
                        drt: *Type = self->a->alloc(sizeof(Type))
                        *drt = *st->type
                        drt->is_ref = False
                        st->type = drt
                    self->resolve_type(st->type)
                    self->infer_array_len(st->type, st->init)
                    self->require_complete(st->type, st->pos)
                # `v: Vec = Vec(1.0, 2.0)` — the constructor IS the whole
                # initializer, so the compound literal buys nothing: a brace list
                # says the same thing, and says it in C89 too.
                self->flatten_complit(st->type, st->init)
                if not st->is_extern:
                    self->require_defined(st->type, st->pos)
                    if is_void_val(st->type):
                        fatal_at(self->file, st->pos, "cannot declare '%s' with type void", st->name)
                elif st->init != None:
                    # block-scope `extern int x = 0;` is invalid C
                    fatal_at(self->file, st->pos, "'extern' declaration of '%s' cannot have an initializer", st->name)
                # full recursive initializer check (C11 6.7.9: braces, elision,
                # designators, strings, unions, positional excess)
                self->check_init(st->type, st->init, st->pos)
                if st->is_static and st->init != None and not self->in_chdr and not self->static_const_ok(st->init):
                    fatal_at(self->file, st->pos, "initializer of static '%s' is not a constant expression", st->name)
                if st->is_const and st->init != None:
                    cok: bool = True
                    cvv: CVal = self->ceval_val(st->init, None, ref cok)
                    if cok and cvv.kind != CV_BAD:
                        cp: *CVal = self->a->alloc(sizeof(CVal))
                        *cp = cvv
                        self->constvals.put(st->name, cp)
                if self->lower_vla_c89(st):
                    # lowered to pointer + malloc(...): check the new init
                    self->check_expr(st->init)
                self->fold_const_dims(st->type)
                if self->cc->std_version == 89:
                    self->lower_designators(st->init, st->type)
                self->scope_add_x(st->name, st->type, st->is_extern)
                self->locals[self->nlocals - 1].pos = st->pos
                if st->init != None or st->is_static or st->is_extern:
                    self->locals[self->nlocals - 1].assigned = True
                self->locals[self->nlocals - 1].nn = self->nn_of_expr(st->init)
                return
            case ST_ASSIGN:
                # Python-style inference: `name = expr` with `name` not yet
                # declared (and a plain '=' op) DECLARES a new local variable with
                # the type inferred from expr. Becomes ST_VAR (backends emit the decl).
                if not self->c_mod and st->op == TK_ASSIGN and st->lhs != None and st->lhs->kind == EX_IDENT and self->scope_find(st->lhs->text) == None and self->globals.get_or(st->lhs->text, None) == None and not self->is_enum_const(st->lhs->text):
                    self->check_expr(st->rhs)
                    ity: *Type = self->infer_type(st->rhs)
                    if ity == None:
                        fatal_at(self->file, st->pos, "cannot infer type of '%s'; declare it with an explicit type ('%s: T = ...')", st->lhs->text, st->lhs->text)
                    if ity->kind == TY_PTR and ity->is_ref:
                        # inference strips ref-ness: what flows in is the pointer
                        irt: *Type = self->a->alloc(sizeof(Type))
                        *irt = *ity
                        irt->is_ref = False
                        ity = irt
                    # `nonlocal x`: the declaration is HOISTED to function scope —
                    # the variable survives this block (Python's if/else idiom)
                    if self->fn_nonlocals.has(st->lhs->text):
                        hd: *Stmt = st_new(self->a, ST_VAR, st->pos)
                        hd->name = st->lhs->text
                        hd->type = ity
                        self->resolve_type(hd->type)
                        self->vla_hoist_add(hd)   # prepended at function entry
                        hp: *Type = self->a->alloc(sizeof(Type))
                        *hp = *ity
                        self->fn_hoisted.put(st->lhs->text, hp)
                        return   # stays a plain assignment to the hoisted variable
                    with st:
                        .kind = ST_VAR
                        .name = st->lhs->text
                        .type = ity
                        .init = st->rhs
                        .is_const = False
                    self->resolve_type(st->type)
                    self->scope_add(st->name, st->type)
                    self->locals[self->nlocals - 1].nn = self->nn_of_expr(st->init)
                    return
                wsi: i32 = self->sym_index(st->lhs->text) if st->lhs != None and st->lhs->kind == EX_IDENT else -1
                if wsi >= 0 and self->locals[wsi].byref == PK_IN:
                    fatal_at(self->file, st->pos, "cannot assign to '%s': it is an 'in' (read-only) parameter", st->lhs->text)
                if wsi >= 0:
                    self->in_wlhs = True   # `x = ...` / `x += ...`: written, not read
                self->check_expr(st->lhs)
                self->in_wlhs = False
                # 65.4: assigning to something already typed gives the lambda
                # its context too
                self->lam_fix(st->rhs, self->type_of(st->lhs))
                self->check_expr(st->rhs)
                if wsi >= 0:
                    self->locals[wsi].written = True
                    self->locals[wsi].assigned = True
                if not is_lvalue(st->lhs):
                    fatal_at(self->file, st->pos, "cannot assign to this expression (not an lvalue — assign to a variable, array element, field or *pointer)")
                bwi: i32 = self->byref_write_base(st->lhs)
                if bwi >= 0:
                    if self->locals[bwi].byref == PK_IN:
                        fatal_at(self->file, st->pos, "cannot modify '%s' through the 'in' (read-only) parameter", self->locals[bwi].name)
                    self->locals[bwi].written = True
                    self->locals[bwi].assigned = True
                salt: *Type = self->type_of(st->lhs)
                if salt != None and salt->kind == TY_ARRAY:
                    fatal_at(self->file, st->pos, "assignment to expression with array type")
                if not self->in_chdr:
                    slsi: *SInfo = self->val_struct(salt)
                    if slsi != None and not slsi->defined:
                        fatal_at(self->file, st->pos, "assignment to an object of incomplete type '%s'", slsi->name)
                if self->func_designator(st->lhs) != None or (salt != None and salt->kind == TY_FUNC):
                    fatal_at(self->file, st->pos, "cannot assign to a function")
                if st->op == TK_ASSIGN:
                    self->check_assign_types(st->pos, salt, self->type_of(st->rhs), st->rhs)
                    self->nn_assign(st->lhs, self->nn_of_expr(st->rhs))
                else:
                    self->check_compound_types(st->pos, st->op, st->lhs, st->rhs)
                    self->nn_assign(st->lhs, 0)
                return
            case ST_EXPR, ST_RETURN:
                if st->kind == ST_RETURN:
                    self->lam_fix(st->expr, self->cur_ret)   # 65.4
                self->check_expr(st->expr)
                if st->kind == ST_RETURN and st->expr != None and self->cur_ret != None and self->cur_ret->kind == TY_PTR and self->cur_ret->is_ref and not self->in_chdr:
                    if st->expr->kind == EX_NONE:
                        fatal_at(self->file, st->pos, "a ref return is never None (69.1) — return a pointer (*T) if absence is a state")
                    st->expr = self->bind_ref(st->expr, self->cur_ret, st->pos, "ref return")
                if st->kind == ST_EXPR and not self->in_chdr and st->expr != None and self->expr_no_effect(st->expr):
                    cdiag_at(self->file, st->pos, "unused-value", WD_WARN, "expression result unused")
                if not self->in_chdr and st->expr != None:
                    xts: *SInfo = self->val_struct(self->type_of(st->expr))
                    if xts != None and not xts->defined:
                        fatal_at(self->file, st->pos, "expression has incomplete type '%s %s'", "union" if xts->is_union else "struct", xts->name)
                if st->kind == ST_RETURN and st->expr == None and self->cur_ret != None and (is_arith_type(self->cur_ret) or self->cur_ret->kind == TY_PTR):
                    cdiag_at(self->file, st->pos, "return-type", WD_ERR, "non-void function should return a value")
                if st->kind == ST_RETURN and st->expr != None and self->cur_ret != None:
                    ret_t: *Type = self->type_of(st->expr)
                    if is_void_val(self->cur_ret) and ret_t != None and (is_arith_type(ret_t) or ret_t->kind == TY_PTR or self->val_struct(ret_t) != None):
                        fatal_at(self->file, st->pos, "void function returns a value")
                    self->check_assign_types(st->pos, self->cur_ret, ret_t, st->expr)
                return
            case ST_IF:
                # compile-time branch pruning: folds the if/elif chain while the
                # conditions are constant. if_sel: live branch (0..nconds-1),
                # nconds = else, -2 = none (all false, no else), -1 = runtime.
                sel = -1
                undecided: bool = False
                ic = 0
                while ic < st->nconds:
                    cok: bool = True
                    cv: i64 = self->ceval(st->conds[ic], ref cok)
                    if not cok:
                        undecided = True   # runtime condition: cannot be pruned
                        break
                    if cv != 0:
                        sel = ic           # first constant-true condition
                        break
                    ic += 1                # constant-false: try the next one
                # doesn't prune if any branch contains a label: it may be the target of a
                # `goto` from outside (the C idiom of dead code reachable via goto).
                has_lbl: bool = False
                for il in range(st->nconds):
                    if block_find_kind(st->blocks[il], ST_LABEL) != None or block_find_kind(st->blocks[il], ST_CASE) != None:
                        has_lbl = True
                if st->else_block != None and (block_find_kind(st->else_block, ST_LABEL) != None or block_find_kind(st->else_block, ST_CASE) != None):
                    has_lbl = True
                if st->must_fold and undecided:
                    # 99.1: the whole point is that the branch not taken is
                    # never CHECKED, and that only holds if the choice is made
                    # here. A condition that is not constant would silently
                    # become a run-time branch, and then both sides have to
                    # compile — which is exactly what a platform guard cannot do.
                    fatal_at(self->file, st->pos, "a `const if` needs a condition known at compile time: this one is not (a predefined like `__PLANG_LINUX__`, a `const`, a `-D`, or `is_defined(...)`)")
                if st->must_fold and has_lbl:
                    fatal_at(self->file, st->pos, "a `const if` cannot hold a label or a `case`: those are reachable by `goto` from outside, so the branch cannot be dropped")
                if undecided or has_lbl:
                    st->if_sel = -1
                elif sel >= 0:
                    st->if_sel = sel
                elif st->else_block != None:
                    st->if_sel = st->nconds
                else:
                    st->if_sel = -2
                # checks only the live branch once folded (dead branches are left out)
                if st->if_sel == -1:
                    # null facts (69.7): each branch sees what its condition
                    # proves; later elifs (and the else) see the accumulated
                    # NEGATIONS of the ones that did not take. After the if,
                    # facts survive only when every then-branch exits — the
                    # `if p == None: return` idiom leaves p proven behind it.
                    nnbase: *i32 = self->nn_save()
                    allcut: bool = st->else_block == None
                    for i in range(st->nconds):
                        self->check_expr(st->conds[i])
                        self->require_scalar(st->conds[i], "if condition")
                        self->check_cond_assign(st->conds[i])
                        nnsnap: *i32 = self->nn_save()
                        self->apply_cond_facts(st->conds[i], True)
                        self->check_block(st->blocks[i])
                        self->nn_restore(nnsnap)
                        self->apply_cond_facts(st->conds[i], False)
                        if not block_terminates(st->blocks[i]):
                            allcut = False
                    if st->else_block != None:
                        self->check_block(st->else_block)
                    if not allcut:
                        # merge point: back to base, minus whatever ANY branch
                        # may have written (a fact must hold on every path)
                        self->nn_restore(nnbase)
                        for i in range(st->nconds):
                            self->nn_kill_writes(st->blocks[i])
                        self->nn_kill_writes(st->else_block)
                elif st->if_sel >= 0 and st->if_sel < st->nconds:
                    self->check_block(st->blocks[st->if_sel])
                elif st->if_sel == st->nconds:
                    self->check_block(st->else_block)
                return
            case ST_WHILE, ST_DO:
                self->check_expr(st->cond)
                self->require_scalar(st->cond, "loop condition")
                self->check_cond_assign(st->cond)
                # the back edge replays the body: a fact on anything the body
                # writes cannot enter it — NOR survive the loop (the kill runs
                # BEFORE the snapshot, so what the loop may have changed stays
                # unknown after it). What the body derives inside stays inside.
                self->nn_kill_writes(st->body)
                lsnap: *i32 = self->nn_save()
                if st->kind == ST_WHILE:
                    self->apply_cond_facts(st->cond, True)
                self->loop_depth += 1
                self->check_block(st->body)
                self->loop_depth -= 1
                self->nn_restore(lsnap)
                return
            case ST_FOR:
                self->check_expr(st->from)
                self->check_expr(st->to)
                self->check_expr(st->step)
                if st->var != None:
                    fvi: i32 = self->sym_index(st->var)
                    if fvi >= 0:
                        self->locals[fvi].assigned = True
                        self->locals[fvi].written = True
                        self->locals[fvi].read = True
                        self->locals[fvi].used = True
                if st->var2 != None:
                    fvi2: i32 = self->sym_index(st->var2)
                    if fvi2 >= 0:
                        self->locals[fvi2].assigned = True
                        self->locals[fvi2].written = True
                        self->locals[fvi2].read = True
                        self->locals[fvi2].used = True
                self->nn_kill_writes(st->body)   # the back edge (69.7) — and the
                fsnap: *i32 = self->nn_save()    #   kill survives the loop too
                self->loop_depth += 1
                self->check_block(st->body)
                self->loop_depth -= 1
                self->nn_restore(fsnap)
                return
            case ST_CFOR:
                self->scope_push()   # C99: the for-init declaration scopes to the LOOP
                if st->for_init != None:
                    if st->for_init->kind == ST_VAR and (st->for_init->is_extern or st->for_init->is_static):
                        fatal_at(self->file, st->for_init->pos, "a variable declared in a for-loop header cannot have a storage class")
                    self->check_stmt(st->for_init)
                self->check_expr(st->cond)
                self->require_scalar(st->cond, "loop condition")
                self->check_cond_assign(st->cond)
                if st->for_post != None:
                    self->check_stmt(st->for_post)
                self->nn_kill_writes(st->body)   # the back edge (69.7) — and the
                if st->for_post != None and st->for_post->kind == ST_ASSIGN:
                    self->nn_assign(st->for_post->lhs, 0)
                cfsnap: *i32 = self->nn_save()   #   kill survives the loop too
                self->loop_depth += 1
                self->check_block(st->body)
                self->loop_depth -= 1
                self->nn_restore(cfsnap)
                self->scope_pop()
                return
            case ST_MATCH:
                self->check_expr(st->subject)
                if not st->is_typematch and self->type_is_string(self->type_of(st->subject)):
                    self->lower_match_strings(st)
                    self->check_stmt(st)   # re-check as the ST_IF it became
                    return
                if st->is_typematch:
                    # compile-time type selection: chooses the case whose type
                    # matches the static type of the subject (resolved HERE — in a
                    # template this only happens at instantiation, when T is concrete).
                    # Only the chosen branch is checked (the others are discarded).
                    self->resolve_typematch(st)
                    if st->tm_sel >= 0:
                        self->sw_depth += 1
                        self->check_block(st->cases[st->tm_sel]->body)
                        self->sw_depth -= 1
                    return
                # covered values, for -Wswitch/-Wswitch-enum (checked after the
                # loop: the folding below is what makes every label ceval-able)
                mvals: *i64 = None
                mn = 0; mcap = 0
                mdef: bool = False
                for j in range(st->ncases):
                    if st->cases[j]->is_default:
                        mdef = True
                    for k in range(st->cases[j]->nvals):
                        cval: *Expr = st->cases[j]->vals[k]
                        self->check_expr(cval)
                        # a case label requires a constant (ICE in C). Number and char
                        # literal are already ICE — we only fold refs to `const`/expressions.
                        # enum is already ICE in C — keep it readable (case EX_IDENT).
                        if cval->kind != EX_NUMBER and cval->kind != EX_CHARLIT and not (cval->kind == EX_IDENT and self->is_enum_const(cval->text)):
                            cok: bool = True
                            cv: i64 = self->ceval(cval, ref cok)
                            if cok:
                                cval->kind = EX_NUMBER
                                cval->text = self->a->printf("%lld", cv)
                        mok: bool = True
                        mv: i64 = self->ceval(cval, ref mok)
                        if mok:
                            mvals = vec_grow(mvals, mn, ref mcap, sizeof(*mvals))
                            mvals[mn] = mv
                            mn += 1
                    msnap: *i32 = self->nn_save()   # facts stay inside the case
                    self->sw_depth += 1
                    self->check_block(st->cases[j]->body)
                    self->sw_depth -= 1
                    self->nn_restore(msnap)
                    self->nn_kill_writes(st->cases[j]->body)   # merge point
                self->check_enum_exhaustive(st->pos, self->type_of(st->subject), mvals, mn, mdef, "match")
                free(mvals)
                return
            case ST_WITH:
                self->check_expr(st->expr)
                tt: *Type = self->type_of(st->expr)
                is_ptr: bool = False
                sname: const *char = None
                if tt != None and tt->kind == TY_PTR and tt->inner != None and tt->inner->kind == TY_NAME:
                    is_ptr = True; sname = tt->inner->name
                elif tt != None and tt->kind == TY_NAME:
                    sname = tt->name
                if sname == None or self->find_struct(sname) == None:
                    fatal_at(self->file, st->pos, "'with' target must be a struct or a pointer to struct")
                # hidden pointer *Struct, evaluated exactly once (Pascal semantics)
                st->type = ty_ptr(self->a, ty_name(self->a, sname))
                st->name = self->a->printf("__with_%d_%d", st->pos.line, st->pos.col)
                if is_ptr:
                    st->init = st->expr
                elif not is_lvalue(st->expr) and st->expr->kind != EX_STRING:
                    # `with faz():` — an RVALUE target. Pascal semantics say
                    # evaluate once, so materialize it: `&faz()` is not C, and
                    # the C backend used to emit it and let the C compiler
                    # complain (the QBE backend refused it outright).
                    st->init = self->materialize_temp(st->expr, "'with' target expression")
                else:
                    st->init = take_addr(self->a, st->expr)
                # pushes the receiver; the body is checked with `.field` available
                self->with_names = vec_grow(self->with_names, self->nwith, ref self->cwith, sizeof(*self->with_names))
                self->with_names[self->nwith] = self->a->strdup(st->name)
                self->nwith += 1
                self->scope_push()
                self->scope_add(st->name, st->type)
                self->check_block(st->body)
                self->scope_pop()
                self->nwith -= 1
                return
            case ST_DEFER:
                self->check_defer_body(st->body, 0, 0)
                # the body runs at block EXIT: today's facts won't hold there (69.7)
                dsnap: *i32 = self->nn_save()
                self->nn_clear_all()
                self->check_block(st->body)
                self->nn_restore(dsnap)
                return
            case ST_BLOCK:
                self->check_block(st->body)
                return
            case ST_CPROTO:
                # block-scope function declaration: the hoisted prototype was
                # registered at file scope; here it re-binds the NAME locally —
                # conflicting with any same-scope object (`int foo = 3; int foo(void);`)
                if st->cfunc != None:
                    cprex: bool = False
                    if self->scope_find_cur(st->cfunc->name, &cprex):
                        # re-DECLARING the same function again is legal; only an
                        # OBJECT of the same name in the same scope conflicts
                        cpt: *Type = self->scope_find(st->cfunc->name)
                        if cpt == None or cpt->kind != TY_FUNC:
                            fatal_at(self->file, st->pos, "'%s' redeclared as a different kind of symbol", st->cfunc->name)
                    else:
                        self->scope_add(st->cfunc->name, ty_func(self->a, st->cfunc->ret))
                return
            case ST_GLOBAL:
                if self->globals.get_or(st->name, None) == None:
                    sgg: Sugg
                    sgg.init(st->name)
                    for gi2 in range(self->globals.elen):
                        if not self->globals.dead[gi2]:
                            sgg.feed(self->globals.keys[gi2])
                    fatal_at(self->file, st->pos, "'global %s': there is no module global named '%s'%s", st->name, st->name, self->sugg_text(&sgg))
                self->fn_globals.add(st->name)
                return
            case ST_NONLOCAL:
                if self->scope_find(st->name) != None and self->globals.get_or(st->name, None) == None:
                    fatal_at(self->file, st->pos, "'nonlocal %s': '%s' is already declared here — nonlocal marks a name whose FIRST assignment should live at function scope", st->name, st->name)
                self->fn_nonlocals.add(st->name)
                return
            case ST_SWITCH:
                self->check_expr(st->subject)
                swt: *Type = self->type_of(st->subject)
                if swt != None and (is_float_type(swt) or self->val_struct(swt) != None or is_void_val(swt) or swt->kind in {TY_PTR, TY_ARRAY, TY_FUNC}):
                    fatal_at(self->file, st->pos, "switch subject must have integer type")
                if self->func_designator(st->subject) != None:
                    fatal_at(self->file, st->pos, "switch subject must have integer type")
                # duplicate cases AFTER conversion to the subject's promoted type
                # (2^34 and 0 collide on an int switch) — scope is live here, so the
                # subject's width is knowable
                swvals: *i64 = None
                swposs: *Pos = None
                swn = 0; swcap = 0; swcap2 = 0; swndef = 0
                swdp: Pos = {0, 0}
                swm: u64 = ~u64(0)
                if swt != None and swt->kind == TY_NAME:
                    sww: i32 = ctype_width(swt->name)
                    if sww > 0 and sww < 4:
                        sww = 4   # C integer PROMOTION: char/short control as int
                    if sww > 0 and sww < 8:
                        swm = (u64(1) << u64(sww * 8)) - 1
                self->switch_collect_cases(st->body, ref swvals, ref swn, ref swcap, ref swposs, ref swcap2, ref swndef, ref swdp, swm)
                self->check_enum_exhaustive(st->pos, swt, swvals, swn, swndef > 0, "switch")
                free(swvals)
                free(swposs)
                swsnap: *i32 = self->nn_save()
                self->sw_depth += 1
                self->check_block(st->body)
                self->sw_depth -= 1
                self->nn_restore(swsnap)
                self->nn_kill_writes(st->body)   # merge point
                return
            case ST_BREAK:
                if self->loop_depth == 0 and self->sw_depth == 0:
                    fatal_at(self->file, st->pos, "'break' outside a loop or switch")
                return
            case ST_CASE:
                if self->sw_depth == 0:
                    fatal_at(self->file, st->pos, "'%s' label outside a switch", "case" if st->expr != None else "default")
                self->nn_clear_all()   # a jump target, like a label (69.7)
                return
            case ST_CONTINUE:
                if self->loop_depth == 0:
                    fatal_at(self->file, st->pos, "'continue' outside a loop")
                return
            # No `case _:` ON PURPOSE — see collect_vars in backend_qbe.p. These
            # three carry nothing for this pass to check; every OTHER kind does,
            # so a new one must not be able to reach here unnoticed.
            case ST_LABEL:
                # a goto may land here from anywhere: every fact dies (69.7)
                self->nn_clear_all()
                return
            case ST_GOTO, ST_PASS:
                return

    private def block_prepend(self: *Sema, b: *Block, st: *Stmt):
        ns: **Stmt = self->a->alloc(usize(b->n + 1) * sizeof(*ns))
        ns[0] = st
        for i in range(b->n):
            ns[i + 1] = b->stmts[i]
        b->stmts = ns
        b->n += 1

    # `for v in it:` where `it` is a struct/record (or pointer to one) that
    # implements Iterable. The FOR becomes, in place, its OWN BLOCK:
    #
    #     {
    #         __itN: *T = &it        (or `it`, when it is already a pointer)
    #         v: <ret of next>
    #         while __itN->has_next():
    #             v = __itN->next()
    #             <body>
    #     }
    #
    # A block, so the cursor and the loop variable die with the loop — two
    # `for v in ...` in a row reuse the name, exactly as 64.1's block scope
    # says — and so the whole thing goes through check_block like hand-written
    # code: the method calls resolve through the lookup the impl block filled,
    # and no backend learns anything.
    private def lower_for_iterable(self: *Sema, st: *Stmt, at: *Type, d1: **Stmt, d2: **Stmt):
        base: *Type = at
        nptr: i32 = 0
        while base != None and base->kind == TY_PTR:
            base = base->inner
            nptr += 1
        si: *SInfo = self->val_struct(base)
        if si == None or nptr > 1:
            fatal_at(self->file, st->pos, "`for v in x` takes a sized array or a type that implements Iterable, not %s", render_type_p(self->a, at))
        if not self->timpls.has(self->a->printf("Iterable/%s", si->name)):
            fatal_at(self->file, st->pos, "`for v in x` over '%s': the type has to implement Iterable — the bound is nominal (68.1), so write `implement Iterable for %s:`", si->name, si->name)
        nx: *Func = sinfo_method(si, "next")
        hn: *Func = sinfo_method(si, "has_next")
        if nx == None or hn == None:
            fatal_at(self->file, st->pos, "'%s' implements Iterable but is missing %s", si->name, "next()" if nx == None else "has_next()")
        # the cursor, bound ONCE — the expression may have effects, and a loop
        # that re-evaluated it would run them every turn
        cn: const *char = self->a->printf("__it%d", self->for_ctr)
        self->for_ctr += 1
        cd: *Stmt = st_new(self->a, ST_VAR, st->pos)
        cd->name = cn
        cd->type = ty_ptr(self->a, ty_name(self->a, si->name))
        if nptr == 1:
            cd->init = st->to
        else:
            amp: *Expr = ex_new(self->a, EX_UNARY, st->pos)
            amp->op = TK_AMP
            amp->lhs = st->to
            cd->init = amp
        vd: *Stmt = st_new(self->a, ST_VAR, st->pos)
        vd->name = st->var2
        vd->type = nx->ret if nx->ret != None else ty_name(self->a, "int")
        # `v = __it->next()` opens the body
        nc: *Expr = ex_new(self->a, EX_CALL, st->pos)
        nf: *Expr = ex_new(self->a, EX_FIELD, st->pos)
        nf->op = TK_ARROW
        nf->lhs = mk_ident(self->a, cn, st->pos)
        nf->field = "next"
        nc->lhs = nf
        bind: *Stmt = st_new(self->a, ST_ASSIGN, st->pos)
        bind->lhs = mk_ident(self->a, st->var2, st->pos)
        bind->op = TK_ASSIGN
        bind->rhs = nc
        self->block_prepend(st->body, bind)
        hc: *Expr = ex_new(self->a, EX_CALL, st->pos)
        hf: *Expr = ex_new(self->a, EX_FIELD, st->pos)
        hf->op = TK_ARROW
        hf->lhs = mk_ident(self->a, cn, st->pos)
        hf->field = "has_next"
        hc->lhs = hf
        wl: *Stmt = st_new(self->a, ST_WHILE, st->pos)
        wl->cond = hc
        wl->body = st->body
        blk: *Block = self->a->alloc(sizeof(Block))
        blk->stmts = self->a->alloc(usize(3) * sizeof(*blk->stmts))
        blk->stmts[0] = cd
        blk->stmts[1] = vd
        blk->stmts[2] = wl
        blk->n = 3
        st->kind = ST_BLOCK
        st->body = blk
        st->var = None
        st->var2 = None
        st->from = None
        st->to = None
        st->step = None
        *d1 = None
        *d2 = None

    private def lower_for_iter(self: *Sema, st: *Stmt, d1: **Stmt, d2: **Stmt):
        *d1 = None
        *d2 = None
        if st->var2 != None:
            # `for v in xs` (parser left var == ""): synthesize the hidden index
            if st->var != None and st->var[0] == '\0':
                st->var = self->a->printf("__fi%d", self->for_ctr)
                self->for_ctr += 1
            arr: *Expr = st->to
            at: *Type = self->type_of(arr)
            if at == None:
                at = self->infer_type(arr)
            # `for v in it` over a type that implements Iterable (68.9): the
            # protocol of 40.3, written out — a cursor bound once, then
            # `while has_next(): v = next()`. Everything here is a DIRECT call
            # the method lookup resolves: no vtable, no allocation, no runtime,
            # which is the condition the request set. Nominal, like every other
            # use of a trait now (68.1): the pair `implement Iterable for T:`
            # has to exist.
            if at != None and at->kind != TY_ARRAY:
                self->lower_for_iterable(st, at, d1, d2)
                return
            if at == None or at->arr_len == None:
                fatal_at(self->file, st->pos, "`for v in x` takes a sized array or a type that implements Iterable (68.9)")
            idecl: *Stmt = st_new(self->a, ST_VAR, st->pos)
            idecl->name = st->var
            idecl->type = ty_name(self->a, "usize")
            vdecl: *Stmt = st_new(self->a, ST_VAR, st->pos)
            vdecl->name = st->var2
            vdecl->type = at->inner
            # bind `v = arr[i]` at the top of the body, then rewrite to range(0, len)
            ix: *Expr = ex_new(self->a, EX_INDEX, st->pos)
            ix->lhs = arr
            ix->rhs = mk_ident(self->a, st->var, st->pos)
            asn: *Stmt = st_new(self->a, ST_ASSIGN, st->pos)
            asn->lhs = mk_ident(self->a, st->var2, st->pos)
            asn->op = TK_ASSIGN
            asn->rhs = ix
            self->block_prepend(st->body, asn)
            st->from = None
            st->to = at->arr_len
            st->step = None
            st->var2 = None       # now a plain range-for for check_stmt and the backends
            self->scope_add(idecl->name, idecl->type)
            self->locals[self->nlocals - 1].for_iter = True
            self->scope_add(vdecl->name, vdecl->type)
            self->locals[self->nlocals - 1].for_iter = True
            *d1 = idecl
            *d2 = vdecl
            return
        is_signed: bool = expr_is_negative(st->from) or expr_is_negative(st->to) or expr_is_negative(st->step)
        if self->scope_find(st->var) != None:
            # the variable already exists: this loop REUSES it (§5). A descending
            # range needs a signed iterator — reusing an unsigned one would compile
            # to `i > -1` on an unsigned variable, a loop that never runs.
            xi: i32 = self->sym_index(st->var)
            if is_signed and xi >= 0 and type_is_unsigned(self->locals[xi].type):
                if self->locals[xi].for_iter and self->locals[xi].for_decl != None:
                    # the compiler owns that declaration: promote it to `isize`,
                    # which represents both this range and the earlier one
                    sty: *Type = ty_name(self->a, "isize")
                    self->resolve_type(sty)
                    self->locals[xi].for_decl->type = sty
                    self->locals[xi].type = sty
                else:
                    fatal_at(self->file, st->pos, "loop variable '%s' is '%s', but this range counts down through negative values — declare it as 'isize' (or use another name)", st->var, render_type_p(self->a, self->locals[xi].type))
            return
        ty: *Type = ty_name(self->a, "isize" if is_signed else "usize")
        decl: *Stmt = st_new(self->a, ST_VAR, st->pos)
        decl->name = st->var
        decl->type = ty
        self->scope_add(st->var, ty)
        self->locals[self->nlocals - 1].for_iter = True
        self->locals[self->nlocals - 1].for_decl = decl
        *d1 = decl

    # checks a block's statements, injecting auto-declared `for` iterators as an
    # ST_VAR right before their loop. The caller owns the scope, so the iterator
    # stays visible after the loop. b->stmts is rebuilt only if something was added.
    private def check_stmts(self: *Sema, b: *Block):
        ns: **Stmt = None
        nn: i32 = 0
        cap: i32 = 0
        injected: bool = False
        for i in range(b->n):
            st: *Stmt = b->stmts[i]
            if st->kind == ST_FOR:
                d1: *Stmt = None
                d2: *Stmt = None
                self->lower_for_iter(st, &d1, &d2)
                if d1 != None:
                    ns = vec_grow(ns, nn, ref cap, sizeof(*ns))
                    ns[nn] = d1
                    nn += 1
                    injected = True
                if d2 != None:
                    ns = vec_grow(ns, nn, ref cap, sizeof(*ns))
                    ns[nn] = d2
                    nn += 1
            mark: i32 = self->se_npend
            self->check_stmt(st)
            for k in range(mark, self->se_npend):
                ns = vec_grow(ns, nn, ref cap, sizeof(*ns))
                ns[nn] = self->se_pend[k]
                nn += 1
                injected = True
            self->se_npend = mark
            ns = vec_grow(ns, nn, ref cap, sizeof(*ns))
            ns[nn] = st
            nn += 1
        if injected:
            b->stmts = ns
            b->n = nn

    private def check_block(self: *Sema, b: *Block):
        self->scope_push()
        self->check_stmts(b)
        self->scope_pop()

    # ---------- function-wide label / case checks ----------
    # collects every ST_LABEL in the function (labels are function-scoped in C);
    # duplicates get a friendly error, then each goto must land on one of them.
    private def walk_labels(self: *Sema, b: *Block, ref names: **char, ref n: i32, ref cap: i32, ref poss: *Pos, ref cap2: i32):
        if b == None:
            return
        for i in range(b->n):
            st: *Stmt = b->stmts[i]
            if st->kind == ST_LABEL:
                for j in range(n):
                    if strcmp(names[j], st->label) == 0:
                        fatal_at(self->file, st->pos, "duplicate label '%s' (already defined at line %d)", st->label, poss[j].line)
                names = vec_grow(names, n, ref cap, sizeof(*names))
                poss = vec_grow(poss, n, ref cap2, sizeof(*poss))
                names[n] = (*char)(st->label)
                poss[n] = st->pos
                n += 1
            self->walk_labels(st->body, ref names, ref n, ref cap, ref poss, ref cap2)
            self->walk_labels(st->else_block, ref names, ref n, ref cap, ref poss, ref cap2)
            for j in range(st->nconds):
                self->walk_labels(st->blocks[j], ref names, ref n, ref cap, ref poss, ref cap2)
            for j in range(st->ncases):
                self->walk_labels(st->cases[j]->body, ref names, ref n, ref cap, ref poss, ref cap2)

    private def walk_gotos(self: *Sema, b: *Block, names: **char, n: i32):
        if b == None:
            return
        for i in range(b->n):
            st: *Stmt = b->stmts[i]
            if st->kind == ST_GOTO:
                found: bool = False
                for j in range(n):
                    if strcmp(names[j], st->label) == 0:
                        found = True
                        break
                if not found:
                    sgl: Sugg
                    sgl.init(st->label)
                    for j in range(n):
                        sgl.feed(names[j])
                    fatal_at(self->file, st->pos, "goto to undefined label '%s'%s", st->label, self->sugg_text(&sgl))
            self->walk_gotos(st->body, names, n)
            self->walk_gotos(st->else_block, names, n)
            for j in range(st->nconds):
                self->walk_gotos(st->blocks[j], names, n)
            for j in range(st->ncases):
                self->walk_gotos(st->cases[j]->body, names, n)

    # duplicate `case` VALUES within one switch (nested switches have their own
    # scope: the walk stops at them and they are checked on their own visit)
    # `mask` truncates each case value to the SUBJECT's width before comparing:
    # in C the case converts to the promoted controlling type, so 2^34 and 0
    # collide on an int switch. Full-width mask when the subject type is unknown.
    private def switch_collect_cases(self: *Sema, b: *Block, ref vals: *i64, ref n: i32, ref cap: i32, ref poss: *Pos, ref cap2: i32, ref ndef: i32, ref defpos: Pos, mask: u64):
        if b == None:
            return
        for i in range(b->n):
            st: *Stmt = b->stmts[i]
            if st->kind == ST_SWITCH or st->kind == ST_MATCH:
                continue   # inner switch: its own scope
            if st->kind == ST_CASE:
                if st->expr == None:
                    if ndef > 0:
                        fatal_at(self->file, st->pos, "duplicate 'default' in switch (already defined at line %d)", defpos.line)
                    ndef += 1
                    defpos = st->pos
                else:
                    cok: bool = True
                    cvv2: CVal = self->ceval_val(st->expr, None, ref cok)
                    if cvv2.kind == CV_STR:
                        fatal_at(self->file, st->pos, "case label is not an integer constant expression (a string)")
                    if cvv2.kind == CV_FLOAT:
                        fatal_at(self->file, st->pos, "case label is not an integer constant expression (a floating value)")
                    v: i64 = cvv2.ival if cok else 0
                    v = i64(u64(v) & mask)
                    if not cok and st->expr->kind == EX_IDENT and self->scope_find(st->expr->text) != None and not self->is_enum_const(st->expr->text):
                        fatal_at(self->file, st->pos, "case value must be a constant expression ('%s' is a variable)", st->expr->text)
                    if cok:
                        for j in range(n):
                            if vals[j] == v:
                                fatal_at(self->file, st->pos, "duplicate case value %lld (already used at line %d; both convert to the same value)", v, poss[j].line)
                        vals = vec_grow(vals, n, ref cap, sizeof(*vals))
                        poss = vec_grow(poss, n, ref cap2, sizeof(*poss))
                        vals[n] = v
                        poss[n] = st->pos
                        n += 1
            self->switch_collect_cases(st->body, ref vals, ref n, ref cap, ref poss, ref cap2, ref ndef, ref defpos, mask)
            self->switch_collect_cases(st->else_block, ref vals, ref n, ref cap, ref poss, ref cap2, ref ndef, ref defpos, mask)
            for j in range(st->nconds):
                self->switch_collect_cases(st->blocks[j], ref vals, ref n, ref cap, ref poss, ref cap2, ref ndef, ref defpos, mask)

    # -Wswitch / -Wswitch-enum: enumerators of the subject's type that no case
    # covers. Clang's split, and we keep it:
    #   -Wswitch       on by default, fires ONLY when there is no default label
    #                  (a default makes the switch total, so C code is quiet).
    #   -Wswitch-enum  off by default and NOT in -Wall, fires even WITH a default.
    # The second is the one a dispatch over an AST node kind wants: the catch-all
    # exists for the kinds that need no work, and adding a kind must still be
    # reported. That is why plangc builds itself with -Wswitch-enum (see the
    # Makefile) — a `case _:` must never be able to swallow a NEW kind silently.
    #
    # Coverage is decided BY VALUE, not by name: two enumerators sharing a value
    # are covered together. Same as clang, and required for correctness — a case
    # on either spelling really does handle both.
    #
    # Only fires on P input today. The C front end MAPS `enum Tag` to its
    # underlying integer type (cfront.p: `unsigned`, or `int` when an enumerator
    # is negative — gcc's rule, and 00218 depends on it), so a C switch subject
    # no longer carries the enum's identity and there is nothing to check
    # against. Keeping that identity means giving TAG_ENUM a width/signedness
    # everywhere arithmetic asks — a real change, not a side effect of this one.
    private def check_enum_exhaustive(self: *Sema, pos: Pos, subj: *Type, vals: *i64, n: i32, has_default: bool, what: const *char):
        if self->in_chdr or subj == None or subj->kind != TY_NAME:
            return
        ed: *Decl = self->enums.get_or(subj->name, None)
        if ed == None or ed->nitems == 0:
            return
        missing: **char = None
        nm = 0; mcap = 0
        for i in range(ed->nitems):
            ecv: *CVal = self->constvals.get_or(ed->items[i].name, None)
            if ecv == None or ecv->kind != CV_INT:
                # a value we cannot fold: stay silent rather than report a
                # coverage hole that may not be one
                free(missing)
                return
            found: bool = False
            for j in range(n):
                if vals[j] == ecv->ival:
                    found = True
                    break
            if not found:
                missing = vec_grow(missing, nm, ref mcap, sizeof(*missing))
                missing[nm] = (*char)(ed->items[i].name)
                nm += 1
        if nm > 0:
            # clang's phrasing, including its "spell out up to 3" cutoff
            # clang says "not EXPLICITLY handled" when a default label exists —
            # the switch is total, the point is only that a case is missing
            expl: const *char = "explicitly " if has_default else ""
            b: StrBuf = {0}
            if nm > 3:
                b.printf("%d enumeration values not %shandled in %s: ", nm, expl, what)
                for i in range(3):
                    b.printf("%s'%s'", "" if i == 0 else ", ", missing[i])
                b.puts("...")
            else:
                b.printf("enumeration value%s ", "" if nm == 1 else "s")
                for i in range(nm):
                    if i > 0:
                        b.puts(", " if nm > 2 and i < nm - 1 else (", and " if nm > 2 else " and "))
                    b.printf("'%s'", missing[i])
                b.printf(" not %shandled in %s", expl, what)
            cdiag_at(self->file, pos, "switch-enum" if has_default else "switch",
                     WD_OFF if has_default else WD_WARN, "%s", b.data)
            b.deinit()
        free(missing)

    private def check_switch_dups(self: *Sema, b: *Block):
        if b == None:
            return
        for i in range(b->n):
            st: *Stmt = b->stmts[i]
            if st->kind == ST_MATCH and not st->is_typematch:
                vals2: *i64 = None
                poss2: *Pos = None
                n2 = 0; c1 = 0; c2 = 0; nd2 = 0
                for j in range(st->ncases):
                    mc: *MatchCase = st->cases[j]
                    if mc->is_default:
                        if nd2 > 0:
                            fatal_at(self->file, st->pos, "duplicate 'case _' in match")
                        nd2 += 1
                    for k in range(mc->nvals):
                        cok2: bool = True
                        v2: i64 = self->ceval(mc->vals[k], ref cok2)
                        if cok2:
                            for q in range(n2):
                                if vals2[q] == v2:
                                    fatal_at(self->file, mc->vals[k]->pos, "duplicate case value %lld in match (already used at line %d)", v2, poss2[q].line)
                            vals2 = vec_grow(vals2, n2, ref c1, sizeof(*vals2))
                            poss2 = vec_grow(poss2, n2, ref c2, sizeof(*poss2))
                            vals2[n2] = v2
                            poss2[n2] = mc->vals[k]->pos
                            n2 += 1
                free(vals2)
                free(poss2)
            self->check_switch_dups(st->body)
            self->check_switch_dups(st->else_block)
            for j in range(st->nconds):
                self->check_switch_dups(st->blocks[j])
            for j in range(st->ncases):
                self->check_switch_dups(st->cases[j]->body)

    private def check_func_body(self: *Sema, f: *Func):
        if f->body == None:
            return
        # defer injects code at the exit points; goto could jump over it
        if block_find_kind(f->body, ST_DEFER) != None:
            g: *Stmt = block_find_kind(f->body, ST_GOTO)
            if g != None:
                fatal_at(self->file, g->pos, "goto cannot be used in a function that contains defer")
        # labels are function-scoped: duplicates and gotos to nowhere are errors
        lnames: **char = None
        lposs: *Pos = None
        ln = 0; lc1 = 0; lc2 = 0
        self->walk_labels(f->body, ref lnames, ref ln, ref lc1, ref lposs, ref lc2)
        self->walk_gotos(f->body, lnames, ln)
        free(lnames)
        free(lposs)
        self->check_switch_dups(f->body)
        prev_fname: const *char = self->cur_fname
        prev_ret: *Type = self->cur_ret
        self->cur_fname = f->cname   # for __func__
        self->cur_ret = f->ret
        self->loop_depth = 0
        self->sw_depth = 0
        self->vla_nhoist = 0         # --std=c89: VLA statements to hoist to the entry
        self->fn_globals.deinit()    # per-function `global`/`nonlocal` state
        self->fn_nonlocals.deinit()
        self->fn_hoisted.deinit()
        self->scope_push()
        for i in range(f->nparams):
            self->scope_add(f->params[i].name, f->params[i].type)
            self->locals[self->nlocals - 1].byref = f->params[i].byref
        self->check_stmts(f->body)
        # C# definite assignment, soft form: an `out` parameter that is never
        # assigned anywhere in the body defeats its contract
        for oi in range(f->nparams):
            if f->params[oi].byref == PK_OUT:
                obase: i32 = self->scopes[self->nscopes - 1]
                if obase + oi < self->nlocals and not self->locals[obase + oi].written:
                    cdiag_at(self->file, f->params[oi].pos, "out-param-unassigned", WD_WARN, "out parameter '%s' is never assigned in '%s'", f->params[oi].name, f->name)
        self->scope_pop()
        # -Wreturn-type: a non-void function whose body can fall off the end
        # (main is exempt: C99 5.1.2.2.3 implies return 0)
        if not self->in_chdr and f->ret != None and not is_void_val(f->ret) and f->name != None and f->name != "main":
            if f->body == None or f->body->n == 0 or not self->stmt_exits_c(f->body->stmts[f->body->n - 1]):
                cdiag_at(self->file, f->pos, "return-type", WD_WARN, "non-void function does not return a value")
        # hoists the hidden pointers + defers of the VLAs to the function's ENTRY. They
        # stay before any label (goto doesn't skip the decl) and in the outermost scope (the
        # free runs on every return, immune to goto). This is why goto+VLA is safe in c89.
        if self->vla_nhoist > 0:
            total: i32 = self->vla_nhoist + f->body->n
            ns: **Stmt = self->a->alloc(usize(total) * sizeof(*ns))
            for i in range(self->vla_nhoist):
                ns[i] = self->vla_hoist[i]
            for i in range(f->body->n):
                ns[self->vla_nhoist + i] = f->body->stmts[i]
            f->body->stmts = ns
            f->body->n = total
        self->cur_fname = prev_fname
        self->cur_ret = prev_ret

    # ---------- declaration registration ----------
    private def register_func(self: *Sema, f: *Func):
        # generic free function (def foo<T>): a template — not resolved/emitted as-is;
        # monomorphized on `declare foo<int>`. Its param/ret types mention T.
        if f->ntparams > 0 and f->owner == None:
            if not self->func_templates.has(f->name):
                self->func_templates.put(f->name, f)
            return
        for i0 in range(f->nparams):
            self->resolve_type(f->params[i0].type)
            self->require_complete(f->params[i0].type, f->pos)
            if f->params[i0].dflt != None and not self->in_chdr:
                if f->is_varargs:
                    fatal_at(self->file, f->pos, "default parameter values cannot be combined with '...' ('%s')", f->name)
                if not self->static_const_ok(f->params[i0].dflt):
                    fatal_at(self->file, f->pos, "default value of parameter '%s' must be a compile-time constant", f->params[i0].name)
            if not self->in_chdr and is_void_val(f->params[i0].type):
                fatal_at(self->file, f->pos, "parameter %d of '%s' has void type", i0 + 1, f->name)
            if f->params[i0].name != None and f->params[i0].name[0] != '\0':
                for j0 in range(i0):
                    if f->params[j0].name != None and strcmp(f->params[j0].name, f->params[i0].name) == 0:
                        fatal_at(self->file, f->pos, "duplicate parameter name '%s' in '%s'", f->params[i0].name, f->name)
            # fold const/enum array dims to literals; under --std=c89 a runtime
            # dimension in a parameter (VLA, e.g. `a: i32[n]`) is rejected here too.
            self->fold_const_dims(f->params[i0].type)
        self->resolve_type(f->ret)
        # a DEFINITION needs complete by-value param and return types (prototypes
        # may mention incomplete tags freely)
        if f->body != None and not self->in_chdr:
            rsi2: *SInfo = self->val_struct(f->ret)
            if rsi2 != None and not rsi2->defined:
                fatal_at(self->file, f->pos, "function '%s' returns incomplete type '%s'", f->name, rsi2->name)
            for ip in range(f->nparams):
                psi2: *SInfo = self->val_struct(f->params[ip].type)
                if psi2 != None and not psi2->defined:
                    fatal_at(self->file, f->pos, "parameter %d of '%s' has incomplete type '%s'", ip + 1, f->name, psi2->name)
        # C: a second DEFINITION of the same function, or a function name that is
        # already a file-scope object, is a redefinition error (C modules only —
        # P generics re-register monomorphized clones legitimately)
        if f->ret != None and f->ret->kind == TY_ARRAY and not self->in_chdr:
            fatal_at(self->file, f->pos, "function '%s' returns an array (functions cannot return array types)", f->name)
        if f->ret != None and f->ret->kind == TY_FUNC and not self->in_chdr:
            fatal_at(self->file, f->pos, "function '%s' returns a function (use a function POINTER)", f->name)
        if self->c_mod and not self->in_chdr and f->owner == None:
            oldf: *Func = self->funcs.get_or(f->cname, None)
            if oldf != None and oldf != f and oldf->body != None and f->body != None:
                fatal_at(self->file, f->pos, "redefinition of function '%s'", f->name)
            if oldf != None and oldf != f and not oldf->is_static and f->is_static:
                fatal_at(self->file, f->pos, "static declaration of '%s' follows non-static declaration", f->name)
            if oldf != None and oldf != f:
                # both signatures KNOWN (not '()') and different: conflict
                if not self->type_compat(oldf->ret, f->ret):
                    fatal_at(self->file, f->pos, "conflicting return types for '%s'", f->name)
                if (oldf->nparams > 0 or oldf->is_varargs or not oldf->sig_empty) and (f->nparams > 0 or f->is_varargs or not f->sig_empty):
                    if oldf->nparams != f->nparams or oldf->is_varargs != f->is_varargs:
                        fatal_at(self->file, f->pos, "conflicting types for '%s' (%d vs %d parameters)", f->name, f->nparams, oldf->nparams)
                    for cfi in range(f->nparams):
                        pa2: *Type = oldf->params[cfi].type
                        pb2: *Type = f->params[cfi].type
                        # arrays in parameters decay: compare the decayed forms
                        if pa2 != None and pa2->kind == TY_ARRAY:
                            pa2 = ty_ptr(self->a, pa2->inner)
                        if pb2 != None and pb2->kind == TY_ARRAY:
                            pb2 = ty_ptr(self->a, pb2->inner)
                        if not self->type_compat(pa2, pb2):
                            fatal_at(self->file, f->pos, "conflicting types for parameter %d of '%s'", cfi + 1, f->name)
            if self->globals.get_or(f->cname, None) != None:
                fatal_at(self->file, f->pos, "'%s' redeclared as a different kind of symbol", f->name)
        if not self->funcs.has(f->cname):
            self->funcs.put(f->cname, f)

        # method declared inside the struct
        if f->owner != None:
            si: *SInfo = self->find_struct(f->owner)
            if si != None and sinfo_method(si, f->name) == None:
                si->methods = vec_grow(si->methods, si->nmethods, ref si->cmethods, sizeof(*si->methods))
                si->methods[si->nmethods] = f
                si->nmethods += 1
            return
        # free form already mangled: def Struct_method(self: *Struct, ...)
        if f->nparams > 0 and f->params[0].name == "self":
            t: *Type = f->params[0].type
            if t->kind == TY_PTR and t->inner->kind == TY_NAME:
                sname: const *char = t->inner->name
                sl: usize = strlen(sname)
                if strncmp(f->cname, sname, sl) == 0 and f->cname[sl] == '_':
                    si2: *SInfo = self->find_struct(sname)
                    if si2 != None:
                        mth: *Func = sinfo_method(si2, f->cname + sl + 1)
                        if mth == None:
                            alias: *Func = self->a->alloc(sizeof(Func))
                            *alias = *f
                            alias->name = f->cname + sl + 1
                            alias->owner = sname
                            si2->methods = vec_grow(si2->methods, si2->nmethods, ref si2->cmethods, sizeof(*si2->methods))
                            si2->methods[si2->nmethods] = alias
                            si2->nmethods += 1

    private def cpp_capture(self: *Sema, flags: const *char, path: const *char, is_sys: bool, dir: const *char) -> const *char:
        return cpp_capture_ex(self->a, self->cc->cpp, flags, path, is_sys, dir)

    private def macro_put(self: *Sema, name: const *char, v: CVal):
        cp: *CVal = self->a->alloc(sizeof(CVal))
        *cp = v
        self->constvals.put(name, cp)
        self->macroconsts.add(name)

    # `cc -E -dM`: every #define visible after including the header. Object-like
    # macros whose RHS is a literal (or an alias to one) become comptime constants —
    # EOF, BUFSIZ, RAND_MAX... Function-like and token/text macros are skipped: they
    # have no typed value (that's cpp territory; in the C backend they still pass
    # through and the emitted #include resolves them).
    private def ingest_macros(self: *Sema, path: const *char, is_sys: bool, dir: const *char):
        # 109: a captura do dump é cacheada no Cc — o mesmo header incluído por
        # cinco módulos rodava o cpp cinco vezes
        src: const *char = None
        for mi in range(self->cc->nmac):
            if strcmp(self->cc->macs[mi].path, path) == 0:
                src = self->cc->macs[mi].text
                break
        if src == None:
            src = self->cpp_capture("-E -dM", path, is_sys, dir)
            self->cc->macs = vec_grow(self->cc->macs, self->cc->nmac, ref self->cc->cmac, sizeof(*self->cc->macs))
            md: MacroDump = {path, src}
            self->cc->macs[self->cc->nmac] = md
            self->cc->nmac += 1
        an: **char = None    # alias macros (NAME -> IDENT): resolved after the scan
        av: **char = None
        nal = 0; cal = 0; cav = 0
        p: const *char = src
        while *p != '\0':
            # each line: #define NAME rest
            eol: const *char = strchr(p, '\n')
            if eol == None:
                eol = p + strlen(p)
            if strncmp(p, "#define ", 8) == 0:
                q: const *char = p + 8
                st: const *char = q
                while q < eol and *q != ' ' and *q != '(' and *q != '\t':
                    q += 1
                if q < eol and *q != '(':   # '(' right after the name = function-like: skip
                    name: const *char = self->a->strndup(st, usize(q - st))
                    while q < eol and (*q == ' ' or *q == '\t'):
                        q += 1
                    rhs: const *char = self->a->strndup(q, usize(eol - q))
                    if not self->constvals.has(name):
                        iv: i64 = 0
                        rl: usize = strlen(rhs)
                        if macro_int_val(rhs, &iv):
                            self->macro_put(name, cv_int(iv))
                        elif rl >= 2 and rhs[0] == '"' and rhs[rl - 1] == '"':
                            self->macro_put(name, cv_str(rhs))
                        elif rl > 0 and (isalpha(rhs[0]) or rhs[0] == '_'):
                            ok2: bool = True
                            k: usize = 1
                            while k < rl:
                                if not (isalnum(rhs[k]) or rhs[k] == '_'):
                                    ok2 = False
                                    break
                                k += 1
                            if ok2:   # NAME -> OTHER_MACRO: resolve later
                                an = vec_grow(an, nal, ref cal, sizeof(*an))
                                av = vec_grow(av, nal, ref cav, sizeof(*av))
                                an[nal] = (*char)(name)
                                av[nal] = (*char)(rhs)
                                nal += 1
            p = eol + 1 if *eol != '\0' else eol
        # alias passes: INT_MAX -> __INT_MAX__ etc. (bounded; chains are short)
        pass_: i32 = 0
        while pass_ < 4:
            changed: bool = False
            for i in range(nal):
                if an[i] != None and not self->constvals.has(an[i]):
                    tv: *CVal = self->constvals.get_or(av[i], None)
                    if tv != None:
                        self->macro_put(an[i], *tv)
                        an[i] = None
                        changed = True
            if not changed:
                break
            pass_ += 1
        # An alias whose target is not a CONSTANT is a rename of a declared OBJECT,
        # and it has to survive too: macOS declares no `stderr` at all — <stdio.h>
        # has `__stderrp` plus `#define stderr __stderrp`. Since a P source is never
        # run through cpp, the macro cannot apply itself, so the name is recorded and
        # an identifier that resolves nowhere else follows the rename (check_expr).
        # Same shape as glibc's `st_mtime` -> `st_mtim.tv_sec`, except a plain rename
        # is something we CAN follow; a member path is what `hasfield` is for.
        for i2 in range(nal):
            if an[i2] != None and not self->macroalias.has(an[i2]):
                self->macroalias.put(an[i2], av[i2])
        free(an)
        free(av)

    private def ingest_c_header(self: *Sema, m: *Module, d: *Decl):
        dir: const *char = path_dir(self->a, m->path)
        key: const *char = self->a->printf("<c>%s", d->import_path)
        # declarations: cache by path (a header is parsed once per compilation)
        cached: *Module = None
        i: i32
        for i in range(self->cc->nmods):
            if strcmp(self->cc->mods[i]->path, key) == 0:
                cached = self->cc->mods[i]
                break
        if cached == None:
            src: const *char = self->cpp_capture("-E -P", d->import_path, d->import_system, dir)
            cached = c_parse(self->a, d->import_path, src, strlen(src), False)
            cached->path = key
            # signatures only: drop function bodies (glibc's static-inline helpers
            # call __builtin_* the QBE backend can't emit, and their bodies would be
            # re-checked/re-emitted per TU). A call to one resolves to the real libc
            # symbol; the C backend's emitted #include keeps the inline version.
            for i in range(cached->ndecls):
                if cached->decls[i]->kind == DL_FUNC:
                    cached->decls[i]->func->body = None
                    cached->decls[i]->func->is_inline = False
                    cached->decls[i]->func->is_static = False
            self->cc->mods = vec_grow(self->cc->mods, self->cc->nmods, ref self->cc->cmods, sizeof(*self->cc->mods))
            self->cc->mods[self->cc->nmods] = cached
            self->cc->nmods += 1
        prevh: bool = self->in_chdr
        self->in_chdr = True
        self->register_module(cached, False)
        self->in_chdr = prevh
        # macro constants: registered per sema run (constvals are per-module state)
        self->ingest_macros(d->import_path, d->import_system, dir)

    # declare/implement X<...>: monomorphizes the template and turns the node into
    # a concrete DL_STRUCT (declare: fields + prototypes; implement: bodies only),
    # which follows the normal registration and emission flow
    # `implement Trait for Type:` (67.2) — attaches the bodies to Type as
    # METHODS, so a call inside a monomorphized generic resolves through the
    # lookup that already exists. No dispatch is invented and no vtable is built:
    # that is exactly what "static form only" (67.1) buys.
    private def trait_impl(self: *Sema, m: *Module, d: *Decl, check_bodies: bool):
        tr: *Decl = self->traits.get_or(d->name, None)
        if tr == None:
            fatal_at(self->file, d->pos, "unknown trait '%s'", d->name)
        si: *SInfo = self->find_struct(d->trait_for)
        if si == None:
            fatal_at(self->file, d->pos, "unknown type '%s'", d->trait_for)
        # THE ORPHAN RULE (67.3): at most one implementation per (trait, type),
        # and this module must own one of the two. Without it, two modules
        # implement the same pair differently and the behaviour depends on who
        # linked — with the error landing far from the cause.
        key: const *char = self->a->printf("%s/%s", d->name, d->trait_for)
        if self->timpls.has(key):
            fatal_at(self->file, d->pos, "'%s' is already implemented for '%s'", d->name, d->trait_for)
        self->timpls.add(key)
        if not decl_in_module(m, d->name) and not decl_in_module(m, d->trait_for):
            fatal_at(self->file, d->pos, "this module declares neither the trait '%s' nor the type '%s', so it cannot implement one for the other (the orphan rule keeps two modules from disagreeing)", d->name, d->trait_for)
        # the ASSOCIATED type (72.5): the trait names it, every implementation
        # says what it is. Checked before the methods, because the methods are
        # compared with it substituted in.
        if tr->assoc != None and d->assoc_type == None:
            fatal_at(self->file, d->pos, "trait '%s' has an associated type: this implementation has to say `type %s = <type>`", d->name, tr->assoc)
        if tr->assoc == None and d->assoc_type != None:
            fatal_at(self->file, d->pos, "trait '%s' declares no associated type, so there is no `type %s` to fill in", d->name, d->assoc)
        if tr->assoc != None and d->assoc != None and strcmp(tr->assoc, d->assoc) != 0:
            fatal_at(self->file, d->pos, "trait '%s' names its associated type '%s', not '%s'", d->name, tr->assoc, d->assoc)
        # every signature the trait names has to be here, WHOLE — parameters
        # and return type, with the trait's own name standing for the type and
        # the associated type for whatever this implementation chose (72.5).
        # Checking only the name and the count let an implementation return
        # something else entirely and be found out much later, inside a
        # monomorphized body, with the error pointing at the wrong line.
        for i in range(tr->nmethods):
            want: *Func = tr->methods[i]
            got: *Func = None
            for j in range(d->nmethods):
                if strcmp(d->methods[j]->name, want->name) == 0:
                    got = d->methods[j]
                    break
            if got == None:
                fatal_at(self->file, d->pos, "'%s' for '%s' is missing '%s'", d->name, d->trait_for, want->name)
            if got->nparams != want->nparams:
                fatal_at(self->file, got->pos, "'%s' takes %d parameter(s) in trait '%s', %d given", want->name, want->nparams, d->name, got->nparams)
            for k in range(want->nparams):
                exp: *Type = trait_sub(self->a, want->params[k].type, d->name, d->trait_for, tr->assoc, d->assoc_type)
                if not type_eq_p(exp, got->params[k].type):
                    fatal_at(self->file, got->pos, "'%s': parameter '%s' is %s in trait '%s', and %s here", want->name, want->params[k].name, render_type_p(self->a, exp), d->name, render_type_p(self->a, got->params[k].type))
                if want->params[k].byref != got->params[k].byref:
                    fatal_at(self->file, got->pos, "'%s': parameter '%s' is passed differently than trait '%s' declares (`in`/`out`/`ref` is part of the contract)", want->name, want->params[k].name, d->name)
            rexp: *Type = trait_sub(self->a, want->ret, d->name, d->trait_for, tr->assoc, d->assoc_type)
            if not type_eq_p(rexp, got->ret):
                fatal_at(self->file, got->pos, "'%s' returns %s in trait '%s', and %s here", want->name, render_type_p(self->a, rexp), d->name, render_type_p(self->a, got->ret))
        for j in range(d->nmethods):
            found: bool = False
            for i in range(tr->nmethods):
                if strcmp(tr->methods[i]->name, d->methods[j]->name) == 0:
                    found = True
                    break
            if not found:
                fatal_at(self->file, d->methods[j]->pos, "'%s' is not a method of trait '%s'", d->methods[j]->name, d->name)
        # registered as the type's own methods
        for j in range(d->nmethods):
            mth: *Func = d->methods[j]
            si->methods = vec_grow(si->methods, si->nmethods, ref si->cmethods, sizeof(*si->methods))
            si->methods[si->nmethods] = mth
            si->nmethods += 1
            if m->is_header:
                mth->in_header = True
            self->register_func(mth)
        for j in range(d->nmethods):
            if check_bodies:
                self->check_func_body(d->methods[j])
        # The node becomes the shape the back ends already emit for "a struct
        # redeclared only to carry method bodies": no fields, no definition,
        # just the functions. So no back end learns anything about traits —
        # after this point there is nothing left of the trait but the methods it
        # required, which is the same thing that makes it cost nothing at run time.
        with d:
            .kind = DL_STRUCT
            .name = d->trait_for
            .fields = None
            .nfields = 0
            .is_def = False
            .is_fwd = False

    # does `t` satisfy `trait`? It does when it has every method the trait names.
    # The impl block registered them as the type's own methods, so this is the
    # same lookup a hand-written call would do.
    private def check_bound(self: *Sema, t: *Type, trait: const *char, tparam: const *char, pos: Pos):
        tr: *Decl = self->traits.get_or(trait, None)
        if tr == None:
            fatal_at(self->file, pos, "unknown trait '%s' in the bound on '%s'", trait, tparam)
        base: *Type = t
        while base != None and base->kind == TY_PTR:
            base = base->inner
        si: *SInfo = self->val_struct(base)
        if si == None:
            fatal_at(self->file, pos, "'%s' = %s does not implement '%s': only a struct or record can (write `implement %s for T:`)", tparam, render_type_p(self->a, t), trait, trait)
        # NOMINAL, as in pscript (66.2/68.1): having the methods is not enough —
        # the pair has to be DECLARED with `implement X for T:`. The two
        # languages answer the same question the same way, which is what 65
        # asked for, and 'satisfies by accident' dies on this side too.
        if not self->timpls.has(self->a->printf("%s/%s", trait, si->name)):
            fatal_at(self->file, pos, "'%s' = '%s' does not DECLARE '%s': the bound is nominal (68.1) — write `implement %s for %s:`", tparam, si->name, trait, trait, si->name)
        for i in range(tr->nmethods):
            if sinfo_method(si, tr->methods[i]->name) == None:
                fatal_at(self->file, pos, "'%s' = '%s' does not implement '%s': '%s' is missing (write `implement %s for %s:`)", tparam, si->name, trait, tr->methods[i]->name, trait, si->name)

    private def instantiate(self: *Sema, m: *Module, d: *Decl, check_bodies: bool):
        g: *Type = d->type

        # implement Name (no arguments): materializes the method bodies that were
        # left as prototypes in the .h (non-generic struct declared in a .ph)
        if g->ntargs == 0:
            si0: *SInfo = self->find_struct(g->name)
            if si0 == None:
                sgi: Sugg
                sgi.init(g->name)
                for ki in range(self->structs.elen):
                    if not self->structs.dead[ki]:
                        sgi.feed(self->structs.keys[ki])
                fatal_at(self->file, d->pos, "struct '%s' not found%s", g->name, self->sugg_text(&sgi))
            if self->implemented.has(g->name):
                fatal_at(self->file, d->pos, "'%s' already implemented (duplicate implement)", g->name)
            self->implemented.add(g->name)
            nb = 0
            for j0 in range(si0->nmethods):
                if si0->methods[j0]->body != None and si0->methods[j0]->in_header:
                    nb += 1
            if nb == 0:
                fatal_at(self->file, d->pos, "struct '%s' has no method bodies in a .ph to implement", g->name)
            bodies0: **Func = self->a->alloc(usize(nb) * sizeof(*bodies0))
            k0 = 0
            for j0 in range(si0->nmethods):
                if si0->methods[j0]->body != None and si0->methods[j0]->in_header:
                    bodies0[k0] = si0->methods[j0]
                    k0 += 1
            with d:
                .kind = DL_STRUCT
                .name = si0->name
                .fields = None
                .nfields = 0
                .methods = bodies0
                .nmethods = nb
            self->register_decl(m, d, check_bodies)
            return

        # generic FREE function: `declare foo<int>` (prototype) / `implement foo<int>`
        # (body) -> a distinctly-named monomorphization foo_int (C has no overloading).
        ftpl: *Func = self->func_templates.get_or(g->name, None)
        if ftpl != None:
            if g->ntargs != ftpl->ntparams:
                fatal_at(self->file, d->pos, "'%s' expects %d type argument(s), got %d", g->name, ftpl->ntparams, g->ntargs)
            for fi in range(g->ntargs):
                self->resolve_type(g->targs[fi])
                # the bound (67.1) is checked HERE too, before the body is
                # cloned: otherwise the failure surfaces as "no method named
                # size" from inside the clone, which names the symptom instead
                # of the contract
                if ftpl->tbounds != None and ftpl->tbounds[fi] != None:
                    self->check_bound(g->targs[fi], ftpl->tbounds[fi], ftpl->tparams[fi], d->pos)
            fmangled: *char = self->mangle_instance(g)
            fsub: Subst = {ftpl->tparams, g->targs, g->ntargs}
            want_body: bool = d->kind == DL_IMPLEMENT
            if d->kind == DL_DECLARE and self->funcs.has(fmangled):
                fatal_at(self->file, d->pos, "'%s' already declared (duplicate declare)", fmangled)
            if d->inline_inst and self->funcs.has(fmangled):
                fatal_at(self->file, d->pos, "'%s' already instantiated in this TU", fmangled)
            if want_body:
                if self->implemented.has(fmangled):
                    fatal_at(self->file, d->pos, "'%s' already implemented (duplicate implement)", fmangled)
                self->implemented.add(fmangled)
            inst: *Func = self->clone_func(&fsub, ftpl, None, want_body)
            inst->name = fmangled
            inst->cname = fmangled
            if d->inline_inst:
                inst->is_static = True   # TU-local: many TUs may inline the same
                inst->is_inline = True   #   instance without link conflicts
            with d:
                .kind = DL_FUNC
                .func = inst
            self->register_decl(m, d, check_bodies)
            return

        tpl: *Decl = self->find_template(g->name)
        if tpl == None:
            fatal_at(self->file, d->pos, "generic struct '%s' not found", g->name)
        if g->ntargs != tpl->ntparams:
            fatal_at(self->file, d->pos, "'%s' expects %d type argument(s), got %d", g->name, tpl->ntparams, g->ntargs)
        for i in range(g->ntargs):
            self->resolve_type(g->targs[i])
        mangled: *char = self->mangle_instance(g)
        sub: Subst = {tpl->tparams, g->targs, g->ntargs}

        if d->inline_inst:
            # `inline Vec<int>`: definition AND bodies here, with INTERNAL linkage
            # (static inline) — safe to repeat in other TUs, link-conflict-free
            if self->find_struct(mangled) != None:
                fatal_at(self->file, d->pos, "'%s' already instantiated in this TU", mangled)
            self->implemented.add(mangled)
            iflds: *Field = self->a->alloc(usize(tpl->nfields) * sizeof(*iflds))
            for ii in range(tpl->nfields):
                iflds[ii] = tpl->fields[ii]
                iflds[ii].type = self->clone_type(&sub, tpl->fields[ii].type)
            ibodies: **Func = self->a->alloc(usize(tpl->nmethods) * sizeof(*ibodies))
            for ii in range(tpl->nmethods):
                ibodies[ii] = self->clone_func(&sub, tpl->methods[ii], mangled, True)
                ibodies[ii]->is_static = True
                ibodies[ii]->is_inline = True
            with d:
                .kind = DL_STRUCT
                .name = mangled
                .fields = iflds
                .nfields = tpl->nfields
                .methods = ibodies
                .nmethods = tpl->nmethods
            self->register_decl(m, d, check_bodies)
            return

        if d->kind == DL_DECLARE:
            if self->find_struct(mangled) != None:
                fatal_at(self->file, d->pos, "'%s' already declared (duplicate declare)", mangled)
            fields: *Field = self->a->alloc(usize(tpl->nfields) * sizeof(*fields))
            for i in range(tpl->nfields):
                fields[i] = tpl->fields[i]   # copies everything (bit_width etc.)
                fields[i].type = self->clone_type(&sub, tpl->fields[i].type)
            protos: **Func = self->a->alloc(usize(tpl->nmethods) * sizeof(*protos))
            for i in range(tpl->nmethods):
                protos[i] = self->clone_func(&sub, tpl->methods[i], mangled, False)
            with d:
                .kind = DL_STRUCT
                .name = mangled
                .fields = fields
                .nfields = tpl->nfields
                .methods = protos
                .nmethods = tpl->nmethods
            self->register_decl(m, d, check_bodies)
            return

        # implement
        if self->find_struct(mangled) == None:
            fatal_at(self->file, d->pos, "run 'declare %s<...>' before implement", g->name)
        if self->implemented.has(mangled):
            fatal_at(self->file, d->pos, "'%s' already implemented (duplicate implement)", mangled)
        self->implemented.add(mangled)
        bodies: **Func = self->a->alloc(usize(tpl->nmethods) * sizeof(*bodies))
        for i in range(tpl->nmethods):
            bodies[i] = self->clone_func(&sub, tpl->methods[i], mangled, True)
        with d:
            .kind = DL_STRUCT
            .name = mangled
            .fields = None
            .nfields = 0
            .methods = bodies
            .nmethods = tpl->nmethods
        self->register_decl(m, d, check_bodies)

    # ---------- qualified names: `import "x.ph" as ns` (42.4) ----------
    # The alias is a SPELLING, not a scope: P links flat, so `ns.f` resolves to
    # the very same symbol `f` names. What the alias buys is a CHECK — the
    # member has to be declared in that module — plus a reader who can see at
    # the call site where a name comes from. The flat spelling keeps working,
    # which is why adding an alias never breaks an existing file.
    private def ns_module(self: *Sema, name: const *char) -> *Module:
        if self->cur_mod == None or name == None:
            return None
        for i in range(self->cur_mod->nns):
            if strcmp(self->cur_mod->ns_names[i], name) == 0:
                return self->cur_mod->ns_mods[i]
        return None

    # a real declaration always wins over an alias: `ns` used as a variable,
    # function, type or constant is that thing, exactly as before the import
    private def ns_shadowed(self: *Sema, name: const *char) -> bool:
        return self->sym_index(name) >= 0 or self->globals.has(name) or self->funcs.has(name) or self->types.has(name) or self->enumconsts.has(name)

    # is `member` declared by module `m` itself? Imports of `m` do NOT re-export
    # (Python's rule): `import "parser.ph" as ps` gives ps.parse_tokens, and the
    # types parser.ph itself imported stay behind their own module.
    private def ns_has(self: *Sema, m: *Module, member: const *char) -> bool:
        for i in range(m->ndecls):
            d: *Decl = m->decls[i]
            match d->kind:
                case DL_FUNC:
                    if d->func != None and d->func->name != None and strcmp(d->func->name, member) == 0:
                        return True
                case DL_VAR, DL_STRUCT, DL_UNION, DL_ENUM:
                    if d->name != None and strcmp(d->name, member) == 0:
                        return True
                    for j in range(d->nitems):
                        if d->items[j].name != None and strcmp(d->items[j].name, member) == 0:
                            return True
                case DL_TRAIT:
                    if d->name != None and strcmp(d->name, member) == 0:
                        return True
                case DL_IMPORT, DL_DECLARE, DL_IMPLEMENT:
                    pass
        return False

    # rewrites `ns.name` to the plain identifier IN PLACE, True when it did.
    # Both places a qualified name can appear go through here: as a value, and
    # as a CALLEE — where it has to happen before the dot is read as a method
    # receiver, and before the callee dispatch that turns `T(x)` into a cast.
    private def try_ns_ref(self: *Sema, e: *Expr) -> bool:
        if e == None or e->kind != EX_FIELD or e->op != TK_DOT:
            return False
        if e->lhs == None or e->lhs->kind != EX_IDENT or e->lhs->text == None or e->field == None:
            return False
        if self->ns_shadowed(e->lhs->text) or self->ns_module(e->lhs->text) == None:
            return False
        qual: const *char = self->a->printf("%s.%s", e->lhs->text, e->field)
        with e:
            .kind = EX_IDENT
            .text = self->ns_plain(qual, e->pos)
            .lhs = None
            .field = None
        return True

    # splits "ns.member" and validates it; returns the plain member name
    private def ns_plain(self: *Sema, dotted: const *char, pos: Pos) -> const *char:
        dot: const *char = strchr(dotted, '.')
        ns: const *char = self->a->strndup(dotted, usize(dot - dotted))
        member: const *char = dot + 1
        m: *Module = self->ns_module(ns)
        # a Type carries no position (the AST never needed one): a zero position
        # means "report against the file, not a line" rather than `file:0:0`
        if m == None:
            if pos.line == 0:
                fatal("%s: '%s' is not an import alias of this file (write `import \"...\" as %s` to make one)", self->file, ns, ns)
            fatal_at(self->file, pos, "'%s' is not an import alias of this file (write `import \"...\" as %s` to make one)", ns, ns)
        if not self->ns_has(m, member):
            if pos.line == 0:
                fatal("%s: module '%s' declares no '%s'", self->file, ns, member)
            fatal_at(self->file, pos, "module '%s' declares no '%s'", ns, member)
        return member

    # `record X:` (65.1) — X must be PURE BYTES: primitives, enums, other
    # records and fixed arrays of those, and nothing else.
    #
    # The rule is one sentence, but every clause of it pays for something: with
    # no pointer inside, a value of X can be memcpy'd, written to a file, sent to
    # another process and compared field by field, and none of those silently
    # break the day someone adds a `name: const *char`. That is the whole feature
    # — it costs nothing at run time and it is a guarantee C cannot state.
    private def check_pure_bytes(self: *Sema, si: *SInfo, d: *Decl):
        for i in range(si->nfields):
            f: *Field = &si->fields[i]
            t: *Type = f->type
            while t != None and t->kind == TY_ARRAY:
                t = t->inner     # `T[N]` of pure bytes is pure bytes
            if t == None:
                continue
            if t->kind == TY_PTR:
                fatal_at(self->file, f->pos, "record '%s': field '%s' is a pointer — a record is pure bytes, so it can be copied, written out and compared as itself. Use `struct` if it has to hold one.", si->name, f->name)
            if t->kind == TY_FUNC:
                fatal_at(self->file, f->pos, "record '%s': field '%s' is a function — a record is pure bytes. Use `struct`.", si->name, f->name)
            if t->kind != TY_NAME:
                continue
            fsi: *SInfo = self->find_struct(t->name)
            if fsi == None:
                continue    # a primitive, an enum, or a C type: nothing to descend
            if fsi->is_union:
                fatal_at(self->file, f->pos, "record '%s': field '%s' is a union — its bytes have no single meaning, so it cannot be compared or written out. Use `struct`.", si->name, f->name)
            if not fsi->is_record:
                fatal_at(self->file, f->pos, "record '%s': field '%s' has type '%s', which is a struct — only another `record` is known to be pure bytes.", si->name, f->name, t->name)

    # `a == b` / `a != b` between two values of the same `record` (65.1).
    # Rewritten into a chain of FIELD comparisons, never a memcmp: the padding a
    # C compiler inserts between fields holds whatever was on the stack, so
    # memcmp would compare garbage and report a difference that is not there.
    # Returns False when this is not a record comparison, and the normal
    # "structs are not scalars" error follows.
    private def record_eq(self: *Sema, e: *Expr) -> bool:
        lsi: *SInfo = self->val_struct(self->type_of(e->lhs))
        rsi: *SInfo = self->val_struct(self->type_of(e->rhs))
        if lsi == None or rsi == None or not lsi->is_record or lsi != rsi:
            return False
        ne: bool = e->op == TK_NE
        # The chain reads each side once PER FIELD, so a side that is not a plain
        # designator — a call, a constructor — would run that many times. Each
        # one is bound to a hidden variable first, evaluated exactly once.
        pre: *Expr = None
        la: *Expr = self->eq_operand(e->lhs, ref pre)
        rb: *Expr = self->eq_operand(e->rhs, ref pre)
        chain: *Expr = self->record_eq_chain(lsi, la, rb, e->pos)
        if pre != None:
            chain = self->comma_join(pre, chain, e->pos)
            chain->parened = True
        if ne:
            n: *Expr = ex_new(self->a, EX_UNARY, e->pos)
            n->op = TK_NOT
            n->lhs = chain
            n->parened = True
            chain = n
        *e = *chain
        return True

    # a side of a record comparison: a plain designator is used as is, anything
    # else is evaluated once into a hidden variable
    private def eq_operand(self: *Sema, e: *Expr, ref pre: *Expr) -> *Expr:
        if is_designator(e):
            return e
        t: *Type = self->type_of(e)
        name: const *char = self->a->printf("__re%d", self->rc_ctr)
        self->rc_ctr += 1
        hd: *Stmt = st_new(self->a, ST_VAR, e->pos)
        hd->name = name
        hd->type = t
        self->vla_hoist_add(hd)
        hp: *Type = self->a->alloc(sizeof(Type))
        *hp = *t
        self->fn_hoisted.put(name, hp)
        asg: *Expr = ex_new(self->a, EX_ASSIGN, e->pos)
        asg->op = TK_ASSIGN
        asg->lhs = mk_ident(self->a, name, e->pos)
        asg->rhs = e
        asg->parened = True
        pre = self->comma_join(pre, asg, e->pos)
        return mk_ident(self->a, name, e->pos)

    # `a.f0 == b.f0 and a.f1 == b.f1 and ...`, descending into nested records and
    # unrolling fixed arrays (their length is a compile-time constant, and a
    # record is small by construction — it is the thing that crosses boundaries)
    private def record_eq_chain(self: *Sema, si: *SInfo, a: *Expr, b: *Expr, pos: Pos) -> *Expr:
        acc: *Expr = None
        for i in range(si->nfields):
            f: *Field = &si->fields[i]
            fa: *Expr = self->mk_field(a, f->name, pos)
            fb: *Expr = self->mk_field(b, f->name, pos)
            acc = self->eq_join(acc, self->record_eq_value(f->type, fa, fb, pos), pos)
        if acc == None:
            # a record with no fields: every value of it is every other value
            acc = ex_new(self->a, EX_TRUE, pos)
        return acc

    private def record_eq_value(self: *Sema, t: *Type, a: *Expr, b: *Expr, pos: Pos) -> *Expr:
        if t != None and t->kind == TY_ARRAY:
            n: i64 = 0
            if t->arr_len == None or not self->const_len(t->arr_len, ref n) or n < 0:
                fatal_at(self->file, pos, "comparing a record with an array field of unknown length")
            acc: *Expr = None
            for k in range(i32(n)):
                idx: *Expr = ex_new(self->a, EX_NUMBER, pos)
                idx->text = self->a->printf("%d", k)
                ia: *Expr = ex_new(self->a, EX_INDEX, pos)
                ia->lhs = a
                ia->rhs = idx
                ib: *Expr = ex_new(self->a, EX_INDEX, pos)
                ib->lhs = b
                ib->rhs = idx
                acc = self->eq_join(acc, self->record_eq_value(t->inner, ia, ib, pos), pos)
            if acc == None:
                acc = ex_new(self->a, EX_TRUE, pos)
            return acc
        nsi: *SInfo = self->val_struct(t)
        if nsi != None:
            return self->record_eq_chain(nsi, a, b, pos)
        cmp: *Expr = ex_new(self->a, EX_BINARY, pos)
        cmp->op = TK_EQ
        cmp->lhs = a
        cmp->rhs = b
        cmp->parened = True
        return cmp

    private def eq_join(self: *Sema, acc: *Expr, one: *Expr, pos: Pos) -> *Expr:
        if acc == None:
            return one
        j: *Expr = ex_new(self->a, EX_BINARY, pos)
        j->op = TK_AND
        j->lhs = acc
        j->rhs = one
        return j

    private def mk_field(self: *Sema, base: *Expr, name: const *char, pos: Pos) -> *Expr:
        f: *Expr = ex_new(self->a, EX_FIELD, pos)
        f->op = TK_DOT
        f->lhs = base
        f->field = name
        return f

    private def const_len(self: *Sema, e: *Expr, ref out_n: i64) -> bool:
        ok: bool = True
        v: i64 = self->ceval(e, ref ok)
        if not ok:
            return False
        out_n = v
        return True

    # `(T){a, b}` -> `(__rcN.f0 = a, __rcN.f1 = b, __rcN)` with `__rcN: T`
    # hoisted to the function entry. Valid C89: a comma expression of plain
    # assignments, evaluated where it is written, so a constructor inside a loop
    # still builds a fresh value each turn.
    private def complit_to_temp(self: *Sema, e: *Expr, si: *SInfo):
        name: const *char = self->a->printf("__rc%d", self->rc_ctr)
        self->rc_ctr += 1
        hd: *Stmt = st_new(self->a, ST_VAR, e->pos)
        hd->name = name
        hd->type = e->cast_type
        self->vla_hoist_add(hd)          # prepended at function entry
        hp: *Type = self->a->alloc(sizeof(Type))
        *hp = *e->cast_type
        self->fn_hoisted.put(name, hp)
        base: *Expr = mk_ident(self->a, name, e->pos)
        chain: *Expr = None
        for i in range(e->nargs):
            if i >= si->nfields:
                break
            chain = self->comma_join(chain, self->fill_field(self->mk_field(base, si->fields[i].name, e->pos), si->fields[i].type, e->args[i], e->pos), e->pos)
        if chain == None:
            *e = *base
            return
        *e = *self->comma_join(chain, base, e->pos)

    # one assignment, descending into nested aggregates because C89 cannot
    # assign a brace list to anything but a declaration
    private def fill_field(self: *Sema, dst: *Expr, t: *Type, src: *Expr, pos: Pos) -> *Expr:
        agg: bool = src != None and (src->kind == EX_COMPOUND or src->kind == EX_INITLIST)
        if agg and t != None and t->kind == TY_ARRAY:
            n: i64 = 0
            if t->arr_len == None or not self->const_len(t->arr_len, ref n):
                fatal_at(self->file, pos, "cannot build this array field under --std=c89")
            acc: *Expr = None
            for k in range(i32(n)):
                if k >= src->nargs:
                    break
                idx: *Expr = ex_new(self->a, EX_NUMBER, pos)
                idx->text = self->a->printf("%d", k)
                el: *Expr = ex_new(self->a, EX_INDEX, pos)
                el->lhs = dst
                el->rhs = idx
                acc = self->comma_join(acc, self->fill_field(el, t->inner, src->args[k], pos), pos)
            if acc == None:
                acc = ex_new(self->a, EX_NUMBER, pos)
                acc->text = "0"
            return acc
        if agg:
            nsi: *SInfo = self->val_struct(t)
            if nsi != None:
                acc2: *Expr = None
                for k in range(nsi->nfields):
                    if k >= src->nargs:
                        break
                    acc2 = self->comma_join(acc2, self->fill_field(self->mk_field(dst, nsi->fields[k].name, pos), nsi->fields[k].type, src->args[k], pos), pos)
                if acc2 == None:
                    acc2 = ex_new(self->a, EX_NUMBER, pos)
                    acc2->text = "0"
                return acc2
        if t != None and t->kind == TY_ARRAY:
            fatal_at(self->file, pos, "cannot assign to an array field under --std=c89 (write the value into a variable first)")
        asg: *Expr = ex_new(self->a, EX_ASSIGN, pos)
        asg->op = TK_ASSIGN
        asg->lhs = dst
        asg->rhs = src
        asg->parened = True
        return asg

    private def comma_join(self: *Sema, acc: *Expr, one: *Expr, pos: Pos) -> *Expr:
        if acc == None:
            return one
        c: *Expr = ex_new(self->a, EX_COMMA, pos)
        c->lhs = acc
        c->rhs = one
        return c

    # a compound literal that IS the whole initializer of a matching declaration
    # is just a brace list wearing a cast
    private def flatten_complit(self: *Sema, t: *Type, init: *Expr):
        if init == None or init->kind != EX_COMPOUND or t == None or init->cast_type == None:
            return
        if t->kind != TY_NAME or init->cast_type->kind != TY_NAME or t->name == None or init->cast_type->name == None:
            return
        if strcmp(t->name, init->cast_type->name) != 0:
            return
        init->kind = EX_INITLIST
        init->cast_type = None

    # `Vec(1.0, 2.0)` / `Vec(y=2.0, x=1.0)` — the record constructor (65.1).
    # Becomes a C compound literal, which is also the first way P has to write an
    # aggregate VALUE inline: before this, a struct value needed a variable to
    # live in. Named arguments become designated initializers, and P already
    # lowers those to positional under --std=c89.
    private def record_ctor(self: *Sema, e: *Expr, si: *SInfo):
        named: bool = False
        positional: bool = False
        for i in range(e->nargs):
            if e->args[i] != None and e->args[i]->kind == EX_DESIG and e->args[i]->field != None:
                named = True
            else:
                positional = True
        if named and positional:
            fatal_at(self->file, e->pos, "%s(...): mixing named and positional fields", si->name)
        if positional and e->nargs > si->nfields:
            fatal_at(self->file, e->pos, "%s(...) takes %d field(s), %d given", si->name, si->nfields, e->nargs)
        if named:
            # Named form must name EVERY field. Partial named construction would
            # need a designated initializer to survive, and those do not exist in
            # C89 — reordering into positional here keeps the emitted C plain in
            # every mode, and "you left one out" is a better error than a silent
            # zero. The positional form keeps C's trailing zero-fill.
            byname: **Expr = self->a->alloc(usize(si->nfields) * sizeof(*byname))
            for i in range(e->nargs):
                a: *Expr = e->args[i]
                slot: i32 = -1
                for fi in range(si->nfields):
                    if strcmp(si->fields[fi].name, a->field) == 0:
                        slot = fi
                        break
                if slot < 0:
                    sgc: Sugg
                    sgc.init(a->field)
                    for fi in range(si->nfields):
                        sgc.feed(si->fields[fi].name)
                    fatal_at(self->file, a->pos, "'%s' has no field '%s'%s", si->name, a->field, self->sugg_text(&sgc))
                if byname[slot] != None:
                    fatal_at(self->file, a->pos, "'%s' is given twice", a->field)
                self->check_expr(a->lhs)
                byname[slot] = a->lhs
            for fi in range(si->nfields):
                if byname[fi] == None:
                    fatal_at(self->file, e->pos, "%s(...): field '%s' is missing (the named form names every field)", si->name, si->fields[fi].name)
            e->args = byname
            e->nargs = si->nfields
        else:
            for i in range(e->nargs):
                self->check_expr(e->args[i])
        ct: *Type = ty_name(self->a, si->name)
        self->resolve_type(ct)
        with e:
            .kind = EX_COMPOUND
            .cast_type = ct
            .lhs = None
        # C89 has no compound literal. Where the constructor is the whole
        # initializer of a declaration it collapses to a brace list (see
        # flatten_complit); anywhere else it is lowered to a hidden variable
        # filled field by field. C89 is the mode that exists for the targets
        # that gave P its reason to be, so the feature works there too rather
        # than being refused there.
        if self->cc != None and self->cc->std_version == 89 and not self->in_complit_init:
            self->complit_to_temp(e, si)

    private def register_decl(self: *Sema, m: *Module, d: *Decl, check_bodies: bool):
        match d->kind:
            case DL_IMPORT:
                if d->is_include:
                    self->ingest_c_header(m, d)
                elif ends_with(d->import_path, ".ph"):
                    full: const *char = ""
                    if d->import_system:
                        # `import <pkg/mod.ph>`: vem de um PACOTE, e procura-se
                        # nas raízes de `--pkg-path` — nunca ao lado de quem
                        # importa. Ver a nota do `pkgroots` em `sema.ph`.
                        full = pkg_resolve(self->cc, self->file, d)
                        # e a partir daqui ele vira um import RELATIVO comum. É
                        # a única forma de o header emitido resolver: o `<>` é
                        # relativo a uma raiz que só o compilador conhece, e o C
                        # gerado tem de incluir o header GERADO, que mora no
                        # espelho do `--out-dir` no mesmo lugar relativo em que
                        # o fonte mora no disco. Reescrever aqui faz todo o
                        # resto do compilador — back end, deps, espelho — não
                        # precisar aprender nada sobre pacotes.
                        if not same_space(m->path, full):
                            fatal_at(self->file, d->pos, "import <%s>: the package root and the sources have to be named the same way — both relative to the current directory, or both absolute. Here the source is '%s' and the package resolved to '%s', and there is no relative path between them that also holds inside the --out-dir mirror", d->import_path, m->path, full)
                        d->import_path = path_relative(self->a, path_dir(self->a, m->path), full)
                        d->import_system = False
                    else:
                        dir: const *char = path_dir(self->a, m->path)
                        # path_join, not printf: an ABSOLUTE import path must be
                        # taken as it stands, not glued behind the includer's
                        # directory (which produced `a/b//abs/path`)
                        full = path_join(self->a, dir, d->import_path)
                    sub: *Module = cc_load_module(self->cc, full)
                    self->register_module(sub, False)
                    if d->import_alias != None:
                        for na in range(m->nns):
                            if strcmp(m->ns_names[na], d->import_alias) == 0:
                                fatal_at(self->file, d->pos, "import alias '%s' is already taken in this file", d->import_alias)
                        m->ns_names[m->nns] = (*char)(d->import_alias)
                        m->ns_mods[m->nns] = sub
                        m->nns += 1
                elif d->import_alias != None:
                    fatal_at(self->file, d->pos, "import '%s' as '%s': only a P header (.ph) has a namespace to qualify", d->import_path, d->import_alias)
                return
            case DL_TRAIT:
                # A trait is a NAME plus signatures; it is emitted nowhere and
                # takes no space. What it buys is the check at instantiation.
                if self->traits.has(d->name):
                    fatal_at(self->file, d->pos, "trait '%s' is declared twice", d->name)
                self->traits.put(d->name, d)
                return
            case DL_DECLARE, DL_IMPLEMENT:
                if d->trait_for != None:
                    self->trait_impl(m, d, check_bodies)
                    return
                self->instantiate(m, d, check_bodies)
                return
            case DL_VAR:
                if d->type == None and d->init != None:
                    d->type = self->infer_type(d->init)   # `g = value` / `const G = value`
                    if d->type == None:
                        fatal_at(self->file, d->pos, "cannot infer type of '%s'; add an explicit type", d->name)
                self->resolve_type(d->type)
                self->infer_array_len(d->type, d->init)
                self->require_complete(d->type, d->pos)
                if not d->is_extern or d->init != None:
                    self->require_defined(d->type, d->pos)
                if is_void_val(d->type) and (not d->is_extern or d->init != None):
                    fatal_at(self->file, d->pos, "cannot declare '%s' with type void", d->name)
                # one tag namespace for file-scope DEFINITIONS: a second initialized
                # definition of the same object is invalid (tentative decls are fine)
                if d->init != None and not self->in_chdr:
                    if self->gdefs.has(d->name):
                        # 110: uma const de `-D` entra em toda unidade E no
                        # header que a usa, então quem importa o header vê a
                        # mesma definição duas vezes. É a única repetição
                        # permitida, e é permitida porque é a MESMA.
                        if not d->is_define:
                            fatal_at(self->file, d->pos, "redefinition of '%s' (already defined with an initializer)", d->name)
                    else:
                        self->gdefs.add(d->name)
                if not self->in_chdr and self->funcs.has(d->name) and self->globals.get_or(d->name, None) == None:
                    fatal_at(self->file, d->pos, "'%s' redeclared as a different kind of symbol", d->name)
                if d->type != None and d->type->is_ref:
                    fatal_at(self->file, d->pos, "'%s' cannot be a module-level ref: a ref binds at a moment; module state holds a pointer (69.1)", d->name)
                if self->c_mod and not self->in_chdr:
                    prevt2: *Type = self->globals.get_or(d->name, None)
                    if prevt2 != None and not self->type_compat(prevt2, d->type):
                        fatal_at(self->file, d->pos, "conflicting types for '%s'", d->name)
                    # linkage bookkeeping: 'static' then a non-static/extern-less
                    # redeclaration (or vice versa) is a linkage conflict (C11 6.2.2)
                    prev2: bool = self->globals.get_or(d->name, None) != None
                    if d->is_static:
                        if (prev2 and not self->gstatics.has(d->name)) or self->gexterns.has(d->name):
                            fatal_at(self->file, d->pos, "static declaration of '%s' follows non-static declaration", d->name)
                        self->gstatics.add(d->name)
                    elif prev2 and self->gstatics.has(d->name) and not d->is_extern:
                        fatal_at(self->file, d->pos, "non-static declaration of '%s' follows static declaration", d->name)
                    if d->init != None and not self->static_const_ok(d->init):
                        fatal_at(self->file, d->pos, "initializer of file-scope '%s' is not a constant expression", d->name)
                self->globals.put(d->name, d->type)
                if check_bodies:
                    prevfi: bool = self->in_complit_init
                    self->in_complit_init = names_own_type(d->type, d->init)
                    self->check_expr(d->init)
                    self->in_complit_init = prevfi
                    # a record constructor that IS the whole initializer of a
                    # file-scope variable collapses to a brace list: a compound
                    # literal is not valid at file scope in C89, and this is
                    # better C in every mode
                    self->flatten_complit(d->type, d->init)
                    self->check_init(d->type, d->init, d->pos)
                # known constant: registers the value (int/float/str) for folding
                # and pruning. `X: const i32 = 4` (P) marks const on the TYPE;
                # `const X = 4` (C) marks it on the Decl — both forms count, else
                # the value would not fold and `i32[X]` would become a VLA.
                if d->init != None and (d->is_const or (d->type != None and d->type->is_const)):
                    cok: bool = True
                    cvv: CVal = self->ceval_val(d->init, None, ref cok)
                    if cok and cvv.kind != CV_BAD:
                        cp: *CVal = self->a->alloc(sizeof(CVal))
                        *cp = cvv
                        self->constvals.put(d->name, cp)
                self->fold_const_dims(d->type)
                if self->cc->std_version == 89:
                    self->lower_designators(d->init, d->type)
                return
            case DL_STRUCT, DL_UNION:
                if d->ntparams > 0:
                    # generic template: stored for declare/implement; not emitted
                    # nor registered (the bodies are only checked once monomorphized)
                    if self->templates.has(d->name):
                        fatal_at(self->file, d->pos, "generic struct '%s' redefined", d->name)
                    self->templates.put(d->name, d)
                    return
                si: *SInfo = self->find_struct(d->name)
                if si == None:
                    si = self->a->alloc(sizeof(SInfo))
                    si->name = d->name
                    si->is_union = d->kind == DL_UNION
                    si->c_tag = self->in_chdr and not d->is_td   # C tag: needs `struct X` in C (not for a renamed typedef)
                    self->structs.put(d->name, si)
                    self->add_type(d->name)
                elif si->is_union != (d->kind == DL_UNION) and not self->in_chdr:
                    # C keeps one tag namespace: `struct S` and `union S` collide
                    fatal_at(self->file, d->pos, "'%s' declared as both struct and union (wrong kind of tag)", d->name)
                for i in range(d->nfields):
                    self->resolve_type(d->fields[i].type)
                    self->require_complete(d->fields[i].type, d->fields[i].pos)
                    self->require_defined(d->fields[i].type, d->fields[i].pos)
                    if not self->in_chdr:
                        wfa: *Type = d->fields[i].type
                        while wfa != None and (wfa->kind == TY_PTR or wfa->kind == TY_ARRAY):
                            if wfa->kind == TY_ARRAY:
                                elfa: *Type = wfa->inner
                                while elfa != None and elfa->kind == TY_ARRAY:
                                    elfa = elfa->inner
                                sfa: *SInfo = self->val_struct(elfa)
                                if sfa != None and not sfa->defined:
                                    fatal_at(self->file, d->fields[i].pos, "member '%s' is an array of the incomplete type '%s'", d->fields[i].name, sfa->name)
                            wfa = wfa->inner
                    self->fold_const_dims(d->fields[i].type)  # i32[MAX] -> i32[64] (enum/const)
                    # dedupe by name — but EVERY anonymous member (name "") must
                    # enter the list, or lookup can't descend into the 2nd one
                    fan: const *char = d->fields[i].name
                    if fan == None or fan[0] == '\0' or sinfo_field(si, fan) == None:
                        si->fields = vec_grow(si->fields, si->nfields, ref si->cfields, sizeof(*si->fields))
                        si->fields[si->nfields] = d->fields[i]
                        si->nfields += 1
                if not d->is_fwd:
                    si->defined = True   # a real definition: values of it may exist
                if d->is_record:
                    si->is_record = True
                    self->check_pure_bytes(si, d)
                for i in range(d->nmethods):
                    if m->is_header:
                        d->methods[i]->in_header = True
                    self->register_func(d->methods[i])
                for i in range(d->nmethods):
                    # inline/static methods from an imported header are emitted
                    # per-TU (QBE emits them inline), so they need to have the body
                    # checked — otherwise casts/method sugar are left un-rewritten.
                    mth: *Func = d->methods[i]
                    if (check_bodies or mth->is_inline or mth->is_static) and not mth->is_comptime:
                        self->check_func_body(mth)
                return
            case DL_ENUM:
                self->add_type(d->name)
                if d->name != None:
                    self->enums.put(d->name, d)
                j: i32
                enext: i64 = 0   # auto-incremented value
                for j in range(d->nitems):
                    self->enumconsts.add(d->items[j].name)
                    if check_bodies and d->items[j].value != None:
                        self->check_expr(d->items[j].value)
                    # constant value -> constvals (for ceval/fold: array dim,
                    # case, if). An explicit value repositions the counter; otherwise auto+1.
                    if d->items[j].value != None:
                        eok: bool = True
                        ev: i64 = self->ceval(d->items[j].value, ref eok)
                        if eok:
                            enext = ev
                    if not self->constvals.has(d->items[j].name):
                        ecp: *CVal = self->a->alloc(sizeof(CVal))
                        *ecp = cv_int(enext)
                        self->constvals.put(d->items[j].name, ecp)
                    enext += 1
                return
            case DL_FUNC:
                self->register_func(d->func)
                # a `const def` isn't type-checked normally: the body is INTERPRETED
                # (via ccall), never emitted. Checking it would try to fold the recursive
                # calls with non-constant params. Errors surface at the use site (like constexpr).
                # Free inline/static functions from an imported header are emitted
                # per-TU (QBE inline), so they also need the body checked.
                if (check_bodies or d->func->is_inline or d->func->is_static) and not d->func->is_comptime:
                    self->check_func_body(d->func)
                return
            case _:
                return

    private def register_module(self: *Sema, m: *Module, check_bodies: bool):
        if self->done.has(m->path):
            return
        self->done.add(m->path)
        # typedef names from an ingested C header (va_list, wchar_t, off_t...)
        for ti in range(m->ntd):
            self->add_type(m->tdnames[ti])

        prev: const *char = self->file
        prevm: *Module = self->cur_mod
        self->file = m->path
        self->cur_mod = m
        # namespace aliases are per FILE (42.4): sized exactly, filled by the
        # DL_IMPORT arm below as each import is registered
        if m->ns_names == None:
            nsn: i32 = 0
            for j in range(m->ndecls):
                if m->decls[j]->kind == DL_IMPORT and m->decls[j]->import_alias != None:
                    nsn += 1
            if nsn > 0:
                m->ns_names = self->a->alloc(usize(nsn) * sizeof(*m->ns_names))
                m->ns_mods = self->a->alloc(usize(nsn) * sizeof(*m->ns_mods))
        # index the module's own functions BEFORE walking it, so a call to one
        # that is only defined further down can be diagnosed as an ordering
        # problem. Only for the module being checked: in an imported one the
        # names are all registered up front anyway, and in a C module
        # use-before-declaration is C's own rule, reported as C reports it.
        if check_bodies and not m->is_c:
            for j in range(m->ndecls):
                fd: *Decl = m->decls[j]
                if fd->kind == DL_FUNC and fd->func != None and fd->func->name != None:
                    # the FIRST spelling of the name: with a prototype below the
                    # call it is the prototype, not the body, that has to move
                    if not self->later_defs.has(fd->func->name):
                        self->later_defs.put(fd->func->name, i64(fd->func->pos.line))
        for j in range(m->ndecls):
            self->register_decl(m, m->decls[j], check_bodies)
        # a typedef of a TAG (`typedef struct re_pattern_buffer regex_t`):
        # register the typedef name as an ALIAS of the same layout — AFTER the
        # decls, once the tags exist. Without this the QBE backend does not know
        # the size of `re: regex_t` (the C backend gets away with it because the
        # system header defines the name, but QBE needs the layout to reserve
        # stack space).
        for ti in range(m->ntd):
            if m->tdtypes == None or m->tdtypes[ti] == None:
                continue
            ut: *Type = m->tdtypes[ti]
            if ut->kind == TY_NAME and ut->name != None and ut->tag_kind != TAG_NONE:
                usi: *SInfo = self->find_struct(ut->name)
                if usi != None and self->find_struct(m->tdnames[ti]) == None:
                    self->structs.put(m->tdnames[ti], usi)
                    self->tdalias.put(m->tdnames[ti], ut)
            elif ut->kind == TY_NAME and ut->name != None:
                # a typedef of a SCALAR (`pthread_t` = `unsigned long`): the C
                # back end never needs it, but a back end that lays out structs
                # itself does — without it the field is four bytes and every
                # offset after it is wrong
                if not self->tdscalar.has(m->tdnames[ti]):
                    self->tdscalar.put(m->tdnames[ti], ut)
        self->file = prev
        self->cur_mod = prevm

    private def reg_builtin(self: *Sema, name: const *char, v: CVal):
        cp: *CVal = self->a->alloc(sizeof(CVal))
        *cp = v
        self->constvals.put(name, cp)

    # predefined compiler constants (C-style, but WITHOUT emission: the
    # references fold to a literal in fold_predefined — they never become a symbol,
    # so they don't collide with the cc's own macros in the C backend).
    private def inject_predefined(self: *Sema, cc: *Cc):
        # __DATE__ "Mmm dd yyyy" / __TIME__ "hh:mm:ss", sliced out of ctime
        # ("Www Mmm dd hh:mm:ss yyyy\n" — fixed positions, dd space-padded)
        now: i64 = time(None)
        cs: *char = ctime(&now)
        if cs != None:
            self->reg_builtin("__DATE__", cv_str(self->a->printf("\"%.7s%.4s\"", cs + 4, cs + 20)))
            self->reg_builtin("__TIME__", cv_str(self->a->printf("\"%.8s\"", cs + 11)))
        self->reg_builtin("__PLANG__", cv_int(1))
        self->reg_builtin("__PLANG_VERSION__", cv_str("\"0.6\""))
        self->reg_builtin("__PLANG_STD__", cv_int(i64(cc->std_version) if cc->std_version != 0 else 99))
        if cc->backend_name != None:
            self->reg_builtin("__PLANG_BACKEND__", cv_str(self->a->printf("\"%s\"", cc->backend_name)))
        # 99.3: WHICH platform, for the `const if` that chooses between two ways
        # of talking to the kernel. It is the host this compiler is RUNNING on,
        # because in the normal flow that is also the host that will compile the
        # C it emits — and `-D` overrides it, which is what a cross build needs.
        osn: const *char = plang_host_os()
        self->reg_builtin("__PLANG_OS__", cv_str(self->a->printf("\"%s\"", osn)))
        self->reg_builtin("__PLANG_LINUX__", cv_int(1 if strcmp(osn, "linux") == 0 else 0))
        self->reg_builtin("__PLANG_MACOS__", cv_int(1 if strcmp(osn, "macos") == 0 else 0))

    # injects the consts passed by the driver (-D NAME=VALUE) as if they were
    # `static const NAME = VALUE` at the top of the module: they are inferred, registered
    # at compile time (is_defined/fold/prune) AND emitted (usable symbol). Without '=',
    # the value is 1 (just "defined"). With '=': int / float / string (a bare word becomes
    # a string literal).
    private def inject_defines(self: *Sema, cc: *Cc, m: *Module):
        if cc->ndefines == 0:
            return
        zp: Pos = {0, 0}
        nd: **Decl = self->a->alloc(usize(cc->ndefines + m->ndecls) * sizeof(*nd))
        np = 0
        for i in range(cc->ndefines):
            d: const *char = cc->defines[i]
            eq: const *char = strchr(d, '=')
            ini: *Expr
            name: const *char
            if eq == None:
                name = self->a->strdup(d); ini = ex_new(self->a, EX_NUMBER, zp)
                ini->text = "1"
            else:
                name = self->a->strndup(d, usize(eq - d))
                val: const *char = eq + 1
                c0: char = val[0]
                if c0 == '"':
                    ini = ex_new(self->a, EX_STRING, zp)
                    ini->text = self->a->strdup(val)
                elif (c0 >= '0' and c0 <= '9') or c0 in {'-', '+', '.'}:
                    ini = ex_new(self->a, EX_NUMBER, zp)
                    ini->text = self->a->strdup(val)
                else:
                    ini = ex_new(self->a, EX_STRING, zp)
                    ini->text = self->a->printf("\"%s\"", val)
            dc: *Decl = self->a->alloc(sizeof(Decl))
            with dc:
                .kind = DL_VAR
                .pos = zp
                .name = name
                .is_const = True
                .is_static = True   # internal linkage: no collision between TUs
                .is_define = True   # 110: a marca que deixa a repetição passar
                .init = ini
            nd[np] = dc
            np += 1
        for j in range(m->ndecls):
            nd[np] = m->decls[j]
            np += 1
        m->decls = nd
        m->ndecls = np


# ---------- module loading ----------
private def ends_with(s: const *char, suf: const *char) -> bool:
    n: usize = strlen(s)
    m: usize = strlen(suf)
    return n >= m and strcmp(s + n - m, suf) == 0

# A raiz de pacote em que um `import <...>` foi encontrado, ou o erro que diz
# onde se procurou. É a única função que sabe traduzir a forma com `<>` num
# caminho, e ela vive aqui porque a sema é quem carrega os módulos.
#
# A mensagem lista as raízes porque é a única informação que resolve o problema:
# "não achei" sozinho deixa quem lê adivinhando se o pacote não foi resolvido, se
# o nome está errado, ou se o `--pkg-path` não chegou até aqui.
def pkg_resolve(cc: *Cc, file: const *char, d: *Decl) -> const *char:
    got: const *char = pkg_find(&cc->arena, cc->pkgroots, cc->npkgroots, d->import_path)
    if got != None:
        return got
    fatal_at(file, d->pos, "import <%s>: not found in any package root (%s)",
             d->import_path, pkg_where(&cc->arena, cc->pkgroots, cc->npkgroots))
    return ""

def cc_load_module(cc: *Cc, path0: const *char) -> *Module:
    # o caminho é NORMALIZADO à entrada: `selfhost/../packages/stl/vec.ph` e
    # `packages/stl/vec.ph` são o mesmo arquivo, e carregá-lo duas vezes daria
    # um "redefinido" que não tem nada de errado com o fonte. As duas grafias
    # aparecem desde que um `import <pkg/x.ph>` é reescrito para relativo.
    path: const *char = path_norm(&cc->arena, path0)
    for i in range(cc->nmods):
        if strcmp(cc->mods[i]->path, path) == 0:
            return cc->mods[i]

    len: usize = 0
    bytes: *char = read_entire_file(path, out len)
    defer free(bytes)
    tl: TokenList = lex(path, bytes, len, &cc->arena)
    m: *Module = parse_tokens(&cc->arena, path, tl, ends_with(path, ".ph"))
    expand_embeds(&cc->arena, m)
    cc->mods = vec_grow(cc->mods, cc->nmods, ref cc->cmods, sizeof(*cc->mods))
    cc->mods[cc->nmods] = m
    cc->nmods += 1
    return m






private def sinfo_method(si: *SInfo, name: const *char) -> *Func:
    for i in range(si->nmethods):
        if strcmp(si->methods[i]->name, name) == 0:
            return si->methods[i]
    return None

private def sinfo_field(si: *SInfo, name: const *char) -> *Field:
    for i in range(si->nfields):
        if strcmp(si->fields[i].name, name) == 0:
            return &si->fields[i]
    return None











private def mangle_type_into(sb: *StrBuf, t: *Type):
    if t->kind == TY_PTR:
        sb->puts("p")
        mangle_type_into(sb, t->inner)
        return
    if t->kind == TY_ARRAY:
        fatal("array cannot be a generic type argument")
    c: const *char = t->name
    while *c != '\0':
        sb->putc('_' if *c == ' ' else *c)
        c += 1



private def subst_lookup(sub: *Subst, name: const *char) -> *Type:
    for i in range(sub->n):
        if strcmp(sub->names[i], name) == 0:
            return sub->types[i]
    return None








private def strip_ptr_or_array(t: *Type) -> *Type:
    if t != None and (t->kind == TY_PTR or t->kind == TY_ARRAY):
        return t->inner
    return None




# integer value of a char literal (with quotes, optional wide prefix)
private def ceval_char(lex: const *char) -> i64:
    if lex[0] in {'L', 'u', 'U'}:
        lex += 1
    # single source of truth for escapes (\a \b \f \v \xNN \NNN...): the C
    # front end's evaluator — an incomplete table here PRUNES BRANCHES WRONG
    return i64(cchar_val(lex))

private def cv_int(v: i64) -> CVal:
    r: CVal = {CV_INT, v, 0.0, None}
    return r
private def cv_flt(v: f64) -> CVal:
    r: CVal = {CV_FLOAT, 0, v, None}
    return r
private def cv_str(v: const *char) -> CVal:
    r: CVal = {CV_STR, 0, 0.0, v}
    return r
private def cv_asf(v: CVal) -> f64:
    return v.fval if v.kind == CV_FLOAT else f64(v.ival)

# text of a float literal that the lexer re-reads as float (ensures '.'/'e' —
# otherwise "%.17g" of 7.0 comes out "7" and becomes an int)
private def cfloat_text(a: *Arena, v: f64) -> const *char:
    t: const *char = a->printf("%.17g", v)
    if strpbrk(t, ".eEnN") == None:
        return a->printf("%s.0", t)
    return t

# EX_NUMBER -> CVal (int or float per '.'/exponent/suffix, like type_of)
private def ceval_num(txt: const *char) -> CVal:
    ishex: bool = txt[0] == '0' and (txt[1] == 'x' or txt[1] == 'X')
    isflt: bool = False
    if not ishex:
        c: const *char = txt
        while *c != '\0':
            if *c == '.' or *c == 'e' or *c == 'E':
                isflt = True
                break
            c += 1
    hasf: bool = False
    i: i32 = i32(strlen(txt))
    while i > 0 and not ishex and (txt[i - 1] == 'f' or txt[i - 1] == 'F'):
        hasf = True
        i -= 1
    if isflt or hasf:
        return cv_flt(strtod(txt, None))
    # integer literal text is always non-negative (unary '-' is a separate node),
    # so strtoull covers the full 0..2^64-1 range; strtoll would saturate a value
    # with the high bit set (e.g. a 64-bit hash seed) at LLONG_MAX. The bits fit i64.
    return cv_int(i64(strtoull(txt, None, 0)))



# width in bytes of a canonical integer type name (0 if not a known integer)
private def ctype_width(n: const *char) -> i32:
    if n in {"char", "i8", "u8", "_Bool", "bool", "signed char", "unsigned char"}:
        return 1
    if n in {"short", "i16", "u16", "unsigned short"}:
        return 2
    if n in {"int", "i32", "u32", "unsigned", "unsigned int"}:
        return 4
    if n in {"long", "long long", "i64", "u64", "usize", "isize", "unsigned long", "unsigned long long"}:
        return 8
    return 0

private def ctype_unsigned(n: const *char) -> bool:
    if strncmp(n, "unsigned", 8) == 0:
        return True
    return n in {"u8", "u16", "u32", "u64", "usize", "bool", "_Bool"}







# ---------- "did you mean ...?" ----------
# Levenshtein distance (names are short; capped at 63 chars)
private def edit_dist(a: const *char, b: const *char) -> i32:
    la: i32 = i32(strlen(a))
    lb: i32 = i32(strlen(b))
    if la > 63 or lb > 63:
        return 999
    prev: i32[64]
    cur: i32[64]
    for j in range(lb + 1):
        prev[j] = i32(j)
    for i in range(1, la + 1):
        cur[0] = i32(i)
        for j in range(1, lb + 1):
            c: i32 = 0 if a[i - 1] == b[j - 1] else 1
            m: i32 = prev[j] + 1
            if cur[j - 1] + 1 < m:
                m = cur[j - 1] + 1
            if prev[j - 1] + c < m:
                m = prev[j - 1] + c
            cur[j] = m
        for j in range(lb + 1):
            prev[j] = cur[j]
    return prev[lb]



# ---------- unknown-type checking ----------
# multi-word C arithmetic spelling ("unsigned long long int"...): every word
# must be a C base/modifier keyword
private def is_c_arith_words(n: const *char) -> bool:
    i: i32 = 0
    words = 0
    while n[i] != '\0':
        st: i32 = i
        while n[i] != '\0' and n[i] != ' ':
            i += 1
        w: const *char = n + st
        wl: i32 = i - st
        ok: bool = (wl == 8 and strncmp(w, "unsigned", 8) == 0) or (wl == 6 and strncmp(w, "signed", 6) == 0) or (wl == 4 and strncmp(w, "long", 4) == 0) or (wl == 5 and strncmp(w, "short", 5) == 0) or (wl == 3 and strncmp(w, "int", 3) == 0) or (wl == 4 and strncmp(w, "char", 4) == 0) or (wl == 6 and strncmp(w, "double", 6) == 0) or (wl == 5 and strncmp(w, "float", 5) == 0)
        if not ok:
            return False
        words += 1
        if n[i] == ' ':
            i += 1
    return words > 0




# can the expression be assigned to / incremented / addressed? (C lvalue rule,
# on the TOP node: variables, array elements, fields, *deref, compound literals)
# is `init` a call to exactly the type `t` names? (`v: Vec = Vec(...)`)
private def names_own_type(t: *Type, init: *Expr) -> bool:
    if t == None or init == None or t->kind != TY_NAME or t->name == None:
        return False
    if init->kind != EX_CALL or init->lhs == None or init->lhs->kind != EX_IDENT or init->lhs->text == None:
        return False
    return strcmp(t->name, init->lhs->text) == 0

# a plain designator: a name, a field of one, an element of one. Reading it
# twice costs nothing and has no side effect.
private def is_designator(e: *Expr) -> bool:
    if e == None:
        return False
    match e->kind:
        case EX_IDENT:
            return True
        case EX_FIELD:
            return is_designator(e->lhs)
        case EX_INDEX:
            return is_designator(e->lhs) and is_designator(e->rhs)
        case EX_NUMBER:
            return True
        case _:
            return False

# does this module declare `name` as a trait or a type? (the orphan rule)
private def decl_in_module(m: *Module, name: const *char) -> bool:
    for i in range(m->ndecls):
        d: *Decl = m->decls[i]
        if d->name != None and strcmp(d->name, name) == 0 and d->kind in {DL_TRAIT, DL_STRUCT, DL_UNION, DL_ENUM}:
            return True
    return False

private def is_lvalue(e: *Expr) -> bool:
    if e == None:
        return True
    match e->kind:
        case EX_IDENT, EX_INDEX, EX_COMPOUND, EX_GENERIC, EX_WITHSELF:
            return True
        case EX_FIELD:
            # p->x is always an lvalue; v.x only when v itself is one
            # ((cond ? a : b).x and f().x are NOT assignable/addressable)
            if e->op == TK_ARROW:
                return True
            return is_lvalue(e->lhs)
        case EX_UNARY:
            return e->op == TK_STAR   # *p
        case _:
            return False





private def mk_ident(a: *Arena, name: const *char, pos: Pos) -> *Expr:
    e: *Expr = ex_new(a, EX_IDENT, pos)
    e->text = name
    return e

private def mk_call1(a: *Arena, fn: const *char, arg: *Expr, pos: Pos) -> *Expr:
    c: *Expr = ex_new(a, EX_CALL, pos)
    c->lhs = mk_ident(a, fn, pos)
    args: **Expr = a->alloc(sizeof(*args))
    args[0] = arg
    c->args = args
    c->nargs = 1
    return c


# an `in self` receiver (READ-ONLY by contract) accepts an rvalue: `f().m()`
# materializes a temporary and passes its address, as `(__inN = f(), &__inN)`
# — valid C89 (the declaration is hoisted to the function entry, like the
# walrus does). `ref`/`out` NEVER do this: writing into a temporary would be a
# silent loss, so there an rvalue is an error.
# `&*p` IS `p`. Every use of a byref parameter is wrapped in an auto-deref, so
# handing one to something that wants its address — another byref call, a
# `with`, a method on `self` — would spell `& *p`. out_done marks exactly that
# generated deref, whose operand is a pointer by construction: collapsing the
# pair preserves the type (an ARRAY operand would not — sizeof would differ).
private def is_byref_deref(x: *Expr) -> bool:
    if x == None or x->kind != EX_UNARY or x->op != TK_STAR:
        return False
    # out_done on the DEREF node itself: a ref-returning call wrapped by sema
    # (69.1) — the operand is a pointer by construction, same as the ident case
    if x->out_done:
        return True
    return x->lhs != None and x->lhs->kind == EX_IDENT and x->lhs->out_done

private def take_addr(a: *Arena, x: *Expr) -> *Expr:
    if is_byref_deref(x):
        return x->lhs
    adr: *Expr = ex_new(a, EX_UNARY, x->pos)
    adr->op = TK_AMP
    adr->lhs = x
    return adr





# renders a type in P's spelling (for typestr): *char, int[4], Point, def()->int
private def render_type_p(a: *Arena, t: *Type) -> const *char:
    if t == None:
        return "?"
    if t->kind == TY_PTR:
        if t->is_ref:
            return a->printf("ref %s", render_type_p(a, t->inner))
        return a->printf("*%s", render_type_p(a, t->inner))
    if t->kind == TY_ARRAY:
        if t->arr_len != None and t->arr_len->kind == EX_NUMBER:
            return a->printf("%s[%s]", render_type_p(a, t->inner), t->arr_len->text)
        return a->printf("%s[]", render_type_p(a, t->inner))
    if t->kind == TY_FUNC:
        buf: const *char = "def("
        for i in range(t->ntargs):
            buf = a->printf("%s%s%s", buf, ", " if i != 0 else "", render_type_p(a, t->targs[i]))
        return a->printf("%s) -> %s", buf, render_type_p(a, t->inner))
    return t->name if t->name != None else "?"



# ---------- expression TYPE CHECKING (rejects invalid programs) ----------
# `type_of` is CONSERVATIVE (None = unknown): every check below fires only
# when the involved types are POSITIVELY known — unknown stays permissive
# (C interop, opaque types, legacy imports). The rejected shapes are invalid
# in both P and C, so the checks are shared by both front ends.



private def is_void_val(t: *Type) -> bool:
    return t != None and t->kind == TY_NAME and t->name == "void"


# positively-known arithmetic scalar (int/char/float families + P aliases)
private def is_arith_type(t: *Type) -> bool:
    if t == None or t->kind != TY_NAME:
        return False
    n: const *char = t->name
    if ctype_width(n) > 0:
        return True
    return n in {"float", "double", "f32", "f64", "long double"}



















private def is_float_type(t: *Type) -> bool:
    if t == None or t->kind != TY_NAME:
        return False
    n: const *char = t->name
    return n in {"float", "double", "f32", "f64", "long double"}

# ---------- recursive initializer checking (C11 6.7.9) ----------
# Walks a brace initializer against its type with the FULL C model: nested
# braces, brace ELISION (flat scalars filling nested aggregates), designators
# (.field and [idx]), string literals into char arrays, unions taking a single
# member. Conservative like the rest of the checker: unknown types/values bail
# out permissive — only positively-wrong shapes are rejected.


# units in a string literal (escapes decoded; quotes and L/u/U prefix in lex).
# -1 when the shape is unexpected (adjacent-literal concat etc.) — caller bails.
private def init_str_units(lex: const *char) -> i32:
    i: i32 = 0
    if lex[i] in {'L', 'u', 'U'}:
        i += 1
    if lex[i] != '"':
        return -1
    i += 1
    units = 0
    while lex[i] != '\0' and lex[i] != '"':
        if lex[i] == '\\':
            i += 1
            if lex[i] == 'x':
                i += 1
                while (lex[i] >= '0' and lex[i] <= '9') or (lex[i] >= 'a' and lex[i] <= 'f') or (lex[i] >= 'A' and lex[i] <= 'F'):
                    i += 1
            elif lex[i] >= '0' and lex[i] <= '7':
                nd = 0
                while nd < 3 and lex[i] >= '0' and lex[i] <= '7':
                    i += 1
                    nd += 1
            elif lex[i] != '\0':
                i += 1
        else:
            i += 1
        units += 1
    if lex[i] != '"' or lex[i + 1] != '\0':
        return -1   # not a single plain literal: bail
    return units


# an unnamed BITFIELD slot takes no initializer; anonymous struct/union
# members (name "" with a linked decl) DO
private def init_skip_field(f: *Field) -> bool:
    return (f->name == None or f->name[0] == '\0') and f->anon == None








# generic free-function call: foo(3) where foo is a `def foo<T>` template.
# Infers each type parameter from the arg whose param type is exactly that
# parameter, then rewrites the callee to the monomorphized name (foo_int), which
# must have been instantiated with `declare foo<int>`.
# unifies a parameter type (which mentions the type-param `tname`) against a
# concrete argument type, binding `tname`. Handles T, *T, T[], nested (**T, *T[]),
# and array<->pointer decay. Returns the bound type or None if `tname` not found.
private def unify_tparam(pt: *Type, at: *Type, tname: const *char) -> *Type:
    if pt == None:
        return None
    if pt->kind == TY_NAME:
        return at if strcmp(pt->name, tname) == 0 else None
    if at == None:
        return None
    if (pt->kind == TY_PTR or pt->kind == TY_ARRAY) and (at->kind == TY_PTR or at->kind == TY_ARRAY):
        return unify_tparam(pt->inner, at->inner, tname)
    return None



# ---------- defer: structural validations ----------
# recursively looks for a statement of kind k (for the goto+defer rule)
# does this block END the flow that entered it? (69.7: what makes the
# `if p == None: return` idiom leave its proof behind). Only the four
# statements the language GUARANTEES to leave count; a call that never
# returns is knowledge sema does not have.
private def block_terminates(b: *Block) -> bool:
    if b == None or b->n == 0:
        return False
    k: i32 = b->stmts[b->n - 1]->kind
    return k == ST_RETURN or k == ST_BREAK or k == ST_CONTINUE or k == ST_GOTO

private def block_find_kind(b: *Block, k: StmtKind) -> *Stmt:
    if b == None:
        return None
    for i in range(b->n):
        st: *Stmt = b->stmts[i]
        if st->kind == k:
            return st
        r: *Stmt = None
        match st->kind:
            case ST_IF:
                for j in range(st->nconds):
                    r = block_find_kind(st->blocks[j], k)
                    if r != None:
                        return r
                r = block_find_kind(st->else_block, k)
                if r != None:
                    return r
            case ST_WHILE, ST_DO, ST_FOR, ST_DEFER, ST_CFOR, ST_WITH:
                r = block_find_kind(st->body, k)
                if r != None:
                    return r
            case ST_MATCH:
                for j2 in range(st->ncases):
                    r = block_find_kind(st->cases[j2]->body, k)
                    if r != None:
                        return r
            case _:
                continue
    return None


# STRUCTURAL equality of types for match type (const/generics already resolved)
# A trait's signature written with the trait's own name where the implementing
# type goes, and with its associated type where the implementation's choice
# goes (72.5). Substituting and then comparing beats a comparison that knows
# about traits: what comes out is an ordinary type, and the ordinary equality
# answers for it.
private def trait_sub(a: *Arena, t: *Type, trait: const *char, forty: const *char, assoc: const *char, at: *Type) -> *Type:
    if t == None:
        return None
    match t->kind:
        case TY_NAME:
            if t->name == None:
                return t
            if strcmp(t->name, trait) == 0:
                r: *Type = ty_name(a, forty)
                r->is_const = t->is_const
                return r
            if assoc != None and at != None and strcmp(t->name, assoc) == 0:
                return at
            return t
        case TY_PTR:
            i1: *Type = trait_sub(a, t->inner, trait, forty, assoc, at)
            if i1 == t->inner:
                return t
            r2: *Type = ty_ptr(a, i1)
            r2->is_const = t->is_const
            r2->is_ref = t->is_ref
            return r2
        case TY_ARRAY:
            i2: *Type = trait_sub(a, t->inner, trait, forty, assoc, at)
            if i2 == t->inner:
                return t
            r3: *Type = a->alloc(sizeof(Type))
            *r3 = *t
            r3->inner = i2
            return r3
        case _:
            return t

private def type_eq_p(a: *Type, b: *Type) -> bool:
    if a == None or b == None:
        return a == b
    if a->kind != b->kind:
        return False
    match a->kind:
        case TY_NAME:
            if a->name == None or b->name == None:
                return a->name == b->name
            return strcmp(a->name, b->name) == 0
        case TY_PTR, TY_FUNC, TY_ARRAY:
            return type_eq_p(a->inner, b->inner)
        case _:
            return False





# `-N` literals parse as EX_UNARY(TK_MINUS): a negative bound/step in a range.
private def expr_is_negative(e: *Expr) -> bool:
    return e != None and e->kind == EX_UNARY and e->op == TK_MINUS


# auto-declaration of `for` loop variables (Python-style: the iterator lives on
# after the loop, in the enclosing scope). Returns the synthesized decl(s) via
# d1/d2 (None when unused); the caller inserts them right before the loop.
#   for i in range(...)        -> `i: usize` (or `isize` if a bound/step is < 0)
#   for i, v in enumerate(arr) -> `i: usize`, `v: <elem>`; the loop is rewritten
#                                 to a range over arr's length + a `v = arr[i]`
#                                 binding at the top of the body (pure sugar).
# A plain-range variable that is already in scope is left untouched (legacy).
private def type_is_unsigned(t: *Type) -> bool:
    if t == None or t->kind != TY_NAME or t->name == None:
        return False
    if strncmp(t->name, "unsigned", 8) == 0:
        return True
    return t->name in {"usize", "u8", "u16", "u32", "u64", "size_t",
                       "uint8_t", "uint16_t", "uint32_t", "uint64_t"}













# object-like macro RHS -> integer, tolerantly: parens, unary +/-/~, ONE integer
# literal with C suffixes. Anything more complex returns False (macro skipped).
def macro_int_val(txt: const *char, out: *i64) -> bool:
    i: i32 = 0
    neg: bool = False
    flip: bool = False
    while txt[i] != '\0':
        c: char = txt[i]
        if c in {' ', '\t', '('}:
            i += 1
        elif c == '-':
            neg = not neg
            i += 1
        elif c == '+':
            i += 1
        elif c == '~':
            flip = not flip
            i += 1
        else:
            break
    if not (txt[i] >= '0' and txt[i] <= '9'):
        return False
    endp: *char = None
    v: i64 = i64(strtoull(txt + i, &endp, 0))
    while *endp == 'u' or *endp == 'U' or *endp == 'l' or *endp == 'L':
        endp += 1
    while *endp != '\0':
        if *endp != ' ' and *endp != '\t' and *endp != ')':
            return False
        endp += 1
    if flip:
        v = ~v
    if neg:
        v = -v
    *out = v
    return True










private def inject_inline_runtime(cc: *Cc, m: *Module):
    tl: TokenList = lex("<inline-runtime>", INLINE_RUNTIME_SRC, strlen(INLINE_RUNTIME_SRC), &cc->arena)
    rtm: *Module = parse_tokens(&cc->arena, "<inline-runtime>", tl, 0)
    if rtm == None or rtm->ndecls == 0:
        return
    total: i32 = rtm->ndecls + m->ndecls
    nd: **Decl = cc->arena.alloc(usize(total) * sizeof(*nd))
    for i in range(rtm->ndecls):
        nd[i] = rtm->decls[i]
    for j in range(m->ndecls):
        nd[rtm->ndecls + j] = m->decls[j]
    m->decls = nd
    m->ndecls = total

def sema_run(cc: *Cc, m: *Module):
    if cc->inline_runtime and not m->is_c:
        inject_inline_runtime(cc, m)
    s: Sema = {0}
    s.cc = cc
    s.a = &cc->arena
    s.file = m->path
    s.c_mod = m->is_c
    defer:
        s.templates.deinit()
        s.func_templates.deinit()
        s.implemented.deinit()
        s.types.deinit()
        s.structs.deinit()
        s.funcs.deinit()
        s.globals.deinit()
        s.constvals.deinit()
        s.macroconsts.deinit()
        s.gdefs.deinit()
        s.gstatics.deinit()
        s.gexterns.deinit()
        s.enumconsts.deinit()
        s.macroalias.deinit()
        s.enums.deinit()
        s.tdalias.deinit()
        s.tdscalar.deinit()
        s.traits.deinit()
        s.timpls.deinit()
        s.fn_globals.deinit()
        s.fn_nonlocals.deinit()
        s.fn_hoisted.deinit()
        s.done.deinit()
        s.later_defs.deinit()
        free(s.locals)
        free(s.lam_pend)
        free(s.scopes)

    j = 0
    while builtins[j] != None:
        s.add_type(builtins[j])
        j += 1

    s.inject_predefined(cc)
    s.inject_defines(cc, m)
    s.register_module(m, True)
    # 65.4: the lifted lambdas. Their bodies are checked HERE, after every
    # ordinary body, because check_func_body resets the per-function
    # `global`/`nonlocal` state and doing that in the middle of the enclosing
    # function would lose it. The loop re-reads the count on purpose: a lambda
    # inside a lambda's body appends while this runs.
    li: i32 = 0
    while li < s.nlam_pend:
        s.check_func_body(s.lam_pend[li])
        li += 1
    if s.nlam_pend > 0:
        # PROTOTYPE first, BODY last. The C this back end emits has no forward
        # declarations — it prints the module in order — so a lifted lambda has
        # to be announced before the function that names it and defined after
        # the globals and structs its body reads. That is exactly what a person
        # writing this C by hand would do.
        total: i32 = 2 * s.nlam_pend + m->ndecls
        nld: **Decl = s.a->alloc(usize(total) * sizeof(*nld))
        for i in range(s.nlam_pend):
            pf: *Func = s.a->alloc(sizeof(Func))
            *pf = *s.lam_pend[i]
            pf->body = None
            pdc: *Decl = s.a->alloc(sizeof(Decl))
            pdc->kind = DL_FUNC
            pdc->pos = pf->pos
            pdc->func = pf
            pdc->name = pf->name
            nld[i] = pdc
        for j in range(m->ndecls):
            nld[s.nlam_pend + j] = m->decls[j]
        for i in range(s.nlam_pend):
            ldc: *Decl = s.a->alloc(sizeof(Decl))
            ldc->kind = DL_FUNC
            ldc->pos = s.lam_pend[i]->pos
            ldc->func = s.lam_pend[i]
            ldc->name = s.lam_pend[i]->name
            nld[s.nlam_pend + m->ndecls + i] = ldc
        m->decls = nld
        m->ndecls = total
    # C module under --std=c89 whose VLAs were lowered to malloc/free: the
    # round-tripped C has no #include, and C89's implicit declaration would
    # TRUNCATE malloc's pointer return on LP64 — inject the two prototypes.
    if m->is_c and cc->std_version == 89 and s.vla_ctr > 0:
        pm: *Func = s.a->alloc(sizeof(Func))
        pm->name = "malloc"; pm->cname = "malloc"
        pm->ret = ty_ptr(s.a, ty_name(s.a, "void"))
        mp: *Param = s.a->alloc(sizeof(Param))
        mp[0].name = "__size"; mp[0].type = ty_name(s.a, "usize")
        pm->params = mp; pm->nparams = 1
        pf: *Func = s.a->alloc(sizeof(Func))
        pf->name = "free"; pf->cname = "free"
        pf->ret = ty_name(s.a, "void")
        fp: *Param = s.a->alloc(sizeof(Param))
        fp[0].name = "__ptr"; fp[0].type = ty_ptr(s.a, ty_name(s.a, "void"))
        pf->params = fp; pf->nparams = 1
        nd: **Decl = s.a->alloc(usize(m->ndecls + 2) * sizeof(*nd))
        d1: *Decl = s.a->alloc(sizeof(Decl)); d1->kind = DL_FUNC; d1->func = pm
        d2: *Decl = s.a->alloc(sizeof(Decl)); d2->kind = DL_FUNC; d2->func = pf
        nd[0] = d1; nd[1] = d2
        for i in range(m->ndecls):
            nd[i + 2] = m->decls[i]
        m->decls = nd
        m->ndecls = m->ndecls + 2

    # typedef -> underlying SCALAR, for a back end that computes layouts itself
    if s.tdscalar.elen > 0:
        sn: **char = s.a->alloc(usize(s.tdscalar.elen) * sizeof(*sn))
        st2: **Type = s.a->alloc(usize(s.tdscalar.elen) * sizeof(*st2))
        nsc: i32 = 0
        for ti in range(s.tdscalar.elen):
            if s.tdscalar.dead[ti]:
                continue
            sn[nsc] = s.a->strdup(s.tdscalar.keys[ti])
            st2[nsc] = s.tdscalar.vals[ti]
            nsc += 1
        m->tdsc_names = sn
        m->tdsc_types = st2
        m->ntdsc = nsc

    # TAG -> typedef reverse map, for the C backend to print `FILE` where the
    # type is canonically `struct _IO_FILE` (see Module.tdrev_*). P modules only:
    # a round-tripped C module has no typedef left in its output to refer to.
    # The keys are copies OWNED by tdalias, which the defer above frees — so
    # they are duplicated into the arena, not aliased.
    if not m->is_c and s.tdalias.elen > 0:
        rtags: **char = s.a->alloc(usize(s.tdalias.elen) * sizeof(*rtags))
        rnames: **char = s.a->alloc(usize(s.tdalias.elen) * sizeof(*rnames))
        nrev: i32 = 0
        for ti in range(s.tdalias.elen):
            if s.tdalias.dead[ti]:
                continue
            tv: *Type = s.tdalias.vals[ti]
            if tv == None or tv->name == None:
                continue
            tdn: const *char = s.tdalias.keys[ti]
            # One entry per TAG, preferring the PUBLIC name: glibc gives
            # `struct _IO_FILE` two typedefs, `FILE` and `__FILE`, and a leading
            # underscore marks the implementation's reserved namespace — the same
            # category as the tag itself, so it is not what we want to print.
            prev: i32 = -1
            for rj in range(nrev):
                if strcmp(rtags[rj], tv->name) == 0:
                    prev = rj
                    break
            if prev >= 0:
                if rnames[prev][0] == '_' and tdn[0] != '_':
                    rnames[prev] = s.a->strdup(tdn)
                continue
            rtags[nrev] = s.a->strdup(tv->name)
            rnames[nrev] = s.a->strdup(tdn)
            nrev += 1
        m->tdrev_tags = rtags
        m->tdrev_names = rnames
        m->ntdrev = nrev
