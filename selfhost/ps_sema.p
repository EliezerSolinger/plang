# ps_sema.p — pscript's semantic analysis.
#
# It does what P's sema deliberately does NOT: pscript is statically typed with
# inference and its execution semantics are its own, so the type of every
# expression has to be known here — the target C compiler cannot be asked to
# finish the job the way P asks it to. What comes out is a tree where every
# expression carries a `type`, which is exactly what ps_lower needs to pick
# between `ps_add` and a plain `+`.
#
# The rules that are NOT C's, and are the reason this file exists:
#   * `/` is float even between ints (39.1); `//` floors and `%` takes the
#     divisor's sign.
#   * `1 + "2"` is an error — no implicit coercion between number and string
#     (7.3). int promotes to float, and nothing else promotes at all.
#   * a condition is a `bool` or a `T?`, never an int (40.1).
#   * scope is per BLOCK, as in P and C (64.1, revising 40.2): the two
#     languages agree, so the lowering never has to reconcile two models. The
#     Python if/else idiom is written with `nonlocal`, the same opt-in P has.
#
# WHAT v1 COVERS. The parser reads the whole language (the two validation
# programs go through it), but the analysis and the lowering grow feature by
# feature with a test each, which is the build order 50.4 asked for. Anything
# parsed and not yet analysed stops with a message that says so by name —
# never a silent wrong type.
include <string.h>
include <stdlib.h>
include <ctype.h>
include <stdio.h>
import "ps_sema.ph"
import <stl/vec.ph>
import <stl/map.ph>
import <stl/set.ph>
import "ps_lower.ph"
import "ps_parser.ph"
import "ps_generic.ph"
import "sema.ph"
import "cfront.ph"
import "parser.ph"   # 75.3: a `.ph` is read with P's own front end

# 111: os módulos que NÃO são arquivo — `sys` e os portados. A lista mora aqui,
# num lugar só: quem resolve o import pergunta a ela, e `builtin_ns` (embaixo)
# diz quais nomes cada um tem. Esquecer de acrescentar um módulo novo AQUI dá
# "cannot find module 'os'", que não diz nada a quem escreveu o import.
# O nome de um módulo de pacote: o último pedaço, sem extensão. `<pui>` -> `pui`,
# `<pui/layout.psc>` -> `layout`. É o mesmo que o nome de arquivo já diz, e é o
# que quem escreve `layout.medir(...)` espera.
private def ps_ends_with(s: const *char, suf: const *char) -> bool:
    n: usize = strlen(s)
    m: usize = strlen(suf)
    return n >= m and strcmp(s + n - m, suf) == 0

def ps_mod_name(a: *Arena, p: const *char) -> const *char:
    base: const *char = p
    sl: const *char = strrchr(p, '/')
    if sl != None:
        base = sl + 1
    n: usize = strlen(base)
    if n > 4 and strcmp(base + n - 4, ".psc") == 0:
        return a->strndup(base, n - 4)
    return a->strdup(base)

# Quantas provas de não-nulidade uma condição pode carregar de uma vez —
# `a != None and b != None and ...`. Oito é muito mais do que qualquer condição
# legível tem, e é um limite dito em vez de um comportamento silencioso: passado
# ele, as provas seguintes simplesmente não se aplicam, e o erro que aparece é o
# mesmo que apareceria sem `and` nenhum.
PS_NARROW_MAX: const i32 = 8

private def ps_builtin_mod(name: const *char) -> bool:
    MODS: const *char[] = {"sys", "re", "json", "net", "random", "math", "time",
                           "bisect", "heapq", "gc", "sched", "os", "path"}
    for i in range(i32(sizeof(MODS) / sizeof(MODS[0]))):
        if strcmp(name, MODS[i]) == 0:
            return True
    return False

declare StrMap<i64>
declare StrMap<*PsFunc>
declare StrMap<*PsExpr>
declare Vec<const *char>   # implemented in vecs.p
implement StrMap<*PsExpr>
implement StrMap<*PsFunc>
declare StrMap<*PsDecl>
implement StrMap<*PsDecl>
declare StrMap<*PsType>
implement StrMap<*PsType>
declare StrMap<*PsNs>
implement StrMap<*PsNs>
declare StrMap<*char>   # implemented in cfront.p; one TU implements, the rest declare
declare Vec<*PsDecl>
declare Vec<*PsFunc>
declare Vec<*PsExpr>   # implemented in ps_parser.p — o ambiente do 65.10
declare Vec<*PsStmt>   # implemented in ps_parser.p
declare Vec<PsParam>   # implemented in ps_parser.p
declare Vec<PsDynUse>
implement Vec<PsDynUse>
# One enclosing lambda while its body is checked (19.2). A STACK of them,
# because a lambda can be written inside a lambda: a name that comes from
# outside BOTH is captured by both — the inner one can only read what the outer
# one carries, so the capture has to travel outward frame by frame.
struct PsLamF:
    base: i32                # where this lambda's own locals begin
    caps: Vec<PsParam>       # what it captured, in order

declare Vec<PsLamF>
implement Vec<PsLamF>

# The prelude (D3/67.4): the names every program has without importing anything.
# It is SOURCE — see ps_prelude.psc — parsed like any other module, because a
# trait built by hand out of AST nodes would be a second way to say the same
# thing, and the day the surface changed one of them would be forgotten.
#
# `embed` (63.5) is what lets it be a real file and still cost nothing at run
# time: the bytes are read at COMPILE time and become a static array, so there
# is no file to find, no path to configure, and the prelude a compiler carries
# is exactly the one that was compiled into it.
private const PS_PRELUDE: const *char = embed("ps_prelude.psc")

# how deep a chain of DISTINCT structs a message may nest (74.2). A type that
# contains itself is not deep — it is caught by the name already on the way
# down — so this only bounds a genuinely long chain.
private const PS_SEND_DEPTH: const i32 = 64

# Renamed name -> the name a diagnostic should print (`geom.Vec2`). Module
# scope because `ps_type_str` is a free function: it is called from everywhere,
# takes only the type, and a message showing `geom__Vec2` would be telling the
# reader about a rename they never asked for. Rebuilt per run; one map per
# compiled program.
private PS_DISP: StrMap<*char>
private PS_DISP_READY: bool = False

# The typed views of 18.3, as a table: the NAME says the element, and the size
# follows from it. Zero means "not a view method".
def ps_view_esize(name: const *char) -> i32:
    if strcmp(name, "view_f64") == 0 or strcmp(name, "view_i64") == 0:
        return 8
    if strcmp(name, "view_f32") == 0 or strcmp(name, "view_i32") == 0:
        return 4
    if strcmp(name, "view_u8") == 0:
        return 1
    return 0

def ps_view_elem(a: *Arena, name: const *char, pos: Pos) -> *PsType:
    if strcmp(name, "view_f64") == 0:
        return ps_type(a, PT_FLOAT, pos)
    if strcmp(name, "view_f32") == 0:
        t: *PsType = ps_type(a, PT_FLOAT, pos)
        t->width = 32
        return t
    t2: *PsType = ps_type(a, PT_INT, pos)
    if strcmp(name, "view_i32") == 0:
        t2->width = 32
    elif strcmp(name, "view_u8") == 0:
        t2->width = 8
        t2->uns = True
    return t2

def ps_disp(name: const *char) -> const *char:
    if not PS_DISP_READY or name == None:
        return name
    d: *char = PS_DISP.get_or(name, None)
    return d if d != None else name


private def ps_expr_what(k: PsExprKind) -> const *char
def ps_mangle_type(a: *Arena, t: *PsType) -> const *char
def ps_type_str(a: *Arena, t: *PsType) -> const *char
def is_ps_designator(e: *PsExpr) -> bool
def zero_ps_pos() -> Pos
private def ns_find(v: *PsNsEnt, n: i32, name: const *char) -> *PsNsEnt
def ps_const_len(e: *PsExpr, ref out: i64) -> bool
private def ps_prog_shadows(m: *PsModule, name: const *char) -> *PsDecl
def ps_is_ref_type(t: *PsType) -> bool
private def ps_kind_of_name(a: *Arena, file: const *char, e: *PsExpr, pos: Pos) -> *PsType
private def ps_lit_fits(file: const *char, e: *PsExpr, t: *PsType)
private def ps_int_widens(from2: *PsType, to: *PsType) -> bool
private def ps_adapt_lit(file: const *char, e: *PsExpr, t: *PsType) -> bool
private def ps_int_common(a: *PsType, b: *PsType) -> *PsType
def opt_is_ref_ps(t: *PsType) -> bool
def ps_has_await(e: *PsExpr) -> bool
private def ps_type_clone(a: *Arena, t: *PsType) -> *PsType
private def ps_subst_self(t: *PsType, name: const *char)
private def ps_subst_named(a: *Arena, t: *PsType, name: const *char, conc: *PsType) -> *PsType
private def ns_check_visible(ns: *PsNs, name: const *char, file: const *char, pos: Pos, spelled: const *char)
private def ps_stmt_what(k: PsStmtKind) -> const *char
private def ps_assign_binop(op: i32) -> i32
private def self_name(a: *Arena, n: const *char) -> const *char

# a local, in the function-wide scope of 40.2
struct PsLocal:
    name: const *char
    type: *PsType
    assigned: bool    # declared without a value: reading it before it gets one
                      #   is an error, the static form of Python's UnboundLocalError
    is_const: bool
    frozen: bool      # 61.3: `const` freezes DEEP — no rebinding AND no writing
                      #   through it. `self` in a struct method is const in the
                      #   first sense and not the second: the receiver cannot be
                      #   rebound, and mutating what it points at is the whole
                      #   reason the method exists (20.1).
    is_module: bool   # a top-level declaration: the name is ALSO a module
                      #   variable (42.2), and the two are the same storage
    depth: i32        # block that owns it; `nonlocal` pins a name to depth 0
    opt_type: *PsType # while NARROWED (43.1): the `T?` it really is, so that an
                      #   assignment inside the branch can restore the proof
    any_type: *PsType # while a `match type(x)` case holds (68.5): what the
                      #   `any` was PROVED to be inside this branch

# quantos passos uma avaliação de compilação pode dar antes de o compilador
# desistir e dizer porquê. Um milhão é muito mais do que uma constante precisa e
# muito menos do que um segundo de espera.
private const CEVAL_BUDGET: i64 = 1000000

# ---------- 65.10: o avaliador de COMPILAÇÃO ----------
#
# A promessa do `const def` é *"isto não existe em tempo de execução"*, e é por
# isso que o avaliador tem de ser TOTAL sobre o que aceita: ou devolve um
# literal, ou dá um erro com uma posição. **Nunca cai para uma chamada.** Uma
# que caísse tornaria a promessa num acaso — a função passaria a existir ou não
# conforme os argumentos, e ninguém saberia qual dos dois sem ler o C gerado.
#
# O que ele sabe é o que uma constante precisa: números, texto, booleanos, as
# operações entre eles, `if`/`while`/`for`, variáveis locais, e chamadas a
# outros `const def`. O que ele não sabe recusa-o pelo NOME — "um `while` que
# não acaba" é uma mensagem melhor do que um compilador que pára.
#
# O orçamento é o que fecha o buraco do laço infinito. Um `const def` mal
# escrito é um compilador que nunca devolve, e isso não é um erro do programa —
# é um erro do programa que se parece com um erro nosso.

struct CEnv:
    names: Vec<*char>
    vals: Vec<*PsExpr>
    ret: *PsExpr
    done: bool


private def cenv_get(ref env: CEnv, name: const *char) -> *PsExpr:
    i: i32 = i32(env.names.len) - 1
    while i >= 0:
        if strcmp(env.names.data[i], name) == 0:
            return env.vals.data[i]
        i -= 1
    return None


private def cenv_set(ref env: CEnv, name: const *char, v: *PsExpr):
    i: i32 = i32(env.names.len) - 1
    while i >= 0:
        if strcmp(env.names.data[i], name) == 0:
            env.vals.data[i] = v
            return
        i -= 1
    env.names.push((*char)(name))
    env.vals.push(v)


# ---- os valores, que são LITERAIS: o resultado substitui a chamada ----

private def cmk_int(a: *Arena, v: i64, pos: Pos) -> *PsExpr:
    e: *PsExpr = ps_expr(a, PE_INT, pos)
    e->text = a->printf("%lld", v)
    e->type = ps_type(a, PT_INT, pos)
    return e


private def cmk_float(a: *Arena, v: f64, pos: Pos) -> *PsExpr:
    e: *PsExpr = ps_expr(a, PE_FLOAT, pos)
    # `%.17g` e não `%g`: dezassete dígitos significativos é o que faz um `f64`
    # sobreviver à ida e volta por texto, e este número vai ser RELIDO pelo
    # compilador de C. Com menos, uma constante muda de valor ao ser escrita.
    e->text = a->printf("%.17g", v)
    e->type = ps_type(a, PT_FLOAT, pos)
    return e


private def cmk_bool(a: *Arena, v: bool, pos: Pos) -> *PsExpr:
    e: *PsExpr = ps_expr(a, PE_BOOL, pos)
    e->text = "True" if v else "False"
    e->type = ps_type(a, PT_BOOL, pos)
    return e


private def cmk_str(a: *Arena, s: const *char, pos: Pos) -> *PsExpr:
    e: *PsExpr = ps_expr(a, PE_STR, pos)
    e->text = s
    e->type = ps_type(a, PT_STR, pos)
    return e


private def cis_num(e: *PsExpr) -> bool:
    return e != None and (e->kind == PE_INT or e->kind == PE_FLOAT)


private def cnum(e: *PsExpr) -> f64:
    if e == None:
        return 0.0
    if e->kind == PE_INT:
        return f64(strtoll(e->text, None, 0))
    if e->kind == PE_FLOAT:
        return strtod(e->text, None)
    if e->kind == PE_BOOL:
        return 1.0 if strcmp(e->text, "True") == 0 else 0.0
    return 0.0


private def cint(e: *PsExpr) -> i64:
    if e != None and e->kind == PE_FLOAT:
        return i64(strtod(e->text, None))
    if e != None and e->kind == PE_BOOL:
        return 1 if strcmp(e->text, "True") == 0 else 0
    return strtoll(e->text, None, 0) if e != None else 0


private def cbool(e: *PsExpr) -> bool:
    if e == None:
        return False
    if e->kind == PE_BOOL:
        return strcmp(e->text, "True") == 0
    return cnum(e) != 0.0


# **Números e booleanos, e o texto ainda não.** O `text` de um `PE_STR` é a
# GRAFIA da fonte — com as aspas e os escapes — e devolver um literal novo
# exigiria reconstruir essa grafia ao contrário, que é onde um escape mal posto
# vira um valor diferente sem ninguém dar por isso. A 65.10 nasceu para o `T[N]`
# e para a f-string, que são números; o texto entra quando alguém o precisar, e
# entra com o codificador escrito e conferido, não de passagem.
private def cval_kind(a: *Arena, e: *PsExpr) -> const *char:
    if e == None:
        return "nothing"
    if e->kind == PE_INT:
        return "an int"
    if e->kind == PE_FLOAT:
        return "a float"
    if e->kind == PE_BOOL:
        return "a bool"
    return "a value this evaluator does not compute"



struct PsSema:
    a: *Arena
    file: const *char
    m: *PsModule
    # as raízes de `--pkg-path`, para `import <pkg/mod.ph>`. Vêm do driver e não
    # do `Cc` porque o front end do pscript não conhece o `Cc` — o que ele
    # precisa saber é onde procurar, e é só isso que atravessa.
    pkgroots: **char
    npkgroots: i32
    funcs: StrMap<*PsFunc>
    records: StrMap<*PsDecl>
    enums: StrMap<*PsDecl>
    enumof: StrMap<*PsDecl>    # enum ITEM name -> the enum that declares it
    globals: StrMap<*PsType>
    gconst: StrSet          # module variables declared `const`
    gconst_num: StrMap<i64> # ... and the VALUE of the ones that are an integer
    # 65.10: o que sobra de uma avaliação de compilação, e o quão fundo ela vai.
    # O orçamento é o que fecha o buraco do laço infinito: um `const def` que
    # não acaba é um compilador que não responde, e isso parece-se com um erro
    # NOSSO em vez de um erro do programa.
    cbudget: i64
    cdepth: i32
                            #   literal, because `xs: int[N]` needs a number:
                            #   C says an array size is a constant expression,
                            #   and a `static const int` is not one (that is C++)
    locals: *PsLocal
    nlocals: i32
    clocals: i32
    cur_ret: *PsType
    cur_fn: const *char
    fn_gone: StrSet          # 107: nomes que já morreram com o bloco nesta função
    loop_depth: i32
    in_with: i32             # S3/147.4: a checar a expressão de um `with`. O
                             #   `taskgroup()` só existe lá — a garantia dele é
                             #   o BLOCO, e fora de um não há bloco nenhum a que
                             #   nada possa sobreviver.
    counter: i32             # `__COUNTER__` (65.11): a fresh number per read
    nogc_depth: i32          # `nogc:` blocks around the statement being checked
                             #   (26.5.1): `await` inside one is refused
    hint: *PsType            # the type the CONTEXT wants, for the one literal that
                             #   cannot infer it alone: `xs: List<int> = []`
    cpp: const *char         # the C compiler used to preprocess an `include <h>`
    cfuncs: StrMap<*PsFunc>  # C functions the boundary rule (45.5) lets through
    cconsts: StrMap<*PsExpr> # C CONSTANTS the boundary lets through (72.4): a
                             #   member of an `enum`, a `static const` scalar and
                             #   an object-like `#define` whose value is a number.
                             #   A read of one is replaced by the literal, so
                             #   nothing of the header survives into the program.
    root_ns: *PsNs           # the module being compiled (41.3)
    cur_ns: *PsNs            # the namespace the declaration being checked is in
    nsof: StrMap<*PsNs>      # by module PATH, so a diamond import loads once
    prefixes: StrSet         # the renaming prefixes already taken
    traits: StrMap<*PsDecl>  # `trait X:` by renamed name (66)
    timpls: StrSet           # "trait|type" pairs already implemented: at most
                             #   one implementation per pair in the program (67.3)
    insts: StrMap<*PsFunc>   # generic instances by "name|type" (66.3), so the
                             #   same pair is monomorphized once
    pending: Vec<*PsFunc>    # instances whose body has not been checked yet: an
                             #   instance may instantiate another one
    ninst: i32               # instances made, capped so recursion that grows a
                             #   new type every round stops with a message
    lam_fr: Vec<PsLamF>      # the lambdas being checked, outermost first. A
                             #   name found below a frame's base is a CAPTURE
                             #   for that frame, and capture is by value (19.2)
    in_async: bool           # checking the body of an `async def`: `await` is
                             #   allowed here and nowhere else but the top level
    at_module: bool          # checking the top-level statements, which ARE the
                             #   program (39.4): a declaration there is a MODULE
                             #   variable, as in Python — visible to every
                             #   function, and assignable with `global x`
    assoc_name: const *char  # while comparing signatures: the trait's associated
    assoc_type: *PsType      #   type (66.4) and what this implementation says it is
    preludes: StrSet         # what the prelude actually provided (68.3): a
                             #   top-level `TYPE = ...` that shadows one of
                             #   these deserves the same warning a declaration
                             #   gets
    shared: StrSet           # `shared x`: synchronized by copy (42.1), one lock
                             #   each, and the only global that is NOT per-worker
    mvars: Vec<*PsStmt>      # the module variables those declarations created:
                             #   the lowering needs one file-scope variable each
    dseen: StrSet            # dyn traits and pairs already noted
    dtraits: Vec<*PsDecl>    # traits used as `dyn` (66.3)
    ablks: Vec<*PsDecl>      # the functions an `async:` block turned into
                             #   (78.3): appended to the module after checking,
                             #   because their bodies were checked HERE, in the
                             #   scope that wrote them
    nablk: i32
    hdrrecs: Vec<*PsDecl>    # records that came from an imported header (72.6):
                             #   they join the module's declarations so the
                             #   lowering finds them, and carry `from_hdr` so
                             #   nothing is emitted for them
    dpairs: Vec<PsDynUse>    # (trait, type) pairs actually boxed
    depth: i32               # current block nesting; 0 = the function's own scope
    fn_nonlocals: StrSet     # `nonlocal x`: the next `x = ...` declares at depth 0
    fn_globals: StrSet       # `global x`: assignments go to the module variable

    private def find_local(self: *PsSema, name: const *char) -> i32
    private def find_local_here(self: *PsSema, name: const *char) -> i32
    private def pop_scope(self: *PsSema)
    private def add_local(self: *PsSema, name: const *char, t: *PsType, assigned: bool, is_const: bool)
    private def check_block(self: *PsSema, b: *PsBlock)
    private def blk_exits(self: *PsSema, b: *PsBlock) -> bool
    private def sug_name(self: *PsSema, t: const *char, pos: Pos) -> *PsExpr
    private def sug_int(self: *PsSema, v: i32, pos: Pos) -> *PsExpr
    private def sug_call1(self: *PsSema, fn: const *char, a1: *PsExpr, pos: Pos) -> *PsExpr
    private def sug_bin(self: *PsSema, op: i32, l: *PsExpr, r: *PsExpr, pos: Pos) -> *PsExpr
    private def sug_index(self: *PsSema, l: *PsExpr, r: *PsExpr, pos: Pos) -> *PsExpr
    private def sug_bind(self: *PsSema, name: const *char, val: *PsExpr, pos: Pos) -> *PsStmt
    private def sug_kind(self: *PsSema, s: *PsStmt) -> i32
    private def sug_hoist(self: *PsSema, b: *PsBlock)
    private def sug_deny(self: *PsSema, a: *PsExpr, outer: const *char)
    private def sug_comp(self: *PsSema, e: *PsExpr)
    private def sug_unpack(self: *PsSema, s: *PsStmt) -> bool
    private def sug_body(self: *PsSema, s: *PsStmt, names: **char, vals: **PsExpr, n: i32)
    private def sug_for(self: *PsSema, s: *PsStmt, k: i32)
    private def check_stmt(self: *PsSema, s: *PsStmt)
    private def check_expr(self: *PsSema, e: *PsExpr) -> *PsType
    private def resolve_type(self: *PsSema, t: *PsType) -> *PsType
    private def check_call(self: *PsSema, e: *PsExpr) -> *PsType
    private def call_generic(self: *PsSema, e: *PsExpr, f: *PsFunc, name: const *char) -> *PsType
    # 65.10: os cinco do avaliador de compilação, declarados aqui porque se
    # chamam uns aos outros em ciclo — uma expressão contém uma chamada, e uma
    # chamada avalia um corpo cheio de expressões
    private def ceval_call(self: *PsSema, f: *PsFunc, args: **PsExpr, nargs: i32, pos: Pos) -> *PsExpr
    private def ceval_block(self: *PsSema, b: *PsBlock, ref env: CEnv, pos: Pos)
    private def ceval_stmt(self: *PsSema, s: *PsStmt, ref env: CEnv)
    private def ceval_expr(self: *PsSema, e: *PsExpr, ref env: CEnv) -> *PsExpr
    private def ceval_callexpr(self: *PsSema, e: *PsExpr, ref env: CEnv) -> *PsExpr
    private def ceval_binop(self: *PsSema, op: i32, l: *PsExpr, r: *PsExpr, pos: Pos) -> *PsExpr
    private def ceval_aug_op(self: *PsSema, op: i32, pos: Pos) -> i32
    private def ceval_step(self: *PsSema, pos: Pos)
    private def desugar_sequence(self: *PsSema, d: *PsDecl)
    private def bind_call_args(self: *PsSema, e: *PsExpr, params: *PsParam, nparams: i32, what: const *char)
    private def try_mod_qual(self: *PsSema, e: *PsExpr) -> bool
    private def builtin_call(self: *PsSema, e: *PsExpr, name: const *char) -> *PsType
    private def io_window(self: *PsSema, e: *PsExpr, what: const *char)
    private def watch_event_type(self: *PsSema, pos: Pos) -> *PsType
    private def want(self: *PsSema, e: *PsExpr, got: *PsType, expect: *PsType, ctx: const *char)
    private def check_want(self: *PsSema, e: *PsExpr, expect: *PsType, ctx: const *char)
    private def opt_of(self: *PsSema, t: *PsType, pos: Pos) -> *PsType
    private def check_func(self: *PsSema, f: *PsFunc)
    private def check_record_bytes(self: *PsSema, d: *PsDecl)
    private def predef(self: *PsSema, e: *PsExpr) -> *PsType
    private def const_root(self: *PsSema, e: *PsExpr) -> const *char
    private def deny_const_mut(self: *PsSema, e: *PsExpr, what: const *char)
    private def const_truth(self: *PsSema, e: *PsExpr, ref ok: bool) -> bool
    private def key_ok(self: *PsSema, t: *PsType, pos: Pos, what: const *char)
    private def byref_ok(self: *PsSema, t: *PsType, pos: Pos, kw: const *char)
    private def pod_only(self: *PsSema, t: *PsType, pos: Pos, what: const *char)
    private def copyable(self: *PsSema, t: *PsType, pos: Pos, what: const *char)
    private def sendable(self: *PsSema, t: *PsType, pos: Pos, what: const *char)
    private def sendable_in(self: *PsSema, t: *PsType, pos: Pos, what: const *char, seen: **char, n: i32)
    private def check_endian(self: *PsSema, e: *PsExpr)
    private def ingest_header(self: *PsSema, m: *PsModule, d: *PsDecl)
    private def ingest_pmodule(self: *PsSema, m: *PsModule, d: *PsDecl)
    private def ingest_cdecls(self: *PsSema, m: *PsModule, cm: *Module)
    private def build_ns(self: *PsSema, m: *PsModule, prefix: const *char, name: const *char) -> *PsNs
    private def builtin_ns(self: *PsSema, name: const *char, path: const *char) -> *PsNs
    private def fresh_prefix(self: *PsSema, name: const *char) -> const *char
    private def gname(self: *PsSema, name: const *char, pos: Pos) -> const *char
    private def gname_soft(self: *PsSema, name: const *char) -> const *char
    private def gname_x(self: *PsSema, name: const *char, pos: Pos, hard: bool) -> const *char
    private def enter_decl(self: *PsSema, d: *PsDecl)
    private def enter_func(self: *PsSema, d: *PsDecl, f: *PsFunc)
    private def check_impl(self: *PsSema, d: *PsDecl)
    private def check_implements(self: *PsSema, d: *PsDecl)
    private def conform(self: *PsSema, rd: *PsDecl, td: *PsDecl, ms: **PsFunc, nms: i32, pos: Pos, closed: bool, assoc: *PsType)
    private def sig_type(self: *PsSema, ns: *PsNs, t: *PsType, selfname: const *char) -> *PsType
    private def resolve_sig(self: *PsSema, f: *PsFunc)
    private def find_trait(self: *PsSema, t: *PsType, pos: Pos) -> *PsDecl
    private def is_struct_name(self: *PsSema, name: const *char) -> bool
    private def named_type(self: *PsSema, name: const *char, pos: Pos) -> *PsType
    private def note_dyn(self: *PsSema, tname: const *char, rname: const *char)
    private def note_dyn_trait(self: *PsSema, td: *PsDecl)
    private def find_trait_named(self: *PsSema, name: const *char, ns: *PsNs, pos: Pos) -> *PsDecl
    private def add_methods(self: *PsSema, rd: *PsDecl, ms: **PsFunc, nms: i32)
    private def c_type(self: *PsSema, t: *Type) -> *PsType
    private def cstr_kind(self: *PsSema, t: *Type) -> i32
    private def cbytes_ok(self: *PsSema, t: *PsType) -> bool
    private def bytes_type(self: *PsSema, pos: Pos) -> *PsType
    private def check_method(self: *PsSema, d: *PsDecl, f: *PsFunc)
    private def find_method(self: *PsSema, rd: *PsDecl, name: const *char) -> *PsFunc
    private def field_type(self: *PsSema, rt: *PsType, name: const *char, pos: Pos) -> *PsType
    private def narrow_from(self: *PsSema, c: *PsExpr, idx: *i32) -> i32
    private def narrow_else(self: *PsSema, c: *PsExpr, idx: *i32) -> i32
    private def narrow_one(self: *PsSema, c: *PsExpr, op: i32) -> i32
    private def narrow_all(self: *PsSema, c: *PsExpr, op: i32, idx: *i32, n: i32) -> i32
    private def narrow_push(self: *PsSema, idx: *i32, n: i32) -> i32
    private def narrow_pop(self: *PsSema, idx: *i32, n: i32)
    private def check_ctor(self: *PsSema, e: *PsExpr, rd: *PsDecl) -> *PsType
    private def check_async_lambda(self: *PsSema, e: *PsExpr, lh: *PsType)
    private def check_lambda_body(self: *PsSema, e: *PsExpr, lh: *PsType)
    private def check_binary(self: *PsSema, e: *PsExpr) -> *PsType

    # innermost first: an inner block may shadow an outer name, exactly as in P
    # `x != None` on a local of option type: the index of that local, or -1.
    # `None != x` counts too; anything else does not narrow.
    private def narrow_from(self: *PsSema, c: *PsExpr, idx: *i32) -> i32:
        return self->narrow_all(c, TK_NE, idx, 0)

    # 114: e o INVERSO — `if x == None: ... else: <aqui x é T>`. É a mesma prova
    # vista do outro lado, e a forma aparece sozinha quando a função trata
    # primeiro o caso ausente. O que NÃO se faz aqui é o `if x == None: return`
    # seguido de código: isso pede análise de fluxo, e o ramo `else` é a metade
    # que sai de graça.
    private def narrow_else(self: *PsSema, c: *PsExpr, idx: *i32) -> i32:
        return self->narrow_all(c, TK_EQ, idx, 0)

    # A FOLHA: `x != None` (ou `None != x`) sobre um local de tipo opcional.
    private def narrow_one(self: *PsSema, c: *PsExpr, op: i32) -> i32:
        if c == None or c->kind != PE_BINARY or c->op != op:
            return -1
        n: *PsExpr = None
        if c->lhs != None and c->lhs->kind == PE_NAME and c->rhs != None and c->rhs->kind == PE_NONE:
            n = c->lhs
        elif c->rhs != None and c->rhs->kind == PE_NAME and c->lhs != None and c->lhs->kind == PE_NONE:
            n = c->rhs
        if n == None:
            return -1
        i: i32 = self->find_local(n->text)
        if i < 0 or self->locals[i].type == None or self->locals[i].type->kind != PT_OPT:
            return -1
        return i

    # ... e a CONJUNÇÃO, que é a parte que faltava. `x != None and y != None`
    # prova as DUAS, e antes provava só a primeira — o `narrow_op` devolvia um
    # índice, portanto sabia dizer "esta" e não "estas". Quem escrevia a forma
    # natural tinha de a aninhar à mão, e foi o portão do `Channel<T>` (S3) que
    # cobrou: `if v1 != None and v2 != None` não compilava.
    #
    # Só para `!=` no `and`: no `==`, o ramo `else` pode ter sido tomado porque
    # o OUTRO lado falhou, e aí nada está provado. E o DUAL — `x == None or
    # <resto>` como guarda — vale pela razão simétrica: se a guarda não saiu,
    # nenhum dos lados valia.
    private def narrow_all(self: *PsSema, c: *PsExpr, op: i32, idx: *i32, n: i32) -> i32:
        if c == None or n >= PS_NARROW_MAX:
            return n
        if c->kind == PE_BINARY and ((c->op == TK_AND and op == TK_NE) or (c->op == TK_OR and op == TK_EQ)):
            return self->narrow_all(c->rhs, op, idx, self->narrow_all(c->lhs, op, idx, n))
        one: i32 = self->narrow_one(c, op)
        if one < 0:
            return n
        for k in range(n):
            if idx[k] == one:
                return n       # `x != None and x != None` é uma prova, não duas
        idx[n] = one
        return n + 1

    # Aplica as provas e COMPACTA a lista às que realmente se aplicaram — o que
    # já estava estreitado por fora não se estreita outra vez, e é essa lista
    # compactada que o `narrow_pop` desfaz.
    private def narrow_push(self: *PsSema, idx: *i32, n: i32) -> i32:
        k: i32 = 0
        for i in range(n):
            j: i32 = idx[i]
            if self->locals[j].opt_type == None and self->locals[j].type != None and self->locals[j].type->kind == PT_OPT:
                self->locals[j].opt_type = self->locals[j].type
                self->locals[j].type = self->locals[j].type->inner
                idx[k] = j
                k += 1
        return k

    private def narrow_pop(self: *PsSema, idx: *i32, n: i32):
        for i in range(n):
            j: i32 = idx[i]
            # uma atribuição dentro do ramo já a pode ter desfeito (43.1)
            if self->locals[j].opt_type != None:
                self->locals[j].type = self->locals[j].opt_type
                self->locals[j].opt_type = None

    private def find_local(self: *PsSema, name: const *char) -> i32:
        i: i32 = self->nlocals - 1
        while i >= 0:
            if strcmp(self->locals[i].name, name) == 0:
                return i
            i -= 1
        return -1

    # only the CURRENT block: redeclaring there is an error, shadowing is not
    private def find_local_here(self: *PsSema, name: const *char) -> i32:
        i: i32 = self->nlocals - 1
        while i >= 0 and self->locals[i].depth >= self->depth:
            if self->locals[i].depth == self->depth and strcmp(self->locals[i].name, name) == 0:
                return i
            i -= 1
        return -1

    private def add_local(self: *PsSema, name: const *char, t: *PsType, assigned: bool, is_const: bool):
        self->locals = vec_grow(self->locals, self->nlocals, ref self->clocals, sizeof(*self->locals))
        with self->locals[self->nlocals]:
            .name = name
            .type = t
            .assigned = assigned
            .is_const = is_const
            # NOT `is_const`: freezing is the DEEP half of const (61.3) and the
            # caller says so — `self` in a struct method is const in the sense
            # that it cannot be rebound, and mutating what it points at is the
            # whole reason the method exists. And it has to be written here at
            # all because of the note below: vec_grow hands back garbage.
            .frozen = False
            .is_module = False
            # EVERY field, always: the array comes from vec_grow, which hands
            # back uninitialized memory. A stale `opt_type` here reads as
            # "this name was proved non-null", and the lowering then reaches
            # inside an option that is not there.
            .opt_type = None
            .any_type = None
            # `nonlocal x` pins the name to the function's own scope, so it
            # survives the block that assigns it — P's rule, reused verbatim
            .depth = 0 if self->fn_nonlocals.has(name) else self->depth
        self->nlocals += 1

    private def pop_scope(self: *PsSema):
        n: i32 = self->nlocals
        while n > 0 and self->locals[n - 1].depth >= self->depth:
            n -= 1
            # 107: o nome morreu com o bloco. Guardar que ele EXISTIU nesta
            # função é o que permite dizer, quando ele for usado depois, que o
            # problema é escopo de bloco (64.1) e não um nome inventado — e
            # apontar o `nonlocal`, que é o opt-in que a própria 64.1 desenhou.
            self->fn_gone.add(self->locals[n].name)
        self->nlocals = n

    # ---------- types ----------
    private def resolve_type(self: *PsSema, t: *PsType) -> *PsType:
        if t == None:
            return None
        match t->kind:
            case PT_NAME:
                # `Error` is built in: one error type with metadata for
                # everything (15.2), and the only thing `catch` ever binds
                if t->qual != None:
                    q2: *PsNsEnt = ns_find(self->cur_ns->quals, self->cur_ns->nquals, t->qual) if self->cur_ns != None else None
                    if q2 == None:
                        fatal_at(self->file, t->pos, "unknown module '%s'", t->qual)
                    ns_check_visible(q2->ns, t->name, self->file, t->pos, q2->orig)
                    t->name = self->a->printf("%s%s", q2->ns->prefix, t->name)
                    t->qual = None
                    if not self->records.has(t->name) and not self->enums.has(t->name):
                        fatal_at(self->file, t->pos, "unknown type '%s'", t->name)
                    t->is_ref = self->is_struct_name(t->name)
                elif strcmp(t->name, "Error") != 0:
                    # 107: os dois tipos que se escrevem com maiúscula e que a
                    # pessoa tenta escrever minúsculos, porque `spawn` e a
                    # chamada de um `async def` os produzem sem nunca serem
                    # escritos — dizer qual é a forma custa uma linha
                    if strcmp(t->name, "worker") == 0 or strcmp(t->name, "task") == 0:
                        fatal_at(self->file, t->pos, "unknown type '%s': it is written `%s<T>`, with the T that crosses the channel — `Worker<int>` for a `spawn` of a function returning int", t->name, "Worker" if strcmp(t->name, "worker") == 0 else "Task")
                    t->name = self->gname(t->name, t->pos)
                    if not self->records.has(t->name) and not self->enums.has(t->name):
                        fatal_at(self->file, t->pos, "unknown type '%s'", t->name)
                t->is_ref = self->is_struct_name(t->name)
            case PT_DYN:
                # `dyn Printable` (66.3): the trait is resolved like any other
                # name, and then the type IS the trait — the concrete type is
                # what the box carries at run time.
                tt: *PsType = ps_type(self->a, PT_NAME, t->pos)
                tt->name = t->name
                tt->qual = t->qual
                td2: *PsDecl = self->find_trait(tt, t->pos)
                # object safety: a method that mentions `Self` anywhere but the
                # receiver cannot be called through a vtable — the caller would
                # have to know the concrete type, which is exactly what `dyn`
                # gave up. Rust draws the line in the same place.
                for i in range(td2->nmethods):
                    tm2: *PsFunc = td2->methods[i]
                    for k in range(tm2->nparams):
                        if ps_mentions(tm2->params[k].type, "Self"):
                            fatal_at(self->file, t->pos, "'%s' cannot be a `dyn`: '%s' takes a `Self`, and through a vtable there is no way to know what Self is", ps_disp(td2->name), tm2->name)
                    if ps_mentions(tm2->ret, "Self"):
                        fatal_at(self->file, t->pos, "'%s' cannot be a `dyn`: '%s' returns `Self`, and through a vtable there is no way to know what Self is", ps_disp(td2->name), tm2->name)
                if td2->assoc != None:
                    fatal_at(self->file, t->pos, "'%s' cannot be a `dyn`: it has an associated type ('%s'), and a vtable does not carry types (66.4)", ps_disp(td2->name), td2->assoc)
                t->name = td2->name
                t->qual = None
                self->note_dyn_trait(td2)
            case PT_SEQ:
                # a sema desaçucara os parâmetros ANTES de resolver o que quer
                # que seja, portanto um `Sequence` que chegue aqui está escrito
                # onde não podia estar. Um valor nunca TEM este tipo: ele diz o
                # que a função aceita, e não o que existe.
                fatal_at(self->file, t->pos, "`Sequence<T>` is only a PARAMETER's type (60.3): it says what a function accepts, and no value ever has it — write the container itself (`List<T>`, `T[N]`, `View<T>`)")
            case PT_OPT:
                if t->inner == None:
                    fatal_at(self->file, t->pos, "an option needs a type: write `T?`")
                if t->inner->kind == PT_OPT:
                    fatal_at(self->file, t->pos, "`T??` does not exist: an option does not nest")
                t->inner = self->resolve_type(t->inner)
            case PT_ARRAY:
                t->inner = self->resolve_type(t->inner)
                # `T[N]`: the size is a CONSTANT EXPRESSION in C, and a
                # `static const int` is not one — that is C++. So a named const
                # used as a size is folded to its number here, where the value
                # is known, instead of being emitted as a name the C compiler
                # would refuse (it emitted an array of no size at all, which
                # became "flexible array member in a struct with no named
                # members" three layers away from the cause).
                # 65.10: e uma CHAMADA a um `const def` também é um número
                # conhecido em compilação — que é literalmente o caso que a
                # 65.10 nomeou ao ser decidida. `check_expr` dobra a chamada no
                # literal, portanto depois desta linha o `count` já é um.
                if t->count != None and t->count->kind == PE_CALL:
                    _ = self->check_expr(t->count)
                if t->count != None and t->count->kind == PE_NAME:
                    cn9: const *char = self->gname_soft(t->count->text)
                    if self->gconst_num.has(cn9):
                        t->count->kind = PE_INT
                        t->count->text = self->a->printf("%lld", self->gconst_num.get_or(cn9, 0))
                    elif self->gconst_num.has(t->count->text):
                        t->count->kind = PE_INT
                        t->count->text = self->a->printf("%lld", self->gconst_num.get_or(t->count->text, 0))
                    else:
                        fatal_at(self->file, t->count->pos, "the size of `T[N]` has to be known at compile time: '%s' is not a `const` with an integer literal (33.4)", t->count->text)
                elif t->count != None and t->count->kind != PE_INT:
                    fatal_at(self->file, t->count->pos, "the size of `T[N]` has to be a number or a `const` with an integer literal, known at compile time (33.4)")
            case PT_LIST, PT_SET, PT_TASK, PT_WORKER:
                t->inner = self->resolve_type(t->inner)
            case PT_DICT:
                t->key = self->resolve_type(t->key)
                t->inner = self->resolve_type(t->inner)
                self->key_ok(t->key, t->pos, "a dict key")
            case PT_VIEW:
                t->inner = self->resolve_type(t->inner)
            case PT_TUPLE, PT_FUNC:
                for i in range(t->nparams):
                    t->params[i] = self->resolve_type(t->params[i])
                t->inner = self->resolve_type(t->inner)
            case PT_CHAN:
                t->inner = self->resolve_type(t->inner)
            case PT_UNKNOWN, PT_INT, PT_FLOAT, PT_BOOL, PT_STR, PT_BYTES, PT_ANY, PT_VOID, PT_FILE, PT_BUFFER, PT_MAPPING, PT_DECODER, PT_DIRITER, PT_WATCHER, PT_TIMER, PT_CONN, PT_PROC, PT_GROUP:
                pass
        return t

    # `T` -> `T?`, para quando o tipo do resultado é "isto pode faltar"
    private def opt_of(self: *PsSema, t: *PsType, pos: Pos) -> *PsType:
        o: *PsType = ps_type(self->a, PT_OPT, pos)
        o->inner = t
        return o

    # Check an expression while SAYING what is wanted. A lambda has no
    # annotations, so the context is the only place its parameter types can come
    # from — and an empty list literal is in the same position.
    private def check_want(self: *PsSema, e: *PsExpr, expect: *PsType, ctx: const *char):
        prev: *PsType = self->hint
        self->hint = expect
        got: *PsType = self->check_expr(e)
        self->hint = prev
        self->want(e, got, expect, ctx)

    private def want(self: *PsSema, e: *PsExpr, got: *PsType, expect: *PsType, ctx: const *char):
        if ps_type_eq(got, expect):
            return
        # a function with a signature fits where SOME function is wanted (29.3):
        # the value carries its own descriptor, so nothing is lost going in —
        # and coming back out takes narrowing, which is checked (29.4)
        if expect != None and expect->kind == PT_FUNC and expect->wide and got != None and got->kind == PT_FUNC:
            return
        # exact widths (68.2): a literal adapts with its range checked; a value
        # WIDENS when nothing can be lost; everything else converts by name
        if ps_adapt_lit(self->file, e, expect):
            return
        if ps_int_widens(got, expect):
            return
        if expect != None and expect->kind == PT_FLOAT and expect->width == 0 and got != None and got->kind == PT_FLOAT and got->width == 32:
            return      # f32 -> float is lossless
        # anything at all where an `any` is wanted (39.2): a str, a list or a
        # dict goes in as ITSELF — it is already an object with a header — and a
        # number, a bool or None gets a box. Reading it back is `as`, checked.
        if expect != None and expect->kind == PT_ANY and got != None and got->kind != PT_ANY:
            match got->kind:
                case PT_LIST, PT_DICT:
                    # what goes inside has to carry its own type too, or reading
                    # it back would be reading bytes nobody tagged (39.2)
                    if got->inner == None or got->inner->kind != PT_ANY:
                        fatal_at(self->file, e->pos, "an `any` holds %s only when its elements are `any` too: write `List<any>`/`Dict<str, any>`, because what is inside has to carry its own type (39.2)", "a list" if got->kind == PT_LIST else "a dict")
                    e->box_any = True
                    return
                case PT_INT, PT_FLOAT, PT_BOOL, PT_STR:
                    e->box_any = True
                    return
                case PT_OPT:
                    if got->inner == None:
                        e->box_any = True
                        return
                case _:
                    pass
            fatal_at(self->file, e->pos, "an `any` holds numbers, bools, strings, lists, dicts and None so far, not %s (39.2)", ps_type_str(self->a, got))
        # a record where a `dyn Trait` is wanted (66.3): BOXED here, and the
        # conversion is written down on the node so the lowering knows to do it.
        # Nominal, like every other use of a trait (66.2).
        if expect != None and expect->kind == PT_DYN and got != None and got->kind == PT_NAME:
            if not self->timpls.has(self->a->printf("%s|%s", expect->name, got->name)):
                fatal_at(self->file, e->pos, "%s does not implement '%s' (66.2)", ps_type_str(self->a, got), ps_disp(expect->name))
            e->box_to = expect
            self->note_dyn(expect->name, got->name)
            return
        # non-null is the DEFAULT (9.4), so the conversions go one way only:
        # a `T` is a valid `T?`, and a bare `None` is the empty of any option.
        if expect != None and expect->kind == PT_OPT:
            if got != None and got->kind == PT_OPT and got->inner == None:
                return      # bare None
            if ps_type_eq(got, expect->inner):
                return
            if expect->inner != None and expect->inner->kind == PT_FLOAT and got != None and got->kind == PT_INT:
                return
        # int -> float is the ONE implicit promotion (32.1); everything else,
        # including bool to int, is written out by hand. It targets the DEFAULT
        # float: an int into an f32 loses precision, so that one is `f32(x)`.
        if expect != None and expect->kind == PT_FLOAT and expect->width == 0 and got != None and got->kind == PT_INT:
            return
        fatal_at(self->file, e->pos, "%s expects %s, found %s", ctx, ps_type_str(self->a, expect), ps_type_str(self->a, got))

    # ---------- expressions ----------
    private def check_expr(self: *PsSema, e: *PsExpr) -> *PsType:
        if e == None:
            return None
        if e->sug_done:
            return e->type
        if e->dflt_bound:
            # a substituted default (44.1): already checked where it was
            # WRITTEN, and looking again here would resolve its names in the
            # caller's scope instead
            return e->type
        t: *PsType = None
        match e->kind:
            case PE_INT:
                t = ps_type(self->a, PT_INT, e->pos)
                if self->hint != None and self->hint->kind == PT_INT and self->hint->width != 0:
                    # a literal ADAPTS to the width the context asks for
                    # (68.2), with the range checked here — out of range is a
                    # compile error, not a runtime surprise
                    ps_lit_fits(self->file, e, self->hint)
                    t = self->hint
                elif self->hint != None and self->hint->kind == PT_FLOAT:
                    # `x: f32 = 1` — the one implicit promotion (32.1), width
                    # and all: a literal has no precision to lose
                    t = self->hint
            case PE_FLOAT:
                t = ps_type(self->a, PT_FLOAT, e->pos)
                if self->hint != None and self->hint->kind == PT_FLOAT and self->hint->width == 32:
                    t = self->hint
            case PE_STR:
                t = ps_type(self->a, PT_STR, e->pos)
            case PE_BYTES:
                t = ps_type(self->a, PT_BYTES, e->pos)
            case PE_BOOL:
                t = ps_type(self->a, PT_BOOL, e->pos)
            case PE_NONE:
                # `None` on its own is the EMPTY of an option whose T the
                # context supplies (9.4). It unifies with any `T?`.
                t = ps_type(self->a, PT_OPT, e->pos)
            case PE_NAME:
                li: i32 = self->find_local(e->text)
                if li >= 0:
                    if not self->locals[li].assigned:
                        fatal_at(self->file, e->pos, "'%s' is used before it is assigned on every path", e->text)
                    # a top-level name is a local AND a module variable: the
                    # same storage, which lives in the context (42.2)
                    e->is_gref = self->locals[li].is_module
                    if self->lam_fr.len > 0 and not self->locals[li].is_module:
                        # a local from OUTSIDE a lambda, read inside it:
                        # CAPTURED, by value, at the moment the lambda is made
                        # (19.2). Every enclosing lambda that the name also
                        # comes from outside of captures it too, because that
                        # is the only way it reaches the inner one.
                        for fi in range(self->lam_fr.len):
                            if li >= self->lam_fr.data[fi].base:
                                continue
                            seen7: bool = False
                            for ci in range(self->lam_fr.data[fi].caps.len):
                                if strcmp(self->lam_fr.data[fi].caps.data[ci].name, e->text) == 0:
                                    seen7 = True
                            if not seen7:
                                cp7: PsParam = {0}
                                cp7.name = e->text
                                cp7.type = self->locals[li].type
                                cp7.pos = e->pos
                                self->lam_fr.data[fi].caps.push(cp7)
                    t = self->locals[li].type
                    # narrowed (43.1): the variable holds `T?` and this read is
                    # a `T`, so the lowering must reach inside the option
                    e->narrowed = self->locals[li].opt_type != None
                    if self->locals[li].any_type != None:
                        # `match type(x)` proved the kind (68.5): the variable
                        # is still `any`, so the read reaches inside it
                        e->any_cast = self->locals[li].any_type
                        t = self->locals[li].any_type
                else:
                    # a constant a C header gave (72.4): the read IS the
                    # number, so nothing of the header survives into the program
                    if self->cconsts.has(e->text) and not self->globals.has(e->text) and not self->funcs.has(e->text):
                        cl9: *PsExpr = self->cconsts.get_or(e->text, None)
                        pp9: Pos = e->pos
                        *e = *cl9
                        e->pos = pp9
                        return self->check_expr(e)
                    # not a local: the name is resolved in the module's
                    # NAMESPACE, and what comes back is the renamed global the
                    # rest of the compiler sees from here on (41.3)
                    e->text = self->gname(e->text, e->pos)
                    # `parent` is the pipe back to whoever spawned this worker
                    # (36.1). It is a NAME and not a keyword: a program that has
                    # its own `parent` keeps it, because the local and the
                    # module variable are both looked at first.
                    e->is_gref = self->globals.has(e->text)
                    # a function named but not called is a VALUE (28.1): a
                    # closure with nothing captured
                    if not self->globals.has(e->text) and self->funcs.has(e->text):
                        fv7: *PsFunc = self->funcs.get_or(e->text, None)
                        if fv7->ntparams == 0:
                            ft7: *PsType = ps_type(self->a, PT_FUNC, e->pos)
                            ft7->params = self->a->alloc(usize(fv7->nparams + 1) * sizeof(*ft7->params))
                            for i in range(fv7->nparams):
                                ft7->params[i] = fv7->params[i].type
                            ft7->nparams = fv7->nparams
                            fr7t: *PsType = fv7->ret if fv7->ret != None else ps_type(self->a, PT_VOID, e->pos)
                            if fv7->is_async:
                                # an `async def` named but not called is a value
                                # too (28.1): calling it hands back a task, so
                                # that is what its type says. The symbol behind
                                # it is the START function, which already has
                                # exactly that shape.
                                at7: *PsType = ps_type(self->a, PT_TASK, e->pos)
                                at7->inner = fr7t
                                fr7t = at7
                            ft7->inner = fr7t
                            e->is_gref = False
                            e->is_fnval = True
                            t = ft7
                            break_out7: bool = True
                            if break_out7:
                                e->type = t
                                return t
                    # `sys.argv` and `sys.env` are VALUES, not calls (48.3)
                    if strncmp(e->text, "__math_", 7) == 0 and (strcmp(e->text + 7, "pi") == 0 or strcmp(e->text + 7, "e") == 0 or strcmp(e->text + 7, "tau") == 0 or strcmp(e->text + 7, "inf") == 0 or strcmp(e->text + 7, "nan") == 0):
                        # 103: as constantes são VALORES, como `sys.argv` é
                        t = ps_type(self->a, PT_FLOAT, e->pos)
                    elif strcmp(e->text, "__os_SEQUENTIAL") == 0 or strcmp(e->text, "__os_RANDOM") == 0 or strcmp(e->text, "__os_WILLNEED") == 0:
                        # 137.1: as três que fazem valer o tipo próprio. São
                        # VALORES, como `sys.argv` é, e o que elas nomeiam é o
                        # que se diz ao núcleo sobre COMO o mapa vai ser lido.
                        t = ps_type(self->a, PT_INT, e->pos)
                    elif strcmp(e->text, "__sys_argv") == 0:
                        av: *PsType = ps_type(self->a, PT_LIST, e->pos)
                        av->inner = ps_type(self->a, PT_STR, e->pos)
                        t = av
                    elif strcmp(e->text, "__sys_out") == 0 or strcmp(e->text, "__sys_err") == 0:
                        # 78.2: the two standard streams as ordinary files, so
                        # writing to them is the same awaitable operation as
                        # writing anywhere else. Closing one is a no-op: they
                        # belong to the process, not to the program.
                        t = ps_type(self->a, PT_FILE, e->pos)
                    elif strcmp(e->text, "__sys_env") == 0:
                        ev: *PsType = ps_type(self->a, PT_DICT, e->pos)
                        ev->key = ps_type(self->a, PT_STR, e->pos)
                        ev->inner = ps_type(self->a, PT_STR, e->pos)
                        t = ev
                    elif strcmp(e->text, "parent") == 0 and not self->globals.has(e->text):
                        pw: *PsType = ps_type(self->a, PT_WORKER, e->pos)
                        pw->inner = self->cur_ret if self->cur_ret != None else ps_type(self->a, PT_VOID, e->pos)
                        t = pw
                    elif self->globals.has(e->text):
                        t = self->globals.get_or(e->text, None)
                    elif self->enumof.has(e->text):
                        ed: *PsDecl = self->enumof.get_or(e->text, None)
                        t = ps_type(self->a, PT_NAME, e->pos)
                        t->name = ed->name
                    else:
                        pdt: *PsType = self->predef(e)
                        if pdt == None:
                            if self->fn_gone.has(e->text):
                                fatal_at(self->file, e->pos, "'%s' was declared inside a block and died with it (64.1): write `nonlocal %s` before the block, and the assignment there lives at the function's scope", e->text, e->text)
                            fatal_at(self->file, e->pos, "unknown name '%s'", e->text)
                        t = pdt
            case PE_AWAIT:
                # `await t` collects what a task produced (35.3), and raises
                # again what it raised (19.3). Only an `async def` and the top
                # level may wait — the top level because the implicit main IS
                # async (39.4).
                if not self->in_async and not self->at_module:
                    fatal_at(self->file, e->pos, "`await` outside an `async def`: only an async function and the top level can wait (39.4)")
                if self->nogc_depth > 0:
                    fatal_at(self->file, e->pos, "`await` inside `nogc:`: waiting lets another task run in this same heap, and it would allocate with the collector off (26.5.1)")
                wt: *PsType = self->check_expr(e->lhs)
                if wt == None or wt->kind != PT_TASK:
                    fatal_at(self->file, e->pos, "`await` takes a task — what calling an `async def` gives back (35.3) — found %s", ps_type_str(self->a, wt))
                t = wt->inner
            case PE_SPAWN:
                # `spawn(f, (a, b))` (35.1): one spawn is one OS THREAD, with a
                # heap and a collector of its own — never a pool, because a pool
                # would put two jobs in one heap and the isolation is the point.
                #
                # The entry function CAPTURES NOTHING: it gets only what was
                # sent, which is what makes the isolation true by construction.
                # And what crosses is BYTES (34.3), so the parameters and the
                # message type have to be types made of bytes.
                if e->lhs == None or e->lhs->kind != PE_TUPLE or e->lhs->nargs != 2 or e->lhs->args[0]->kind != PE_NAME:
                    fatal_at(self->file, e->pos, "spawn takes a function and its arguments: `spawn(work, (a, b))` (35.1)")
                wn: const *char = self->gname(e->lhs->args[0]->text, e->pos)
                if not self->funcs.has(wn):
                    fatal_at(self->file, e->pos, "spawn needs a function of this program: '%s' is not one (35.1)", ps_disp(wn))
                wf: *PsFunc = self->funcs.get_or(wn, None)
                if wf->ntparams > 0:
                    fatal_at(self->file, e->pos, "a worker starts in a plain function: '%s' is generic", ps_disp(wn))
                # an `async def` IS allowed as a worker entry (76.1): the thread
                # has a scheduler of its own and drives it the way the top level
                # does. That is what lets a worker do I/O without stopping the
                # tasks it started itself.
                at6: *PsExpr = e->lhs->args[1]
                nsent: i32 = at6->nargs if at6->kind == PE_TUPLE else 1
                if nsent != wf->nparams:
                    fatal_at(self->file, e->pos, "'%s' takes %d argument(s), %d sent", ps_disp(wn), wf->nparams, nsent)
                for i in range(nsent):
                    ae: *PsExpr = at6->args[i] if at6->kind == PE_TUPLE else at6
                    aty: *PsType = self->check_expr(ae)
                    self->want(ae, aty, wf->params[i].type, self->a->printf("parameter '%s'", wf->params[i].name))
                    # a `str` argument crosses as BYTES and is rebuilt on the
                    # other side (34.3): the copy ladder, for the one collected
                    # type that already has it
                    pty: *PsType = wf->params[i].type
                    if pty != None and pty->kind == PT_STR:
                        pass
                    elif pty != None and pty->kind == PT_LIST and pty->inner != None and not opt_is_ref_ps(pty->inner):
                        # a list of PURE BYTES crosses whole (34.3): copied out
                        # here, rebuilt there. A list of references would need
                        # each of them serialized, which is the rung above.
                        self->pod_only(pty->inner, e->pos, "the element of a list sent to a worker")
                    else:
                        self->pod_only(pty, e->pos, "an argument to a worker")
                if wf->ret != None and wf->ret->kind != PT_VOID:
                    # 34.3: bytes cross by memcpy, and what is not bytes is
                    # SERIALIZED — a `str` as its characters, a `list` of bytes
                    # as a count and its elements. Nothing of one heap ever
                    # reaches another either way.
                    self->sendable(wf->ret, e->pos, "a message from a worker")
                e->spawn_fn = wn
                wt6: *PsType = ps_type(self->a, PT_WORKER, e->pos)
                wt6->inner = wf->ret if wf->ret != None else ps_type(self->a, PT_VOID, e->pos)
                t = wt6
            case PE_LAMBDA:
                # A lambda has no annotations — Python's shape — so its
                # parameter types come from the CONTEXT: the annotation on the
                # variable, the field, the parameter it is passed to. Without
                # one there is nothing to infer from, and the message says so.
                # 112: um `def(...)?` também é contexto — a lambda vai para
                # dentro do opcional. Um SINAL que ninguém ligou é ausente, e é
                # por isso que o campo é opcional; quem liga passa a lambda, e
                # ela não deixa de ter contexto por causa do `?`.
                lhint: *PsType = self->hint
                if lhint != None and lhint->kind == PT_OPT and lhint->inner != None:
                    lhint = lhint->inner
                if lhint == None or lhint->kind != PT_FUNC:
                    fatal_at(self->file, e->pos, "the type of this lambda cannot be inferred: annotate what receives it, as in `f: def(float) -> float = lambda v: v * 2.0`")
                lh: *PsType = lhint
                if e->is_async_lam:
                    # 78.3: an `async lambda` is TWO things that already work —
                    # an `async def` for the body (the state machine) and an
                    # ordinary lambda that calls it (the closure environment).
                    # Composing them is what would be new; putting one on top
                    # of the other is not.
                    if lh->inner == None or lh->inner->kind != PT_TASK:
                        fatal_at(self->file, e->pos, "an `async lambda` hands back a task: the type that receives it says so, as in `f: def(int) -> Task<int> = async lambda x: ...`")
                    self->check_async_lambda(e, lh)
                    e->type = lh
                    return lh
                if lh->nparams != e->nparams:
                    fatal_at(self->file, e->pos, "this lambda takes %d parameter(s); %s asks for %d", e->nparams, ps_type_str(self->a, lh), lh->nparams)
                fr7: PsLamF = {0}
                fr7.base = self->nlocals
                fr7.caps.init()
                self->lam_fr.push(fr7)
                self->depth += 1
                for i in range(e->nparams):
                    e->params[i].type = lh->params[i]
                    self->add_local(e->params[i].name, lh->params[i], True, True)
                prevh2: *PsType = self->hint
                self->hint = lh->inner
                bt7: *PsType = self->check_expr(e->lhs)
                self->hint = prevh2
                if lh->inner != None and lh->inner->kind != PT_VOID:
                    self->want(e->lhs, bt7, lh->inner, "the body of this lambda")
                self->pop_scope()
                self->depth -= 1
                top7: i32 = self->lam_fr.len - 1
                e->caps = self->lam_fr.data[top7].caps.data
                e->ncaps = self->lam_fr.data[top7].caps.len
                self->lam_fr.len -= 1
                t = lh
            case PE_ASYNCBLK:
                # 78.3: the block becomes an `async def` of its own, whose
                # PARAMETERS are what it captured. The capture analysis is the
                # lambda's (19.2) — a name from outside, read inside, travels
                # by value — and the rewrite is a call to that function, so
                # from here on it is an ordinary task.
                fr8: PsLamF = {0}
                fr8.base = self->nlocals
                fr8.caps.init()
                self->lam_fr.push(fr8)
                self->depth += 1
                prevret: *PsType = self->cur_ret
                previn: bool = self->in_async
                self->cur_ret = ps_type(self->a, PT_VOID, e->pos)
                self->in_async = True
                self->check_block(e->body)
                self->cur_ret = prevret
                self->in_async = previn
                self->pop_scope()
                self->depth -= 1
                tp8: i32 = self->lam_fr.len - 1
                caps8: *PsParam = self->lam_fr.data[tp8].caps.data
                nc8: i32 = self->lam_fr.data[tp8].caps.len
                self->lam_fr.len -= 1
                fn8: *PsFunc = self->a->alloc(sizeof(PsFunc))
                fn8->name = self->a->printf("__ablk%d", self->nablk)
                self->nablk += 1
                fn8->params = caps8
                fn8->nparams = nc8
                fn8->ret = ps_type(self->a, PT_VOID, e->pos)
                fn8->body = e->body
                fn8->is_async = True
                fn8->pos = e->pos
                dcl8: *PsDecl = ps_decl(self->a, PD_FUNC, e->pos)
                dcl8->name = fn8->name
                dcl8->func = fn8
                self->ablks.push(dcl8)
                self->funcs.put(fn8->name, fn8)
                # the expression IS the call now
                args8: **PsExpr = self->a->alloc(usize(nc8 + 1) * sizeof(*args8))
                for i in range(nc8):
                    nm8: *PsExpr = ps_expr(self->a, PE_NAME, e->pos)
                    nm8->text = caps8[i].name
                    nm8->type = caps8[i].type
                    args8[i] = nm8
                cal8: *PsExpr = ps_expr(self->a, PE_NAME, e->pos)
                cal8->text = fn8->name
                with e:
                    .kind = PE_CALL
                    .lhs = cal8
                    .args = args8
                    .nargs = nc8
                    .body = None
                tk8: *PsType = ps_type(self->a, PT_TASK, e->pos)
                tk8->inner = ps_type(self->a, PT_VOID, e->pos)
                t = tk8
            case PE_CAST:
                # `x as T` (55.2) UNBOXES an `any`, and it is CHECKED: the tag
                # has to agree or it raises. Converting between numbers is a
                # different operation and has a different name — `int(x)`.
                ct9: *PsType = self->check_expr(e->lhs)
                if ct9 != None and ct9->kind == PT_FUNC:
                    # 29.4: narrowing a `def` — the descriptor the value carries
                    # has to agree, and it raises when it does not. What comes
                    # out is an ordinary function value, called with no boxing.
                    nt9: *PsType = self->resolve_type(e->type)
                    if nt9 == None or nt9->kind != PT_FUNC or nt9->wide:
                        fatal_at(self->file, e->pos, "a `def` narrows to a SIGNATURE: `f as def(str) -> bool` (29.4)")
                    t = nt9
                    e->type = nt9
                    break_fn9: bool = True
                    if break_fn9:
                        e->type = t
                        return t
                if ct9 == None or ct9->kind != PT_ANY:
                    fatal_at(self->file, e->pos, "`as` reads an `any` (55.2); to convert a number, write `int(x)` or `float(x)` — found %s", ps_type_str(self->a, ct9))
                t = self->resolve_type(e->type)
                if t == None or t->kind not in {PT_INT, PT_FLOAT, PT_BOOL, PT_STR, PT_LIST, PT_DICT}:
                    fatal_at(self->file, e->pos, "`as %s` is not compiled yet: an `any` holds numbers, bools, strings, lists and dicts so far", ps_type_str(self->a, t))
            case PE_IS:
                # `a is b` is IDENTITY (22.2): the same object, not an equal
                # one. Only a reference has an identity to compare — a number
                # or a record IS its value, and `==` is the question for those.
                il9: *PsType = self->check_expr(e->lhs)
                ir9: *PsType = self->check_expr(e->rhs)
                if not ps_is_ref_type(il9) or not ps_is_ref_type(ir9):
                    fatal_at(self->file, e->pos, "`is` compares IDENTITY, which only a reference has (22.2): for a number, a record or a string's content, `==` is the question")
                t = ps_type(self->a, PT_BOOL, e->pos)
            case PE_UNARY:
                ot: *PsType = self->check_expr(e->lhs)
                if e->op == TK_NOT:
                    self->want(e->lhs, ot, ps_type(self->a, PT_BOOL, e->pos), "'not'")
                    t = ps_type(self->a, PT_BOOL, e->pos)
                elif e->op == TK_TILDE:
                    self->want(e->lhs, ot, ps_type(self->a, PT_INT, e->pos), "'~'")
                    t = ot
                else:
                    if ot == None or (ot->kind != PT_INT and ot->kind != PT_FLOAT):
                        fatal_at(self->file, e->pos, "unary '%s' expects a number, found %s", "-" if e->op == TK_MINUS else "+", ps_type_str(self->a, ot))
                    if e->op == TK_MINUS and ot->kind == PT_INT and ot->uns:
                        fatal_at(self->file, e->pos, "unary '-' on %s: an unsigned value has no negative — `0 %%- x` is the wrap, int(x) the conversion (68.2)", ps_type_str(self->a, ot))
                    t = ot
            case PE_BINARY:
                t = self->check_binary(e)
            case PE_CALL:
                t = self->check_call(e)
            case PE_TERNARY:
                ct: *PsType = self->check_expr(e->cond)
                self->want(e->cond, ct, ps_type(self->a, PT_BOOL, e->pos), "a conditional expression")
                at: *PsType = self->check_expr(e->lhs)
                bt: *PsType = self->check_expr(e->rhs)
                # both arms must agree; int/float mixes settle on float (32.1)
                if ps_type_eq(at, bt):
                    t = at
                elif at != None and bt != None and at->kind == PT_INT and bt->kind == PT_FLOAT:
                    t = bt
                elif at != None and bt != None and at->kind == PT_FLOAT and bt->kind == PT_INT:
                    t = at
                # 113: um dos lados é `None`, o outro é um tipo — o resultado é
                # o OPCIONAL desse tipo. `None if x else "a"` é como se escreve
                # "isto pode não ter valor" numa expressão, e recusá-lo obrigava
                # a um `if` de três linhas para dizer o mesmo.
                elif at != None and at->kind == PT_OPT and at->inner == None and bt != None:
                    t = bt if bt->kind == PT_OPT else self->opt_of(bt, e->pos)
                elif bt != None and bt->kind == PT_OPT and bt->inner == None and at != None:
                    t = at if at->kind == PT_OPT else self->opt_of(at, e->pos)
                else:
                    fatal_at(self->file, e->pos, "the two arms of a conditional expression differ: %s and %s", ps_type_str(self->a, at), ps_type_str(self->a, bt))
            case PE_LIST:
                # An `any` holding a list holds a `List<any>` (39.2): the value
                # inside has to carry its own type, and only `any` elements do.
                if self->hint != None and self->hint->kind == PT_ANY:
                    la9: *PsType = ps_type(self->a, PT_LIST, e->pos)
                    la9->inner = ps_type(self->a, PT_ANY, e->pos)
                    self->hint = la9
                # a homogeneous literal INFERS its element type (4.1/27.3); an
                # empty one needs the annotation to say what it holds
                if e->nargs == 0:
                    # nothing to infer from, so the annotation has to say it
                    if self->hint == None or self->hint->kind != PT_LIST:
                        fatal_at(self->file, e->pos, "an empty list literal needs a type: `xs: List<int> = []`")
                    t = self->hint
                    e->type = t
                    return t
                # `xs: int[3] = [1, 2, 3]` — the same literal fills a FIXED
                # array (33.4), and then nothing is allocated at all: the
                # elements live where the variable lives.
                if self->hint != None and self->hint->kind == PT_ARRAY:
                    at9: *PsType = self->hint
                    n9: i64 = 0
                    ok9: bool = ps_const_len(at9->count, ref n9)
                    if ok9 and i64(e->nargs) != n9:
                        fatal_at(self->file, e->pos, "this literal has %d element(s); %s holds %lld", e->nargs, ps_type_str(self->a, at9), n9)
                    for i in range(e->nargs):
                        self->check_want(e->args[i], at9->inner, "an element of this array")
                    e->type = at9
                    return at9
                # the ANNOTATION wins when there is one: `List<dyn Shape>` is
                # exactly the case where the elements differ from each other on
                # purpose and each one converts (66.3)
                want_e: *PsType = self->hint->inner if self->hint != None and self->hint->kind == PT_LIST else None
                lt2: *PsType = want_e
                if lt2 == None:
                    lt2 = self->check_expr(e->args[0])
                    for i in range(1, e->nargs):
                        at3: *PsType = self->check_expr(e->args[i])
                        if not ps_type_eq(at3, lt2):
                            fatal_at(self->file, e->args[i]->pos, "a list is homogeneous: this element is %s, the first was %s", ps_type_str(self->a, at3), ps_type_str(self->a, lt2))
                else:
                    prevh2: *PsType = self->hint
                    self->hint = lt2
                    for i in range(e->nargs):
                        at4: *PsType = self->check_expr(e->args[i])
                        self->want(e->args[i], at4, lt2, "an element of this list")
                    self->hint = prevh2
                lw: *PsType = ps_type(self->a, PT_LIST, e->pos)
                lw->inner = lt2
                t = lw
            case PE_INDEX:
                # neither the container nor the index inherits the type the
                # SURROUNDINGS expect: in `Vec(trio[0] as float, ...)` the
                # float belongs to the result, and letting it reach the `0`
                # would index a list with a floating point number
                prevhx: *PsType = self->hint
                self->hint = None
                ct3: *PsType = self->check_expr(e->lhs)
                it3: *PsType = self->check_expr(e->rhs)
                self->hint = prevhx
                if ct3 != None and ct3->kind == PT_TUPLE:
                    # 98.1: `t[0]`. The index has to be a LITERAL, and not
                    # because it is easier: each slot of a tuple has its own
                    # type, so `t[i]` with a runtime `i` has no type at all.
                    # That is the difference between a tuple and a list, and it
                    # is why one is written with `(` and the other with `[`.
                    if e->rhs->kind != PE_INT:
                        fatal_at(self->file, e->rhs->pos, "the index of a tuple has to be a literal number: each slot has its own type, so `t[i]` with a variable would have no type (98.1)")
                    ix9: i64 = strtoll(e->rhs->text, None, 0)
                    if ix9 < 0 or ix9 >= i64(ct3->nparams):
                        fatal_at(self->file, e->rhs->pos, "this tuple has %d slots, so %lld is out of range", ct3->nparams, ix9)
                    e->type = ct3->params[ix9]
                    return e->type
                if ct3 != None and ct3->kind == PT_ARRAY:
                    # a fixed array knows its size, so the check is a compare
                    # against a constant — indexing still RAISES (5.2)
                    self->want(e->rhs, it3, ps_type(self->a, PT_INT, e->pos), "an index")
                    e->type = ct3->inner
                    return ct3->inner
                if ct3 == None or ct3->kind != PT_DICT:
                    self->want(e->rhs, it3, ps_type(self->a, PT_INT, e->pos), "an index")
                if ct3 != None and ct3->kind == PT_DICT:
                    self->want(e->rhs, it3, ct3->key, "a dict key")
                    t = ct3->inner
                elif ct3 != None and ct3->kind == PT_STR:
                    t = ct3        # `s[i]` is the i-th CHARACTER, a 1-char string (3.4)
                elif ct3 != None and ct3->kind == PT_BYTES:
                    # `b[i]` is a NUMBER, and that is the one place `bytes` and
                    # `str` deliberately answer differently. A character has no
                    # type of its own (3.4), so `s[i]` can only be a string; a
                    # byte does have one, and `b[0] == 0x7f` is what reading a
                    # binary format looks like.
                    bu9: *PsType = ps_type(self->a, PT_INT, e->pos)
                    bu9->width = 8
                    bu9->uns = True
                    t = bu9
                elif ct3 != None and ct3->kind == PT_VIEW:
                    t = ct3->inner
                elif ct3 != None and ct3->kind == PT_BUFFER:
                    # 135.5: as operações valem nos DOIS. `b[i]` num Buffer é um
                    # byte, pela mesma razão que num `bytes` é: um byte tem tipo
                    # próprio e um carácter não (3.4).
                    bu8: *PsType = ps_type(self->a, PT_INT, e->pos)
                    bu8->width = 8
                    bu8->uns = True
                    t = bu8
                elif ct3 == None or ct3->kind != PT_LIST:
                    fatal_at(self->file, e->pos, "indexing %s is not compiled yet (str, bytes, List and View work)", ps_type_str(self->a, ct3))
                else:
                    t = ct3->inner
            case PE_DICT:
                if self->hint != None and self->hint->kind == PT_ANY:
                    da9: *PsType = ps_type(self->a, PT_DICT, e->pos)
                    da9->key = ps_type(self->a, PT_STR, e->pos)
                    da9->inner = ps_type(self->a, PT_ANY, e->pos)
                    self->hint = da9
                if e->nargs == 0:
                    if self->hint == None or self->hint->kind != PT_DICT:
                        fatal_at(self->file, e->pos, "an empty dict literal needs a type: `d: Dict<str, int> = {}`")
                    t = self->hint
                    e->type = t
                    return t
                # the ANNOTATION wins when there is one, exactly as for a list:
                # it is what a lambda in a value position has to read its
                # parameter types from
                hk: *PsType = self->hint->key if self->hint != None and self->hint->kind == PT_DICT else None
                hv: *PsType = self->hint->inner if self->hint != None and self->hint->kind == PT_DICT else None
                kt: *PsType = hk
                vt5: *PsType = hv
                if kt == None:
                    kt = self->check_expr(e->args[0]->lhs)
                else:
                    self->check_want(e->args[0]->lhs, kt, "a dict key")
                if vt5 == None:
                    vt5 = self->check_expr(e->args[0]->rhs)
                else:
                    self->check_want(e->args[0]->rhs, vt5, "a dict value")
                self->key_ok(kt, e->pos, "a dict key")
                for i in range(1, e->nargs):
                    self->check_want(e->args[i]->lhs, kt, "a dict key")
                    self->check_want(e->args[i]->rhs, vt5, "a dict value")
                dw: *PsType = ps_type(self->a, PT_DICT, e->pos)
                dw->key = kt
                dw->inner = vt5
                t = dw
            case PE_SET:
                if e->nargs == 0:
                    # `Set<T>()`: the parser already read the element type onto
                    # the node, and there is nothing to infer from
                    if e->type != None and e->type->kind == PT_SET:
                        t = self->resolve_type(e->type)
                        e->type = t
                        return t
                    fatal_at(self->file, e->pos, "`{}` is the empty DICT; an empty set is `Set<T>()`")
                et5: *PsType = self->check_expr(e->args[0])
                self->key_ok(et5, e->pos, "a set element")
                for i in range(1, e->nargs):
                    self->want(e->args[i], self->check_expr(e->args[i]), et5, "a set element")
                sw: *PsType = ps_type(self->a, PT_SET, e->pos)
                sw->inner = et5
                t = sw
            case PE_COMPREHEND:
                # 104: `enumerate`/`zip`/`reversed` aqui também — a reescrita
                # troca o iterável por um range e deixa as amarrações no nó
                self->sug_comp(e)
                # `[e for x in xs if c]` (8.1) — and the same over braces: a SET
                # comprehension when the element is one expression, a DICT
                # comprehension when it is `k: v`. Which of the three it is
                # comes from the bracket the parser closed with, because `{...}`
                # cannot tell a set from a dict by looking at the element alone.
                cset: bool = e->op == TK_RBRACE and e->lhs != None and e->lhs->kind != PE_DESIG
                cdict: bool = e->op == TK_RBRACE and e->lhs != None and e->lhs->kind == PE_DESIG
                # The iterable is checked first, because it is what gives the
                # loop variable its type — and `range(...)` is recognised by
                # SHAPE here for the same reason it is in a `for` statement
                # (there is no range object to hold, and `[i for i in
                # range(n)]` is the most common comprehension there is).
                crange: bool = e->rhs != None and e->rhs->kind == PE_CALL and e->rhs->lhs != None and e->rhs->lhs->kind == PE_NAME and strcmp(e->rhs->lhs->text, "range") == 0
                ivt: *PsType = None
                if crange:
                    if e->rhs->nargs < 1 or e->rhs->nargs > 3:
                        fatal_at(self->file, e->pos, "range() takes one, two or three arguments")
                    for ri in range(e->rhs->nargs):
                        self->want(e->rhs->args[ri], self->check_expr(e->rhs->args[ri]), ps_type(self->a, PT_INT, e->pos), "a bound of range()")
                    ivt = ps_type(self->a, PT_INT, e->pos)
                else:
                    sit: *PsType = self->check_expr(e->rhs)
                    if sit == None or sit->kind not in {PT_LIST, PT_SET, PT_DICT, PT_STR}:
                        fatal_at(self->file, e->pos, "a comprehension iterates a list, a dict, a set, a string or a range, not %s", ps_type_str(self->a, sit))
                    if sit->kind == PT_DICT:
                        ivt = sit->key
                    elif sit->kind == PT_STR:
                        # 72.3: over a string the loop yields CHARACTERS
                        ivt = ps_type(self->a, PT_STR, e->pos)
                    else:
                        ivt = sit->inner
                # An annotation on what receives it wins over inference, the
                # same way a list literal reads its element type from the
                # variable it is assigned to.
                chint: *PsType = self->hint
                hit: bool = chint != None and ((cdict and chint->kind == PT_DICT) or (cset and chint->kind == PT_SET) or (not cdict and not cset and chint->kind == PT_LIST))
                self->depth += 1
                self->add_local(e->var, ivt, True, False)
                # as amarrações da 104 são locais do CORPO, tipadas aqui: o
                # lowering só as emite, e por isso não precisa saber indexar
                for si in range(e->nsug):
                    svt: *PsType = self->check_expr(e->sug_vals[si])
                    if svt == None or svt->kind == PT_VOID:
                        fatal_at(self->file, e->pos, "internal: the comprehension binding for '%s' has no type", e->sug_names[si])
                    self->add_local(e->sug_names[si], svt, True, False)
                if e->cond != None:
                    self->want(e->cond, self->check_expr(e->cond), ps_type(self->a, PT_BOOL, e->pos), "a comprehension filter")
                elt: *PsType = None
                cvt: *PsType = None
                if cdict:
                    if hit:
                        self->check_want(e->lhs->lhs, chint->key, "a dict comprehension key")
                        self->check_want(e->lhs->rhs, chint->inner, "a dict comprehension value")
                        elt = chint->key
                        cvt = chint->inner
                    else:
                        elt = self->check_expr(e->lhs->lhs)
                        cvt = self->check_expr(e->lhs->rhs)
                    self->key_ok(elt, e->pos, "a dict comprehension key")
                else:
                    if hit:
                        self->check_want(e->lhs, chint->inner, "a comprehension element")
                        elt = chint->inner
                    else:
                        elt = self->check_expr(e->lhs)
                    if cset:
                        self->key_ok(elt, e->pos, "a set element")
                self->pop_scope()
                self->depth -= 1
                if elt == None or elt->kind == PT_VOID:
                    fatal_at(self->file, e->pos, "a comprehension element has no value")
                if cdict and (cvt == None or cvt->kind == PT_VOID):
                    fatal_at(self->file, e->pos, "a dict comprehension value has no value")
                cw: *PsType = ps_type(self->a, PT_DICT if cdict else (PT_SET if cset else PT_LIST), e->pos)
                if cdict:
                    cw->key = elt
                    cw->inner = cvt
                else:
                    cw->inner = elt
                t = cw
            case PE_SLICE:
                st4: *PsType = self->check_expr(e->lhs)
                if st4 == None or (st4->kind != PT_STR and st4->kind != PT_BYTES and st4->kind != PT_LIST and st4->kind != PT_VIEW and st4->kind != PT_BUFFER and st4->kind != PT_MAPPING):
                    fatal_at(self->file, e->pos, "slicing %s is not compiled yet (str, bytes, List, View, Buffer and Mapping work)", ps_type_str(self->a, st4))
                for i in range(3):
                    if e->args[i] != None:
                        pt4: *PsType = self->check_expr(e->args[i])
                        self->want(e->args[i], pt4, ps_type(self->a, PT_INT, e->pos), "a slice bound")
                if st4->kind == PT_MAPPING:
                    # 137.1: fatia-se em `bytes` SEM copiar. O bloco é do
                    # núcleo e não se move, que é a condição inteira que uma
                    # janela pede — a mesma que faz a fatia de um `bytes` ser
                    # uma janela.
                    t = ps_type(self->a, PT_BYTES, e->pos)
                elif st4->kind == PT_BUFFER:
                    # 135.8: `b[0:8]` is sugar for `b.view_u8(0, 8)`, so what
                    # comes back is a `View<u8>` and NOT a `Buffer`. That is the
                    # distinction earning its keep: the window cannot be closed,
                    # because closing it would mean deciding a lifetime that
                    # belongs to the buffer.
                    if e->args[2] != None:
                        fatal_at(self->file, e->pos, "a window over a Buffer has no step: it is the same bytes seen as elements, and a step would mean copying them (135.8) — slice the View it gives you")
                    vb4: *PsType = ps_type(self->a, PT_VIEW, e->pos)
                    vb4->inner = ps_type(self->a, PT_INT, e->pos)
                    vb4->inner->width = 8
                    vb4->inner->uns = True
                    t = vb4
                else:
                    t = st4
            case PE_TUPLE:
                # a tuple is a VALUE (3.2/38.2): immutable, copied, no header.
                # Its type is the list of its element types.
                if e->nargs < 2:
                    fatal_at(self->file, e->pos, "a tuple needs at least two elements")
                tt: *PsType = ps_type(self->a, PT_TUPLE, e->pos)
                tt->params = self->a->alloc(usize(e->nargs) * sizeof(*tt->params))
                for i in range(e->nargs):
                    tt->params[i] = self->check_expr(e->args[i])
                    if tt->params[i] == None or tt->params[i]->kind == PT_VOID:
                        fatal_at(self->file, e->args[i]->pos, "a tuple element has no value")
                tt->nparams = e->nargs
                # 98.4: a tuple that holds a `str` (or a list, or a struct) IS
                # allowed now, and stays a VALUE — the frame registers the
                # references INSIDE it, which is what the collector needs and is
                # compile-time data. What is still refused is such a tuple as a
                # dict KEY (hash and equality would have to walk it) and inside
                # a container (the element trace is the next step).
                t = tt
            case PE_COALESCE:
                # `a ?? b` (43.2): only for `T?`, so it can never be confused
                # with boolean logic the way a two-meaning `or` would be
                ot2: *PsType = self->check_expr(e->lhs)
                if ot2 == None or ot2->kind != PT_OPT or ot2->inner == None:
                    fatal_at(self->file, e->pos, "'??' takes an option on the left, found %s", ps_type_str(self->a, ot2))
                dt: *PsType = self->check_expr(e->rhs)
                self->want(e->rhs, dt, ot2->inner, "the default of '??'")
                t = ot2->inner
            case PE_OPTFIELD:
                # `a?.f` (43.3): None stays None, otherwise the field, wrapped
                ot3: *PsType = self->check_expr(e->lhs)
                if ot3 == None or ot3->kind != PT_OPT or ot3->inner == None:
                    fatal_at(self->file, e->pos, "'?.' takes an option on the left, found %s", ps_type_str(self->a, ot3))
                ft: *PsType = self->field_type(ot3->inner, e->text, e->pos)
                w: *PsType = ps_type(self->a, PT_OPT, e->pos)
                w->inner = ft
                t = w
            case PE_IN:
                # `k in d` / `x in s` — membership, and the only reason a set
                # exists (8.1)
                nt5: *PsType = self->check_expr(e->lhs)
                ht5: *PsType = self->check_expr(e->rhs)
                if ht5 != None and ht5->kind == PT_STR:
                    # 72.2: over a string `in` is SUBSTRING, as Python spells
                    # it. There is no second reading to confuse it with — a
                    # string is not a container of anything else.
                    self->want(e->lhs, nt5, ps_type(self->a, PT_STR, e->pos), "the text looked for")
                    t = ps_type(self->a, PT_BOOL, e->pos)
                    e->type = t
                    return t
                if ht5 != None and ht5->kind == PT_LIST:
                    # over a LIST `in` is a linear scan by VALUE, as Python's is.
                    # A set is still the reason a set exists (8.1) — this is O(n)
                    # and says so — but refusing it would make the obvious
                    # spelling of "is this in here" an error in a language whose
                    # north star spells it exactly this way.
                    self->want(e->lhs, nt5, ht5->inner, "the tested value")
                    t = ps_type(self->a, PT_BOOL, e->pos)
                    e->type = t
                    return t
                if ht5 == None or ht5->kind not in {PT_DICT, PT_SET}:
                    fatal_at(self->file, e->pos, "`in` takes a list, a dict, a set or a string on the right, not %s", ps_type_str(self->a, ht5))
                self->want(e->lhs, nt5, ht5->key if ht5->kind == PT_DICT else ht5->inner, "the tested value")
                t = ps_type(self->a, PT_BOOL, e->pos)
            case PE_WALRUS:
                # `(n := f())` (45.2): binds and evaluates to what it bound. The
                # name belongs to the scope that CONTAINS the expression, which
                # is what makes `if (n := len(xs)) > 2:` able to read `n` in the
                # branch — and what makes it a declaration and not a temporary.
                wlt: *PsType = self->check_expr(e->lhs)
                if wlt == None or wlt->kind == PT_VOID:
                    fatal_at(self->file, e->pos, "`:=` needs a value to bind, and %s has none", ps_expr_what(e->lhs->kind))
                self->add_local(e->var, wlt, True, False)
                t = wlt
            case PE_FIELD:
                if self->try_mod_qual(e):
                    return self->check_expr(e)
                t = self->field_type(self->check_expr(e->lhs), e->text, e->pos)
            case _:
                fatal_at(self->file, e->pos, "%s is parsed but not compiled yet", ps_expr_what(e->kind))
        e->type = t
        return t

    private def check_binary(self: *PsSema, e: *PsExpr) -> *PsType:
        # The context type does NOT reach through an operator. What a `+` needs
        # from its operands is that they agree with EACH OTHER (68.2 decides
        # how); letting the surrounding expectation in would make
        # `float(x %* K)` adapt K to float, which is a different program.
        prevh: *PsType = self->hint
        self->hint = None
        lt: *PsType = self->check_expr(e->lhs)
        # 114: `x != None and x.f` — o `and` curto-circuita, então a prova do
        # lado esquerdo vale ENQUANTO o direito é checado. É a metade que faltava
        # da 43.1: a prova já valia no corpo do `if`, e não na própria condição.
        # `and`: o direito é checado com a prova do esquerdo. `or`: o direito é
        # checado sabendo que o esquerdo foi FALSO, então um `x == None` à
        # esquerda também prova (114).
        nwa: i32[PS_NARROW_MAX]
        nand: i32 = 0
        if e->op == TK_AND:
            nand = self->narrow_all(e->lhs, TK_NE, nwa, 0)
        elif e->op == TK_OR:
            nand = self->narrow_all(e->lhs, TK_EQ, nwa, 0)
        nand = self->narrow_push(nwa, nand)
        rt: *PsType = self->check_expr(e->rhs)
        self->narrow_pop(nwa, nand)
        self->hint = prevh
        bl: *PsType = ps_type(self->a, PT_BOOL, e->pos)
        # exact widths (68.2): a literal takes the other side's width (range
        # checked); two typed operands need a lossless COMMON type or an
        # explicit conversion. `ONE unsigned bit pattern meaning two things` is
        # exactly what this refuses.
        if lt != None and rt != None and lt->kind == PT_INT and rt->kind == PT_INT and not ps_type_eq(lt, rt):
            if ps_adapt_lit(self->file, e->lhs, rt):
                lt = e->lhs->type
            elif ps_adapt_lit(self->file, e->rhs, lt):
                rt = e->rhs->type
        icommon: *PsType = ps_int_common(lt, rt) if lt != None and rt != None and lt->kind == PT_INT and rt->kind == PT_INT else None
        if lt != None and rt != None and lt->kind == PT_INT and rt->kind == PT_INT and icommon == None and e->op != TK_SHL and e->op != TK_SHR:
            fatal_at(self->file, e->pos, "%s and %s have no lossless common type: convert one side by name (68.2)", ps_type_str(self->a, lt), ps_type_str(self->a, rt))
        num: bool = lt != None and rt != None and (lt->kind == PT_INT or lt->kind == PT_FLOAT) and (rt->kind == PT_INT or rt->kind == PT_FLOAT)
        flt: bool = num and (lt->kind == PT_FLOAT or rt->kind == PT_FLOAT)
        match e->op:
            case TK_AND, TK_OR:
                # a condition is a bool, never a truthy int (40.1)
                self->want(e->lhs, lt, bl, "'and'/'or'")
                self->want(e->rhs, rt, bl, "'and'/'or'")
                return bl
            case TK_EQ, TK_NE:
                # `x != None` is the test that PROVES non-null (43.1); it is the
                # only comparison an option takes part in
                if (lt != None and lt->kind == PT_OPT) or (rt != None and rt->kind == PT_OPT):
                    lnone: bool = lt != None and lt->kind == PT_OPT and lt->inner == None
                    rnone: bool = rt != None and rt->kind == PT_OPT and rt->inner == None
                    if not lnone and not rnone:
                        fatal_at(self->file, e->pos, "compare an option against None; to compare the values, prove they are there first")
                    return bl
                # `==` compares CONTENT (22.2); the two sides have to be the
                # same kind of thing, with the int/float mix allowed
                if not num and not ps_type_eq(lt, rt):
                    fatal_at(self->file, e->pos, "cannot compare %s with %s", ps_type_str(self->a, lt), ps_type_str(self->a, rt))
                if lt != None and (lt->kind == PT_DICT or lt->kind == PT_SET):
                    # 22.2 diz CONTEÚDO, e comparar dois dicts por conteúdo é
                    # independente da ordem — não está escrito. O que estava a
                    # sair era uma comparação de PONTEIROS, que responde False a
                    # dois dicts iguais: recusar é melhor do que mentir.
                    fatal_at(self->file, e->pos, "`==` on a %s is not compiled yet (22.2): compare `len()` and the keys, or say what you mean with a loop", "Dict" if lt->kind == PT_DICT else "Set")
                if lt != None and lt->kind == PT_TUPLE and not tuple_is_pure(lt):
                    # a tuple of pure bytes gets P's derived `==` for free; one
                    # holding a `str` needs a comparison that walks it, and that
                    # is not written yet (98.4). Comparing slot by slot works
                    # today and says exactly what it means.
                    fatal_at(self->file, e->pos, "`==` on a tuple that holds a reference is not compiled yet (98.4): compare the slots — `a[0] == b[0] and a[1] == b[1]`")
                return bl
            case TK_LT, TK_LE, TK_GT, TK_GE:
                if num:
                    return bl
                if lt != None and rt != None and lt->kind == PT_STR and rt->kind == PT_STR:
                    return bl
                # 104: entre conjuntos, `<=` é subconjunto e `<` é subconjunto
                # ESTRITO, como no Python
                if lt != None and rt != None and lt->kind == PT_SET and rt->kind == PT_SET:
                    if not ps_type_eq(lt->inner, rt->inner):
                        fatal_at(self->file, e->pos, "cannot compare %s with %s", ps_type_str(self->a, lt), ps_type_str(self->a, rt))
                    return bl
                fatal_at(self->file, e->pos, "cannot order %s and %s", ps_type_str(self->a, lt), ps_type_str(self->a, rt))
            case TK_PLUS:
                if lt != None and rt != None and lt->kind == PT_STR and rt->kind == PT_STR:
                    return lt
                # 104: `a + b` de listas é uma lista NOVA, como no Python. O que
                # ela copia são os ELEMENTOS (os bytes); dois objetos apontados
                # continuam sendo os mesmos dois objetos.
                if lt != None and rt != None and lt->kind == PT_LIST and rt->kind == PT_LIST:
                    if not ps_type_eq(lt->inner, rt->inner):
                        fatal_at(self->file, e->pos, "cannot add %s and %s: the elements would have two different types", ps_type_str(self->a, lt), ps_type_str(self->a, rt))
                    return lt
                if not num:
                    # the classic: 7.3 says no implicit coercion, so say which
                    # way the fix goes instead of just refusing
                    fatal_at(self->file, e->pos, "cannot add %s and %s (there is no implicit conversion: write str(x) or int(x))", ps_type_str(self->a, lt), ps_type_str(self->a, rt))
                if icommon != None:
                    return icommon
                return rt if flt and lt->kind == PT_INT else lt
            case TK_MINUS, TK_STAR:
                # 104: `a - b` entre conjuntos é a diferença
                if e->op == TK_MINUS and lt != None and rt != None and lt->kind == PT_SET and rt->kind == PT_SET:
                    if not ps_type_eq(lt->inner, rt->inner):
                        fatal_at(self->file, e->pos, "cannot subtract %s from %s: the elements would have two different types", ps_type_str(self->a, rt), ps_type_str(self->a, lt))
                    return lt
                # `"ab" * 3` repeats, as Python does — and only in that order:
                # `3 * "ab"` is refused, because a language with no implicit
                # conversion (7.3) should not have one operand teaching the
                # other what the expression means.
                if e->op == TK_STAR and lt != None and rt != None and lt->kind == PT_STR and rt->kind == PT_INT:
                    return lt
                if e->op == TK_STAR and lt != None and rt != None and lt->kind == PT_LIST and rt->kind == PT_INT:
                    return lt
                if not num:
                    fatal_at(self->file, e->pos, "'%s' expects numbers, found %s and %s", "-" if e->op == TK_MINUS else "*", ps_type_str(self->a, lt), ps_type_str(self->a, rt))
                if icommon != None:
                    return icommon
                return rt if flt and lt->kind == PT_INT else lt
            case TK_SLASH:
                # 39.1: `/` is float even between ints. Whoever wants integer
                # division writes `//`.
                if not num:
                    fatal_at(self->file, e->pos, "'/' expects numbers, found %s and %s", ps_type_str(self->a, lt), ps_type_str(self->a, rt))
                return ps_type(self->a, PT_FLOAT, e->pos)
            case TK_FLOORDIV, TK_PERCENT:
                if not num:
                    fatal_at(self->file, e->pos, "'%s' expects numbers, found %s and %s", "//" if e->op == TK_FLOORDIV else "%", ps_type_str(self->a, lt), ps_type_str(self->a, rt))
                if flt:
                    return ps_type(self->a, PT_FLOAT, e->pos)
                return icommon if icommon != None else lt
            case TK_POW:
                if not num:
                    fatal_at(self->file, e->pos, "'**' expects numbers, found %s and %s", ps_type_str(self->a, lt), ps_type_str(self->a, rt))
                if flt:
                    return ps_type(self->a, PT_FLOAT, e->pos)
                if lt != None and lt->uns and rt != None and not rt->uns:
                    # `u ** i` would need a negative-exponent story unsigned
                    # cannot tell; the exponent adapts or converts
                    fatal_at(self->file, e->pos, "the exponent of an unsigned base is unsigned too: write u64(e) (68.2)")
                return icommon if icommon != None else lt
            case TK_WRAP_PLUS, TK_WRAP_MINUS, TK_WRAP_STAR:
                # 54.1: the wrapping forms, the only arithmetic that does not
                # raise on overflow — integers only, by definition
                if lt == None or rt == None or lt->kind != PT_INT or rt->kind != PT_INT:
                    fatal_at(self->file, e->pos, "the wrapping operators expect integers, found %s and %s", ps_type_str(self->a, lt), ps_type_str(self->a, rt))
                return icommon if icommon != None else lt
            case TK_AMP, TK_PIPE, TK_CARET, TK_SHL, TK_SHR:
                # 104: entre conjuntos, `|`, `&` e `^` são união, interseção e
                # diferença simétrica — os mesmos símbolos do Python
                if e->op != TK_SHL and e->op != TK_SHR and lt != None and rt != None and lt->kind == PT_SET and rt->kind == PT_SET:
                    if not ps_type_eq(lt->inner, rt->inner):
                        fatal_at(self->file, e->pos, "cannot combine %s and %s: the elements would have two different types", ps_type_str(self->a, lt), ps_type_str(self->a, rt))
                    return lt
                if lt == None or rt == None or lt->kind != PT_INT or rt->kind != PT_INT:
                    fatal_at(self->file, e->pos, "bitwise operators expect integers, found %s and %s", ps_type_str(self->a, lt), ps_type_str(self->a, rt))
                if e->op == TK_SHL or e->op == TK_SHR:
                    # the COUNT is any integer; the value keeps its own type,
                    # and on unsigned `>>` is logical by construction (68.2)
                    return lt
                return icommon if icommon != None else lt
            case _:
                fatal_at(self->file, e->pos, "operator not compiled yet")
        return None

    # ---------- calls ----------
    private def check_call(self: *PsSema, e: *PsExpr) -> *PsType:
        # `vec3.f(...)` is a QUALIFIED call, never a method call
        if self->try_mod_qual(e->lhs):
            pass
        # `v.dot(w)` — a method on a record (57.1). The receiver goes in as the
        # first argument, by reference, because `in self` reads without copying.
        if e->lhs != None and e->lhs->kind == PE_FIELD:
            rt: *PsType = self->check_expr(e->lhs->lhs)
            if rt != None and (rt->kind == PT_DICT or rt->kind == PT_SET):
                nm3: const *char = e->lhs->text
                e->lhs->type = rt
                kty: *PsType = rt->key if rt->kind == PT_DICT else rt->inner
                if strcmp(nm3, "add") == 0 or strcmp(nm3, "remove") == 0:
                    self->deny_const_mut(e->lhs->lhs, self->a->printf("%s()", nm3))
                if strcmp(nm3, "add") == 0 and rt->kind == PT_SET:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "add() takes one value")
                    self->want(e->args[0], self->check_expr(e->args[0]), kty, "the added value")
                    return ps_type(self->a, PT_VOID, e->pos)
                if strcmp(nm3, "remove") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "remove() takes one key")
                    self->want(e->args[0], self->check_expr(e->args[0]), kty, "the removed key")
                    return ps_type(self->a, PT_BOOL, e->pos)
                # ---- 104: o resto do que um dict/set faz no Python ----
                if strcmp(nm3, "clear") == 0:
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "clear() takes no arguments")
                    self->deny_const_mut(e->lhs->lhs, "clear()")
                    return ps_type(self->a, PT_VOID, e->pos)
                if strcmp(nm3, "copy") == 0:
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "copy() takes no arguments")
                    return rt
                if strcmp(nm3, "update") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "update() takes one %s", "Dict" if rt->kind == PT_DICT else "Set")
                    self->deny_const_mut(e->lhs->lhs, "update()")
                    self->check_want(e->args[0], rt, "the update")
                    return ps_type(self->a, PT_VOID, e->pos)
                if strcmp(nm3, "pop") == 0 and rt->kind == PT_DICT:
                    # `pop(k)` levanta se não houver, `pop(k, d)` devolve `d` —
                    # como no Python, e a mesma divisão de `d[k]` contra `get`
                    if e->nargs < 1 or e->nargs > 2:
                        fatal_at(self->file, e->pos, "pop(key) or pop(key, default)")
                    self->deny_const_mut(e->lhs->lhs, "pop()")
                    self->want(e->args[0], self->check_expr(e->args[0]), kty, "the key")
                    if e->nargs == 2:
                        self->check_want(e->args[1], rt->inner, "the default")
                    return rt->inner
                if strcmp(nm3, "setdefault") == 0 and rt->kind == PT_DICT:
                    if e->nargs != 2:
                        fatal_at(self->file, e->pos, "setdefault(key, value) takes both: the value is what goes in when the key is NOT there")
                    self->deny_const_mut(e->lhs->lhs, "setdefault()")
                    self->want(e->args[0], self->check_expr(e->args[0]), kty, "the key")
                    self->check_want(e->args[1], rt->inner, "the value")
                    return rt->inner
                if strcmp(nm3, "discard") == 0 and rt->kind == PT_SET:
                    # o `remove` do Python levanta e o `discard` não; aqui o
                    # `remove` já devolve bool, então `discard` é o mesmo com o
                    # resultado jogado fora — e existe para o código ler igual
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "discard() takes one value")
                    self->deny_const_mut(e->lhs->lhs, "discard()")
                    self->want(e->args[0], self->check_expr(e->args[0]), kty, "the discarded value")
                    return ps_type(self->a, PT_VOID, e->pos)
                if strcmp(nm3, "get") == 0 and rt->kind == PT_DICT:
                    if e->nargs != 2:
                        fatal_at(self->file, e->pos, "get() takes a key and a default (5.2: plain indexing raises)")
                    self->want(e->args[0], self->check_expr(e->args[0]), kty, "the key")
                    self->want(e->args[1], self->check_expr(e->args[1]), rt->inner, "the default")
                    return rt->inner
                # 61.4: the Python iteration pack. `keys()` and `values()` hand
                # back a LIST in insertion order — a copy, because a view into
                # an object that moves is an interior pointer (17.3).
                if strcmp(nm3, "keys") == 0:
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "keys() takes no arguments")
                    kl: *PsType = ps_type(self->a, PT_LIST, e->pos)
                    kl->inner = kty
                    return kl
                if strcmp(nm3, "values") == 0 and rt->kind == PT_DICT:
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "values() takes no arguments")
                    vl: *PsType = ps_type(self->a, PT_LIST, e->pos)
                    vl->inner = rt->inner
                    return vl
                if strcmp(nm3, "items") == 0 and rt->kind == PT_DICT:
                    # 98.5: as a VALUE it is a list of PAIRS, and the tuple now
                    # holds references — so this is exactly the comprehension
                    # somebody would write by hand, built here. Everything
                    # downstream (the loop, the tuple, the element trace the
                    # collector needs) is machinery that already exists.
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "items() takes no arguments")
                    recv9: *PsExpr = e->lhs->lhs
                    if recv9->kind != PE_NAME and recv9->kind != PE_FIELD:
                        fatal_at(self->file, e->pos, "`items()` on something that is not a plain variable would evaluate it twice: put the dict in a variable first")
                    kv9: const *char = self->a->printf("__it%d", self->counter)
                    self->counter += 1
                    knm: *PsExpr = ps_expr(self->a, PE_NAME, e->pos)
                    knm->text = kv9
                    vix: *PsExpr = ps_expr(self->a, PE_INDEX, e->pos)
                    vix->lhs = recv9
                    vix->rhs = knm
                    pair: *PsExpr = ps_expr(self->a, PE_TUPLE, e->pos)
                    pair->args = self->a->alloc(usize(2) * sizeof(*pair->args))
                    pair->args[0] = knm
                    pair->args[1] = vix
                    pair->nargs = 2
                    cmp9: *PsExpr = ps_expr(self->a, PE_COMPREHEND, e->pos)
                    cmp9->op = TK_RBRACKET
                    cmp9->var = kv9
                    cmp9->lhs = pair
                    cmp9->rhs = recv9
                    with e:
                        .kind = PE_COMPREHEND
                        .op = TK_RBRACKET
                        .var = kv9
                        .lhs = pair
                        .rhs = recv9
                        .args = None
                        .nargs = 0
                    return self->check_expr(e)
                fatal_at(self->file, e->pos, "a %s has %s", "Dict" if rt->kind == PT_DICT else "Set", "get, pop, setdefault, remove, update, clear, copy, keys, values and items" if rt->kind == PT_DICT else "add, remove, discard, update, clear, copy and keys")
            if rt != None and rt->kind == PT_BYTES:
                # 155: ESCREVER uma codificação de fio é um método dos BYTES, e
                # ler é um método do TEXTO. Não há módulo nenhum, portanto não há
                # `import` para lembrar — e `d.hex()` é literalmente o que se
                # escreveria em Python.
                bm: const *char = e->lhs->text
                e->lhs->type = rt
                if strcmp(bm, "hex") == 0 or strcmp(bm, "base64") == 0:
                    maxb: i32 = 2 if strcmp(bm, "base64") == 0 else 1
                    if e->nargs > maxb:
                        fatal_at(self->file, e->pos, "%s() takes %s", bm,
                                 "nothing, or `urlsafe` and `pad`" if strcmp(bm, "base64") == 0 else "nothing, or `upper`")
                    for i in range(e->nargs):
                        bfl: *PsType = self->check_expr(e->args[i])
                        self->want(e->args[i], bfl, ps_type(self->a, PT_BOOL, e->pos), self->a->printf("a flag of %s()", bm))
                    return ps_type(self->a, PT_STR, e->pos)
                fatal_at(self->file, e->pos, "`bytes` has hex() and base64() — and the way back is on the TEXT: `s.from_hex()`, `s.from_base64()` (155). Found '%s'", bm)
            if rt != None and rt->kind == PT_STR:
                nm2: const *char = e->lhs->text
                e->lhs->type = rt
                st5: *PsType = ps_type(self->a, PT_STR, e->pos)
                bl2: *PsType = ps_type(self->a, PT_BOOL, e->pos)
                if strcmp(nm2, "split") == 0:
                    # sem separador parte em CORRIDAS de espaço e não devolve
                    # pedaço vazio: `" a  b ".split()` dá dois, e
                    # `" a  b ".split(" ")` dá cinco. São duas funções porque
                    # são dois resultados.
                    if e->nargs > 1:
                        fatal_at(self->file, e->pos, "split() takes one separator, or nothing (which splits on runs of whitespace)")
                    if e->nargs == 1:
                        self->want(e->args[0], self->check_expr(e->args[0]), st5, "the separator")
                    lw2: *PsType = ps_type(self->a, PT_LIST, e->pos)
                    lw2->inner = st5
                    return lw2
                if strcmp(nm2, "strip") == 0 or strcmp(nm2, "lstrip") == 0 or strcmp(nm2, "rstrip") == 0:
                    # com um argumento tira qualquer um daqueles CARACTERES das
                    # pontas (não é um prefixo), como no Python
                    if e->nargs > 1:
                        fatal_at(self->file, e->pos, "%s() takes nothing (whitespace) or the set of characters to strip", nm2)
                    if e->nargs == 1:
                        self->want(e->args[0], self->check_expr(e->args[0]), st5, "the characters to strip")
                    return st5
                if strcmp(nm2, "lower") == 0 or strcmp(nm2, "upper") == 0 or strcmp(nm2, "title") == 0 or strcmp(nm2, "capitalize") == 0 or strcmp(nm2, "swapcase") == 0:
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "%s() takes no arguments", nm2)
                    return st5
                # 105: os predicados, sobre a string INTEIRA e com as
                # categorias do Unicode — a string vazia é False em todos
                if nm2 in {"isalpha", "isdigit", "isdecimal", "isnumeric", "isalnum", "isspace", "isupper", "islower", "istitle"}:
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "%s() takes no arguments", nm2)
                    return bl2
                if strcmp(nm2, "find") == 0 and e->nargs == 2:
                    # `find(sub, start)`: o começo conta em CARACTERES
                    self->want(e->args[0], self->check_expr(e->args[0]), st5, "what to look for")
                    self->want(e->args[1], self->check_expr(e->args[1]), ps_type(self->a, PT_INT, e->pos), "where to start")
                    return ps_type(self->a, PT_INT, e->pos)
                if strcmp(nm2, "find") == 0 or strcmp(nm2, "startswith") == 0 or strcmp(nm2, "endswith") == 0 or strcmp(nm2, "contains") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "%s() takes one string", nm2)
                    self->want(e->args[0], self->check_expr(e->args[0]), st5, "the argument")
                    return ps_type(self->a, PT_INT, e->pos) if strcmp(nm2, "find") == 0 else bl2
                if strcmp(nm2, "replace") == 0:
                    if e->nargs != 2:
                        fatal_at(self->file, e->pos, "replace() takes what to find and what to put there")
                    self->want(e->args[0], self->check_expr(e->args[0]), st5, "what to find")
                    self->want(e->args[1], self->check_expr(e->args[1]), st5, "what to put there")
                    return st5
                # ---- 104: o resto do que uma str faz no Python ----
                if strcmp(nm2, "count") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "count() takes one string")
                    self->want(e->args[0], self->check_expr(e->args[0]), st5, "what to count")
                    return ps_type(self->a, PT_INT, e->pos)
                if strcmp(nm2, "rfind") == 0 or strcmp(nm2, "index") == 0 or strcmp(nm2, "rindex") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "%s() takes one string", nm2)
                    self->want(e->args[0], self->check_expr(e->args[0]), st5, "what to look for")
                    return ps_type(self->a, PT_INT, e->pos)
                if strcmp(nm2, "removeprefix") == 0 or strcmp(nm2, "removesuffix") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "%s() takes one string", nm2)
                    self->want(e->args[0], self->check_expr(e->args[0]), st5, "the affix")
                    return st5
                if strcmp(nm2, "splitlines") == 0:
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "splitlines() takes no arguments")
                    sl5: *PsType = ps_type(self->a, PT_LIST, e->pos)
                    sl5->inner = st5
                    return sl5
                if strcmp(nm2, "ljust") == 0 or strcmp(nm2, "rjust") == 0 or strcmp(nm2, "center") == 0:
                    if e->nargs < 1 or e->nargs > 2:
                        fatal_at(self->file, e->pos, "%s(width) or %s(width, fill)", nm2, nm2)
                    self->want(e->args[0], self->check_expr(e->args[0]), ps_type(self->a, PT_INT, e->pos), "the width")
                    if e->nargs == 2:
                        self->want(e->args[1], self->check_expr(e->args[1]), st5, "the fill")
                    return st5
                if strcmp(nm2, "zfill") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "zfill(width) takes the width")
                    self->want(e->args[0], self->check_expr(e->args[0]), ps_type(self->a, PT_INT, e->pos), "the width")
                    return st5
                if strcmp(nm2, "join") == 0:
                    # the SEPARATOR is the receiver, as in Python: `", ".join(xs)`
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "join() takes one list of strings")
                    jt: *PsType = self->check_expr(e->args[0])
                    if jt == None or jt->kind != PT_LIST or jt->inner == None or jt->inner->kind != PT_STR:
                        fatal_at(self->file, e->pos, "join() takes a List<str>, not %s", ps_type_str(self->a, jt))
                    return st5
                if strcmp(nm2, "encode") == 0:
                    # 135.7, the third place a `bytes` is born. It is not a
                    # conversion so much as taking off a promise: the bytes
                    # handed over are the UTF-8 the `str` already stores, and
                    # what is dropped is the guarantee that they are text.
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "encode() takes no arguments: a `str` is UTF-8 already, and there is no second encoding to ask for")
                    return ps_type(self->a, PT_BYTES, e->pos)
                # 155: ler uma codificação de fio é um MÉTODO do texto, e não
                # um módulo. Não há `import` nenhum, e o nome fica ao lado dos
                # outros que o `str` já tem — que é onde alguém o procura.
                #
                # **Devolvem `bytes?`, e None quer dizer "isto não é aquilo"**
                # (4.2): o texto veio de fora, e não analisar é uma resposta.
                if strcmp(nm2, "from_base64") == 0 or strcmp(nm2, "from_hex") == 0:
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "%s() takes no arguments: the text is the string it is called on", nm2)
                    fo: *PsType = ps_type(self->a, PT_OPT, e->pos)
                    fo->inner = ps_type(self->a, PT_BYTES, e->pos)
                    return fo
                fatal_at(self->file, e->pos, "a string has split, splitlines, strip, lstrip, rstrip, lower, upper, title, capitalize, swapcase, find, rfind, index, rindex, count, contains, startswith, endswith, removeprefix, removesuffix, replace, join, ljust, rjust, center, zfill, encode, from_base64, from_hex, and isalpha/isdigit/isdecimal/isnumeric/isalnum/isspace/isupper/islower/istitle")
            if rt != None and rt->kind == PT_VIEW:
                # 135.8, and this is the whole reason a View is a type of its
                # own: what it CANNOT do is refused HERE, in compilation,
                # instead of raising when the program is already running.
                #
                # It borrows: the elements belong to a `Buffer` and there are
                # exactly as many as the window says. Growing would mean owning
                # them, and `close` would mean deciding a lifetime that is not
                # this object's — so neither is a mistake to be caught. Neither
                # is a thing anybody can write.
                vm: const *char = e->lhs->text
                # the RECEIVER's type has to be written back, exactly as the
                # list branch below does: it is what the lowering dispatches on,
                # and without it the call falls through to the user-method path
                # and dereferences a name that is not there
                e->lhs->type = rt
                if vm in {"append", "insert", "remove_at", "extend", "clear", "pop", "remove", "sort", "reverse"}:
                    fatal_at(self->file, e->pos, "a View borrows: it has exactly the elements the window covers, and `%s()` would mean owning them (135.8) — write into it by index, or build in a List and convert", vm)
                if strcmp(vm, "close") == 0:
                    fatal_at(self->file, e->pos, "a View has no close(): the lifetime belongs to the `Buffer` it borrows from (135.8/136.1) — close that instead")
                if strcmp(vm, "copy") == 0:
                    # the way OUT of borrowing, and it says so by copying
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "copy() takes no arguments")
                    cpv: *PsType = ps_type(self->a, PT_LIST, e->pos)
                    cpv->inner = rt->inner
                    return cpv
                if strcmp(vm, "index") == 0 or strcmp(vm, "count") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "%s() takes one value", vm)
                    self->check_want(e->args[0], rt->inner, "the value looked for")
                    return ps_type(self->a, PT_INT, e->pos)
                fatal_at(self->file, e->pos, "a View has index, count and copy — it borrows, so it does not grow and does not close (135.8) — not '%s'", vm)
            if rt != None and rt->kind == PT_LIST:
                lm: const *char = e->lhs->text
                e->lhs->type = rt
                if lm in {"append", "insert", "remove_at", "reverse", "pop", "extend", "clear", "remove", "sort"}:
                    self->deny_const_mut(e->lhs->lhs, self->a->printf("%s()", lm))
                if strcmp(lm, "append") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "append() takes one value")
                    self->check_want(e->args[0], rt->inner, "the appended value")
                    return ps_type(self->a, PT_VOID, e->pos)
                if strcmp(lm, "insert") == 0:
                    if e->nargs != 2:
                        fatal_at(self->file, e->pos, "insert() takes a position and a value")
                    self->want(e->args[0], self->check_expr(e->args[0]), ps_type(self->a, PT_INT, e->pos), "the position")
                    self->check_want(e->args[1], rt->inner, "the inserted value")
                    return ps_type(self->a, PT_VOID, e->pos)
                if strcmp(lm, "remove_at") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "remove_at() takes a position")
                    self->want(e->args[0], self->check_expr(e->args[0]), ps_type(self->a, PT_INT, e->pos), "the position")
                    return ps_type(self->a, PT_VOID, e->pos)
                if strcmp(lm, "reverse") == 0:
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "reverse() takes no arguments")
                    return ps_type(self->a, PT_VOID, e->pos)
                # ---- 104: o resto do que uma lista faz no Python ----
                if strcmp(lm, "pop") == 0:
                    # sem argumento tira o ÚLTIMO, como no Python
                    if e->nargs > 1:
                        fatal_at(self->file, e->pos, "pop() takes nothing (the last element) or one position")
                    if e->nargs == 1:
                        self->want(e->args[0], self->check_expr(e->args[0]), ps_type(self->a, PT_INT, e->pos), "the position")
                    return rt->inner
                if strcmp(lm, "extend") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "extend() takes one list")
                    self->check_want(e->args[0], rt, "the extension")
                    return ps_type(self->a, PT_VOID, e->pos)
                if strcmp(lm, "clear") == 0:
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "clear() takes no arguments")
                    return ps_type(self->a, PT_VOID, e->pos)
                if strcmp(lm, "copy") == 0:
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "copy() takes no arguments")
                    return rt
                if strcmp(lm, "index") == 0 or strcmp(lm, "count") == 0 or strcmp(lm, "remove") == 0:
                    # por CONTEÚDO, como o `in` (55.4): duas strings iguais são a
                    # mesma para procurar, mesmo escritas em lugares diferentes
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "%s() takes one value", lm)
                    self->key_ok(rt->inner, e->pos, self->a->printf("what %s() looks for", lm))
                    self->check_want(e->args[0], rt->inner, self->a->printf("what %s() looks for", lm))
                    if strcmp(lm, "remove") == 0:
                        return ps_type(self->a, PT_VOID, e->pos)
                    return ps_type(self->a, PT_INT, e->pos)
                if strcmp(lm, "sort") == 0:
                    # `sort()` ordena NO LUGAR e `sorted(xs)` devolve outra —
                    # a mesma divisão do Python. Aqui é `xs = sorted(xs)` escrito
                    # por dentro, então a comparação é a mesma e há uma só.
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "sort() takes no arguments here; for a key write `xs = sorted(xs, key=...)`")
                    if rt->inner == None or rt->inner->kind not in {PT_INT, PT_FLOAT, PT_STR}:
                        fatal_at(self->file, e->pos, "sort() orders numbers or strings; for anything else write `sorted(xs, key=...)` (which says WHAT to compare)")
                    return ps_type(self->a, PT_VOID, e->pos)
                fatal_at(self->file, e->pos, "a list has append, insert, remove_at, reverse, pop, extend, clear, copy, index, count, remove and sort, not '%s'", lm)
            # a task can be asked to stop (37.2). It is not a kill: the next
            # step of THAT task raises inside it, so its `defer` and its `with`
            # unwind exactly as they would for any other error.
            if rt != None and rt->kind == PT_TASK:
                tm9: const *char = e->lhs->text
                if strcmp(tm9, "cancel") != 0 and strcmp(tm9, "cancelled") != 0:
                    fatal_at(self->file, e->pos, "a task has cancel() and cancelled(), not '%s'", tm9)
                if e->nargs != 0:
                    fatal_at(self->file, e->pos, "%s() takes no arguments", tm9)
                e->lhs->type = rt
                return ps_type(self->a, PT_BOOL if strcmp(tm9, "cancelled") == 0 else PT_VOID, e->pos)
            # the repeating clock (48.2/51.1): one method, and what it gives
            # back is a TASK — so waiting for a tick is the same `await` every
            # other wait uses (36.2)
            if rt != None and rt->kind == PT_TIMER:
                if strcmp(e->lhs->text, "tick") != 0:
                    fatal_at(self->file, e->pos, "an interval has tick(), not '%s'", e->lhs->text)
                if e->nargs != 0:
                    fatal_at(self->file, e->pos, "tick() takes no arguments")
                e->lhs->type = rt
                tk9: *PsType = ps_type(self->a, PT_TASK, e->pos)
                tk9->inner = ps_type(self->a, PT_VOID, e->pos)
                return tk9
            # a buffer (19.4/52.3): the bytes, by index
            if rt != None and rt->kind == PT_BUFFER:
                bm: const *char = e->lhs->text
                e->lhs->type = rt
                if strcmp(bm, "set_f64") == 0:
                    if e->nargs != 2:
                        fatal_at(self->file, e->pos, "set_f64() takes an index and a value")
                    self->check_want(e->args[0], ps_type(self->a, PT_INT, e->pos), "the index")
                    self->check_want(e->args[1], ps_type(self->a, PT_FLOAT, e->pos), "the value")
                    return ps_type(self->a, PT_VOID, e->pos)
                if strcmp(bm, "get_f64") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "get_f64() takes an index")
                    self->check_want(e->args[0], ps_type(self->a, PT_INT, e->pos), "the index")
                    return ps_type(self->a, PT_FLOAT, e->pos)
                if strcmp(bm, "size") == 0:
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "size() takes no arguments")
                    return ps_type(self->a, PT_INT, e->pos)
                if strcmp(bm, "freeze") == 0:
                    # 135.4: the block changes hands with ZERO copy and the
                    # buffer is invalidated — the same rule `transfer` follows
                    # (18.2), and it prevents the same mistake: two owners
                    # writing the same bytes becomes an error instead of a race.
                    # Whoever wants to keep both writes `bytes(b)`, which copies
                    # and says so.
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "freeze() takes no arguments")
                    return ps_type(self->a, PT_BYTES, e->pos)
                # 18.3: the same bytes seen as elements. What comes back IS a
                # list — len, index, write, iterate and slice all read the same
                # way they do anywhere else — and it borrows: no copy, and no
                # growing, because growing would mean owning.
                if strcmp(bm, "close") == 0:
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "close() takes no arguments")
                    return ps_type(self->a, PT_VOID, e->pos)
                vw: i32 = ps_view_esize(bm)
                if vw != 0:
                    # 135.8: with no arguments the window is the whole buffer;
                    # with two it is a REGION, which is what `b[a:b]` lowers to.
                    if e->nargs != 0 and e->nargs != 2:
                        fatal_at(self->file, e->pos, "%s() takes nothing (the whole Buffer) or an offset and a count", bm)
                    for vi in range(e->nargs):
                        vat: *PsType = self->check_expr(e->args[vi])
                        self->want(e->args[vi], vat, ps_type(self->a, PT_INT, e->pos), "an offset into a Buffer" if vi == 0 else "how many elements")
                    vl: *PsType = ps_type(self->a, PT_VIEW, e->pos)
                    vl->inner = ps_view_elem(self->a, bm, e->pos)
                    return vl
                fatal_at(self->file, e->pos, "a Buffer has get_f64, set_f64, size, freeze and the typed views (view_f64, view_f32, view_i64, view_i32, view_u8) — not '%s'", bm)
            if rt != None and rt->kind == PT_CHAN:
                cm: const *char = e->lhs->text
                e->lhs->type = rt
                if strcmp(cm, "send") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "send(v) takes the value that crosses")
                    self->check_want(e->args[0], rt->inner, "what a Channel carries")
                    # 4.2/45.3: mandar para um canal fechado é uma RESPOSTA e
                    # não uma excepção, exactamente como mandar para um worker
                    # que já acabou
                    cs9: *PsType = ps_type(self->a, PT_TASK, e->pos)
                    cs9->inner = ps_type(self->a, PT_BOOL, e->pos)
                    return cs9
                if e->nargs != 0:
                    fatal_at(self->file, e->pos, "'%s' takes no arguments", cm)
                if strcmp(cm, "recv") == 0:
                    # 147.1: `T?`, e None quer dizer que o canal fechou e não
                    # sobrou nada. Chegar ao fim é parte do algoritmo, e a 4.2
                    # diz que o que é parte do algoritmo devolve-se.
                    cr9: *PsType = ps_type(self->a, PT_TASK, e->pos)
                    cr9->inner = self->opt_of(rt->inner, e->pos)
                    return cr9
                if strcmp(cm, "open") == 0:
                    return ps_type(self->a, PT_BOOL, e->pos)
                if strcmp(cm, "len") == 0:
                    return ps_type(self->a, PT_INT, e->pos)
                if strcmp(cm, "close") == 0:
                    return ps_type(self->a, PT_VOID, e->pos)
                fatal_at(self->file, e->pos, "a Channel has send(), recv(), open(), len() and close() (147), not '%s'", cm)
            if rt != None and rt->kind == PT_GROUP:
                gm: const *char = e->lhs->text
                e->lhs->type = rt
                if strcmp(gm, "spawn") != 0:
                    fatal_at(self->file, e->pos, "a task group has spawn() and nothing else — collecting results is what gather() is for (147.4), not '%s'", gm)
                if e->nargs != 1:
                    fatal_at(self->file, e->pos, "g.spawn(t) takes the task to keep inside the block")
                gt9: *PsType = self->check_expr(e->args[0])
                if gt9 == None or gt9->kind != PT_TASK:
                    fatal_at(self->file, e->pos, "g.spawn() takes a task, found %s", ps_type_str(self->a, gt9))
                return ps_type(self->a, PT_VOID, e->pos)
            if rt != None and rt->kind == PT_WATCHER:
                # 146.4: os DOIS, porque são duas perguntas. `next()` espera;
                # `pending()` diz quantos estão à espera AGORA, e é o que
                # transforma oitocentos eventos num laço em vez de oitocentas
                # esperas — porque `next()` sobre uma fila não vazia devolve uma
                # tarefa JÁ PRONTA, e uma tarefa pronta não estaciona.
                wm: const *char = e->lhs->text
                e->lhs->type = rt
                if e->nargs != 0:
                    fatal_at(self->file, e->pos, "'%s' takes no arguments", wm)
                if strcmp(wm, "ready") == 0:
                    # espera até haver alguma coisa. `False` quer dizer que o
                    # vigia fechou — é o mesmo "acabou" que uma leitura de zero
                    # bytes quer dizer num socket (79.2).
                    wt0: *PsType = ps_type(self->a, PT_TASK, e->pos)
                    wt0->inner = ps_type(self->a, PT_BOOL, e->pos)
                    return wt0
                if strcmp(wm, "take") == 0:
                    # tira UM da fila, sem esperar. Levanta se não houver — a
                    # pergunta "há alguma coisa?" tem nome próprio (`pending`),
                    # e responder com um evento inventado seria pior.
                    return self->watch_event_type(e->pos)
                if strcmp(wm, "pending") == 0:
                    return ps_type(self->a, PT_INT, e->pos)
                if strcmp(wm, "close") == 0:
                    return ps_type(self->a, PT_VOID, e->pos)
                fatal_at(self->file, e->pos, "a Watcher has ready(), take(), pending() and close() (140/146.4), not '%s'", wm)
            if rt != None and rt->kind == PT_DECODER:
                dm: const *char = e->lhs->text
                e->lhs->type = rt
                if strcmp(dm, "feed") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "feed(b) takes the bytes that just arrived")
                    dt: *PsType = self->check_expr(e->args[0])
                    if dt == None or (dt->kind != PT_BYTES and dt->kind != PT_VIEW):
                        fatal_at(self->file, e->args[0]->pos, "feed() takes `bytes` or a View<u8> — what a read gives (135.2) — found %s", ps_type_str(self->a, dt))
                    return ps_type(self->a, PT_STR, e->pos)
                if e->nargs != 0:
                    fatal_at(self->file, e->pos, "'%s' takes no arguments", dm)
                if strcmp(dm, "finish") == 0:
                    return ps_type(self->a, PT_STR, e->pos)
                if strcmp(dm, "pending") == 0:
                    return ps_type(self->a, PT_INT, e->pos)
                fatal_at(self->file, e->pos, "a Decoder has feed(b), finish() and pending() (140), not '%s'", dm)
            # 137.1: o mapa É um tipo próprio porque DÁ coisas — `advise`,
            # `sync`, `lock` — que não cabem num valor. E fecha-se: um mapa é
            # espaço de endereçamento, um inode e um descritor, e essas coisas
            # esgotam-se muito antes do monte (136.1).
            if rt != None and rt->kind == PT_MAPPING:
                mm: const *char = e->lhs->text
                e->lhs->type = rt
                if strcmp(mm, "advise") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "advise() takes one of os.SEQUENTIAL, os.RANDOM or os.WILLNEED")
                    ma: *PsType = self->check_expr(e->args[0])
                    self->want(e->args[0], ma, ps_type(self->a, PT_INT, e->pos), "the advice")
                    return ps_type(self->a, PT_VOID, e->pos)
                if e->nargs != 0:
                    fatal_at(self->file, e->pos, "'%s' takes no arguments", mm)
                if strcmp(mm, "size") == 0:
                    return ps_type(self->a, PT_INT, e->pos)
                if strcmp(mm, "sync") == 0 or strcmp(mm, "lock") == 0 or strcmp(mm, "close") == 0:
                    return ps_type(self->a, PT_VOID, e->pos)
                fatal_at(self->file, e->pos, "a Mapping has size, advise, sync, lock and close (137.1), not '%s'", mm)
            # 118: um processo que já terminou (`await os.run(...)`): o status
            # e tudo que ele imprimiu. Métodos e não campos, que é a forma que
            # `conn.port()` já tinha.
            if rt != None and rt->kind == PT_PROC:
                pm: const *char = e->lhs->text
                e->lhs->type = rt
                if e->nargs != 0:
                    fatal_at(self->file, e->pos, "'%s' takes no arguments", pm)
                if strcmp(pm, "status") == 0:
                    # 0 quando saiu bem, 128+sinal quando um sinal o matou — a
                    # convenção do shell. Sair com != 0 NÃO é exceção: um `cc`
                    # que recusa o programa é resultado, e quem chamou decide.
                    return ps_type(self->a, PT_INT, e->pos)
                if strcmp(pm, "output") == 0:
                    return ps_type(self->a, PT_STR, e->pos)
                fatal_at(self->file, e->pos, "a finished process has status() and output() (118), not '%s'", pm)
            # a file (48.1): read, write, readlines, close
            # a socket (77.1): accept, read, write, close, port. Accept, read
            # and write are POLLED — a socket has a real non-blocking mode, so
            # the scheduler waits for the descriptor in the `poll` it already
            # runs and the syscall happens when it can no longer block.
            if rt != None and rt->kind == PT_CONN:
                cm: const *char = e->lhs->text
                e->lhs->type = rt
                ctk: *PsType = ps_type(self->a, PT_TASK, e->pos)
                if strcmp(cm, "write") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "write() takes one str, one `bytes` or one List<u8>")
                    cw: *PsType = self->check_expr(e->args[0])
                    if cw == None or not (cw->kind == PT_STR or cw->kind == PT_BYTES or (cw->kind == PT_LIST and cw->inner != None and cw->inner->kind == PT_INT and cw->inner->width == 8)):
                        fatal_at(self->file, e->pos, "write() takes a str, `bytes` or a List<u8>, found %s", ps_type_str(self->a, cw))
                    ctk->inner = ps_type(self->a, PT_INT, e->pos)
                    return ctk
                if strcmp(cm, "recv_from") == 0:
                    # F7: um datagrama diz DE ONDE veio, e é a única diferença
                    # que o `read_into` não cobre sozinho. Devolve os dois: quem
                    # mandou, e quantos bytes entraram no Buffer.
                    if e->nargs != 3:
                        fatal_at(self->file, e->pos, "recv_from(buf, off, n) takes a Buffer, where in it to start, and how many bytes — and gives back (from, count)")
                    self->io_window(e, cm)
                    rf9: *PsType = ps_type(self->a, PT_TUPLE, e->pos)
                    rf9->params = self->a->alloc(usize(2) * sizeof(*rf9->params))
                    rf9->params[0] = ps_type(self->a, PT_STR, e->pos)
                    rf9->params[1] = ps_type(self->a, PT_INT, e->pos)
                    rf9->nparams = 2
                    return rf9
                if strcmp(cm, "send_to") == 0:
                    if e->nargs != 5:
                        fatal_at(self->file, e->pos, "send_to(buf, off, n, host, port) takes what to send and WHERE — a datagram carries its destination (F7)")
                    for si in range(3):
                        sat: *PsType = self->check_expr(e->args[si])
                        if si == 0:
                            if sat == None or sat->kind != PT_BUFFER:
                                fatal_at(self->file, e->args[0]->pos, "send_to() takes a Buffer, found %s", ps_type_str(self->a, sat))
                        else:
                            self->want(e->args[si], sat, ps_type(self->a, PT_INT, e->pos), "where in the Buffer" if si == 1 else "how many bytes")
                    sh9: *PsType = self->check_expr(e->args[3])
                    self->want(e->args[3], sh9, ps_type(self->a, PT_STR, e->pos), "the address to send to")
                    sp9: *PsType = self->check_expr(e->args[4])
                    self->want(e->args[4], sp9, ps_type(self->a, PT_INT, e->pos), "the port")
                    return ps_type(self->a, PT_INT, e->pos)
                if strcmp(cm, "read_into") == 0 or strcmp(cm, "write_from") == 0:
                    self->io_window(e, cm)
                    ctk->inner = ps_type(self->a, PT_INT, e->pos)
                    return ctk
                if e->nargs != 0:
                    fatal_at(self->file, e->pos, "'%s' takes no arguments", cm)
                if strcmp(cm, "accept") == 0:
                    ctk->inner = ps_type(self->a, PT_CONN, e->pos)
                    return ctk
                if strcmp(cm, "close") == 0:
                    return ps_type(self->a, PT_VOID, e->pos)
                if strcmp(cm, "port") == 0:
                    return ps_type(self->a, PT_INT, e->pos)
                fatal_at(self->file, e->pos, "a socket has accept, read_into, write, write_from, close and port; a DATAGRAM one has recv_from and send_to (77.1/135.2/F7) — not '%s'", cm)
            # 48.1 + 76.2: every one of these is a TASK now. The names say what
            # comes back, because the return type follows the name and not the
            # number of arguments: `read(n)` gives BYTES (up to n, empty at the
            # end — the semantics of recv, 79.2), `text()` gives the whole
            # thing decoded, `read_all()` gives the whole thing as bytes.
            if rt != None and rt->kind == PT_FILE:
                fm: const *char = e->lhs->text
                e->lhs->type = rt
                ftk: *PsType = ps_type(self->a, PT_TASK, e->pos)
                if strcmp(fm, "write") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "write() takes one str, one `bytes` or one List<u8>")
                    wat: *PsType = self->check_expr(e->args[0])
                    if wat == None or not (wat->kind == PT_STR or wat->kind == PT_BYTES or (wat->kind == PT_LIST and wat->inner != None and wat->inner->kind == PT_INT and wat->inner->width == 8)):
                        fatal_at(self->file, e->pos, "write() takes a str, `bytes` or a List<u8>, found %s", ps_type_str(self->a, wat))
                    ftk->inner = ps_type(self->a, PT_INT, e->pos)
                    return ftk
                if strcmp(fm, "read_into") == 0 or strcmp(fm, "write_from") == 0:
                    self->io_window(e, fm)
                    ftk->inner = ps_type(self->a, PT_INT, e->pos)
                    return ftk
                if e->nargs != 0:
                    fatal_at(self->file, e->pos, "'%s' takes no arguments", fm)
                if strcmp(fm, "size") == 0:
                    # 135.10: o tamanho de um ficheiro JÁ ABERTO, perguntado ao
                    # DESCRITOR. O `path.getsize` obriga a guardar o caminho
                    # depois de se ter o `File`, e a perguntar ao NOME — o que
                    # abre uma janela entre a resposta e a leitura em que o
                    # ficheiro pode ser trocado por outro.
                    #
                    # Não é `await`: um `fstat` num descritor aberto responde do
                    # que o núcleo já tem, e mandá-lo à piscina custaria mais do
                    # que a resposta.
                    return ps_type(self->a, PT_INT, e->pos)
                if strcmp(fm, "read_all") == 0:
                    # 135.9: what changes in a file is only what gave back
                    # BYTES. `text()` and `readlines()` stay exactly as they
                    # were — they are text convenience, not byte I/O, and
                    # nobody wants them to become a buffer.
                    #
                    # 135.10: no ceiling, and it does not need one. Reading a
                    # 4 GB file allocates 4 GB and that is right — it is what
                    # was asked for. A ceiling would be a magic number somebody
                    # would one day have to raise for a legitimate reason, and
                    # the alternative to bringing it all in is not reading less:
                    # it is `os.mmap`.
                    ftk->inner = ps_type(self->a, PT_BYTES, e->pos)
                    return ftk
                if strcmp(fm, "text") == 0:
                    ftk->inner = ps_type(self->a, PT_STR, e->pos)
                    return ftk
                if strcmp(fm, "readlines") == 0:
                    lr: *PsType = ps_type(self->a, PT_LIST, e->pos)
                    lr->inner = ps_type(self->a, PT_STR, e->pos)
                    ftk->inner = lr
                    return ftk
                if strcmp(fm, "close") == 0:
                    ftk->inner = ps_type(self->a, PT_VOID, e->pos)
                    return ftk
                fatal_at(self->file, e->pos, "a file has read_into, read_all, text, readlines, write, write_from, size and close (48.1/76.2/135.2/135.10), not '%s'", fm)
            # `w.send(x)` / `await w.recv()` — the worker IS the channel (36.1),
            # and one worker is one pipe in both directions.
            if rt != None and rt->kind == PT_WORKER:
                wm: const *char = e->lhs->text
                if strcmp(wm, "send") == 0:
                    if e->nargs != 1:
                        fatal_at(self->file, e->pos, "send() takes one message")
                    smt: *PsType = self->check_expr(e->args[0])
                    self->want(e->args[0], smt, rt->inner, "the message")
                    e->lhs->type = rt
                    # 45.3: `send` to a worker that is gone answers False —
                    # neither an exception nor silence
                    return ps_type(self->a, PT_BOOL, e->pos)
                # 107.8: o predicado. `w.alive()` de fora, `parent.open()` de
                # dentro — a mesma pergunta ("ainda pode chegar mensagem?"), com
                # o nome que se lê melhor de cada lado. Os dois nomes valem nos
                # dois, porque recusar um deles seria só decorar.
                if strcmp(wm, "close") == 0:
                    # 107.8: o pai diz que acabou de mandar. Do lado do worker
                    # não existe: ele fecha ao RETORNAR, e é o `done` que a fila
                    # de subida sempre teve.
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "close() takes no arguments")
                    if e->lhs->lhs->kind == PE_NAME and strcmp(e->lhs->lhs->text, "parent") == 0:
                        fatal_at(self->file, e->pos, "`parent.close()` does not exist: a worker closes its side by RETURNING, and whoever reads it sees the channel end there (36.4)")
                    e->lhs->type = rt
                    return ps_type(self->a, PT_VOID, e->pos)
                if strcmp(wm, "alive") == 0 or strcmp(wm, "open") == 0:
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "%s() takes no arguments", wm)
                    e->lhs->type = rt
                    return ps_type(self->a, PT_BOOL, e->pos)
                if strcmp(wm, "error") == 0:
                    # 37.3/37.4: the parent COLLECTS the failure and decides —
                    # relaunch, rethrow, ignore. The object is the same `Error`
                    # a catch binds, rebuilt in THIS heap, and collecting it is
                    # what silences the automatic stderr line at join.
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "error() takes no arguments")
                    e->lhs->type = rt
                    ert: *PsType = ps_type(self->a, PT_NAME, e->pos)
                    ert->name = "Error"
                    eo: *PsType = ps_type(self->a, PT_OPT, e->pos)
                    eo->inner = ert
                    return eo
                if strcmp(wm, "detach") == 0:
                    # 36.3: the program stops waiting for THIS one at the end.
                    # Nothing is killed — a worker only ever finishes itself
                    # (36.4) — the shutdown simply does not block on it.
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "detach() takes no arguments")
                    e->lhs->type = rt
                    return ps_type(self->a, PT_VOID, e->pos)
                if strcmp(wm, "recv") == 0:
                    if e->nargs != 0:
                        fatal_at(self->file, e->pos, "recv() takes no arguments")
                    e->lhs->type = rt
                    rtk: *PsType = ps_type(self->a, PT_TASK, e->pos)
                    rtk->inner = rt->inner
                    return rtk
                fatal_at(self->file, e->pos, "a worker has send, recv, alive (`open` reads better on `parent`), close, detach and error (36.1/37.3/107.8), not '%s' — and what it is DOING is `status(w)`, a function and not a method, because it also answers for a worker that is already gone", wm)
            # a method on a `dyn Trait` (66.3): the call goes through the
            # vtable in the box, and what is checked here is the TRAIT's
            # signature — the concrete type is not known and is not needed
            if rt != None and rt->kind == PT_DYN:
                td3: *PsDecl = self->traits.get_or(rt->name, None)
                dm: *PsFunc = None
                for i in range(td3->nmethods):
                    if strcmp(td3->methods[i]->name, e->lhs->text) == 0:
                        dm = td3->methods[i]
                        break
                if dm == None:
                    fatal_at(self->file, e->pos, "trait '%s' has no method '%s'", ps_disp(td3->name), e->lhs->text)
                if e->nargs != dm->nparams - 1:
                    fatal_at(self->file, e->pos, "'%s.%s' takes %d argument(s), %d given", ps_disp(td3->name), dm->name, dm->nparams - 1, e->nargs)
                for i in range(e->nargs):
                    self->check_want(e->args[i], self->sig_type(td3->ns, dm->params[i + 1].type, None), self->a->printf("parameter '%s'", dm->params[i + 1].name))
                e->lhs->type = rt
                e->is_dyn = True
                return self->sig_type(td3->ns, dm->ret, None)
            if rt == None or rt->kind != PT_NAME or not self->records.has(rt->name):
                fatal_at(self->file, e->pos, "'.%s()' on %s, which has no methods", e->lhs->text, ps_type_str(self->a, rt))
            rd: *PsDecl = self->records.get_or(rt->name, None)
            mth: *PsFunc = self->find_method(rd, e->lhs->text)
            if mth == None:
                # 112: um CAMPO que guarda função é chamável. A 28.1 diz que
                # função é valor e que valor vive em contêiner, e um campo é
                # contêiner — `x.f(a)` só é método quando o método existe. É o
                # que um toolkit de widgets pede: o comportamento do widget do
                # app mora em campos do nó.
                fty7: *PsType = None
                for fi in range(rd->nfields):
                    if strcmp(rd->fields[fi].name, e->lhs->text) == 0:
                        fty7 = self->resolve_type(rd->fields[fi].type)
                        break
                if fty7 != None and fty7->kind == PT_OPT and fty7->inner != None and fty7->inner->kind == PT_FUNC:
                    # a prova de não-nulo é sobre LOCAL (43.1), então a saída é
                    # tirar o campo para uma variável — e a mensagem diz como
                    fatal_at(self->file, e->pos, "'%s.%s' may be None: take it out first — `f = x.%s` and then `if f != None: f(...)` (43.1 proves it on a LOCAL, not on a field)", rt->name, e->lhs->text, e->lhs->text)
                if fty7 != None and fty7->kind == PT_FUNC:
                    if fty7->wide:
                        fatal_at(self->file, e->pos, "'%s.%s' is a bare `def`: narrow it before calling — `f as def(str) -> bool` (29.4)", rt->name, e->lhs->text)
                    if e->nargs != fty7->nparams:
                        fatal_at(self->file, e->pos, "'%s.%s' takes %d argument(s), %d given", rt->name, e->lhs->text, fty7->nparams, e->nargs)
                    for i in range(e->nargs):
                        self->check_want(e->args[i], fty7->params[i], "an argument")
                    e->lhs->type = fty7        # é o CAMPO, não o receptor: a
                    return fty7->inner         #   lowering vê a função e não um método
                fatal_at(self->file, e->pos, "'%s' has no method '%s'", rt->name, e->lhs->text)
            nrecv: i32 = 1 if not mth->is_smethod else 0
            if mth->nparams - nrecv > 0:
                self->bind_call_args(e, &mth->params[nrecv], mth->nparams - nrecv, self->a->printf("'%s.%s'", rt->name, mth->name))
            if e->nargs != mth->nparams - nrecv:
                fatal_at(self->file, e->pos, "'%s.%s' takes %d argument(s), %d given", rt->name, mth->name, mth->nparams - nrecv, e->nargs)
            # 112: `check_want` e não `check_expr` + `want`: o argumento de um
            # MÉTODO também é contexto. Uma lambda não tem anotação (a forma do
            # Python), então o tipo do parâmetro é o único lugar de onde os
            # tipos dela podem vir — e uma lista vazia está na mesma posição.
            # Era o que faltava para `ui.on_click(id, lambda i, a: ...)`.
            for i in range(e->nargs):
                self->check_want(e->args[i], mth->params[i + nrecv].type, self->a->printf("parameter '%s'", mth->params[i + nrecv].name))
            e->lhs->type = rt
            mret: *PsType = mth->ret if mth->ret != None else ps_type(self->a, PT_VOID, e->pos)
            if mth->is_async:
                # 35.3: calling it STARTS it and hands back the task, exactly as
                # a free `async def` does. A method is not a different kind of
                # function — it is a function with a receiver.
                mtk: *PsType = ps_type(self->a, PT_TASK, e->pos)
                mtk->inner = mret
                return mtk
            return mret
        # a VALUE of function type, called (28.1): a local, a parameter, an
        # element of a `Dict<str, def(...)>`, the result of an index
        sig7: *PsType = None
        if e->lhs != None and e->lhs->kind == PE_NAME:
            lv7: i32 = self->find_local(e->lhs->text)
            if lv7 >= 0 and self->locals[lv7].type != None and self->locals[lv7].type->kind == PT_FUNC:
                sig7 = self->locals[lv7].type
                self->check_expr(e->lhs)
            elif lv7 < 0:
                # a MODULE variable holding a function (28.1) — which is what a
                # decorated name is (28.3), and what a dispatch table built at
                # the top level is too
                gv7: *PsType = self->globals.get_or(self->gname(e->lhs->text, e->pos), None)
                if gv7 != None and gv7->kind == PT_FUNC:
                    sig7 = gv7
                    self->check_expr(e->lhs)
        elif e->lhs != None and e->lhs->kind in {PE_INDEX, PE_CALL}:
            # the result of an index or of another CALL: `table[k](x)`, and
            # `repeat(3)(f)` — a decorator that takes arguments is exactly a
            # call whose callee is a call (28.3)
            it7: *PsType = self->check_expr(e->lhs)
            if it7 != None and it7->kind == PT_FUNC:
                sig7 = it7
        if sig7 != None and sig7->wide:
            fatal_at(self->file, e->pos, "this is a bare `def`: its signature is not known, so narrow it before calling — `f as def(str) -> bool` (29.4)")
        if sig7 != None:
            if e->nargs != sig7->nparams:
                fatal_at(self->file, e->pos, "this function takes %d argument(s), %d given", sig7->nparams, e->nargs)
            for i in range(e->nargs):
                self->check_want(e->args[i], sig7->params[i], "an argument")
            return sig7->inner
        if e->lhs == None or e->lhs->kind != PE_NAME:
            fatal_at(self->file, e->pos, "only a plain function name can be called for now")
        name: const *char = self->gname(e->lhs->text, e->pos)
        e->lhs->text = name
        # 65.11: the comptime intrinsics of the P, answered HERE and gone before
        # the lowering sees them. `is_defined` never CHECKS its argument — the
        # whole point of asking is that the name may not exist.
        if strcmp(name, "is_defined") == 0 and not self->funcs.has(name):
            if e->nargs != 1 or e->args[0]->kind != PE_NAME:
                fatal_at(self->file, e->pos, "is_defined() takes one NAME, and answers at compile time")
            dn6: const *char = e->args[0]->text
            dq6: const *char = self->gname(dn6, e->pos)
            known6: bool = self->find_local(dn6) >= 0 or self->globals.has(dq6) or self->funcs.has(dq6) or self->records.has(dq6) or self->enums.has(dq6) or self->enumof.has(dq6) or self->cfuncs.has(dn6) or self->cconsts.has(dn6) or self->traits.has(dq6)
            e->kind = PE_BOOL
            e->text = "True" if known6 else "False"
            e->nargs = 0
            return ps_type(self->a, PT_BOOL, e->pos)
        if strcmp(name, "typestr") == 0 and not self->funcs.has(name):
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "typestr() takes one value and answers its type as a string, at compile time")
            tt6: *PsType = self->check_expr(e->args[0])
            e->kind = PE_STR
            e->text = self->a->printf("\"%s\"", ps_type_str(self->a, tt6))
            e->nargs = 0
            return ps_type(self->a, PT_STR, e->pos)
        if strcmp(name, "hasfield") == 0 and not self->funcs.has(name):
            if e->nargs != 2 or e->args[0]->kind != PE_NAME or e->args[1]->kind != PE_STR:
                fatal_at(self->file, e->pos, "hasfield() takes a TYPE and a field name written as a string: `hasfield(Vec, \"z\")`")
            tn6: const *char = self->gname(e->args[0]->text, e->pos)
            rd6: *PsDecl = self->records.get_or(tn6, None)
            if rd6 == None:
                fatal_at(self->file, e->pos, "hasfield(): '%s' is not a record or a struct declared here", e->args[0]->text)
            fl6: usize = 0
            fn6: const *char = str_lit_decode_py(self->a, e->args[1]->text, out fl6)
            hit6: bool = False
            for i in range(rd6->nfields):
                if strcmp(rd6->fields[i].name, fn6) == 0:
                    hit6 = True
            e->kind = PE_BOOL
            e->text = "True" if hit6 else "False"
            e->nargs = 0
            return ps_type(self->a, PT_BOOL, e->pos)
        # a type name used as a call CONSTRUCTS (54.2) — checked before the
        # named-argument guard below, because the constructor is where named
        # arguments already work
        if self->records.has(name):
            return self->check_ctor(e, self->records.get_or(name, None))
        for i in range(e->nargs):
            # `sorted(xs, key=f)` names its second argument, and that name is
            # part of what the builtin IS (28.4) — the general named argument
            # (44.1's `f(x=1)`) is still ahead
            if e->args[i]->kind == PE_DESIG and strcmp(name, "sorted") != 0 and strcmp(name, "gather_map") != 0 and strcmp(name, "__gc_tune") != 0 and strcmp(name, "__os_run") != 0 and not self->funcs.has(name) and not self->cfuncs.has(name):
                fatal_at(self->file, e->args[i]->pos, "'%s' does not take named arguments", ps_disp(name))
        if self->cfuncs.has(name) and not self->funcs.has(name):
            cf: *PsFunc = self->cfuncs.get_or(name, None)
            if e->nargs != cf->nparams:
                fatal_at(self->file, e->pos, "'%s' takes %d argument(s), %d given", name, cf->nparams, e->nargs)
            for i in range(e->nargs):
                at4: *PsType = self->check_expr(e->args[i])
                # 84.1: what the lowering needs to know at the call, marked on
                # the nodes it will see — the same way `is_in` is
                e->args[i]->cstr_arg = cf->params[i].cstr
                if cf->params[i].cstr != 0 and cf->params[i].is_in:
                    # `in s: CStr` on the P side: what goes over is the ADDRESS
                    # of the pair the call builds, which is P's own spelling
                    e->args[i]->is_in = True
                if cf->params[i].is_in and cf->params[i].cstr == 0:
                    # 72.6, checked HERE because only the call site knows what
                    # it is handing over: a `const` module variable of that
                    # record type. A const lives in C's file scope — its
                    # address is stable, the collector never touches it, and
                    # nothing can change its bytes while the other side reads.
                    if e->args[i]->kind != PE_NAME or not self->gconst.has(e->args[i]->text):
                        fatal_at(self->file, e->args[i]->pos, "'%s' takes '%s' by reference (72.6), so the argument has to be a module-level `const` of type %s — a value with an address that is stable and bytes nothing can change", name, cf->params[i].name, ps_type_str(self->a, cf->params[i].type))
                    e->args[i]->is_in = True
                if cf->params[i].cstr == 2:
                    # either currency crosses as a `CBytes` (84.1/135.3), and
                    # `bytes` crosses BETTER: its block is outside the heap and
                    # never moves, so the pair points straight at it
                    if not self->cbytes_ok(at4):
                        fatal_at(self->file, e->args[i]->pos, "parameter '%s' is a `CBytes`: it takes `bytes` or a List<u8>, found %s (84.1)", cf->params[i].name, ps_type_str(self->a, at4))
                    e->args[i]->type = at4
                else:
                    self->want(e->args[i], at4, cf->params[i].type, self->a->printf("parameter '%s'", cf->params[i].name))
            e->is_cfunc = True
            e->cstr_ret = cf->ret_cstr
            return cf->ret
        if self->funcs.has(name):
            f: *PsFunc = self->funcs.get_or(name, None)
            if f->is_ceval:
                # 65.10: a chamada NÃO fica. O que fica é o literal que ela deu,
                # escrito por cima deste nó — e é por isso que o `const def` não
                # é emitido: depois desta linha não há quem lhe chame.
                top: CEnv
                top.names.init()
                top.vals.init()
                top.ret = None
                top.done = False
                tv: **PsExpr = self->a->alloc(usize(e->nargs + 1) * sizeof(*tv))
                for k9 in range(e->nargs):
                    tv[k9] = self->ceval_expr(e->args[k9], ref top)
                lit: *PsExpr = self->ceval_call(f, tv, e->nargs, e->pos)
                top.names.deinit()
                top.vals.deinit()
                *e = *lit
                return e->type
            if f->ntparams > 0:
                return self->call_generic(e, f, name)
            if f->is_async:
                # 35.3: calling it STARTS it and gives back the task; the value
                # is collected with `await`
                if e->nargs != f->nparams:
                    fatal_at(self->file, e->pos, "'%s' takes %d argument(s), %d given", ps_disp(name), f->nparams, e->nargs)
                for i in range(e->nargs):
                    self->check_want(e->args[i], f->params[i].type, self->a->printf("parameter '%s'", f->params[i].name))
                tk2: *PsType = ps_type(self->a, PT_TASK, e->pos)
                tk2->inner = f->ret if f->ret != None else ps_type(self->a, PT_VOID, e->pos)
                return tk2
            self->bind_call_args(e, f->params, f->nparams, self->a->printf("'%s'", ps_disp(name)))
            vf: bool = f->nparams > 0 and f->params[f->nparams - 1].is_varargs
            if (not vf and e->nargs != f->nparams) or (vf and e->nargs < f->nparams - 1):
                fatal_at(self->file, e->pos, "'%s' takes %s%d argument(s), %d given", name, "at least " if vf else "", f->nparams - (1 if vf else 0), e->nargs)
            for i in range(e->nargs):
                pi: i32 = i if i < f->nparams else f->nparams - 1
                pt: *PsType = f->params[pi].type
                if e->args[i] != None and e->args[i]->is_splat:
                    # `f(*xs)` (44.2): the list is handed over WHOLE, so it has
                    # to be the collecting parameter and nothing may follow it
                    if not f->params[pi].is_varargs or i != e->nargs - 1:
                        fatal_at(self->file, e->args[i]->pos, "`*xs` spreads into a `*rest` parameter, and has to be the last argument (44.2)")
                    self->check_want(e->args[i], pt, self->a->printf("the spread into '%s'", f->params[pi].name))
                elif f->params[pi].is_varargs:
                    # the extra ones are ELEMENTS of the list (44.2)
                    self->check_want(e->args[i], pt->inner, self->a->printf("an element of '%s'", f->params[pi].name))
                else:
                    # 65.12: `out`/`ref` are spelled at the CALL SITE too, the
                    # way P spells them and for the same reason — a call that
                    # can write to your variable should say so where you read
                    # it, not only where the function was declared.
                    if f->params[pi].is_out or f->params[pi].is_ref:
                        kw5: const *char = "out" if f->params[pi].is_out else "ref"
                        gv5: bool = e->args[i] != None and (e->args[i]->is_out if f->params[pi].is_out else e->args[i]->is_ref)
                        if not gv5:
                            fatal_at(self->file, e->args[i]->pos, "parameter '%s' of '%s' is `%s`, so the argument is written `%s x` (65.12)", f->params[pi].name, ps_disp(name), kw5, kw5)
                        if e->args[i]->kind != PE_NAME:
                            # A plain VARIABLE and nothing else. A field of a
                            # collected object would hand over a pointer INTO
                            # something the collector moves, which 17.2 refuses
                            # outright — and a local or a module variable has an
                            # address that stands still (one is on the C stack,
                            # the other in the context's own globals).
                            fatal_at(self->file, e->args[i]->pos, "`%s` takes a plain variable: a field or an element would be an address INSIDE an object the collector moves (17.2) — read it out, pass the variable, write it back", kw5)
                        self->byref_ok(pt, e->args[i]->pos, kw5)
                    elif e->args[i] != None and (e->args[i]->is_out or e->args[i]->is_ref):
                        fatal_at(self->file, e->args[i]->pos, "parameter '%s' of '%s' is an ordinary parameter: it takes a value, not `out`/`ref` (65.12)", f->params[pi].name, ps_disp(name))
                    self->check_want(e->args[i], pt, self->a->printf("parameter '%s'", f->params[pi].name))
            return f->ret if f->ret != None else ps_type(self->a, PT_VOID, e->pos)
        return self->builtin_call(e, name)

    # A call to `def f<T: Trait>(...)` (66.3). The type parameter is READ OFF
    # the arguments — nobody writes `f<int>(...)` — the bound is checked here,
    # where the concrete type finally exists, and what the call ends up naming
    # is an ordinary function: a copy of the body with the type in place.
    #
    # Monomorphizing is what makes the bound free. There is no vtable and no
    # boxing, and the calls inside the body resolve by the method lookup that
    # was already there. It is also why the check is at the instantiation and
    # not on the generic body: P answers this the same way (D1/67.1), and two
    # languages disagreeing about when a bound is checked would be a trap.
    # Positional arguments, then `name=value`, then the DEFAULTS for whatever
    # is still missing (44.1/44.2). What comes out is a plain positional list
    # in declaration order, so nothing downstream — checking, lowering, the
    # back ends — ever learns that named arguments or defaults exist.
    #
    # The default is COPIED per call site and evaluated there, which is what
    # gives `def f(xs=[])` a new list every call instead of Python's one shared
    # list. It is checked with the caller's locals HIDDEN: a default belongs to
    # the scope that WROTE it, so a caller local that happens to share a name
    # with a module variable cannot capture it.
    private def bind_call_args(self: *PsSema, e: *PsExpr, params: *PsParam, nparams: i32, what: const *char):
        vf: bool = nparams > 0 and params[nparams - 1].is_varargs
        named: bool = False
        for i in range(e->nargs):
            if e->args[i] != None and e->args[i]->kind == PE_DESIG:
                named = True
        if not named and e->nargs == nparams:
            return                      # the ordinary call: nothing to arrange
        if vf:
            if named:
                fatal_at(self->file, e->pos, "%s takes `*%s`, and a named argument cannot be told from an element of it (44.2)", what, params[nparams - 1].name)
            return                      # the varargs path packs the rest itself
        if not named and e->nargs > nparams:
            fatal_at(self->file, e->pos, "%s takes %d argument(s), %d given", what, nparams, e->nargs)
        slots: **PsExpr = self->a->alloc(usize(nparams if nparams > 0 else 1) * sizeof(*slots))
        for i in range(nparams):
            slots[i] = None
        pos_done: bool = False
        npos: i32 = 0
        for i in range(e->nargs):
            a: *PsExpr = e->args[i]
            if a != None and a->kind == PE_DESIG:
                pos_done = True
                pi: i32 = -1
                for j in range(nparams):
                    if strcmp(params[j].name, a->text) == 0:
                        pi = j
                if pi < 0:
                    fatal_at(self->file, a->pos, "%s has no parameter named '%s'", what, a->text)
                if slots[pi] != None:
                    fatal_at(self->file, a->pos, "'%s' was given twice", a->text)
                slots[pi] = a->lhs
            else:
                if pos_done:
                    fatal_at(self->file, a->pos, "a positional argument cannot follow a named one")
                if npos >= nparams:
                    fatal_at(self->file, e->pos, "%s takes %d argument(s), %d given", what, nparams, e->nargs)
                slots[npos] = a
                npos += 1
        for i in range(nparams):
            if slots[i] == None:
                if params[i].dflt == None:
                    fatal_at(self->file, e->pos, "%s is missing '%s'", what, params[i].name)
                d: *PsExpr = ps_copy_expr(self->a, params[i].dflt)
                saved: i32 = self->nlocals
                self->nlocals = 0       # a default sees the scope that WROTE it
                self->check_want(d, params[i].type, self->a->printf("the default of '%s'", params[i].name))
                self->nlocals = saved
                d->dflt_bound = True
                slots[i] = d
        e->args = slots
        e->nargs = nparams

    # 60.3/62.1 — `Sequence<T>` como parâmetro, e o que ele realmente é.
    #
    # `def total(xs: Sequence<float>)` vira, aqui e agora,
    #
    #     def total<__seq: Sequence<float>>(xs: __seq)
    #
    # e daí em diante a maquinaria é a que existe desde a 66.3: o parâmetro é
    # inferido do argumento, o limite é conferido onde o tipo concreto está, e o
    # corpo é monomorfizado. **Zero vtable e zero cópia** — que é o que a 60.3
    # prometeu e o que um parâmetro `List<float>` não dava, porque obrigava quem
    # tem um `float[8]` a construir uma lista para poder chamar.
    #
    # **Vários parâmetros `Sequence` partilham UM parâmetro de tipo**, portanto
    # `def dot(a: Sequence<float>, b: Sequence<float>)` exige que os dois sejam
    # o mesmo contentor. É uma restrição real e é a honesta: a alternativa era
    # um parâmetro de tipo por argumento, e a monomorfização compila um.
    private def desugar_sequence(self: *PsSema, d: *PsDecl):
        f: *PsFunc = d->func
        if f == None or f->nparams == 0:
            return
        first: i32 = -1
        for i in range(f->nparams):
            if f->params[i].type != None and f->params[i].type->kind == PT_SEQ:
                if first < 0:
                    first = i
                elif not ps_type_eq(f->params[i].type->inner, f->params[first].type->inner):
                    fatal_at(self->file, f->params[i].type->pos, "'%s' asks for two different Sequence elements; the parameters share ONE type parameter, so they share the element too (60.3)", ps_disp(f->name))
        if first < 0:
            return
        if f->ntparams > 0:
            fatal_at(self->file, f->pos, "'%s' is already generic: a `Sequence` parameter IS the type parameter, so the two are not written together (60.3)", ps_disp(f->name))
        tp: *PsTParam = self->a->alloc(sizeof(PsTParam))
        tp->name = self->a->printf("__seq_%s", f->name)
        tp->bound = None
        tp->seq_elem = f->params[first].type->inner
        tp->pos = f->params[first].type->pos
        f->tparams = tp
        f->ntparams = 1
        for j in range(f->nparams):
            if f->params[j].type != None and f->params[j].type->kind == PT_SEQ:
                nt: *PsType = ps_type(self->a, PT_NAME, f->params[j].type->pos)
                nt->name = tp->name
                f->params[j].type = nt

    # ---------- 65.10: avaliar um `const def` ----------
    #
    # Uma chamada a um `const def` é substituída pelo literal que ela dá, e a
    # função nunca chega a existir. O que segue é o interpretador que produz
    # esse literal — pequeno de propósito, e a recusar pelo nome tudo o que não
    # sabe fazer.
    private def ceval_call(self: *PsSema, f: *PsFunc, args: **PsExpr, nargs: i32, pos: Pos) -> *PsExpr:
        if f->is_async:
            fatal_at(self->file, pos, "'%s' is a `const def` and `async`: a function evaluated at compile time has nothing to wait for (65.10)", ps_disp(f->name))
        if nargs != f->nparams:
            fatal_at(self->file, pos, "'%s' takes %d argument(s), %d given", ps_disp(f->name), f->nparams, nargs)
        self->cdepth += 1
        if self->cdepth > 64:
            fatal_at(self->file, pos, "'%s' calls itself deeper than a compile-time evaluation goes (65.10): 64 frames", ps_disp(f->name))
        # os argumentos chegam JÁ AVALIADOS, e não podia ser de outra maneira:
        # eles pertencem ao ambiente de quem CHAMA, e o ambiente novo é o do
        # corpo. Avaliá-los aqui dava um `fib(n - 1)` a procurar o `n` do
        # próprio `fib` que ainda não tem nenhum — que é uma recursão a olhar
        # para dentro de si em vez de para fora.
        env: CEnv
        env.names.init()
        env.vals.init()
        env.ret = None
        env.done = False
        for i in range(nargs):
            cenv_set(ref env, f->params[i].name, args[i])
        self->ceval_block(f->body, ref env, pos)
        self->cdepth -= 1
        if env.ret == None:
            fatal_at(self->file, pos, "'%s' is a `const def` and this call reached its end without a `return` (65.10): a compile-time evaluation has to produce a value", ps_disp(f->name))
        r: *PsExpr = env.ret
        env.names.deinit()
        env.vals.deinit()
        return r

    private def ceval_step(self: *PsSema, pos: Pos):
        self->cbudget -= 1
        if self->cbudget <= 0:
            fatal_at(self->file, pos, "a compile-time evaluation ran past its budget of %d steps (65.10) — a `const def` that does not finish is a compiler that does not answer, which is why the budget exists", CEVAL_BUDGET)

    private def ceval_block(self: *PsSema, b: *PsBlock, ref env: CEnv, pos: Pos):
        if b == None:
            return
        for i in range(b->n):
            if env.done:
                return
            self->ceval_stmt(b->stmts[i], ref env)

    private def ceval_stmt(self: *PsSema, s: *PsStmt, ref env: CEnv):
        self->ceval_step(s->pos)
        match s->kind:
            case PS_RETURN:
                env.ret = self->ceval_expr(s->expr, ref env) if s->expr != None else None
                env.done = True
            case PS_VAR, PS_ASSIGN:
                if s->lhs != None and s->lhs->kind != PE_NAME:
                    fatal_at(self->file, s->pos, "a `const def` assigns to plain names only (65.10)")
                nm: const *char = s->name if s->name != None else s->lhs->text
                if s->op != 0 and s->op != TK_ASSIGN:
                    # `x += e` — o mesmo operador composto, resolvido aqui
                    cur: *PsExpr = cenv_get(ref env, nm)
                    if cur == None:
                        fatal_at(self->file, s->pos, "'%s' is not a name this compile-time evaluation knows", nm)
                    cenv_set(ref env, nm, self->ceval_binop(self->ceval_aug_op(s->op, s->pos), cur, self->ceval_expr(s->rhs, ref env), s->pos))
                else:
                    if s->rhs == None:
                        fatal_at(self->file, s->pos, "a name in a `const def` is born with a value (65.10)")
                    cenv_set(ref env, nm, self->ceval_expr(s->rhs, ref env))
            case PS_EXPR:
                _ = self->ceval_expr(s->expr, ref env)
            case PS_PASS:
                pass
            case PS_IF:
                for k in range(s->nconds):
                    if cbool(self->ceval_expr(s->conds[k], ref env)):
                        self->ceval_block(s->blocks[k], ref env, s->pos)
                        return
                self->ceval_block(s->else_block, ref env, s->pos)
            case PS_WHILE:
                while cbool(self->ceval_expr(s->cond, ref env)) and not env.done:
                    self->ceval_step(s->pos)
                    self->ceval_block(s->body, ref env, s->pos)
            case PS_FOR:
                # um `range`, e nada mais. O protocolo geral de iteração (40.3)
                # precisa de um cursor mutável, e em compilação não há contentor
                # nenhum para percorrer — o mesmo motivo pelo qual a v1 do `for`
                # em tempo de execução também só sabe `range`.
                isr: bool = s->iter != None and s->iter->kind == PE_CALL and s->iter->lhs != None and s->iter->lhs->kind == PE_NAME and strcmp(s->iter->lhs->text, "range") == 0
                if not isr or s->nnames != 1:
                    fatal_at(self->file, s->pos, "a `for` in a `const def` walks a `range(...)` with one variable (65.10): at compile time there is no container to walk")
                na: i32 = s->iter->nargs
                if na < 1 or na > 3:
                    fatal_at(self->file, s->pos, "`range` takes one, two or three arguments")
                lo: i64 = 0
                hi: i64 = 0
                st: i64 = 1
                if na == 1:
                    hi = cint(self->ceval_expr(s->iter->args[0], ref env))
                else:
                    lo = cint(self->ceval_expr(s->iter->args[0], ref env))
                    hi = cint(self->ceval_expr(s->iter->args[1], ref env))
                    if na == 3:
                        st = cint(self->ceval_expr(s->iter->args[2], ref env))
                if st == 0:
                    fatal_at(self->file, s->pos, "a `range` step of zero never advances")
                v: i64 = lo
                while (v < hi if st > 0 else v > hi) and not env.done:
                    self->ceval_step(s->pos)
                    cenv_set(ref env, s->names[0], cmk_int(self->a, v, s->pos))
                    self->ceval_block(s->body, ref env, s->pos)
                    v += st
            case _:
                fatal_at(self->file, s->pos, "a `const def` does not do this at compile time (65.10): what it computes is numbers and booleans, with `if`, `while`, `for i in range(...)`, locals, and calls to other `const def`s")

    # o operador por trás de um `+=`, para o composto e o simples serem um só
    private def ceval_aug_op(self: *PsSema, op: i32, pos: Pos) -> i32:
        if op == TK_PLUS_EQ:
            return TK_PLUS
        if op == TK_MINUS_EQ:
            return TK_MINUS
        if op == TK_STAR_EQ:
            return TK_STAR
        if op == TK_SLASH_EQ:
            return TK_SLASH
        if op == TK_PERCENT_EQ:
            return TK_PERCENT
        fatal_at(self->file, pos, "a `const def` does not compute this compound assignment yet (65.10)")
        return TK_PLUS

    private def ceval_expr(self: *PsSema, e: *PsExpr, ref env: CEnv) -> *PsExpr:
        if e == None:
            # não devia acontecer: quem chama já conferiu. Mas um avaliador que
            # rebenta em vez de dizer é a pior maneira de descobrir isso.
            z: Pos
            z.line = 0
            z.col = 0
            fatal_at(self->file, z, "a `const def` was handed nothing to evaluate")
        self->ceval_step(e->pos)
        match e->kind:
            case PE_INT, PE_FLOAT, PE_BOOL:
                return e
            case PE_NAME:
                v: *PsExpr = cenv_get(ref env, e->text)
                if v != None:
                    return v
                # um `const` do módulo é conhecido em compilação por definição,
                # e é o que torna `const N: int = 8` utilizável dentro de um
                # `const def` sem o passar como argumento
                gn: const *char = self->gname_soft(e->text)
                if self->gconst_num.has(gn):
                    return cmk_int(self->a, self->gconst_num.get_or(gn, 0), e->pos)
                if self->gconst_num.has(e->text):
                    return cmk_int(self->a, self->gconst_num.get_or(e->text, 0), e->pos)
                fatal_at(self->file, e->pos, "'%s' is not known at compile time: a `const def` sees its own parameters, its own locals, and the module's `const`s (65.10)", e->text)
            case PE_UNARY:
                u: *PsExpr = self->ceval_expr(e->lhs, ref env)
                if e->op == TK_NOT:
                    return cmk_bool(self->a, not cbool(u), e->pos)
                if e->op == TK_MINUS:
                    if u->kind == PE_FLOAT:
                        return cmk_float(self->a, -cnum(u), e->pos)
                    return cmk_int(self->a, -cint(u), e->pos)
                if e->op == TK_PLUS:
                    return u
                fatal_at(self->file, e->pos, "a `const def` does not compute this unary operator yet (65.10)")
            case PE_BINARY:
                # `and`/`or` PARAM no primeiro que decide, como em tempo de
                # execução — e é isso que faz `n != 0 and 100 // n` ser legal
                if e->op == TK_AND:
                    l1: *PsExpr = self->ceval_expr(e->lhs, ref env)
                    if not cbool(l1):
                        return cmk_bool(self->a, False, e->pos)
                    return cmk_bool(self->a, cbool(self->ceval_expr(e->rhs, ref env)), e->pos)
                if e->op == TK_OR:
                    l2: *PsExpr = self->ceval_expr(e->lhs, ref env)
                    if cbool(l2):
                        return cmk_bool(self->a, True, e->pos)
                    return cmk_bool(self->a, cbool(self->ceval_expr(e->rhs, ref env)), e->pos)
                return self->ceval_binop(e->op, self->ceval_expr(e->lhs, ref env), self->ceval_expr(e->rhs, ref env), e->pos)
            case PE_TERNARY:
                return self->ceval_expr(e->lhs if cbool(self->ceval_expr(e->cond, ref env)) else e->rhs, ref env)
            case PE_CALL:
                return self->ceval_callexpr(e, ref env)
            case _:
                fatal_at(self->file, e->pos, "a `const def` computes numbers and booleans (65.10), and this is %s", cval_kind(self->a, e))
        return None

    # `a <op> b`, com a promoção da 32.1: um `int` e um `float` acertam em
    # `float`, e `/` dá sempre `float` enquanto `//` dá o piso — a divisão do
    # Python que a 39.1 fixou, e que aqui tem de dar o MESMO resultado que dá em
    # tempo de execução, senão uma constante muda de valor ao ser dobrada.
    private def ceval_binop(self: *PsSema, op: i32, l: *PsExpr, r: *PsExpr, pos: Pos) -> *PsExpr:
        if not cis_num(l) and l->kind != PE_BOOL:
            fatal_at(self->file, pos, "a `const def` computes numbers and booleans (65.10), and the left side is %s", cval_kind(self->a, l))
        if not cis_num(r) and r->kind != PE_BOOL:
            fatal_at(self->file, pos, "a `const def` computes numbers and booleans (65.10), and the right side is %s", cval_kind(self->a, r))
        flt: bool = l->kind == PE_FLOAT or r->kind == PE_FLOAT
        if op == TK_EQ:
            return cmk_bool(self->a, cnum(l) == cnum(r), pos)
        if op == TK_NE:
            return cmk_bool(self->a, cnum(l) != cnum(r), pos)
        if op == TK_LT:
            return cmk_bool(self->a, cnum(l) < cnum(r), pos)
        if op == TK_LE:
            return cmk_bool(self->a, cnum(l) <= cnum(r), pos)
        if op == TK_GT:
            return cmk_bool(self->a, cnum(l) > cnum(r), pos)
        if op == TK_GE:
            return cmk_bool(self->a, cnum(l) >= cnum(r), pos)
        if op == TK_SLASH:
            # 39.1: `/` é SEMPRE float, mesmo entre dois inteiros
            if cnum(r) == 0.0:
                fatal_at(self->file, pos, "division by zero, at compile time")
            return cmk_float(self->a, cnum(l) / cnum(r), pos)
        if flt:
            if op == TK_POW:
                # o expoente é um INTEIRO não-negativo, e a potência é uma
                # multiplicação repetida. O compilador não liga a `libm` — e um
                # `2 ** 0.5` em compilação era pedir uma raiz quadrada ao
                # compilador, que é um pedido diferente e merece a sua recusa.
                if r->kind == PE_FLOAT or cint(r) < 0:
                    fatal_at(self->file, pos, "`**` at compile time takes a non-negative whole exponent (65.10): the compiler does not link the maths library")
                fp: f64 = 1.0
                for _f in range(i32(cint(r))):
                    fp *= cnum(l)
                return cmk_float(self->a, fp, pos)
            if op == TK_PLUS:
                return cmk_float(self->a, cnum(l) + cnum(r), pos)
            if op == TK_MINUS:
                return cmk_float(self->a, cnum(l) - cnum(r), pos)
            if op == TK_STAR:
                return cmk_float(self->a, cnum(l) * cnum(r), pos)
            fatal_at(self->file, pos, "a `const def` does not compute this operator on floats yet (65.10)")
        li: i64 = cint(l)
        ri: i64 = cint(r)
        if op == TK_PLUS:
            return cmk_int(self->a, li + ri, pos)
        if op == TK_MINUS:
            return cmk_int(self->a, li - ri, pos)
        if op == TK_STAR:
            return cmk_int(self->a, li * ri, pos)
        if op == TK_FLOORDIV or op == TK_PERCENT:
            if ri == 0:
                fatal_at(self->file, pos, "division by zero, at compile time")
            # 39.1: o piso e o resto do PYTHON, e não os do C. Em C o `-7 / 2`
            # trunca para -3 e o resto fica negativo; em Python o piso é -4 e o
            # resto tem o sinal do divisor. Escrito à mão porque o C não o dá.
            q: i64 = li / ri
            m: i64 = li % ri
            if m != 0 and ((m < 0) != (ri < 0)):
                q -= 1
                m += ri
            return cmk_int(self->a, q if op == TK_FLOORDIV else m, pos)
        if op == TK_AMP:
            return cmk_int(self->a, li & ri, pos)
        if op == TK_PIPE:
            return cmk_int(self->a, li | ri, pos)
        if op == TK_CARET:
            return cmk_int(self->a, li ^ ri, pos)
        if op == TK_SHL:
            return cmk_int(self->a, li << ri, pos)
        if op == TK_SHR:
            return cmk_int(self->a, li >> ri, pos)
        if op == TK_POW:
            if ri < 0:
                fatal_at(self->file, pos, "`**` at compile time takes a non-negative whole exponent (65.10): a negative one is a division, and `x ** -1` is written `1 / x`")
            p9: i64 = 1
            for _k in range(i32(ri)):
                p9 *= li
            return cmk_int(self->a, p9, pos)
        fatal_at(self->file, pos, "a `const def` does not compute this operator yet (65.10)")
        return None

    # Uma chamada DENTRO de um `const def`: outro `const def`, ou uma das poucas
    # funções embutidas que fazem sentido sem tempo de execução. Tudo o resto é
    # recusado pelo nome — `print` num `const def` é um pedido para imprimir
    # durante a compilação, e a resposta é dizê-lo em vez de o ignorar.
    private def ceval_callexpr(self: *PsSema, e: *PsExpr, ref env: CEnv) -> *PsExpr:
        if e->lhs == None or e->lhs->kind != PE_NAME:
            fatal_at(self->file, e->pos, "a `const def` calls a plain name (65.10)")
        nm: const *char = e->lhs->text
        if strcmp(nm, "int") == 0 and e->nargs == 1:
            return cmk_int(self->a, cint(self->ceval_expr(e->args[0], ref env)), e->pos)
        if strcmp(nm, "float") == 0 and e->nargs == 1:
            return cmk_float(self->a, cnum(self->ceval_expr(e->args[0], ref env)), e->pos)
        if strcmp(nm, "bool") == 0 and e->nargs == 1:
            return cmk_bool(self->a, cbool(self->ceval_expr(e->args[0], ref env)), e->pos)
        if strcmp(nm, "abs") == 0 and e->nargs == 1:
            av: *PsExpr = self->ceval_expr(e->args[0], ref env)
            if av->kind == PE_FLOAT:
                fv: f64 = cnum(av)
                return cmk_float(self->a, -fv if fv < 0.0 else fv, e->pos)
            iv: i64 = cint(av)
            return cmk_int(self->a, -iv if iv < 0 else iv, e->pos)
        if (strcmp(nm, "min") == 0 or strcmp(nm, "max") == 0) and e->nargs == 2:
            m1: *PsExpr = self->ceval_expr(e->args[0], ref env)
            m2: *PsExpr = self->ceval_expr(e->args[1], ref env)
            wants_lo: bool = strcmp(nm, "min") == 0
            return m1 if (cnum(m1) <= cnum(m2)) == wants_lo else m2
        gf: const *char = self->gname_soft(nm)
        cf: *PsFunc = self->funcs.get_or(gf, None)
        if cf == None:
            cf = self->funcs.get_or(nm, None)
        if cf == None or not cf->is_ceval:
            fatal_at(self->file, e->pos, "a `const def` calls other `const def`s and `int`/`float`/`bool`/`abs`/`min`/`max` (65.10); '%s' is not one of those", ps_disp(nm))
        vals: **PsExpr = self->a->alloc(usize(e->nargs + 1) * sizeof(*vals))
        for k in range(e->nargs):
            vals[k] = self->ceval_expr(e->args[k], ref env)
        return self->ceval_call(cf, vals, e->nargs, e->pos)

    private def call_generic(self: *PsSema, e: *PsExpr, f: *PsFunc, name: const *char) -> *PsType:
        if f->ntparams != 1:
            fatal_at(self->file, e->pos, "'%s' has %d type parameters; one is what is compiled so far", ps_disp(name), f->ntparams)
        if e->nargs != f->nparams:
            fatal_at(self->file, e->pos, "'%s' takes %d argument(s), %d given", ps_disp(name), f->nparams, e->nargs)
        tp: const *char = f->tparams[0].name
        conc: *PsType = None
        for i in range(e->nargs):
            at: *PsType = self->check_expr(e->args[i])
            if conc == None:
                conc = ps_infer(f->params[i].type, at, tp)
        if conc == None:
            fatal_at(self->file, e->pos, "cannot tell what '%s' is in this call to '%s': it has to appear in a parameter's type", tp, ps_disp(name))
        # 60.3: um limite NATIVO — o contentor tem de ser um que a linguagem
        # saiba percorrer, e o elemento tem de ser o pedido. Não há trait para
        # procurar porque não há `implement Sequence for List<T>` para escrever.
        if f->tparams[0].seq_elem != None:
            el9: *PsType = None
            if conc->kind == PT_LIST or conc->kind == PT_ARRAY or conc->kind == PT_VIEW:
                el9 = conc->inner
            elif conc->kind == PT_BYTES:
                el9 = ps_type(self->a, PT_INT, e->pos)
                el9->width = 8
                el9->uns = True
            if el9 == None or not ps_type_eq(el9, f->tparams[0].seq_elem):
                fatal_at(self->file, e->pos, "'%s' takes a Sequence<%s> — a `List`, a `T[N]`, a `View` or `bytes` of it — and %s is not one", ps_disp(name), ps_type_str(self->a, f->tparams[0].seq_elem), ps_type_str(self->a, conc))
        # the bound (66.2/67.3): NOMINAL, so having the methods is not enough —
        # the type has to have declared the trait, in a clause or in a block
        elif f->tparams[0].bound != None:
            td: *PsDecl = self->find_trait_named(f->tparams[0].bound, f->ns, e->pos)
            cn9: const *char = conc->name if conc->kind == PT_NAME else ps_builtin_tname(conc)
            if cn9 == None or not self->timpls.has(self->a->printf("%s|%s", td->name, cn9)):
                fatal_at(self->file, e->pos, "%s does not implement '%s', which '%s' requires of '%s' (66.2)", ps_type_str(self->a, conc), ps_disp(td->name), ps_disp(name), tp)
        key: const *char = self->a->printf("%s|%s", name, ps_type_str(self->a, conc))
        inst: *PsFunc = self->insts.get_or(key, None)
        if inst == None:
            self->ninst += 1
            if self->ninst > 4096:
                fatal_at(self->file, e->pos, "too many instances of generic functions: a generic that instantiates itself with a new type every round never ends")
            iname: const *char = self->a->printf("%s__%s", name, ps_mangle_type(self->a, conc))
            inst = ps_instantiate(self->a, f, conc, iname)
            inst->ns = f->ns
            self->insts.put(key, inst)
            self->funcs.put(iname, inst)
            self->pending.push(inst)
        e->lhs->text = inst->name
        for i in range(e->nargs):
            at2: *PsType = e->args[i]->type
            self->want(e->args[i], at2, inst->params[i].type, self->a->printf("parameter '%s'", inst->params[i].name))
        rt9: *PsType = inst->ret if inst->ret != None else ps_type(self->a, PT_VOID, e->pos)
        if inst->is_async:
            # 35.3, and the ordinary call path already did this: calling an
            # `async def` STARTS it and gives back the task. A generic one is
            # not different, and forgetting it here made `await copy(r, w)`
            # complain that `await` had been handed an `int` — which is what a
            # generic over an async trait does on its very first line.
            tg9: *PsType = ps_type(self->a, PT_TASK, e->pos)
            tg9->inner = rt9
            return tg9
        return rt9

    # 135.2: `read_into(buf, off, n)` and `write_from(buf, off, n)` — the same
    # three arguments on both sides, and the same on a file and on a socket.
    #
    # The `Buffer` is the point: it is malloc'd and never moves (52.3), so the
    # syscall may read and write it DIRECTLY. That is what turns four copies
    # into none — a proxy moving a megabyte used to malloc it, memcpy it into a
    # collected `List<u8>`, slice it, and copy again.
    # 140/F5: o que um evento É — o caminho, a espécie, e o `cookie` que
    # emparelha as duas metades de um `moved`. Sem ele, mover um ficheiro dentro
    # da árvore lê-se como apagar um e criar outro, que é a diferença entre um
    # `git mv` e uma perda.
    #
    # Uma TUPLA e não um record: um `record` é bytes puros (58.2) e isto carrega
    # uma `str`. Uma tupla que segura uma referência é permitida e continua a ser
    # um VALOR (98.4), que é exactamente o que um evento deve ser.
    private def watch_event_type(self: *PsSema, pos: Pos) -> *PsType:
        t: *PsType = ps_type(self->a, PT_TUPLE, pos)
        t->params = self->a->alloc(usize(3) * sizeof(*t->params))
        t->params[0] = ps_type(self->a, PT_STR, pos)
        # a espécie é o enum `Change` do prelúdio, e não um `int`: comparar com
        # `CREATED` tem de ler como comparar, e um `int` obrigaria a conversão
        # em todo o sítio onde alguém quer saber o que mudou
        t->params[1] = ps_type(self->a, PT_NAME, pos)
        t->params[1]->name = "Change"
        t->params[2] = ps_type(self->a, PT_INT, pos)
        t->nparams = 3
        return t

    private def io_window(self: *PsSema, e: *PsExpr, what: const *char):
        if e->nargs != 3:
            fatal_at(self->file, e->pos, "%s(buf, off, n) takes a Buffer, where in it to start, and how many bytes (135.2)", what)
        bt: *PsType = self->check_expr(e->args[0])
        if bt == None or bt->kind != PT_BUFFER:
            fatal_at(self->file, e->args[0]->pos, "%s() takes a Buffer — memory you already have, which is the whole reason it exists — found %s", what, ps_type_str(self->a, bt))
        for i in range(1, 3):
            at: *PsType = self->check_expr(e->args[i])
            self->want(e->args[i], at, ps_type(self->a, PT_INT, e->pos), "where in the Buffer to start" if i == 1 else "how many bytes")

    # The builtins that have to exist on day one. `print` needs *args (44.2) to
    # be what Python's is; until that is compiled, one argument is the honest
    # subset and the error says so.
    private def builtin_call(self: *PsSema, e: *PsExpr, name: const *char) -> *PsType:
        if strcmp(name, "print") == 0 or strcmp(name, "aprint") == 0:
            # Python's `print`: as many values as you like, joined by spaces
            # (44.2). The general `*args` is still ahead; this is the one place
            # it was missed every day.
            #
            # 78.2: `print` stays SYNCHRONOUS — it is the language's diagnostic
            # channel, it writes into a buffer, and an `await` on every line
            # would poison every program. `aprint` is the sibling for when the
            # write itself can wait (a full pipe, a slow terminal): same
            # arguments, same joining, and a task to await.
            if e->nargs == 0:
                fatal_at(self->file, e->pos, "%s() takes at least one value", name)
            for i in range(e->nargs):
                self->check_expr(e->args[i])
            if strcmp(name, "aprint") == 0:
                at9: *PsType = ps_type(self->a, PT_TASK, e->pos)
                at9->inner = ps_type(self->a, PT_INT, e->pos)
                return at9
            return ps_type(self->a, PT_VOID, e->pos)
        if strcmp(name, "sleep") == 0:
            # 48.2: `await sleep(s)`. It IS a task, so it is awaited like
            # everything else — what is missing is the loop that would let other
            # tasks run meanwhile (18.4), and until then it really sleeps.
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "sleep() takes the seconds")
            slt2: *PsType = self->check_expr(e->args[0])
            self->want(e->args[0], slt2, ps_type(self->a, PT_FLOAT, e->pos), "sleep()")
            stk: *PsType = ps_type(self->a, PT_TASK, e->pos)
            stk->inner = ps_type(self->a, PT_INT, e->pos)
            return stk
        if strcmp(name, "status") == 0:
            # 37.3: what a worker is doing, so that a parent can supervise
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "status() takes a worker")
            wst: *PsType = self->check_expr(e->args[0])
            if wst == None or wst->kind != PT_WORKER:
                fatal_at(self->file, e->pos, "status() takes a worker, found %s", ps_type_str(self->a, wst))
            rt7: *PsType = ps_type(self->a, PT_NAME, e->pos)
            rt7->name = "Status"
            return rt7
        if strcmp(name, "transfer") == 0:
            # 18.2: the bytes change hands. Nothing is copied — what changes is
            # WHO may use them, and using them after giving them away raises.
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "transfer() takes a buffer")
            bft: *PsType = self->check_expr(e->args[0])
            if bft == None or bft->kind != PT_BUFFER:
                fatal_at(self->file, e->pos, "transfer() takes a buffer — the one thing meant to be shared (52.3) — found %s", ps_type_str(self->a, bft))
            return bft
        if strcmp(name, "race") == 0:
            # 37.2: the first to finish WINS and the others are cancelled — the
            # idiom that leaves no orphan behind. What comes back is the INDEX
            # of the winner, because knowing who won is the reason to race; the
            # value is read from that task afterwards.
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "race() takes a list of tasks")
            rt9: *PsType = self->check_expr(e->args[0])
            if rt9 == None or rt9->kind != PT_LIST or rt9->inner == None or rt9->inner->kind != PT_TASK:
                fatal_at(self->file, e->pos, "race() takes a list of tasks, found %s", ps_type_str(self->a, rt9))
            rk9: *PsType = ps_type(self->a, PT_TASK, e->pos)
            rk9->inner = ps_type(self->a, PT_INT, e->pos)
            return rk9
        if strcmp(name, "timeout") == 0:
            # 48.2: a race against the clock that CANCELS the loser. True when
            # the task finished in time, False when the clock did.
            if e->nargs != 2:
                fatal_at(self->file, e->pos, "timeout() takes a task and the seconds")
            tt9: *PsType = self->check_expr(e->args[0])
            if tt9 == None or tt9->kind != PT_TASK:
                fatal_at(self->file, e->pos, "timeout() takes a task, found %s", ps_type_str(self->a, tt9))
            st9: *PsType = self->check_expr(e->args[1])
            self->want(e->args[1], st9, ps_type(self->a, PT_FLOAT, e->pos), "the seconds of timeout()")
            ok9: *PsType = ps_type(self->a, PT_TASK, e->pos)
            ok9->inner = ps_type(self->a, PT_BOOL, e->pos)
            return ok9
        if strcmp(name, "gather") == 0:
            # 35.3: `await gather(ts)` — every task, in the order they were
            # given. It IS a task itself, so it is awaited like any other.
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "gather() takes a list of tasks")
            gt: *PsType = self->check_expr(e->args[0])
            if gt == None or gt->kind != PT_LIST or gt->inner == None or gt->inner->kind != PT_TASK:
                fatal_at(self->file, e->pos, "gather() takes a list of tasks, found %s", ps_type_str(self->a, gt))
            gl: *PsType = ps_type(self->a, PT_LIST, e->pos)
            gl->inner = gt->inner->inner
            gk: *PsType = ps_type(self->a, PT_TASK, e->pos)
            gk->inner = gl
            return gk
        if strcmp(name, "gather_map") == 0:
            # 79.4: the concurrency limit, in the only shape that can throttle
            # anything. `gather(ts, at_most=8)` cannot: with the hot start of
            # 35.1 every task in `ts` is ALREADY running by the time gather
            # sees it. So the limit belongs where the tasks are MADE — over the
            # items, calling the function at most `at_most` at a time.
            if e->nargs != 3:
                fatal_at(self->file, e->pos, "gather_map(f, items, at_most=8): the function, what to run it over, and how many at a time (79.4)")
            gm: *PsType = self->check_expr(e->args[0])
            if gm == None or gm->kind != PT_FUNC or gm->wide or gm->nparams != 1 or gm->inner == None or gm->inner->kind != PT_TASK:
                fatal_at(self->file, e->pos, "gather_map() takes a function of one argument that hands back a task, as in `def(str) -> Task<int>`, found %s", ps_type_str(self->a, gm))
            gi: *PsType = self->check_expr(e->args[1])
            if gi == None or gi->kind != PT_LIST:
                fatal_at(self->file, e->pos, "gather_map() runs over a list, found %s", ps_type_str(self->a, gi))
            self->want(e->args[1], gi->inner, gm->params[0], "the element gather_map() hands to the function")
            lim: *PsExpr = e->args[2]
            if lim->kind == PE_DESIG:
                if strcmp(lim->text, "at_most") != 0:
                    fatal_at(self->file, lim->pos, "gather_map() names its limit `at_most`, not '%s'", lim->text)
                lim = lim->lhs
                e->args[2] = lim
            lt2: *PsType = self->check_expr(lim)
            self->want(lim, lt2, ps_type(self->a, PT_INT, e->pos), "at_most")
            gmo: *PsType = ps_type(self->a, PT_LIST, e->pos)
            gmo->inner = gm->inner->inner
            gmk: *PsType = ps_type(self->a, PT_TASK, e->pos)
            gmk->inner = gmo
            return gmk
        if strcmp(name, "gather_settled") == 0 or strcmp(name, "first_ok") == 0:
            # 79.4: the siblings of `gather` and `race`. `gather_settled` waits
            # for every task and answers with the ERROR of each one, None where
            # it worked — the values are read from the tasks, which are done by
            # then. `first_ok` gives the index of the first that succeeded.
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "%s() takes a list of tasks", name)
            st9: *PsType = self->check_expr(e->args[0])
            if st9 == None or st9->kind != PT_LIST or st9->inner == None or st9->inner->kind != PT_TASK:
                fatal_at(self->file, e->pos, "%s() takes a list of tasks, found %s", name, ps_type_str(self->a, st9))
            rk9: *PsType = ps_type(self->a, PT_TASK, e->pos)
            if strcmp(name, "first_ok") == 0:
                rk9->inner = ps_type(self->a, PT_INT, e->pos)
                return rk9
            eo9: *PsType = ps_type(self->a, PT_LIST, e->pos)
            eo9->inner = ps_type(self->a, PT_OPT, e->pos)
            eo9->inner->inner = self->named_type("Error", e->pos)
            rk9->inner = eo9
            return rk9
        if strcmp(name, "sorted") == 0:
            # 28.4: a COPY, ordered. Without `key=` the order is the natural one
            # and the elements have to be comparable; with it, what is compared
            # is the key, and the key is computed once per element.
            if e->nargs < 1 or e->nargs > 2:
                fatal_at(self->file, e->pos, "sorted() takes a list and an optional `key=`")
            slt: *PsType = self->check_expr(e->args[0])
            if slt == None or slt->kind != PT_LIST:
                fatal_at(self->file, e->pos, "sorted() takes a list, found %s", ps_type_str(self->a, slt))
            if e->nargs == 2:
                ka: *PsExpr = e->args[1]
                if ka->kind == PE_DESIG:
                    if strcmp(ka->text, "key") != 0:
                        fatal_at(self->file, e->pos, "sorted() knows `key=`, not '%s='", ka->text)
                    ka = ka->lhs
                    e->args[1] = ka
                # 28.4 writes this case out: `sorted(xs, key=len)`. A BUILTIN is
                # not a value — `len` has no closure to hand over, and 29.3 kept
                # the function universal separate on purpose — so the shortest
                # honest answer is to write the lambda the user would have
                # written: `key=len` becomes `key=lambda __k: len(__k)`, and
                # every machine downstream (the closure, the adapter emitted per
                # call site) works on it unchanged.
                if ka->kind == PE_NAME and self->find_local(ka->text) < 0 and not self->funcs.has(ka->text) and not self->globals.has(ka->text):
                    klam: *PsExpr = ps_expr(self->a, PE_LAMBDA, ka->pos)
                    klam->params = self->a->alloc(sizeof(PsParam))
                    klam->params[0].name = "__k"
                    klam->params[0].type = slt->inner
                    klam->params[0].pos = ka->pos
                    klam->nparams = 1
                    kcall: *PsExpr = ps_expr(self->a, PE_CALL, ka->pos)
                    kcall->lhs = ka
                    kcall->args = self->a->alloc(sizeof(*kcall->args))
                    kcall->args[0] = ps_expr(self->a, PE_NAME, ka->pos)
                    kcall->args[0]->text = "__k"
                    kcall->nargs = 1
                    klam->lhs = kcall
                    ka = klam
                    e->args[1] = klam
                kw: *PsType = ps_type(self->a, PT_FUNC, e->pos)
                kw->params = self->a->alloc(sizeof(*kw->params))
                kw->params[0] = slt->inner
                kw->nparams = 1
                kw->inner = ps_type(self->a, PT_FLOAT, e->pos)
                prevk: *PsType = self->hint
                self->hint = kw
                kt: *PsType = self->check_expr(ka)
                self->hint = prevk
                if kt == None or kt->kind != PT_FUNC or kt->nparams != 1 or kt->inner == None or kt->inner->kind not in {PT_INT, PT_FLOAT}:
                    fatal_at(self->file, e->pos, "the `key=` of sorted() takes one element and answers a number (28.4)")
                return slt
            # 62.1: `Comparable` is the trait for a CUSTOM order, and this is
            # the place it was declared for — `sorted(xs)` over a type that
            # implements it sorts by the type's own `cmp`.
            if slt->inner != None and slt->inner->kind == PT_NAME and self->timpls.has(self->a->printf("Comparable|%s", slt->inner->name)):
                return slt
            if slt->inner == None or slt->inner->kind not in {PT_INT, PT_FLOAT, PT_STR}:
                fatal_at(self->file, e->pos, "sorted() orders numbers and strings by itself, and any type that implements `Comparable` (62.1) by its `cmp`; for anything else give it a `key=` (28.4)")
            return slt
        if ps_width_name(name) != 0 or strcmp(name, "i64") == 0 or strcmp(name, "f64") == 0:
            # the width conversions (68.2): CHECKED — out of range RAISES, in
            # the same voice as every other overflow (53.1). The intentional
            # wrap has its own spelling (`%+ %- %*`), so a conversion that
            # silently truncated would be the one liar in the family.
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "%s() takes one value", name)
            cst: *PsType = self->check_expr(e->args[0])
            if cst == None or cst->kind not in {PT_INT, PT_FLOAT, PT_BOOL}:
                fatal_at(self->file, e->pos, "%s() converts numbers and bools, found %s", name, ps_type_str(self->a, cst))
            if strcmp(name, "i64") == 0:
                return ps_type(self->a, PT_INT, e->pos)
            if strcmp(name, "f64") == 0:
                return ps_type(self->a, PT_FLOAT, e->pos)
            wt7: *PsType = ps_type(self->a, PT_FLOAT if name[0] == 'f' else PT_INT, e->pos)
            wt7->width = ps_width_name(name)
            wt7->uns = name[0] == 'u'
            return wt7
        # 135.6: `bytes(xs)` and `list(b)`, the crossing in both directions.
        # Explicit BOTH ways, and on purpose: each one copies, and a copy that
        # happens by itself is a copy nobody sees. The `List<u8>` is not going
        # anywhere — it is still the right type for BUILDING and CHANGING
        # bytes, with every list operation; `bytes` is what CROSSES.
        if strcmp(name, "bytes") == 0:
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "bytes() takes one List<u8> or one View<u8>")
            # 68.2: a literal ADAPTS to the width of its context, so
            # `bytes([0xFF, 0xFE])` is a `List<u8>` and not a `List<int>` that
            # is then refused for a reason nobody wrote down.
            bhu: *PsType = ps_type(self->a, PT_LIST, e->pos)
            bhu->inner = ps_type(self->a, PT_INT, e->pos)
            bhu->inner->width = 8
            bhu->inner->uns = True
            bph: *PsType = self->hint
            self->hint = bhu
            bfa: *PsType = self->check_expr(e->args[0])
            self->hint = bph
            if bfa != None and bfa->kind == PT_BYTES:
                return bfa      # already bytes: asking again is not an error
            # a `View<u8>` counts too, and it is the form that reads best after
            # a `read_into`: the window says which bytes, and `bytes()` says
            # that they are being copied out of borrowed memory into a value
            # that outlives it
            bfk: PsTypeKind = bfa->kind if bfa != None else PT_UNKNOWN
            if not ((bfk == PT_LIST or bfk == PT_VIEW) and bfa->inner != None and bfa->inner->kind == PT_INT and bfa->inner->width == 8 and bfa->inner->uns):
                fatal_at(self->file, e->pos, "bytes() takes a List<u8> or a View<u8> — a copy, said out loud (135.6) — found %s", ps_type_str(self->a, bfa))
            return ps_type(self->a, PT_BYTES, e->pos)
        if strcmp(name, "list") == 0:
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "list() takes one `bytes`, and gives back the List<u8> you can change")
            lfa: *PsType = self->check_expr(e->args[0])
            if lfa == None or lfa->kind != PT_BYTES:
                fatal_at(self->file, e->pos, "list() takes `bytes` — the way back from what crosses to what you can build with (135.6) — found %s", ps_type_str(self->a, lfa))
            lu8: *PsType = ps_type(self->a, PT_LIST, e->pos)
            lu8->inner = ps_type(self->a, PT_INT, e->pos)
            lu8->inner->width = 8
            lu8->inner->uns = True
            return lu8
        if strcmp(name, "str") == 0 or strcmp(name, "int") == 0 or strcmp(name, "float") == 0 or strcmp(name, "bool") == 0:
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "%s() takes exactly one argument", name)
            at: *PsType = self->check_expr(e->args[0])
            if at == None or at->kind in {PT_VOID, PT_UNKNOWN}:
                fatal_at(self->file, e->pos, "%s() has nothing to convert", name)
            if strcmp(name, "str") == 0:
                return ps_type(self->a, PT_STR, e->pos)
            if strcmp(name, "int") == 0:
                return ps_type(self->a, PT_INT, e->pos)
            if strcmp(name, "float") == 0:
                return ps_type(self->a, PT_FLOAT, e->pos)
            return ps_type(self->a, PT_BOOL, e->pos)
        if strcmp(name, "__fmt") == 0:
            # emitted by the f-string desugaring, never written by hand: the
            # value plus the pieces of a spec that were parsed at compile time
            if e->nargs != 5:
                fatal_at(self->file, e->pos, "__fmt is internal to f-strings")
            vt2: *PsType = self->check_expr(e->args[0])
            # a record, a struct or an enum formats through its derived repr
            # (44.3) — the same text `print` and `str()` give
            # ... and a CONTAINER through its own (97), which is the same text
            # again: one repr, three ways of asking for it
            if vt2 == None or vt2->kind not in {PT_INT, PT_FLOAT, PT_BOOL, PT_STR, PT_NAME, PT_LIST, PT_SET, PT_DICT, PT_TUPLE}:
                fatal_at(self->file, e->args[0]->pos, "an f-string cannot format %s yet", ps_type_str(self->a, vt2))
            for i in range(1, 5):
                self->check_expr(e->args[i])
            return ps_type(self->a, PT_STR, e->pos)
        if strcmp(name, "error") == 0:
            # `error(msg)` / `error(msg, category)` (54.3): the ONE error type,
            # with a category code so a handler can filter without matching text
            if e->nargs < 1 or e->nargs > 2:
                fatal_at(self->file, e->pos, "error() takes a message and an optional category")
            mt: *PsType = self->check_expr(e->args[0])
            self->want(e->args[0], mt, ps_type(self->a, PT_STR, e->pos), "the message of error()")
            if e->nargs == 2:
                ct2: *PsType = self->check_expr(e->args[1])
                cn9: *PsType = ps_type(self->a, PT_NAME, e->pos)
                cn9->name = "Category"
                self->want(e->args[1], ct2, cn9, "the category of error()")
            r: *PsType = ps_type(self->a, PT_NAME, e->pos)
            r->name = "Error"
            return r
        # ---- 110: o módulo `gc` e `sys.pool` ----
        # ---- S3: o módulo `sched` ----
        if strcmp(name, "__sched_stats") == 0:
            if e->nargs != 0:
                fatal_at(self->file, e->pos, "sched.stats() takes no arguments")
            sd: *PsType = ps_type(self->a, PT_DICT, e->pos)
            sd->key = ps_type(self->a, PT_STR, e->pos)
            sd->inner = ps_type(self->a, PT_INT, e->pos)
            return sd
        if strncmp(name, "__gc_", 5) == 0:
            gf: const *char = name + 5
            if strcmp(gf, "collect") == 0:
                if e->nargs != 0:
                    fatal_at(self->file, e->pos, "gc.collect() takes no arguments")
                return ps_type(self->a, PT_VOID, e->pos)
            if strcmp(gf, "stats") == 0:
                if e->nargs != 0:
                    fatal_at(self->file, e->pos, "gc.stats() takes no arguments")
                # Dict<str, int>: nenhum tipo novo para a linguagem aprender, e
                # o `print` já sabe imprimi-lo
                gd: *PsType = ps_type(self->a, PT_DICT, e->pos)
                gd->key = ps_type(self->a, PT_STR, e->pos)
                gd->inner = ps_type(self->a, PT_INT, e->pos)
                return gd
            if strcmp(gf, "tune") == 0:
                # `gc.tune(bytes=..., objects=...)`: os dois por nome, cada um
                # opcional — o que não vier fica como está. Aceita posicional
                # também, na mesma ordem.
                if e->nargs < 1 or e->nargs > 2:
                    fatal_at(self->file, e->pos, "gc.tune(bytes=..., objects=...) takes one or both")
                seen_b: bool = False
                seen_o: bool = False
                for i in range(e->nargs):
                    a: *PsExpr = e->args[i]
                    if a->kind == PE_DESIG:
                        nm: const *char = a->text
                        if strcmp(nm, "bytes") == 0:
                            if seen_b:
                                fatal_at(self->file, e->pos, "gc.tune(): 'bytes' given twice")
                            seen_b = True
                        elif strcmp(nm, "objects") == 0:
                            if seen_o:
                                fatal_at(self->file, e->pos, "gc.tune(): 'objects' given twice")
                            seen_o = True
                        else:
                            fatal_at(self->file, e->pos, "gc.tune() takes 'bytes' (the budget floor, in bytes) and 'objects' (the object count), not '%s'", nm)
                        self->want(a->lhs, self->check_expr(a->lhs), ps_type(self->a, PT_INT, e->pos), "a limit of gc.tune()")
                    else:
                        self->want(a, self->check_expr(a), ps_type(self->a, PT_INT, e->pos), "a limit of gc.tune()")
                return ps_type(self->a, PT_VOID, e->pos)
            fatal_at(self->file, e->pos, "gc has collect, tune and stats")
        if strcmp(name, "__sys_pool") == 0:
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "sys.pool(n) takes the number of I/O threads")
            self->want(e->args[0], self->check_expr(e->args[0]), ps_type(self->a, PT_INT, e->pos), "the thread count")
            return ps_type(self->a, PT_VOID, e->pos)
        if strcmp(name, "__sys_exit") == 0:
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "sys.exit() takes a status")
            xt: *PsType = self->check_expr(e->args[0])
            self->want(e->args[0], xt, ps_type(self->a, PT_INT, e->pos), "sys.exit()")
            return ps_type(self->a, PT_VOID, e->pos)
        if strcmp(name, "__sys_time") == 0:
            if e->nargs != 0:
                fatal_at(self->file, e->pos, "sys.time() takes no arguments")
            return ps_type(self->a, PT_FLOAT, e->pos)
        if strcmp(name, "__net_udp") == 0:
            # F7: `net.udp(port)` — um `Socket` que fala em DATAGRAMAS. É o
            # mesmo tipo, porque o que muda são os MÉTODOS que ele aceita, e
            # essa é a distinção que a marca no objecto faz em execução.
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "net.udp(port) takes the port to bind — 0 lets the system choose")
            up: *PsType = self->check_expr(e->args[0])
            self->want(e->args[0], up, ps_type(self->a, PT_INT, e->pos), "the port")
            return ps_type(self->a, PT_CONN, e->pos)
        if strcmp(name, "__net_unix") == 0 or strcmp(name, "__net_unix_listen") == 0:
            # F7: o mesmo `Socket` sobre um CAMINHO. Vale por si — é como dois
            # processos na mesma máquina falam sem passar pela rede.
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "net.%s(path) takes the path of the socket", "unix" if strcmp(name, "__net_unix") == 0 else "unix_listen")
            xp: *PsType = self->check_expr(e->args[0])
            self->want(e->args[0], xp, ps_type(self->a, PT_STR, e->pos), "the path")
            return ps_type(self->a, PT_CONN, e->pos)
        if strcmp(name, "__net_listen") == 0:
            # 77.1: binding and listening are instant, so this one is NOT a
            # task — what waits is `accept`, and that is where the await goes
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "net.listen() takes a port: `net.listen(8080)`")
            lp: *PsType = self->check_expr(e->args[0])
            self->want(e->args[0], lp, ps_type(self->a, PT_INT, e->pos), "net.listen()")
            return ps_type(self->a, PT_CONN, e->pos)
        if strcmp(name, "__net_connect") == 0:
            if e->nargs != 2:
                fatal_at(self->file, e->pos, "net.connect() takes a host and a port: `await net.connect(\"example.com\", 80)`")
            ch: *PsType = self->check_expr(e->args[0])
            self->want(e->args[0], ch, ps_type(self->a, PT_STR, e->pos), "net.connect()")
            cp: *PsType = self->check_expr(e->args[1])
            self->want(e->args[1], cp, ps_type(self->a, PT_INT, e->pos), "net.connect()")
            ct: *PsType = ps_type(self->a, PT_TASK, e->pos)
            ct->inner = ps_type(self->a, PT_CONN, e->pos)
            return ct
        if strcmp(name, "__net_starttls") == 0 or strcmp(name, "__net_starttls_insecure") == 0:
            # `await net.starttls(c, "example.com")` — promove uma ligação já
            # aberta. O NOME é obrigatório e não é decoração: é ele que vai no
            # SNI e é contra ele que o certificado é verificado. Sem ele, um
            # certificado válido para outro domínio passaria.
            wt: const *char = "net.starttls()" if strcmp(name, "__net_starttls") == 0 else "net.starttls_insecure()"
            if e->nargs != 2:
                fatal_at(self->file, e->pos, "%s takes the connection and the host name: `await net.starttls(c, \"example.com\")`", wt)
            tc: *PsType = self->check_expr(e->args[0])
            if tc == None or tc->kind != PT_CONN:
                fatal_at(self->file, e->args[0]->pos, "%s takes a Socket, found %s", wt, ps_type_str(self->a, tc))
            th: *PsType = self->check_expr(e->args[1])
            self->want(e->args[1], th, ps_type(self->a, PT_STR, e->pos), "the host name")
            tt: *PsType = ps_type(self->a, PT_TASK, e->pos)
            tt->inner = ps_type(self->a, PT_BOOL, e->pos)
            return tt
        if strcmp(name, "__net_tls_available") == 0:
            if e->nargs != 0:
                fatal_at(self->file, e->pos, "net.tls_available() takes no arguments")
            return ps_type(self->a, PT_BOOL, e->pos)
        if strcmp(name, "__net_lookup") == 0:
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "net.lookup() takes a host name")
            lh: *PsType = self->check_expr(e->args[0])
            self->want(e->args[0], lh, ps_type(self->a, PT_STR, e->pos), "net.lookup()")
            lt: *PsType = ps_type(self->a, PT_TASK, e->pos)
            lt->inner = ps_type(self->a, PT_STR, e->pos)
            return lt
        if strcmp(name, "__json_stringify") == 0:
            # 41.1 do outro lado: um valor entra e sai TEXTO. Não há esquema a
            # declarar porque o compilador já sabe a forma do tipo — é a mesma
            # tabela de campos que o `repr` usa (F5), e é por isso que isto não
            # custa uma linha de código por tipo.
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "json.stringify() takes one value")
            st9: *PsType = self->check_expr(e->args[0])
            # o `any` ATRAVESSA (39.2): ele só pode conter números, bools,
            # strings, None, `List<any>` e `Dict<str, any>` — que é exactamente
            # a lista de formas que o JSON tem. Recusá-lo era recusar o tipo
            # cuja forma é a do próprio formato.
            if st9 == None or st9->kind in {PT_VOID, PT_UNKNOWN, PT_FUNC, PT_TASK, PT_WORKER, PT_FILE, PT_CONN, PT_DYN}:
                fatal_at(self->file, e->args[0]->pos, "json.stringify() does not carry %s: JSON has numbers, text, booleans, lists and objects, and what is not one of those would have to be invented", ps_type_str(self->a, st9))
            return ps_type(self->a, PT_STR, e->pos)
        if strcmp(name, "__json_parse") == 0:
            # 41.1: text in, `any` out. There is no schema to declare — reading
            # it back is `as`, which checks (55.2).
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "json.parse() takes the text")
            jt: *PsType = self->check_expr(e->args[0])
            self->want(e->args[0], jt, ps_type(self->a, PT_STR, e->pos), "json.parse()")
            return ps_type(self->a, PT_ANY, e->pos)
        # ---- 103: random, math, time ----
        if strncmp(name, "__random_", 9) == 0:
            fn9: const *char = name + 9
            it9: *PsType = ps_type(self->a, PT_INT, e->pos)
            ft9: *PsType = ps_type(self->a, PT_FLOAT, e->pos)
            if strcmp(fn9, "random") == 0:
                if e->nargs != 0:
                    fatal_at(self->file, e->pos, "random.random() takes no arguments")
                return ft9
            if strcmp(fn9, "seed") == 0:
                if e->nargs != 1:
                    fatal_at(self->file, e->pos, "random.seed(n) takes one number")
                self->want(e->args[0], self->check_expr(e->args[0]), it9, "the seed")
                return ps_type(self->a, PT_VOID, e->pos)
            if strcmp(fn9, "getrandbits") == 0:
                if e->nargs != 1:
                    fatal_at(self->file, e->pos, "random.getrandbits(n) takes one number")
                self->want(e->args[0], self->check_expr(e->args[0]), it9, "the argument")
                return it9
            if strcmp(fn9, "randrange") == 0:
                # as três formas do Python: (stop), (start, stop), (start, stop, step)
                if e->nargs < 1 or e->nargs > 3:
                    fatal_at(self->file, e->pos, "random.randrange takes (stop), (start, stop) or (start, stop, step), and the stop is EXCLUDED — randint includes it")
                for i in range(e->nargs):
                    self->want(e->args[i], self->check_expr(e->args[i]), it9, "an end of the range")
                return it9
            if strcmp(fn9, "randint") == 0:
                if e->nargs != 2:
                    fatal_at(self->file, e->pos, "random.randint(a, b) takes two numbers, and BOTH ends are included, as in Python")
                for i in range(2):
                    self->want(e->args[i], self->check_expr(e->args[i]), it9, "an end of the range")
                return it9
            if strcmp(fn9, "gauss") == 0:
                if e->nargs != 2:
                    fatal_at(self->file, e->pos, "random.gauss(mu, sigma) takes the mean and the STANDARD DEVIATION, not the variance")
                for i in range(2):
                    self->check_want(e->args[i], ft9, "an argument")
                return ft9
            if strcmp(fn9, "expovariate") == 0:
                if e->nargs != 1:
                    fatal_at(self->file, e->pos, "random.expovariate(lambd) takes the rate")
                self->check_want(e->args[0], ft9, "the rate")
                return ft9
            if strcmp(fn9, "uniform") == 0:
                if e->nargs != 2:
                    fatal_at(self->file, e->pos, "random.uniform(a, b) takes two numbers")
                for i in range(2):
                    self->check_want(e->args[i], ft9, "an end of the range")
                return ft9
            if strcmp(fn9, "choice") == 0:
                # `Lib/random.py`: `seq[self._randbelow(len(seq))]`. Written HERE
                # as exactly that, so there is no generic to instantiate and the
                # element type comes out of the list itself.
                if e->nargs != 1:
                    fatal_at(self->file, e->pos, "random.choice(xs) takes one list")
                cl9: *PsType = self->check_expr(e->args[0])
                if cl9 == None or cl9->kind != PT_LIST:
                    fatal_at(self->file, e->pos, "random.choice() takes a list, found %s", ps_type_str(self->a, cl9))
                if e->args[0]->kind != PE_NAME and e->args[0]->kind != PE_FIELD:
                    fatal_at(self->file, e->pos, "random.choice() on something that is not a plain variable would evaluate it twice: put the list in a variable first")
                lenc: *PsExpr = ps_expr(self->a, PE_CALL, e->pos)
                lenc->lhs = ps_expr(self->a, PE_NAME, e->pos)
                lenc->lhs->text = "len"
                lenc->args = self->a->alloc(sizeof(*lenc->args))
                lenc->args[0] = e->args[0]
                lenc->nargs = 1
                below: *PsExpr = ps_expr(self->a, PE_CALL, e->pos)
                below->lhs = ps_expr(self->a, PE_NAME, e->pos)
                below->lhs->text = "__random_below"
                below->args = self->a->alloc(sizeof(*below->args))
                below->args[0] = lenc
                below->nargs = 1
                with e:
                    .kind = PE_INDEX
                    .lhs = e->args[0]
                    .rhs = below
                    .args = None
                    .nargs = 0
                return self->check_expr(e)
            if strcmp(fn9, "below") == 0:
                # o interno que o `choice` acima usa
                if e->nargs != 1:
                    fatal_at(self->file, e->pos, "internal: __random_below takes one number")
                self->want(e->args[0], self->check_expr(e->args[0]), it9, "the bound")
                return it9
            if strcmp(fn9, "shuffle") == 0:
                if e->nargs != 1:
                    fatal_at(self->file, e->pos, "random.shuffle(xs) takes one list")
                sl9: *PsType = self->check_expr(e->args[0])
                if sl9 == None or sl9->kind != PT_LIST:
                    fatal_at(self->file, e->pos, "random.shuffle() takes a list, found %s", ps_type_str(self->a, sl9))
                return ps_type(self->a, PT_VOID, e->pos)
            fatal_at(self->file, e->pos, "random has seed, random, getrandbits, randint, randrange, uniform, gauss, expovariate, choice and shuffle")
        # ---- 106: bisect e heapq ----
        if strncmp(name, "__bisect_", 9) == 0 or strncmp(name, "__heapq_", 8) == 0:
            bh: const *char = name + (9 if strncmp(name, "__bisect_", 9) == 0 else 8)
            ins: bool = strncmp(bh, "insort", 6) == 0
            push: bool = strcmp(bh, "heappush") == 0
            pop: bool = strcmp(bh, "heappop") == 0
            heapi: bool = strcmp(bh, "heapify") == 0
            want: i32 = 1 if (pop or heapi) else 2
            if e->nargs != want:
                fatal_at(self->file, e->pos, "%s takes %d argument(s)", bh, want)
            blt: *PsType = self->check_expr(e->args[0])
            if blt == None or blt->kind != PT_LIST or blt->inner == None or blt->inner->kind not in {PT_INT, PT_FLOAT, PT_STR}:
                fatal_at(self->file, e->pos, "%s takes a list of numbers or strings, not %s — the order it assumes is the one `sorted` produces, and that is defined for those three (106.3)", bh, ps_type_str(self->a, blt))
            if ins or push or heapi:
                self->deny_const_mut(e->args[0], bh)
            if want == 2:
                self->check_want(e->args[1], blt->inner, "the value")
            if pop:
                return blt->inner
            if ins or push or heapi:
                return ps_type(self->a, PT_VOID, e->pos)
            return ps_type(self->a, PT_INT, e->pos)
        if strncmp(name, "__math_", 7) == 0:
            mf: const *char = name + 7
            mft: *PsType = ps_type(self->a, PT_FLOAT, e->pos)
            if strcmp(mf, "isnan") == 0 or strcmp(mf, "isinf") == 0:
                if e->nargs != 1:
                    fatal_at(self->file, e->pos, "math.%s(x) takes one number", mf)
                self->check_want(e->args[0], mft, "the argument")
                return ps_type(self->a, PT_BOOL, e->pos)
            # `floor`, `ceil` e `trunc` devolvem INT no Python, e é o que um
            # índice espera — os outros devolvem float
            if strcmp(mf, "floor") == 0 or strcmp(mf, "ceil") == 0 or strcmp(mf, "trunc") == 0:
                if e->nargs != 1:
                    fatal_at(self->file, e->pos, "math.%s(x) takes one number", mf)
                self->check_want(e->args[0], mft, "the argument")
                return ps_type(self->a, PT_INT, e->pos)
            n2: i32 = 2 if (strcmp(mf, "pow") == 0 or strcmp(mf, "atan2") == 0 or strcmp(mf, "hypot") == 0 or strcmp(mf, "fmod") == 0) else 1
            if e->nargs != n2:
                fatal_at(self->file, e->pos, "math.%s takes %d number(s)", mf, n2)
            for i in range(n2):
                self->check_want(e->args[i], mft, "the argument")
            return mft
        if strncmp(name, "__time_", 7) == 0:
            if e->nargs != 0:
                fatal_at(self->file, e->pos, "time.%s() takes no arguments", name + 7)
            return ps_type(self->a, PT_FLOAT, e->pos)
        # ---- 111: `os` e `path`, a camada de sistema ----
        if strncmp(name, "__os_", 5) == 0 or strncmp(name, "__path_", 7) == 0:
            isos: bool = strncmp(name, "__os_", 5) == 0
            of: const *char = name + (5 if isos else 7)
            # 118 / pforge 1.2: rodar um processo. Fica ANTES da conta genérica
            # porque não tem a forma das outras: um vetor de argumentos, três
            # opções por nome, e o que volta é uma TASK.
            if isos and strcmp(of, "run") == 0:
                if e->nargs < 1:
                    fatal_at(self->file, e->pos, "os.run() takes the command as a list: os.run([\"cc\", \"-c\", \"a.c\"])")
                if e->args[0]->kind == PE_DESIG:
                    fatal_at(self->file, e->pos, "os.run(): the command comes first, and by position")
                at0: *PsType = self->check_expr(e->args[0])
                if at0 == None or at0->kind != PT_LIST or at0->inner == None or at0->inner->kind != PT_STR:
                    fatal_at(self->file, e->args[0]->pos, "os.run() takes a List<str> — the program and its arguments, one per element, with NO shell in between (1.6) — found %s", ps_type_str(self->a, at0))
                seen_env: bool = False
                seen_cwd: bool = False
                seen_out: bool = False
                seen_con: bool = False
                for ri in range(1, e->nargs):
                    ra: *PsExpr = e->args[ri]
                    if ra->kind != PE_DESIG:
                        fatal_at(self->file, ra->pos, "os.run(): what comes after the command is given BY NAME — env=, cwd=, stdout=")
                    rn: const *char = ra->text
                    rv: *PsType = self->check_expr(ra->lhs)
                    if strcmp(rn, "env") == 0:
                        if seen_env:
                            fatal_at(self->file, ra->pos, "os.run(): 'env' given twice")
                        seen_env = True
                        if rv == None or rv->kind != PT_DICT or rv->key == None or rv->key->kind != PT_STR or rv->inner == None or rv->inner->kind != PT_STR:
                            fatal_at(self->file, ra->pos, "os.run(env=): a Dict<str, str>, and it REPLACES the environment (it is not merged) — found %s", ps_type_str(self->a, rv))
                    elif strcmp(rn, "cwd") == 0 or strcmp(rn, "stdout") == 0:
                        if (strcmp(rn, "cwd") == 0 and seen_cwd) or (strcmp(rn, "stdout") == 0 and seen_out):
                            fatal_at(self->file, ra->pos, "os.run(): '%s' given twice", rn)
                        if strcmp(rn, "cwd") == 0:
                            seen_cwd = True
                        else:
                            seen_out = True
                        if rv == None or rv->kind != PT_STR:
                            fatal_at(self->file, ra->pos, "os.run(%s=): a path, as str — found %s", rn, ps_type_str(self->a, rv))
                        if strcmp(rn, "stdout") == 0 and seen_con:
                            fatal_at(self->file, ra->pos, "os.run(): 'console' and 'stdout' say opposite things about where the output goes")
                    elif strcmp(rn, "console") == 0:
                        # `console=True` é a AUSÊNCIA de captura: o filho herda
                        # este terminal. Com `stdout=` junto seriam duas ordens
                        # contrárias sobre o mesmo descritor, e escolher uma
                        # delas em silêncio é pior que recusar.
                        if seen_con:
                            fatal_at(self->file, ra->pos, "os.run(): 'console' given twice")
                        seen_con = True
                        if rv == None or rv->kind != PT_BOOL:
                            fatal_at(self->file, ra->pos, "os.run(console=): a bool — found %s", ps_type_str(self->a, rv))
                        if seen_out:
                            fatal_at(self->file, ra->pos, "os.run(): 'console' and 'stdout' say opposite things about where the output goes")
                    else:
                        fatal_at(self->file, ra->pos, "os.run() knows env=, cwd=, stdout= and console=, not '%s'", rn)
                rtk: *PsType = ps_type(self->a, PT_TASK, e->pos)
                rtk->inner = ps_type(self->a, PT_PROC, e->pos)
                return rtk
            if isos and strcmp(of, "spawn") == 0:
                # F6: o terceiro caso. `run` espera, `exec` vira o filho, e este
                # LANÇA e segue — que é o que um laço de desenvolvimento precisa.
                # O que volta é o PID, um número: um objeto vivo num runtime com
                # coletor levantaria a pergunta do que acontece quando ele é
                # recolhido com o filho a correr, e três funções sobre um número
                # não têm essa pergunta.
                if e->nargs != 1:
                    fatal_at(self->file, e->pos, "os.spawn() takes the command as a list: os.spawn([\"./meu-programa\"])")
                sa: *PsType = self->check_expr(e->args[0])
                if sa == None or sa->kind != PT_LIST or sa->inner == None or sa->inner->kind != PT_STR:
                    fatal_at(self->file, e->args[0]->pos, "os.spawn() takes a List<str> — o programa e os argumentos, um por elemento (1.6) — found %s", ps_type_str(self->a, sa))
                return ps_type(self->a, PT_INT, e->pos)
            if isos and strcmp(of, "spawn_pty") == 0:
                # F8: the fourth case. `run` waits, `exec` becomes the child,
                # `spawn` launches and moves on — and this one gives the child a
                # TERMINAL, which is what makes an interactive program behave
                # the way it does in a shell: line editing, colours, a prompt,
                # and a SIGINT that reaches it.
                #
                # What comes back is a `Conn`, the same type a socket is. That is
                # the decision: `read`, `write` and `close` on it are already
                # written, already awaitable and already polled by the scheduler
                # instead of blocking a thread, and a terminal is a descriptor
                # with a child on the other end — which is what a socket is, with
                # a machine on the other end.
                if e->nargs != 3:
                    fatal_at(self->file, e->pos, "os.spawn_pty() takes the command, the columns and the rows: os.spawn_pty([\"/bin/sh\"], 80, 24)")
                pa: *PsType = self->check_expr(e->args[0])
                if pa == None or pa->kind != PT_LIST or pa->inner == None or pa->inner->kind != PT_STR:
                    fatal_at(self->file, e->args[0]->pos, "os.spawn_pty() takes a List<str> — the program and its arguments, one per element (1.6) — found %s", ps_type_str(self->a, pa))
                self->check_want(e->args[1], ps_type(self->a, PT_INT, e->pos), "as colunas")
                self->check_want(e->args[2], ps_type(self->a, PT_INT, e->pos), "as linhas")
                return ps_type(self->a, PT_CONN, e->pos)
            if isos and strcmp(of, "pty_resize") == 0:
                # the one thing a terminal needs that a socket does not, so it is
                # a function and not a method: a socket has no size, and giving
                # every socket a `resize` would be lying about what one is
                if e->nargs != 3:
                    fatal_at(self->file, e->pos, "os.pty_resize() takes the terminal, the columns and the rows")
                pr: *PsType = self->check_expr(e->args[0])
                if pr == None or pr->kind != PT_CONN:
                    fatal_at(self->file, e->args[0]->pos, "os.pty_resize() takes what os.spawn_pty() gave, found %s", ps_type_str(self->a, pr))
                self->check_want(e->args[1], ps_type(self->a, PT_INT, e->pos), "as colunas")
                self->check_want(e->args[2], ps_type(self->a, PT_INT, e->pos), "as linhas")
                return ps_type(self->a, PT_VOID, e->pos)
            if isos and strcmp(of, "pty_pid") == 0:
                if e->nargs != 1:
                    fatal_at(self->file, e->pos, "os.pty_pid() takes what os.spawn_pty() gave")
                pp: *PsType = self->check_expr(e->args[0])
                if pp == None or pp->kind != PT_CONN:
                    fatal_at(self->file, e->args[0]->pos, "os.pty_pid() takes what os.spawn_pty() gave, found %s", ps_type_str(self->a, pp))
                return ps_type(self->a, PT_INT, e->pos)
            if isos and (strcmp(of, "kill") == 0 or strcmp(of, "alive") == 0):
                if e->nargs != 1:
                    fatal_at(self->file, e->pos, "os.%s() takes the pid that os.spawn() gave", of)
                self->check_want(e->args[0], ps_type(self->a, PT_INT, e->pos), "o pid")
                if strcmp(of, "alive") == 0:
                    return ps_type(self->a, PT_BOOL, e->pos)
                return ps_type(self->a, PT_VOID, e->pos)
            if isos and strcmp(of, "exec") == 0:
                # F7: o programa PASSA A SER este processo. Não devolve, então
                # não tem tipo de retorno que interesse — e é por isso que ele
                # não é uma `Task`: não há nada por que esperar.
                if e->nargs != 1:
                    fatal_at(self->file, e->pos, "os.exec() takes the command as a list: os.exec([\"vim\", \"a.txt\"])")
                ae: *PsType = self->check_expr(e->args[0])
                if ae == None or ae->kind != PT_LIST or ae->inner == None or ae->inner->kind != PT_STR:
                    fatal_at(self->file, e->args[0]->pos, "os.exec() takes a List<str> — o programa e os argumentos, um por elemento, SEM shell no meio (1.6) — found %s", ps_type_str(self->a, ae))
                return ps_type(self->a, PT_VOID, e->pos)
            if isos and strcmp(of, "watch") == 0:
                # 140/F5: `os.watch(d)` vigia um directório e `os.watch(d, True)`
                # a árvore. A recursão é NOSSA (146.1): o `inotify` vigia um
                # directório, e uma árvore são N vigias.
                if e->nargs != 1 and e->nargs != 2:
                    fatal_at(self->file, e->pos, "os.watch(dir) watches a directory; os.watch(dir, True) watches the tree (140)")
                wp0: *PsType = self->check_expr(e->args[0])
                self->want(e->args[0], wp0, ps_type(self->a, PT_STR, e->pos), "the directory to watch")
                if e->nargs == 2:
                    wr0: *PsType = self->check_expr(e->args[1])
                    self->want(e->args[1], wr0, ps_type(self->a, PT_BOOL, e->pos), "whether to watch the whole tree")
                return ps_type(self->a, PT_WATCHER, e->pos)
            if isos and strcmp(of, "scandir") == 0:
                # 140/F4: os nomes UM DE CADA VEZ, na ordem em que o sistema de
                # ficheiros os der. O `listdir` fica como está — devolve tudo,
                # ordenado, e é o que o oráculo compara com o do Python — e o
                # que ele NÃO pode ser é preguiçoso, porque ordenar exige ter
                # tudo em mão. Quem quer ordem chama `sorted`, e assim vê-se que
                # a pediu.
                if e->nargs != 1:
                    fatal_at(self->file, e->pos, "os.scandir(path) takes one path")
                cd0: *PsType = self->check_expr(e->args[0])
                self->want(e->args[0], cd0, ps_type(self->a, PT_STR, e->pos), "the path")
                return ps_type(self->a, PT_DIRITER, e->pos)
            if isos and strcmp(of, "stat") == 0:
                # 140/F4: tudo o que o disco sabe do nome, de UMA vez. Um Dict e
                # não um record, pela mesma razão que o `gc.stats()` (110): não
                # há tipo novo para a linguagem aprender, e acrescentar uma
                # medida depois não quebra programa nenhum.
                if e->nargs != 1:
                    fatal_at(self->file, e->pos, "os.stat(path) takes one path")
                sp0: *PsType = self->check_expr(e->args[0])
                self->want(e->args[0], sp0, ps_type(self->a, PT_STR, e->pos), "the path")
                sd0: *PsType = ps_type(self->a, PT_DICT, e->pos)
                sd0->key = ps_type(self->a, PT_STR, e->pos)
                sd0->inner = ps_type(self->a, PT_INT, e->pos)
                return sd0
            if isos and (strcmp(of, "pread") == 0 or strcmp(of, "pwrite") == 0):
                # 140/F4: POSICIONAL, sem `seek`. É a diferença que torna o
                # acesso concorrente seguro: um `seek` seguido de um `read` são
                # duas operações sobre um cursor partilhado, e dois workers
                # intercalam-se nelas.
                if e->nargs != 4:
                    fatal_at(self->file, e->pos, "os.%s(f, buf, off, n): the file, a Buffer, WHERE in the file, and how many bytes (140)", of)
                pf0: *PsType = self->check_expr(e->args[0])
                if pf0 == None or pf0->kind != PT_FILE:
                    fatal_at(self->file, e->args[0]->pos, "os.%s() takes an open File, found %s", of, ps_type_str(self->a, pf0))
                pb0: *PsType = self->check_expr(e->args[1])
                if pb0 == None or pb0->kind != PT_BUFFER:
                    fatal_at(self->file, e->args[1]->pos, "os.%s() takes a Buffer — memory you already have — found %s", of, ps_type_str(self->a, pb0))
                for pi in range(2, 4):
                    px0: *PsType = self->check_expr(e->args[pi])
                    self->want(e->args[pi], px0, ps_type(self->a, PT_INT, e->pos), "where in the file" if pi == 2 else "how many bytes")
                return ps_type(self->a, PT_INT, e->pos)
            if isos and strcmp(of, "mmap") == 0:
                # 137.3: o ficheiro inteiro, ou uma REGIÃO. Um membro de um
                # arquivo enorme lê-se sem mapear os outros gigabytes, e custa
                # dois argumentos. (Uma fatia `m[off:off+n]` dá a região DENTRO
                # de um mapa que já existe; isto dá não mapear o resto de todo.)
                if e->nargs != 1 and e->nargs != 2 and e->nargs != 4:
                    fatal_at(self->file, e->pos, "os.mmap(path) maps the whole file, os.mmap(path, mode) says how, and os.mmap(path, mode, off, n) maps a REGION (137.3)")
                mp0: *PsType = self->check_expr(e->args[0])
                self->want(e->args[0], mp0, ps_type(self->a, PT_STR, e->pos), "the path to map")
                if e->nargs >= 2:
                    mp1: *PsType = self->check_expr(e->args[1])
                    self->want(e->args[1], mp1, ps_type(self->a, PT_STR, e->pos), "the mode: \"r\" or \"w\"")
                for mi in range(2, e->nargs):
                    mpx: *PsType = self->check_expr(e->args[mi])
                    self->want(e->args[mi], mpx, ps_type(self->a, PT_INT, e->pos), "where the region starts" if mi == 2 else "how long the region is")
                return ps_type(self->a, PT_MAPPING, e->pos)
            if isos and (strcmp(of, "SEQUENTIAL") == 0 or strcmp(of, "RANDOM") == 0 or strcmp(of, "WILLNEED") == 0):
                fatal_at(self->file, e->pos, "os.%s is a VALUE, not a call: `m.advise(os.%s)`", of, of)
            if isos and strcmp(of, "nproc") == 0:
                if e->nargs != 0:
                    fatal_at(self->file, e->pos, "os.nproc() takes no arguments")
                return ps_type(self->a, PT_INT, e->pos)
            # ---- S2: os temporários. Três perguntas, três funções ----
            if isos and (strcmp(of, "tempdir") == 0 or strcmp(of, "tempfile") == 0 or strcmp(of, "tempdir_new") == 0):
                nt: i32 = 0 if strcmp(of, "tempdir") == 0 else (2 if strcmp(of, "tempfile") == 0 else 1)
                if e->nargs > nt:
                    fatal_at(self->file, e->pos, "os.%s() takes %d argument(s)", of, nt)
                stt: *PsType = ps_type(self->a, PT_STR, e->pos)
                for i in range(e->nargs):
                    self->check_want(e->args[i], stt, "the prefix" if i == 0 else "the suffix")
                return stt
            st1: *PsType = ps_type(self->a, PT_STR, e->pos)
            # `getcwd()` é a única sem caminho; `rename` e `join` querem dois; e
            # `join` aceita MAIS de dois, como no Python (`path.join(a, b, c)`)
            lo: i32 = 1
            hi: i32 = 1
            if strcmp(of, "getcwd") == 0:
                lo = 0
                hi = 0
            elif strcmp(of, "rename") == 0:
                lo = 2
                hi = 2
            elif strcmp(of, "join") == 0:
                lo = 2
                hi = 64
            if e->nargs < lo or e->nargs > hi:
                if lo == hi:
                    fatal_at(self->file, e->pos, "%s.%s() takes %d argument(s)", "os" if isos else "path", of, lo)
                fatal_at(self->file, e->pos, "path.join() joins two or more pieces: `path.join(dir, name)`")
            for i in range(e->nargs):
                self->check_want(e->args[i], st1, "the path")
            if strcmp(of, "listdir") == 0:
                dl: *PsType = ps_type(self->a, PT_LIST, e->pos)
                dl->inner = ps_type(self->a, PT_STR, e->pos)
                return dl
            if strcmp(of, "exists") == 0 or strcmp(of, "isdir") == 0 or strcmp(of, "isfile") == 0:
                return ps_type(self->a, PT_BOOL, e->pos)
            if strcmp(of, "getsize") == 0 or strcmp(of, "getmtime") == 0 or strcmp(of, "getmtime_ns") == 0:
                return ps_type(self->a, PT_INT, e->pos)
            if isos and strcmp(of, "getcwd") != 0:
                return ps_type(self->a, PT_VOID, e->pos)
            return st1
        if strcmp(name, "__re_match") == 0 or strcmp(name, "__re_search") == 0:
            # 41.2: the groups, or None. [0] is the whole match.
            #
            # S2b: `match` exige o PRINCÍPIO e `search` procura. A diferença é da
            # API e não do autómato — ele responde às duas perguntas com o mesmo
            # programa, e ancorar por dentro obrigaria a compilar duas vezes.
            what: const *char = "re.match()" if strcmp(name, "__re_match") == 0 else "re.search()"
            if e->nargs != 2:
                fatal_at(self->file, e->pos, "%s takes a pattern and a string", what)
            for i in range(2):
                rat: *PsType = self->check_expr(e->args[i])
                self->want(e->args[i], rat, ps_type(self->a, PT_STR, e->pos), what)
            gl: *PsType = ps_type(self->a, PT_LIST, e->pos)
            gl->inner = ps_type(self->a, PT_STR, e->pos)
            ro: *PsType = ps_type(self->a, PT_OPT, e->pos)
            ro->inner = gl
            return ro
        if strcmp(name, "__re_findall") == 0 or strcmp(name, "__re_split") == 0:
            # o que sai é uma lista SEMPRE — não achar nada é uma lista vazia, e
            # não uma ausência: procurar todas as ocorrências de uma coisa que
            # não está lá tem resposta, e a resposta é "nenhuma" (4.2)
            wf: const *char = "re.findall()" if strcmp(name, "__re_findall") == 0 else "re.split()"
            if e->nargs < 2 or e->nargs > (2 if strcmp(name, "__re_findall") == 0 else 3):
                fatal_at(self->file, e->pos, "%s takes a pattern and a string%s", wf,
                         "" if strcmp(name, "__re_findall") == 0 else ", and an optional limit")
            for i in range(2):
                rft: *PsType = self->check_expr(e->args[i])
                self->want(e->args[i], rft, ps_type(self->a, PT_STR, e->pos), wf)
            if e->nargs == 3:
                lt3: *PsType = self->check_expr(e->args[2])
                self->want(e->args[2], lt3, ps_type(self->a, PT_INT, e->pos), "the limit")
            fl: *PsType = ps_type(self->a, PT_LIST, e->pos)
            fl->inner = ps_type(self->a, PT_STR, e->pos)
            return fl
        if strcmp(name, "__re_finditer") == 0:
            # as POSIÇÕES, quatro números por casamento e mais dois por grupo:
            # início e fim de cada um. É o que quem substitui precisa, e é uma
            # lista plana para não alocar uma lista por casamento.
            if e->nargs != 2:
                fatal_at(self->file, e->pos, "re.finditer() takes a pattern and a string")
            for i in range(2):
                rit: *PsType = self->check_expr(e->args[i])
                self->want(e->args[i], rit, ps_type(self->a, PT_STR, e->pos), "re.finditer()")
            il: *PsType = ps_type(self->a, PT_LIST, e->pos)
            il->inner = ps_type(self->a, PT_INT, e->pos)
            return il
        if strcmp(name, "__re_sub") == 0:
            if e->nargs < 3 or e->nargs > 4:
                fatal_at(self->file, e->pos, "re.sub(pattern, replacement, text, count=0)")
            for i in range(3):
                rst: *PsType = self->check_expr(e->args[i])
                self->want(e->args[i], rst, ps_type(self->a, PT_STR, e->pos), "re.sub()")
            if e->nargs == 4:
                ct4: *PsExpr = e->args[3]
                if ct4->kind == PE_DESIG:
                    if strcmp(ct4->text, "count") != 0:
                        fatal_at(self->file, ct4->pos, "re.sub() names its limit `count`, not '%s'", ct4->text)
                    ct4 = ct4->lhs
                    e->args[3] = ct4
                lt4: *PsType = self->check_expr(ct4)
                self->want(ct4, lt4, ps_type(self->a, PT_INT, e->pos), "count")
            return ps_type(self->a, PT_STR, e->pos)
        if strcmp(name, "ord") == 0 or strcmp(name, "chr") == 0:
            # Python's pair. A character IS a one-character string here (3.4),
            # so these are the door between text and the number a codepoint is
            # — and the only way a string reaches an interface of scalars.
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "%s() takes one %s", name, "character" if strcmp(name, "ord") == 0 else "codepoint")
            if strcmp(name, "ord") == 0:
                self->check_want(e->args[0], ps_type(self->a, PT_STR, e->pos), "the character of ord()")
                return ps_type(self->a, PT_INT, e->pos)
            self->check_want(e->args[0], ps_type(self->a, PT_INT, e->pos), "the codepoint of chr()")
            return ps_type(self->a, PT_STR, e->pos)
        if strcmp(name, "interval") == 0:
            # 48.2/51.1: a repeating clock, consumed with `await t.tick()` in an
            # ordinary loop — no new grammar, and a tick that coalesces
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "interval() takes the period in seconds")
            it9: *PsType = self->check_expr(e->args[0])
            self->want(e->args[0], it9, ps_type(self->a, PT_FLOAT, e->pos), "the period of interval()")
            return ps_type(self->a, PT_TIMER, e->pos)
        if strcmp(name, "pack") == 0:
            # 59.1/62.4: the compiler knows the offsets, so this is a language
            # primitive and not a protocol somebody writes. What comes back is
            # `List<u8>` — no new `bytes` type (62.4)
            if e->nargs < 1 or e->nargs > 2:
                fatal_at(self->file, e->pos, "pack() takes a record and, if the bytes are for somebody else, the byte order: `pack(r, BE)`")
            pt9: *PsType = self->check_expr(e->args[0])
            if pt9 == None or pt9->kind != PT_NAME or not self->records.has(pt9->name) or self->records.get_or(pt9->name, None)->kind != PD_RECORD:
                fatal_at(self->file, e->pos, "pack() takes a `record` — the only thing that IS pure bytes (58.2) — found %s", ps_type_str(self->a, pt9))
            if e->nargs == 2:
                self->check_endian(e->args[1])
            pl9: *PsType = ps_type(self->a, PT_LIST, e->pos)
            pl9->inner = ps_type(self->a, PT_INT, e->pos)
            pl9->inner->width = 8
            pl9->inner->uns = True
            return pl9
        if strcmp(name, "unpack") == 0:
            # `unpack<T>(b)` (59.3): the size is the contract — the length has
            # to match exactly, and it raises when it does not
            if e->nargs < 1 or e->nargs > 2 or e->type == None:
                fatal_at(self->file, e->pos, "unpack names the type it reads: `unpack<Sphere>(bytes)`, and optionally the byte order: `unpack<Sphere>(bytes, BE)` (59.3)")
            ut9: *PsType = self->resolve_type(e->type)
            if ut9 == None or ut9->kind != PT_NAME or not self->records.has(ut9->name) or self->records.get_or(ut9->name, None)->kind != PD_RECORD:
                fatal_at(self->file, e->pos, "unpack reads a `record`, found %s", ps_type_str(self->a, ut9))
            bt9: *PsType = self->check_expr(e->args[0])
            if bt9 == None or bt9->kind != PT_LIST or bt9->inner == None or bt9->inner->kind != PT_INT or bt9->inner->width != 8:
                fatal_at(self->file, e->pos, "unpack reads the `List<u8>` that pack made, found %s", ps_type_str(self->a, bt9))
            if e->nargs == 2:
                self->check_endian(e->args[1])
            e->type = ut9
            return ut9
        if strcmp(name, "render") == 0 and not self->funcs.has(name):
            # 63.2: a template is an f-string that lives in a file. The holes
            # resolve against the scope of THIS call, at compile time (63.3) —
            # there is no template engine at run time, and no second language
            # to specify: `{{`/`}}` escape and the format spec is the one
            # f-strings already have.
            if e->nargs < 1 or e->nargs > 2 or e->args[0]->kind != PE_STR:
                fatal_at(self->file, e->pos, "render() takes a string literal path and, if the holes are not names in scope, a dict literal with the values: `render(\"email.tpl\", {\"name\": who})` (63.2/75.2)")
            rl8: usize = 0
            rel8: const *char = str_lit_decode_py(self->a, e->args[0]->text, out rl8)
            p8: const *char = path_join(self->a, path_dir(self->a, self->file), rel8)
            n8: usize = 0
            by8: *char = read_entire_file_opt(p8, out n8)
            if by8 == None:
                fatal_at(self->file, e->pos, "render(): could not read '%s'", p8)
            if strlen(by8) != n8:
                fatal_at(self->file, e->pos, "render(): '%s' has a nul byte — a template is text", p8)
            lex8: const *char = c_string_literal(self->a, by8, n8)
            free(by8)
            tpl8: *PsExpr
            if e->nargs == 2:
                # 75.2: the values come in a dict LITERAL written right there.
                # A dict VARIABLE would mean looking a key up at run time, and
                # then a template could ask for something that is not in it —
                # which is the template engine 63.2 refused to have. Written at
                # the call, the key set is known when the file is spliced, so
                # every hole is resolved, typed and formatted at compile time,
                # and the values may be of DIFFERENT types, which a real dict
                # could not hold.
                d8: *PsExpr = e->args[1]
                if d8->kind != PE_DICT:
                    fatal_at(self->file, e->pos, "render(): the values come in a dict literal written at the call — `render(\"email.tpl\", {\"name\": who})` — because the holes are resolved at compile time (75.2)")
                nk8: i32 = d8->nargs
                keys8: **char = None
                vals8: **PsExpr = None
                used8: *bool = None
                keys8 = self->a->alloc(usize(nk8 + 1) * sizeof(*keys8))
                vals8 = self->a->alloc(usize(nk8 + 1) * sizeof(*vals8))
                used8 = self->a->alloc(usize(nk8 + 1) * sizeof(*used8))
                for i8 in range(nk8):
                    ent8: *PsExpr = d8->args[i8]
                    if ent8->kind != PE_DESIG or ent8->lhs == None or ent8->lhs->kind != PE_STR:
                        fatal_at(self->file, ent8->pos if ent8 != None else e->pos, "render(): every key of the values dict is a string literal, because it names a hole of the template (75.2)")
                    kl8: usize = 0
                    keys8[i8] = self->a->strdup(str_lit_decode_py(self->a, ent8->lhs->text, out kl8))
                    for j8 in range(i8):
                        if strcmp(keys8[j8], keys8[i8]) == 0:
                            fatal_at(self->file, ent8->pos, "render(): the key '%s' is given twice", keys8[i8])
                    vals8[i8] = ent8->rhs
                    used8[i8] = False
                tpl8 = ps_template_dict(self->a, self->file, lex8, e->pos, keys8, vals8, used8, nk8)
                for i8 in range(nk8):
                    if not used8[i8]:
                        fatal_at(self->file, d8->args[i8]->pos, "render(): '%s' is in the values, but no hole of the template asks for it", keys8[i8])
            else:
                tpl8 = ps_template(self->a, self->file, lex8, e->pos)
            *e = *tpl8
            return self->check_expr(e)
        if strcmp(name, "embed") == 0 or strcmp(name, "embed_bytes") == 0:
            # 63.1/63.5: the file becomes DATA at compile time. In P the result
            # is a static array; here a `str` is what the language already has,
            # so `embed` yields one and pays what every string literal pays.
            bin7: bool = strcmp(name, "embed_bytes") == 0
            if e->nargs != 1 or e->args[0]->kind != PE_STR:
                fatal_at(self->file, e->pos, "%s() takes exactly one string literal path", name)
            rl7: usize = 0
            rel7: const *char = str_lit_decode_py(self->a, e->args[0]->text, out rl7)
            if rl7 == 0:
                fatal_at(self->file, e->pos, "%s(): the path is empty", name)
            if strlen(rel7) != rl7:
                fatal_at(self->file, e->pos, "%s(): the path contains a nul byte", name)
            p7: const *char = path_join(self->a, path_dir(self->a, self->file), rel7)
            n7: usize = 0
            by7: *char = read_entire_file_opt(p7, out n7)
            if by7 == None:
                fatal_at(self->file, e->pos, "%s(): could not read '%s'", name, p7)
            if not bin7 and strlen(by7) != n7:
                fatal_at(self->file, e->pos, "embed(): '%s' has a nul byte at offset %zu — binary data is embed_bytes()", p7, strlen(by7))
            lit7: const *char = c_string_literal(self->a, by7, n7)
            free(by7)
            if not bin7:
                # it IS a string literal from here on: the same node the lexer
                # would have produced had the bytes been written in the source
                with e:
                    .kind = PE_STR
                    .text = lit7
                    .lhs = None
                    .rhs = None
                    .args = None
                    .nargs = 0
                return ps_type(self->a, PT_STR, e->pos)
            # `embed_bytes` is the fixed array of 33.4, and C initializes one
            # from a string literal — which is what the P side emits too, and
            # why a megabyte of font does not become a megabyte of AST
            ln7: *Expr = ex_new(self->a, EX_STRING, e->pos)
            ln7->text = lit7
            with e:
                .kind = PE_LOWERED
                .low = ln7
                .lhs = None
                .rhs = None
                .args = None
                .nargs = 0
            at7: *PsType = ps_type(self->a, PT_ARRAY, e->pos)
            at7->inner = ps_type(self->a, PT_INT, e->pos)
            at7->inner->width = 8
            at7->inner->uns = True
            at7->count = ps_expr(self->a, PE_INT, e->pos)
            at7->count->text = self->a->printf("%zu", n7)
            at7->count->type = ps_type(self->a, PT_INT, e->pos)
            e->type = at7
            return at7
        if strcmp(name, "Channel") == 0:
            # S3/147: `Channel<T>(n)`. O elemento vem da ANOTAÇÃO, como um `[]`
            # vazio — escrever `Channel<int>(4)` numa expressão daria ao `<` dois
            # significados no mesmo sítio, e o preço disso paga-se para sempre.
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "Channel(n) takes the capacity, and it is at least 1 — there is no rendezvous channel (147)")
            cct: *PsType = self->check_expr(e->args[0])
            self->want(e->args[0], cct, ps_type(self->a, PT_INT, e->pos), "the capacity of a Channel")
            ch9: *PsType = self->hint
            if ch9 == None or ch9->kind != PT_CHAN or ch9->inner == None:
                fatal_at(self->file, e->pos, "a Channel needs to say what crosses it: `ch: Channel<int> = Channel(4)`")
            if ch9->inner->kind == PT_OPT:
                # 147.1: `recv()` já responde None no fim. Um canal de `T?`
                # faria de None duas coisas — um valor que atravessou e o fim do
                # canal — e nenhum laço conseguiria distinguir as duas.
                fatal_at(self->file, e->pos, "a Channel of `%s` cannot be told apart from its own end: recv() answers None when the channel closes (147.1)", ps_type_str(self->a, ch9->inner))
            return ch9
        if strcmp(name, "taskgroup") == 0:
            # S3/147.4: um grupo é sobre TEMPO DE VIDA. Só faz sentido num
            # `with`, e é lá que a garantia dele vive — fora dele não haveria
            # bloco nenhum a que nada pudesse sobreviver.
            if e->nargs != 0:
                fatal_at(self->file, e->pos, "taskgroup() takes no arguments")
            if self->in_with == 0:
                fatal_at(self->file, e->pos, "a task group only exists as `with taskgroup() as g:` — what it promises is that nothing it started outlives the BLOCK, and outside one there is no block (147.4)")
            return ps_type(self->a, PT_GROUP, e->pos)
        if strcmp(name, "Decoder") == 0:
            # 140/F6: `Decoder()` — bytes entram, o texto que já dá para dizer
            # sai, e o que ficou a meio de um codepoint fica cá dentro.
            if e->nargs != 0:
                fatal_at(self->file, e->pos, "Decoder() takes no arguments: what it decodes comes in through feed()")
            return ps_type(self->a, PT_DECODER, e->pos)
        if ps_renamed_name(self->file, e->pos, name, "buffer", "Buffer"):
            # 19.4/52.3: bytes every worker can write into, closed explicitly —
            # which is what `with` is for
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "Buffer() takes a size in bytes")
            bst: *PsType = self->check_expr(e->args[0])
            self->want(e->args[0], bst, ps_type(self->a, PT_INT, e->pos), "the size of a Buffer")
            return ps_type(self->a, PT_BUFFER, e->pos)
        if strcmp(name, "open") == 0:
            # 48.1: Python's shape, and failure RAISES with the `io` category —
            # a program that ignores the possibility stops instead of writing
            # into nothing
            if e->nargs != 2:
                fatal_at(self->file, e->pos, "open() takes a path and a mode: `open(\"out.txt\", \"w\")`")
            for i in range(2):
                oat: *PsType = self->check_expr(e->args[i])
                self->want(e->args[i], oat, ps_type(self->a, PT_STR, e->pos), "open()")
            # 76.2: opening can take a while (a slow disk, a network mount), so
            # it goes to the pool like every other file operation and what comes
            # back is a TASK: `f = await open("x", "r")`
            ot: *PsType = ps_type(self->a, PT_TASK, e->pos)
            ot->inner = ps_type(self->a, PT_FILE, e->pos)
            return ot
        if strcmp(name, "len") == 0 and e->nargs == 1:
            lat: *PsType = self->check_expr(e->args[0])
            if lat != None and lat->kind == PT_ARRAY:
                return ps_type(self->a, PT_INT, e->pos)
        if strcmp(name, "len") == 0:
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "len() takes exactly one argument")
            at2: *PsType = self->check_expr(e->args[0])
            if at2 != None and at2->kind == PT_TUPLE:
                # 98.1: how many slots, which is known at compile time — the
                # length of a tuple is part of its TYPE
                return ps_type(self->a, PT_INT, e->pos)
            if at2 == None or at2->kind not in {PT_STR, PT_BYTES, PT_LIST, PT_VIEW, PT_DICT, PT_SET, PT_MAPPING, PT_BUFFER}:
                fatal_at(self->file, e->pos, "len() of %s is not compiled yet", ps_type_str(self->a, at2))
            return ps_type(self->a, PT_INT, e->pos)
        if strcmp(name, "abs") == 0:
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "abs() takes one number")
            ab: *PsType = self->check_expr(e->args[0])
            if ab == None or ab->kind not in {PT_INT, PT_FLOAT}:
                fatal_at(self->file, e->pos, "abs() takes a number, not %s", ps_type_str(self->a, ab))
            return ab
        # ---- 104: sum, any, all, round, divmod ----
        if strcmp(name, "sum") == 0:
            if e->nargs < 1 or e->nargs > 2:
                fatal_at(self->file, e->pos, "sum(xs) or sum(xs, start)")
            slt: *PsType = self->check_expr(e->args[0])
            if slt == None or slt->kind != PT_LIST or slt->inner == None or slt->inner->kind not in {PT_INT, PT_FLOAT}:
                fatal_at(self->file, e->pos, "sum() takes a list of numbers, not %s", ps_type_str(self->a, slt))
            if e->nargs == 2:
                self->want(e->args[1], self->check_expr(e->args[1]), slt->inner, "the start of sum()")
            return slt->inner
        if strcmp(name, "any") == 0 or strcmp(name, "all") == 0:
            if e->nargs != 1:
                fatal_at(self->file, e->pos, "%s(xs) takes one list", name)
            alt: *PsType = self->check_expr(e->args[0])
            if alt == None or alt->kind != PT_LIST or alt->inner == None or alt->inner->kind != PT_BOOL:
                fatal_at(self->file, e->pos, "%s() takes a List<bool> — write the test in a comprehension: %s([x > 0 for x in xs]). There is no truthiness here (39.3), so a list of numbers has no answer", name, name)
            return ps_type(self->a, PT_BOOL, e->pos)
        if strcmp(name, "round") == 0:
            if e->nargs < 1 or e->nargs > 2:
                fatal_at(self->file, e->pos, "round(x) or round(x, digits)")
            self->check_want(e->args[0], ps_type(self->a, PT_FLOAT, e->pos), "the number")
            if e->nargs == 2:
                self->want(e->args[1], self->check_expr(e->args[1]), ps_type(self->a, PT_INT, e->pos), "the number of digits")
                return ps_type(self->a, PT_FLOAT, e->pos)
            # sem casas, o Python devolve INT — e arredonda meio para o PAR
            return ps_type(self->a, PT_INT, e->pos)
        if strcmp(name, "divmod") == 0:
            # `divmod(a, b)` é `(a // b, a % b)`, e é escrito aqui como
            # exatamente isso: a tupla já é um valor (98.5), então não há função
            # de runtime nem par de saída por ponteiro
            if e->nargs != 2:
                fatal_at(self->file, e->pos, "divmod(a, b) takes two numbers")
            dt1: *PsType = self->check_expr(e->args[0])
            dt2: *PsType = self->check_expr(e->args[1])
            if dt1 == None or dt1->kind != PT_INT or dt2 == None or dt2->kind != PT_INT:
                fatal_at(self->file, e->pos, "divmod() takes two ints (the float form is `x // y` and `x %% y` written out)")
            # o TIPO é a tupla; quem a constrói é o lowering, que sabe amarrar
            # cada lado num temporário para não avaliar duas vezes
            dtt: *PsType = ps_type(self->a, PT_TUPLE, e->pos)
            dtt->params = self->a->alloc(2 * sizeof(*dtt->params))
            dtt->params[0] = ps_type(self->a, PT_INT, e->pos)
            dtt->params[1] = ps_type(self->a, PT_INT, e->pos)
            dtt->nparams = 2
            return dtt
        if strcmp(name, "min") == 0 or strcmp(name, "max") == 0:
            # a forma de UMA lista: `max(xs)`, que o Python tem e que levanta
            # com a lista vazia em vez de devolver um zero com cara de resposta
            if e->nargs == 1:
                mlt: *PsType = self->check_expr(e->args[0])
                if mlt == None or mlt->kind != PT_LIST or mlt->inner == None or mlt->inner->kind not in {PT_INT, PT_FLOAT, PT_STR}:
                    fatal_at(self->file, e->pos, "%s() takes two numbers, or one list of numbers or strings, not %s", name, ps_type_str(self->a, mlt))
                return mlt->inner
            # two numbers of the same kind. Python also takes an iterable and any
            # number of arguments; those are additive and this is the form that
            # every program actually writes.
            if e->nargs != 2:
                fatal_at(self->file, e->pos, "%s() takes two numbers", name)
            m1: *PsType = self->check_expr(e->args[0])
            m2: *PsType = self->check_expr(e->args[1])
            if m1 == None or m1->kind not in {PT_INT, PT_FLOAT}:
                fatal_at(self->file, e->pos, "%s() takes numbers, not %s", name, ps_type_str(self->a, m1))
            if m2 == None or m2->kind != m1->kind:
                fatal_at(self->file, e->pos, "%s() takes two numbers of the SAME kind: %s and %s", name, ps_type_str(self->a, m1), ps_type_str(self->a, m2))
            return m1
        # 104: os três chegam aqui quando foram escritos onde NÃO são um laço.
        # São açúcar sobre o laço de índice (não há objeto iterador), então
        # dizer isso é melhor do que "função desconhecida".
        if strcmp(name, "enumerate") == 0 or strcmp(name, "zip") == 0 or strcmp(name, "reversed") == 0:
            fatal_at(self->file, e->pos, "%s() is not a value: it only appears as the iterable of a `for` (it is the index loop written out, not an iterator object)", name)
        fatal_at(self->file, e->pos, "unknown function '%s'", name)
        return None

    # ---------- modules (41.3) ----------
    # `import geom`, `import geom as g`, `from geom import Vec2 [as V]`.
    #
    # The visibility is Python's: a module's names are NOT visible in another
    # module unless the qualifier names them or `from` brings them over. The
    # target, though, is a single translation unit, which has no namespaces —
    # so the namespace is resolved here, by RENAMING: every declaration of an
    # imported module gets a unique global name (`geom__area`), and a qualified
    # or imported reference is rewritten to it while the names are still being
    # resolved. Two modules may each declare `area`, and neither sees the
    # other's.
    #
    # This is the one place pscript deliberately answers differently from P.
    # P's 42.4 made the qualifier a checked SPELLING over one flat set of
    # names, because P is the language that talks to C, where a name already IS
    # global and renaming would break the very thing it is for. pscript has no
    # such obligation, so it pays a rename and gets real modules.
    #
    # Declarations still all end up in ONE module — the renaming is what makes
    # that safe — because the backend emits one file.
    private def build_ns(self: *PsSema, m: *PsModule, prefix: const *char, name: const *char) -> *PsNs:
        ns: *PsNs = self->a->alloc(sizeof(*ns))
        ns->name = name
        ns->prefix = prefix
        ns->m = m
        ns->sym.init()
        ns->priv.init()
        ns->ents = None
        ns->nents = 0
        ns->cents = 0
        ns->quals = None
        ns->nquals = 0
        ns->cquals = 0
        # cached BEFORE recursing: a cycle (a imports b imports a) then finds
        # this namespace instead of parsing a second copy of the file
        self->nsof.put(m->path, ns)

        # 1. the module's OWN top-level names, as written
        for i in range(m->ndecls):
            d: *PsDecl = m->decls[i]
            d->src_name = d->name
            match d->kind:
                case PD_FUNC, PD_RECORD, PD_STRUCT, PD_VAR, PD_SHARED, PD_TRAIT:
                    ns->sym.add(d->name)
                    if d->is_private:
                        ns->priv.add(d->name)    # 44.4
                case PD_ENUM:
                    ns->sym.add(d->name)
                    for j in range(d->nitems):
                        ns->sym.add(d->items[j].name)   # an item is reached bare
                case _:
                    pass

        # 2. rename them, unless this is the module being compiled
        if prefix[0] != 0:
            for i in range(m->ndecls):
                d: *PsDecl = m->decls[i]
                if d->src_name != None:
                    PS_DISP.put(self->a->printf("%s%s", prefix, d->src_name),
                                (*char)(self->a->printf("%s.%s", name, d->src_name)))
                match d->kind:
                    case PD_FUNC:
                        d->name = self->a->printf("%s%s", prefix, d->name)
                        if d->func != None:
                            d->func->name = d->name
                    case PD_RECORD, PD_STRUCT, PD_VAR, PD_SHARED, PD_TRAIT:
                        d->name = self->a->printf("%s%s", prefix, d->name)
                    case PD_ENUM:
                        d->name = self->a->printf("%s%s", prefix, d->name)
                        for j in range(d->nitems):
                            src: const *char = d->items[j].name
                            d->items[j].name = self->a->printf("%s%s", prefix, src)
                            PS_DISP.put(d->items[j].name, (*char)(self->a->printf("%s.%s", name, src)))
                    case _:
                        pass

        # every declaration carries the namespace that WROTE it: the lists are
        # merged below, and a body has to be checked where it was written
        for i in range(m->ndecls):
            d0: *PsDecl = m->decls[i]
            d0->ns = ns
            if d0->func != None:
                d0->func->ns = ns
            for j in range(d0->nmethods):
                d0->methods[j]->ns = ns

        # 3. its own imports, depth first
        dir: const *char = path_dir(self->a, m->path)
        acc: Vec<*PsDecl>
        acc.init()
        for i in range(m->ndecls):
            d: *PsDecl = m->decls[i]
            if d->kind != PD_IMPORT and d->kind != PD_FROM_IMPORT:
                continue
            # ONDE o módulo está, e COMO ele se chama aqui — duas coisas
            # diferentes assim que `<>` entra em jogo. `<pui>` é o pacote (a
            # raiz dele: `pui/pui.psc`), `<pui/layout.psc>` é um módulo dele, e
            # nos dois casos o nome do espaço é o último pedaço sem extensão.
            path: const *char = ""
            qual: const *char = d->path
            if d->import_system:
                rel: const *char = d->path
                if not ps_ends_with(d->path, ".psc"):
                    rel = self->a->printf("%s/%s.psc", d->path, d->path)
                got: const *char = pkg_find(self->a, self->pkgroots, self->npkgroots, rel)
                if got == None:
                    fatal_at(m->path, d->pos, "import <%s>: not found in any package root (%s)",
                             d->path, pkg_where(self->a, self->pkgroots, self->npkgroots))
                path = got
                qual = ps_mod_name(self->a, d->path)
            else:
                path = path_join(self->a, dir, self->a->printf("%s.psc", d->path))
            sub: *PsNs = self->nsof.get_or(path, None)
            # `sys` is the one module that is not a file (48.3): what it names
            # is the program's own surroundings, which only the runtime can
            # answer. Its members are BUILTINS, so there is nothing to load.
            if sub == None and not d->import_system and ps_builtin_mod(d->path):
                sub = self->builtin_ns(d->path, path)
            if sub == None:
                n: usize = 0
                bytes: *char = read_entire_file_opt(path, out n)
                if bytes == None:
                    fatal_at(m->path, d->pos, "cannot find module '%s' (looked for '%s')", d->path, path)
                tl: TokenList = ps_lex(path, bytes, n, self->a)
                sm: *PsModule = ps_parse(self->a, path, tl)
                free(bytes)
                sub = self->build_ns(sm, self->fresh_prefix(qual), qual)
                for j in range(sm->ndecls):
                    sd: *PsDecl = sm->decls[j]
                    if sd->kind == PD_IMPORT or sd->kind == PD_FROM_IMPORT:
                        continue
                    acc.push(sd)
            # checked on EVERY import, not only the one that read the file: a
            # module can reach the cache through a transitive import first
            if sub->m->main != None and sub->m->main->n > 0:
                fatal_at(m->path, d->pos, "module '%s' has top-level statements: an imported module is a set of definitions, not a program to run", d->path)
            if d->kind == PD_IMPORT:
                q: const *char = d->alias if d->alias != None else qual
                if ns_find(ns->quals, ns->nquals, q) != None:
                    fatal_at(m->path, d->pos, "'%s' is already imported", q)
                ns->quals = vec_grow(ns->quals, ns->nquals, ref ns->cquals, sizeof(*ns->quals))
                with ns->quals[ns->nquals]:
                    .name = q
                    .orig = d->path
                    .ns = sub
                ns->nquals += 1
            else:
                for k in range(d->nnames):
                    ns_check_visible(sub, d->names[k], m->path, d->pos, d->path)
                    local: const *char = d->aliases[k] if d->aliases[k] != None else d->names[k]
                    if ns->sym.has(local) or ns_find(ns->ents, ns->nents, local) != None:
                        fatal_at(m->path, d->pos, "'%s' is already declared in this module", local)
                    ns->ents = vec_grow(ns->ents, ns->nents, ref ns->cents, sizeof(*ns->ents))
                    with ns->ents[ns->nents]:
                        .name = local
                        .orig = d->names[k]
                        .ns = sub
                    ns->nents += 1
        if acc.len > 0:
            nd: **PsDecl = self->a->alloc(usize(acc.len + m->ndecls) * sizeof(*nd))
            for i in range(acc.len):
                nd[i] = acc.data[i]
            for i in range(m->ndecls):
                nd[acc.len + i] = m->decls[i]
            m->decls = nd
            m->ndecls = acc.len + m->ndecls
        return ns

    # Enter the namespace a declaration came from: the flat list holds every
    # module's declarations, and a body has to be checked — and its errors
    # reported — in the module that WROTE it.
    private def enter_decl(self: *PsSema, d: *PsDecl):
        self->cur_ns = d->ns if d != None and d->ns != None else self->root_ns
        self->file = self->cur_ns->m->path

    # A METHOD's namespace, which is not always its type's: an
    # `implement Trait for Point:` block in another module writes methods that
    # end up on `Point`, and their bodies belong where they were written.
    private def enter_func(self: *PsSema, d: *PsDecl, f: *PsFunc):
        ns: *PsNs = f->ns if f != None and f->ns != None else None
        if ns == None:
            ns = d->ns if d != None and d->ns != None else self->root_ns
        self->cur_ns = ns
        self->file = ns->m->path

    # ---------- traits (66/67) ----------
    # `implement Printable for Point:` — the implementation as a block of its
    # own (66.1). What makes it cheap is the same trick P's D1 used: the block's
    # methods are registered as methods OF THE TYPE, so every call resolves
    # through the method lookup that already existed and no dispatch is
    # invented. The trait is a CONTRACT, checked here and then gone.
    private def check_impl(self: *PsSema, d: *PsDecl):
        self->enter_decl(d)
        td: *PsDecl = self->find_trait(d->trait_type, d->pos)
        ft: *PsType = self->resolve_type(d->for_type)
        if ft == None or ft->kind != PT_NAME or not self->records.has(ft->name):
            fatal_at(self->file, d->pos, "a trait is implemented for a record: '%s' is not one", ps_type_str(self->a, d->for_type))
        rd: *PsDecl = self->records.get_or(ft->name, None)
        # the orphan rule (67.3): the trait or the type has to be YOURS. Without
        # it, two modules implement the same pair differently and which one runs
        # depends on who linked — the error lands far from the cause.
        if td->ns != self->cur_ns and rd->ns != self->cur_ns:
            fatal_at(self->file, d->pos, "neither the trait '%s' nor the type '%s' belongs to this module: an implementation has to live with one of them (67.3)", ps_disp(td->name), ps_disp(rd->name))
        key: const *char = self->a->printf("%s|%s", td->name, rd->name)
        if self->timpls.has(key):
            fatal_at(self->file, d->pos, "'%s' is already implemented for '%s': one implementation per pair, in the whole program (67.3)", ps_disp(td->name), ps_disp(rd->name))
        self->timpls.add(key)
        for j in range(d->nmethods):
            d->methods[j]->owner = rd->name
        self->conform(rd, td, d->methods, d->nmethods, d->pos, True, d->assoc_type)
        self->add_methods(rd, d->methods, d->nmethods)

    # `record R implements Printable:` — the same contract, declared where the
    # type is (66.1). Nominal either way (66.2): having the methods is not
    # enough, and this is the line that says so.
    private def check_implements(self: *PsSema, d: *PsDecl):
        self->enter_decl(d)
        for i in range(d->nimplements):
            tt: *PsType = ps_type(self->a, PT_NAME, d->pos)
            tt->name = d->implements[i]
            td: *PsDecl = self->find_trait(tt, d->pos)
            key: const *char = self->a->printf("%s|%s", td->name, d->name)
            if self->timpls.has(key):
                fatal_at(self->file, d->pos, "'%s' is already implemented for '%s': one implementation per pair, in the whole program (67.3)", ps_disp(td->name), ps_disp(d->name))
            self->timpls.add(key)
            # the clause form is only for a type that IS yours, so the orphan
            # rule holds by construction; what is left is the conformance
            self->conform(d, td, d->methods, d->nmethods, d->pos, False, d->assoc_type)

    # The two lists the lowering needs: which traits are used as a `dyn` (one
    # vtable STRUCT each) and which pairs are actually boxed (one vtable VALUE
    # each). Kept here because the sema is where both halves are known.
    private def note_dyn_trait(self: *PsSema, td: *PsDecl):
        if self->dseen.has(td->name):
            return
        self->dseen.add(td->name)
        self->dtraits.push(td)

    private def note_dyn(self: *PsSema, tname: const *char, rname: const *char):
        key: const *char = self->a->printf("%s|%s", tname, rname)
        if self->dseen.has(key):
            return
        self->dseen.add(key)
        u: PsDynUse = {0}
        u.td = self->traits.get_or(tname, None)
        u.rd = self->records.get_or(rname, None)
        self->dpairs.push(u)

    # a `struct` is the collected REFERENCE type (20.1); a `record` is the value
    # one (52.1). Everything downstream reads this off the type node.
    private def is_struct_name(self: *PsSema, name: const *char) -> bool:
        if name == None or not self->records.has(name):
            return False
        d: *PsDecl = self->records.get_or(name, None)
        return d != None and d->kind == PD_STRUCT

    private def named_type(self: *PsSema, name: const *char, pos: Pos) -> *PsType:
        t: *PsType = ps_type(self->a, PT_NAME, pos)
        t->name = name
        t->is_ref = self->is_struct_name(name)
        return t

    # a bound is written as a bare name, and it is resolved in the namespace of
    # the function that WROTE it, not of the call site
    private def find_trait_named(self: *PsSema, name: const *char, ns: *PsNs, pos: Pos) -> *PsDecl:
        save: *PsNs = self->cur_ns
        if ns != None:
            self->cur_ns = ns
        t: *PsType = ps_type(self->a, PT_NAME, pos)
        t->name = name
        td: *PsDecl = self->find_trait(t, pos)
        self->cur_ns = save
        return td

    private def find_trait(self: *PsSema, t: *PsType, pos: Pos) -> *PsDecl:
        name: const *char = t->name
        if t->qual != None:
            q: *PsNsEnt = ns_find(self->cur_ns->quals, self->cur_ns->nquals, t->qual) if self->cur_ns != None else None
            if q == None:
                fatal_at(self->file, pos, "unknown module '%s'", t->qual)
            ns_check_visible(q->ns, name, self->file, pos, q->orig)
            name = self->a->printf("%s%s", q->ns->prefix, name)
        else:
            name = self->gname(name, pos)
        if not self->traits.has(name):
            fatal_at(self->file, pos, "unknown trait '%s'", t->name)
        return self->traits.get_or(name, None)

    # Nominal conformance (66.2). `closed` says whether the method list is the
    # WHOLE of what was written for this trait: an `implement` block holds
    # nothing else, so a method the trait never asked for is a mistake there —
    # while a record with `implements` naturally has methods of its own.
    private def conform(self: *PsSema, rd: *PsDecl, td: *PsDecl, ms: **PsFunc, nms: i32, pos: Pos, closed: bool, assoc: *PsType):
        # the associated type (66.4): the trait names it, the implementation
        # says what it IS, and from here on the two signatures are compared with
        # that name standing for that type — exactly like `Self`
        if td->assoc != None:
            if assoc == None:
                fatal_at(self->file, pos, "'%s' declares the associated type '%s': the implementation has to say what it is, with `type %s = T` (66.4)", ps_disp(td->name), td->assoc, td->assoc)
            self->assoc_name = td->assoc
            self->assoc_type = self->resolve_type(assoc)
        else:
            if assoc != None:
                fatal_at(self->file, pos, "'%s' has no associated type", ps_disp(td->name))
            self->assoc_name = None
            self->assoc_type = None
        for i in range(td->nmethods):
            tm: *PsFunc = td->methods[i]
            im: *PsFunc = None
            for j in range(nms):
                if strcmp(ms[j]->name, tm->name) == 0:
                    im = ms[j]
                    break
            if im == None:
                fatal_at(self->file, pos, "'%s' does not implement '%s.%s' (66.2)", ps_disp(rd->name), ps_disp(td->name), tm->name)
            # `async` is part of the signature, not a decoration: an `async
            # def` gives back a `Task<T>` and a plain `def` gives back the `T`.
            # A caller written against the trait writes `await` or does not, so
            # the two have to agree or the call site is wrong for one of them.
            if im->is_async != tm->is_async:
                fatal_at(self->file, im->pos, "'%s.%s' is %s; the trait declares it %s — `async` is part of the signature, because one gives back a Task and the other gives back the value", ps_disp(rd->name), im->name, "`async def`" if im->is_async else "a plain `def`", "`async def`" if tm->is_async else "a plain `def`")
            if im->nparams != tm->nparams:
                fatal_at(self->file, im->pos, "'%s.%s' takes %d parameter(s); the trait declares %d", ps_disp(rd->name), im->name, im->nparams, tm->nparams)
            for k in range(tm->nparams):
                tp: *PsParam = &tm->params[k]
                ip: *PsParam = &im->params[k]
                if tp->type == None and ip->type == None:
                    # the receiver: its type IS the implementing type, and
                    # whether it is written `in self` or `self` is decided by
                    # that type's KIND — a record is a value (57.1), a struct is
                    # a reference (20.1) — not by the trait
                    continue
                if tp->is_in != ip->is_in:
                    fatal_at(self->file, ip->pos, "parameter '%s' is %s in the trait", ip->name, "`in`" if tp->is_in else "not `in`")
                want: *PsType = self->sig_type(td->ns, tp->type, rd->name)
                got: *PsType = self->sig_type(im->ns, ip->type, rd->name)
                if not ps_type_eq(want, got):
                    fatal_at(self->file, ip->pos, "parameter '%s' is %s; the trait declares %s", ip->name, ps_type_str(self->a, got), ps_type_str(self->a, want))
            wr: *PsType = self->sig_type(td->ns, tm->ret, rd->name)
            gr: *PsType = self->sig_type(im->ns, im->ret, rd->name)
            if not ps_type_eq(wr, gr):
                fatal_at(self->file, im->pos, "'%s.%s' returns %s; the trait declares %s", ps_disp(rd->name), im->name, ps_type_str(self->a, gr), ps_type_str(self->a, wr))
        if closed:
            for j in range(nms):
                found: bool = False
                for i in range(td->nmethods):
                    if strcmp(ms[j]->name, td->methods[i]->name) == 0:
                        found = True
                        break
                if not found:
                    fatal_at(self->file, ms[j]->pos, "'%s' is not a method of trait '%s': an `implement` block holds the trait's methods and nothing else", ms[j]->name, ps_disp(td->name))

    # A signature type, resolved in the namespace that WROTE it and with `Self`
    # standing for the implementing type (66.4). It resolves a COPY: the same
    # trait signature is compared against every type that implements it.
    # the types a signature names, resolved in the namespace that WROTE it
    private def resolve_sig(self: *PsSema, f: *PsFunc):
        if f == None:
            return
        f->ret = self->resolve_type(f->ret)
        for i in range(f->nparams):
            if f->params[i].type != None:
                f->params[i].type = self->resolve_type(f->params[i].type)

    private def sig_type(self: *PsSema, ns: *PsNs, t: *PsType, selfname: const *char) -> *PsType:
        if t == None:
            return None
        c: *PsType = ps_type_clone(self->a, t)
        if selfname != None:
            ps_subst_self(c, selfname)
        if self->assoc_name != None and self->assoc_type != None:
            c = ps_subst_named(self->a, c, self->assoc_name, self->assoc_type)
        save: *PsNs = self->cur_ns
        savef: const *char = self->file
        if ns != None:
            self->cur_ns = ns
            self->file = ns->m->path
        r: *PsType = self->resolve_type(c)
        self->cur_ns = save
        self->file = savef
        return r

    # the trait's methods become the TYPE's: no new dispatch, and the lowering
    # emits them exactly like the ones written inside the record
    private def add_methods(self: *PsSema, rd: *PsDecl, ms: **PsFunc, nms: i32):
        if nms == 0:
            return
        nw: **PsFunc = self->a->alloc(usize(rd->nmethods + nms) * sizeof(*nw))
        for i in range(rd->nmethods):
            nw[i] = rd->methods[i]
        for i in range(nms):
            for j in range(rd->nmethods):
                if strcmp(nw[j]->name, ms[i]->name) == 0:
                    fatal_at(self->file, ms[i]->pos, "'%s' already has a method '%s'", ps_disp(rd->name), ms[i]->name)
            nw[rd->nmethods + i] = ms[i]
        rd->methods = nw
        rd->nmethods = rd->nmethods + nms

    # 111: os módulos que NÃO são arquivo, numa lista só. Estava escrito como
    # uma corrente de `strcmp` no lugar onde o import resolve, e cada módulo novo
    # tinha de ser acrescentado LÁ e aqui embaixo — esquecer um dos dois dá
    # "cannot find module 'os'", que não diz nada.
    # A module with no file behind it (48.3). Its members resolve to names the
    # sema knows by hand — `__sys_argv` and friends — which is what lets the
    # program spell it `sys.argv` while the runtime answers.
    private def builtin_ns(self: *PsSema, name: const *char, path: const *char) -> *PsNs:
        ns: *PsNs = self->a->alloc(sizeof(PsNs))
        ns->name = name
        ns->prefix = self->a->printf("__%s_", name)
        ns->m = self->a->alloc(sizeof(PsModule))
        ns->m->path = self->a->printf("<%s>", name)
        ns->sym.init()
        ns->priv.init()
        ns->ents = None
        ns->nents = 0
        ns->cents = 0
        ns->quals = None
        ns->nquals = 0
        ns->cquals = 0
        if strcmp(name, "net") == 0:
            # 77.1: what a program actually wants from a network, with
            # socket/bind/listen/setsockopt left behind
            ns->sym.add("listen")
            ns->sym.add("connect")
            ns->sym.add("lookup")
            # F7: os dois que faltavam. `udp` fala em DATAGRAMAS e `unix` fala
            # sobre um CAMINHO — e o segundo herda tudo o resto de graça, porque
            # já é um fluxo e já é sondado.
            ns->sym.add("udp")
            ns->sym.add("unix")
            ns->sym.add("unix_listen")
            # S7: o TLS é um MODO de uma ligação que já existe, portanto vive
            # aqui e não num tipo novo. **Duas funções e não uma bandeira**: não
            # há `verify=False`, há `starttls_insecure`, que aparece num `grep`
            # e que ninguém escreve por descuido (141.4).
            ns->sym.add("starttls")
            ns->sym.add("starttls_insecure")
            ns->sym.add("tls_available")
        elif strcmp(name, "re") == 0:
            # S2b: o motor passou a ser NOSSO, e com ele vieram as funções que
            # faltavam. `import re` continua a não ter caminho e o compilador
            # continua a validar os nomes — a libc foi substituída por dentro.
            ns->sym.add("match")
            ns->sym.add("search")
            ns->sym.add("findall")
            ns->sym.add("finditer")
            ns->sym.add("sub")
            ns->sym.add("split")
        elif strcmp(name, "json") == 0:
            ns->sym.add("parse")
            ns->sym.add("stringify")
        elif strcmp(name, "random") == 0:
            # 103: portado do CPython, então a mesma semente dá a mesma
            # sequência — e é isso que o oráculo confere
            ns->sym.add("seed")
            ns->sym.add("random")
            ns->sym.add("getrandbits")
            ns->sym.add("randint")
            ns->sym.add("randrange")
            ns->sym.add("gauss")
            ns->sym.add("expovariate")
            ns->sym.add("uniform")
            ns->sym.add("choice")
            ns->sym.add("shuffle")
        elif strcmp(name, "math") == 0:
            # casca fina sobre a libm, que é o que o `mathmodule.c` do CPython
            # também é — não há o que portar, e a 27.1 diz que a libc É o runtime
            ns->sym.add("sqrt")
            ns->sym.add("floor")
            ns->sym.add("ceil")
            ns->sym.add("trunc")
            ns->sym.add("fabs")
            ns->sym.add("exp")
            ns->sym.add("log")
            ns->sym.add("log2")
            ns->sym.add("log10")
            ns->sym.add("pow")
            ns->sym.add("sin")
            ns->sym.add("cos")
            ns->sym.add("tan")
            ns->sym.add("asin")
            ns->sym.add("acos")
            ns->sym.add("atan")
            ns->sym.add("atan2")
            ns->sym.add("hypot")
            ns->sym.add("fmod")
            ns->sym.add("isnan")
            ns->sym.add("isinf")
            ns->sym.add("pi")
            ns->sym.add("e")
            ns->sym.add("tau")
            ns->sym.add("inf")
            ns->sym.add("nan")
        elif strcmp(name, "time") == 0:
            ns->sym.add("time")
            ns->sym.add("monotonic")
        elif strcmp(name, "sched") == 0:
            # S3: o escalonador diz o que sabe. Módulo próprio e não `sys`,
            # pelo mesmo motivo que o `gc` é próprio: são os botões e os números
            # de UMA máquina, e juntá-los a `sys` faria de `sys` um caixote.
            ns->sym.add("stats")
        elif strcmp(name, "gc") == 0:
            # 110: os knobs de RUNTIME do coletor. Módulo próprio, como no
            # Python — o que dimensiona array é `-D PSRT_*`, o que se ajusta com
            # a carga é chamada.
            ns->sym.add("collect")
            ns->sym.add("tune")
            ns->sym.add("stats")
        elif strcmp(name, "bisect") == 0:
            # 106: portado de `Lib/bisect.py`, com os dois nomes que o Python
            # tem para cada um (o sem sufixo é o `right`)
            ns->sym.add("bisect")
            ns->sym.add("bisect_left")
            ns->sym.add("bisect_right")
            ns->sym.add("insort")
            ns->sym.add("insort_left")
            ns->sym.add("insort_right")
        elif strcmp(name, "heapq") == 0:
            ns->sym.add("heappush")
            ns->sym.add("heappop")
            ns->sym.add("heapify")
        elif strcmp(name, "os") == 0:
            # 111: a camada de sistema, com os nomes do Python. O que MUDA o
            # sistema de arquivos fica em `os`; o que é conta sobre o nome fica
            # em `path` (que é o `os.path` do Python, importado direto).
            ns->sym.add("listdir")
            ns->sym.add("mkdir")
            ns->sym.add("makedirs")
            ns->sym.add("remove")
            ns->sym.add("rmdir")
            ns->sym.add("rename")
            ns->sym.add("getcwd")
            # 118: as duas que o build pediu — rodar um processo, e saber de
            # quantos núcleos a máquina dispõe
            ns->sym.add("run")
            ns->sym.add("nproc")
            ns->sym.add("exec")
            ns->sym.add("spawn")
            ns->sym.add("kill")
            ns->sym.add("alive")
            # F8: o quarto caso — um filho num TERMINAL. O que volta é o mesmo
            # `Conn` de um socket, então `read`, `write` e `close` já existem.
            # 137: `os.mmap(p)` — o ficheiro em memória, sem o ler
            ns->sym.add("mmap")
            # 140/F4: o que o `java.nio.file` tem e nós não tínhamos
            ns->sym.add("stat")
            ns->sym.add("pread")
            ns->sym.add("pwrite")
            ns->sym.add("scandir")
            # 140/F5: o vigia
            ns->sym.add("watch")
            # ... e as três constantes do `advise`, que são o que faz valer a
            # pena o tipo próprio (137.1)
            ns->sym.add("SEQUENTIAL")
            ns->sym.add("RANDOM")
            ns->sym.add("WILLNEED")
            # S2: os temporários. `tempdir()` diz ONDE; as outras duas CRIAM e
            # devolvem o caminho — nunca um nome que ainda não existe, que é a
            # corrida clássica do `mktemp`.
            ns->sym.add("tempdir")
            ns->sym.add("tempfile")
            ns->sym.add("tempdir_new")
            ns->sym.add("spawn_pty")
            ns->sym.add("pty_resize")
            ns->sym.add("pty_pid")
        elif strcmp(name, "path") == 0:
            ns->sym.add("join")
            ns->sym.add("dirname")
            ns->sym.add("basename")
            ns->sym.add("normpath")
            ns->sym.add("abspath")
            ns->sym.add("exists")
            ns->sym.add("isdir")
            ns->sym.add("isfile")
            ns->sym.add("getsize")
            ns->sym.add("getmtime")
            ns->sym.add("getmtime_ns")   # 118: o mesmo, em nanossegundos
        else:
            ns->sym.add("argv")
            ns->sym.add("env")
            ns->sym.add("exit")
            ns->sym.add("pool")
            ns->sym.add("time")
            ns->sym.add("out")
            ns->sym.add("err")
        self->nsof.put(path, ns)
        return ns

    # a prefix no other module took. Two files named `util.psc` in different
    # directories are different modules and must not collide.
    private def fresh_prefix(self: *PsSema, name: const *char) -> const *char:
        base: const *char = name
        i: i32 = i32(strlen(name)) - 1
        while i >= 0:
            if name[i] == '/':
                base = name + i + 1
                break
            i -= 1
        p: const *char = self->a->printf("%s__", base)
        k: i32 = 2
        while self->prefixes.has(p):
            p = self->a->printf("%s%d__", base, k)
            k += 1
        self->prefixes.add(p)
        return p

    # The one place a name written in the source becomes the name the rest of
    # the compiler sees. A name that is not the module's own and was not
    # imported stays as written — it is a builtin or a C function — EXCEPT when
    # it belongs to the module being compiled, which an imported module must
    # not be able to reach: that is the visibility rule doing its job.
    private def gname(self: *PsSema, name: const *char, pos: Pos) -> const *char:
        return self->gname_x(name, pos, True)

    # `soft` is for a name that is about to be BOUND, not read: a local of an
    # imported module may perfectly well share its spelling with a variable of
    # the program that imports it, and refusing that would make a module's
    # locals depend on who imports it.
    private def gname_soft(self: *PsSema, name: const *char) -> const *char:
        zp: Pos = {0}
        return self->gname_x(name, zp, False)

    private def gname_x(self: *PsSema, name: const *char, pos: Pos, hard: bool) -> const *char:
        ns: *PsNs = self->cur_ns
        if ns == None:
            return name
        if ns->sym.has(name):
            return self->a->printf("%s%s", ns->prefix, name)
        e: *PsNsEnt = ns_find(ns->ents, ns->nents, name)
        if e != None:
            return self->a->printf("%s%s", e->ns->prefix, e->orig)
        # O PRELÚDIO É DA LINGUAGEM, e por isso é de TODO módulo e não só do
        # programa. Ele é prependido ao módulo de cima (é lá que o shadowing da
        # 68.3 se decide), o que o punha no namespace da raiz — e um módulo
        # importado que escrevesse `error(msg, VALUE)` ouvia que `VALUE`
        # "pertence ao módulo sendo compilado, que este não importa". Ninguém
        # importa o prelúdio; era a mensagem certa para a pergunta errada.
        if self->preludes.has(name) and self->root_ns != None and self->root_ns->sym.has(name):
            return self->a->printf("%s%s", self->root_ns->prefix, name)
        if hard and ns != self->root_ns and self->root_ns != None and self->root_ns->sym.has(name):
            fatal_at(ns->m->path, pos, "unknown name '%s' (it belongs to the module being compiled, which '%s' does not import)", name, ns->name)
        return name

    # `geom.area` — resolve the qualifier and rewrite the node to the plain,
    # renamed global. Called from BOTH places a qualified name can appear: as a
    # value, and as a CALLEE, where it has to happen before the dot would be
    # read as a method receiver.
    private def try_mod_qual(self: *PsSema, e: *PsExpr) -> bool:
        if e == None or e->kind != PE_FIELD or e->lhs == None or e->lhs->kind != PE_NAME:
            return False
        if self->cur_ns == None or self->find_local(e->lhs->text) >= 0:
            return False
        q: *PsNsEnt = ns_find(self->cur_ns->quals, self->cur_ns->nquals, e->lhs->text)
        if q == None:
            return False
        ns_check_visible(q->ns, e->text, self->file, e->pos, q->orig)
        with e:
            .kind = PE_NAME
            .text = self->a->printf("%s%s", q->ns->prefix, e->text)
            .lhs = None
        return True

    # ---------- C headers (45.5) ----------
    # `include <math.h>` makes the header's declarations available — but ONLY
    # the ones whose signature has no pointer in it. That is the whole boundary
    # rule: with no pointer crossing, there is nothing for the collector to lose
    # track of and nothing for C to free behind pscript's back. `sqrt` comes
    # through; `fopen` does not, and `unsafe` is where that conversation goes.
    #
    # A declaration that does not fit is SKIPPED, not rejected: a header has
    # hundreds, and refusing the file because one of them takes a `FILE*` would
    # make the rule useless.
    # A constant the header gave: kept as the LITERAL it is, so a read becomes
    # the number and nothing of the header survives into the program (72.4).
    private def cconst_put(self: *PsSema, name: const *char, v: i64):
        if name == None or self->cconsts.has(name) or self->cfuncs.has(name):
            return
        lit: *PsExpr = ps_expr(self->a, PE_INT, zero_ps_pos())
        lit->text = self->a->printf("%lld", v)
        self->cconsts.put(name, lit)

    private def ingest_header(self: *PsSema, m: *PsModule, d: *PsDecl):
        dir: const *char = path_dir(self->a, m->path)
        src: const *char = cpp_capture_ex(self->a, self->cpp, "-E -P", d->path, d->import_system, dir)
        cm: *Module = c_parse(self->a, d->path, src, strlen(src), False)
        # every object-like #define whose value is an integer literal (72.4).
        # `-E -P` expands macros away, so they are read from `-E -dM`, which is
        # the same door the P side uses.
        mac: const *char = cpp_capture_ex(self->a, self->cpp, "-E -dM", d->path, d->import_system, dir)
        al9: Vec<const *char>
        av9: Vec<const *char>
        al9.init()
        av9.init()
        p9: const *char = mac
        while *p9 != '\0':
            eol: const *char = strchr(p9, '\n')
            if eol == None:
                eol = p9 + strlen(p9)
            if strncmp(p9, "#define ", 8) == 0:
                q9: const *char = p9 + 8
                st9: const *char = q9
                while q9 < eol and *q9 != ' ' and *q9 != '(' and *q9 != '\t':
                    q9 += 1
                if q9 < eol and *q9 != '(':        # function-like: no typed value
                    nm9: const *char = self->a->strndup(st9, usize(q9 - st9))
                    while q9 < eol and (*q9 == ' ' or *q9 == '\t'):
                        q9 += 1
                    rhs9: const *char = self->a->strndup(q9, usize(eol - q9))
                    iv9: i64 = 0
                    if macro_int_val(rhs9, &iv9):
                        self->cconst_put(nm9, iv9)
                    elif strlen(rhs9) > 0 and (isalpha(rhs9[0]) or rhs9[0] == '_'):
                        # `#define INT_MAX __INT_MAX__` — an alias. Kept for a
                        # second pass, because the macro it names may not have
                        # been read yet.
                        al9.push(nm9)
                        av9.push(rhs9)
            p9 = eol + 1 if *eol != '\0' else eol
        # the aliases, now that every literal is known. Two rounds is enough for
        # the chains a header actually writes (NAME -> OTHER -> literal).
        for round9 in range(2):
            for k9 in range(al9.len):
                tgt9: *PsExpr = self->cconsts.get_or(av9.data[k9], None)
                if tgt9 != None and not self->cconsts.has(al9.data[k9]):
                    self->cconsts.put(al9.data[k9], tgt9)
        self->ingest_cdecls(m, cm)

    # 75.3/2.4: a P MODULE, read with P's own front end. Nothing about the
    # boundary is loosened — what crosses is what 45.5 always allowed, and the
    # registration below is the very same one a C header goes through. What the
    # import adds is the BUILD: the driver sees this declaration and compiles
    # the module's `.p` alongside, so one command covers both halves instead of
    # the two-step the pstudio port had to do by hand.
    private def ingest_pmodule(self: *PsSema, m: *PsModule, d: *PsDecl):
        # `import <pkg/mod.ph>` vem de um PACOTE e procura-se nas raízes;
        # `import "x.ph"` está ao lado de quem importa. As duas formas não se
        # misturam de propósito — ver a nota do `pkgroots` em `sema.ph`.
        full: const *char = ""
        if d->import_system:
            got: const *char = pkg_find(self->a, self->pkgroots, self->npkgroots, d->path)
            if got == None:
                fatal_at(m->path, d->pos, "import <%s>: not found in any package root (%s)",
                         d->path, pkg_where(self->a, self->pkgroots, self->npkgroots))
            full = got
            # e a partir daqui ele é um import RELATIVO comum: o C gerado inclui
            # o header GERADO, que mora no espelho do `--out-dir` no mesmo lugar
            # relativo em que o fonte mora no disco. A âncora é o arquivo DE
            # CIMA (`self->m`), porque é lá que o C do programa sai — um módulo
            # pscript importado não gera arquivo próprio.
            if not same_space(self->m->path, full):
                fatal_at(m->path, d->pos, "import <%s>: the package root and the sources have to be named the same way — both relative to the current directory, or both absolute. Here the program is '%s' and the package resolved to '%s', and there is no relative path between them that also holds inside the --out-dir mirror", d->path, self->m->path, full)
            d->path = path_relative(self->a, path_dir(self->a, self->m->path), full)
            d->import_system = False
        else:
            full = path_join(self->a, path_dir(self->a, m->path), d->path)
        n: usize = 0
        bytes: *char = read_entire_file_opt(full, out n)
        if bytes == None:
            fatal_at(m->path, d->pos, "import: could not read '%s'", full)
        tl: TokenList = lex(full, bytes, n, self->a)
        pm: *Module = parse_tokens(self->a, full, tl, 1)
        free(bytes)
        self->ingest_cdecls(m, pm)

    # what a module of DECLARATIONS gives a pscript program: the functions
    # whose signature is pointer-free, the members of its enums, and its scalar
    # constants (45.5/72.4). Everything else is silently not there, which is
    # the safe default — a name that did not cross is a name the program
    # cannot spell.
    private def ingest_cdecls(self: *PsSema, m: *PsModule, cm: *Module):
        for i in range(cm->ndecls):
            cd: *Decl = cm->decls[i]
            # a member of an `enum`, and a `static const` scalar: both are
            # values a number can carry, so both cross (72.4)
            if cd->kind == DL_ENUM:
                nxt: i64 = 0
                for j in range(cd->nitems):
                    if cd->items[j].value != None and cd->items[j].value->kind == EX_NUMBER:
                        nxt = strtoll(cd->items[j].value->text, None, 0)
                    self->cconst_put(cd->items[j].name, nxt)
                    nxt += 1
                continue
            # `static T X = <literal>;` in a HEADER is the shape a constant
            # takes there — it is what P emits for a `const` module variable and
            # what any header writes when it wants a named number. A mutable
            # `static` in a header is a per-includer COPY, so reading its
            # initializer says exactly as much as reading the variable would.
            # 113: `const` também. `X: const i32 = 0` num `.ph` é a forma que
            # um número nomeado tem quando o header é LIDO pelo front end do P
            # (75.3) em vez de pelo C — o `static` só aparece no `.h` que o
            # compilador emite. Sem esta linha, uma constante atravessava por
            # `include "x.h"` e desaparecia por `import "x.ph"`, que é a porta
            # que uma função de `CStr` obriga a usar. O `const` pode estar no
            # DECL (`const X = 0`) ou no TIPO (`X: const i32 = 0`) — as duas
            # grafias existem no P, e o `.ph` do editor usa a segunda.
            if cd->kind == DL_VAR and (cd->is_static or cd->is_const or (cd->type != None and cd->type->is_const)) and cd->name != None and cd->init != None and cd->init->kind == EX_NUMBER and cd->type != None and self->c_type(cd->type) != None and self->c_type(cd->type)->kind == PT_INT:
                self->cconst_put(cd->name, strtoll(cd->init->text, None, 0))
                continue
            # 72.6: a P `record` of numbers is a `record` here too. The type
            # is declared THERE and used HERE, which is the only arrangement in
            # which the two languages cannot disagree about its layout — and it
            # is what makes a record able to cross by reference at all.
            #
            # A P `record` and not any struct: `record` is the word for a value
            # the compiler CHECKS to be pure bytes, and it is the one that has
            # a constructor on both sides — so `Rect(3, 4)` means the same
            # thing in the program that writes it and in the module that
            # declared the type.
            if cd->kind == DL_STRUCT and cd->is_record and cd->nfields > 0 and cd->name != None:
                if self->records.has(cd->name) or self->enums.has(cd->name) or self->traits.has(cd->name):
                    continue
                okr: bool = True
                fls: *PsField = self->a->alloc(usize(cd->nfields) * sizeof(PsField))
                for j in range(cd->nfields):
                    fty: *PsType = self->c_type(cd->fields[j].type)
                    if fty == None or fty->kind == PT_VOID or cd->fields[j].name == None:
                        okr = False
                        break
                    fls[j].name = cd->fields[j].name
                    fls[j].type = fty
                    fls[j].pos = zero_ps_pos()
                if not okr:
                    continue
                rdh: *PsDecl = ps_decl(self->a, PD_RECORD, zero_ps_pos())
                rdh->name = cd->name
                rdh->src_name = cd->name
                rdh->fields = fls
                rdh->nfields = cd->nfields
                rdh->from_hdr = True
                self->records.put(cd->name, rdh)
                self->hdrrecs.push(rdh)
                continue
            if cd->kind != DL_FUNC or cd->func == None or cd->func->name == None:
                continue
            f: *Func = cd->func
            if f->is_varargs or f->sig_empty:
                continue      # 12.1: C's variadic ABI does not cross
            rck: i32 = self->cstr_kind(f->ret)
            rt: *PsType = self->c_type(f->ret)
            if rck != 0:
                rt = ps_type(self->a, PT_STR, zero_ps_pos()) if rck == 1 else self->bytes_type(zero_ps_pos())
            if rt == None:
                continue
            ps: *PsFunc = self->a->alloc(sizeof(PsFunc))
            ps->name = f->name
            ps->ret = rt
            ps->ret_cstr = rck
            ok: bool = True
            if f->nparams > 0:
                ps->params = self->a->alloc(usize(f->nparams) * sizeof(PsParam))
                for j in range(f->nparams):
                    pt: *PsType = self->c_type(f->params[j].type)
                    inp: bool = False
                    csk: i32 = self->cstr_kind(f->params[j].type)
                    if csk != 0:
                        # 84.1: a pointer and its length, as a value. On this
                        # side it is `str` or `List<u8>`; what crosses is the
                        # pair, built at the call and valid for its duration.
                        pt = ps_type(self->a, PT_STR, zero_ps_pos()) if csk == 1 else self->bytes_type(zero_ps_pos())
                        # `in s: CStr` is P's spelling for a const reference, so
                        # what the call hands over is the ADDRESS of the pair
                        inp = f->params[j].type != None and f->params[j].type->kind == TY_PTR
                    if pt == None:
                        # 72.6: `const *R` — a record BY REFERENCE, read-only.
                        # It is the one pointer that crosses 45.5, and it does
                        # because nothing on the other side can write through
                        # it and the thing it points at never moves.
                        ptr: *Type = f->params[j].type
                        if ptr != None and ptr->kind == TY_PTR and ptr->inner != None and ptr->inner->kind == TY_NAME and ptr->inner->is_const and ptr->inner->name != None and self->records.has(ptr->inner->name):
                            pt = self->named_type(ptr->inner->name, zero_ps_pos())
                            inp = True
                    if pt == None or pt->kind == PT_VOID:
                        ok = False
                        break
                    ps->params[j].name = f->params[j].name if f->params[j].name != None else "arg"
                    ps->params[j].type = pt
                    ps->params[j].is_in = inp
                    ps->params[j].cstr = csk
                ps->nparams = f->nparams
            if ok and not self->cfuncs.has(f->name) and not self->funcs.has(f->name):
                self->cfuncs.put(f->name, ps)

    # `CStr` / `CBytes` (84.1), by name and by shape: a struct of exactly a
    # pointer and a length. The name is what the compiler recognizes, and the
    # `in` form counts too, because that is how a P signature spells it.
    private def cstr_kind(self: *PsSema, t: *Type) -> i32:
        b: *Type = t
        if b != None and b->kind == TY_PTR:
            b = b->inner
        if b == None or b->kind != TY_NAME or b->name == None:
            return 0
        if strcmp(b->name, "CStr") == 0:
            return 1
        if strcmp(b->name, "CBytes") == 0:
            return 2
        return 0

    # 84.1 + 135.3: what a `CBytes` parameter accepts. `List<u8>` was the only
    # answer before there was a `bytes`, and now there are two — and the second
    # is the better one for exactly the reason 141.3 gives: a `bytes` block
    # lives OUTSIDE the collected heap and never moves, so the pair handed over
    # points straight at it. A `List<u8>` has to be borrowed carefully, because
    # its storage is collected and the collector moves it.
    private def cbytes_ok(self: *PsSema, t: *PsType) -> bool:
        if t == None:
            return False
        if t->kind == PT_BYTES:
            return True
        return t->kind == PT_LIST and t->inner != None and t->inner->kind == PT_INT and t->inner->width == 8 and t->inner->uns

    private def bytes_type(self: *PsSema, pos: Pos) -> *PsType:
        l: *PsType = ps_type(self->a, PT_LIST, pos)
        l->inner = ps_type(self->a, PT_INT, pos)
        l->inner->width = 8
        l->inner->uns = True
        return l

    # a C type as a pscript type, or None when it cannot cross (45.5)
    private def c_type(self: *PsSema, t: *Type) -> *PsType:
        if t == None:
            return ps_type(self->a, PT_VOID, zero_ps_pos())
        if t->kind != TY_NAME or t->name == None:
            return None       # pointer, array, function: does not cross
        n: const *char = t->name
        if strcmp(n, "void") == 0:
            return ps_type(self->a, PT_VOID, zero_ps_pos())
        if strcmp(n, "float") == 0 or strcmp(n, "double") == 0 or strcmp(n, "long double") == 0:
            return ps_type(self->a, PT_FLOAT, zero_ps_pos())
        if strcmp(n, "bool") == 0 or strcmp(n, "_Bool") == 0:
            return ps_type(self->a, PT_BOOL, zero_ps_pos())
        # the integer spellings a C header actually uses in a pointer-free
        # signature. Anything else does not cross, which is the safe default.
        if n in {"int", "char", "short", "long", "signed char", "unsigned char",
                 "unsigned int", "unsigned short", "unsigned long", "unsigned",
                 "long long", "unsigned long long", "size_t", "ssize_t",
                 "int8_t", "int16_t", "int32_t", "int64_t",
                 "uint8_t", "uint16_t", "uint32_t", "uint64_t",
                 "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "usize"}:
            return ps_type(self->a, PT_INT, zero_ps_pos())
        return None

    # Which types may be a dict key or a set element (38.1)? The key is COPIED
    # on insert and compared by CONTENT, so it has to be something a copy fully
    # determines. int, bool, enum and str are; a record would be too, and needs
    # a generated field-by-field hash first, because raw bytes include padding.
    # What may cross between two heaps (34.3): BYTES. A message is copied on
    # the way out and on the way in, which is what keeps the isolation of 18.1
    # true — no reference ever spans two heaps, so no collector ever has to
    # know about another collector's objects. `str`, `list` and friends need
    # the serialization the battery describes, and that is not built yet.
    # the COPY LADDER of 42.1: what a shared table can hold. Bytes qualify, and
    # so does a string — the table keeps a copy of the bytes and gives back a
    # fresh string in the reader's own heap. Everything else the collector owns
    # would mean a pointer crossing heaps (18.1).
    # the byte order of pack/unpack (59.2, extended): an `Endian` — LE, which is
    # the default, or BE. It is a value like any other, so it can be computed
    # (a program that reads the order out of a header file is the point).
    private def check_endian(self: *PsSema, e: *PsExpr):
        et: *PsType = self->check_expr(e)
        if et == None or et->kind != PT_NAME or et->name == None or strcmp(ps_disp(et->name), "Endian") != 0:
            fatal_at(self->file, e->pos, "the byte order is an `Endian` — `LE` or `BE` — found %s", ps_type_str(self->a, et))

    # what a MESSAGE may be (34.3): bytes, a string, or a list of either — the
    # three shapes the runtime knows how to rebuild in the receiver's own heap
    # 34.3/74.2: what may cross between two heaps. Bytes cross by memcpy;
    # anything the collector owns is a GRAPH, and a graph crosses by being
    # written out and built again on the other side. So the question here is
    # not "is this flat" any more — it is "is every part of this a thing the
    # shape can describe", and the walk says which part is not.
    private def sendable(self: *PsSema, t: *PsType, pos: Pos, what: const *char):
        if t != None and t->kind == PT_BUFFER:
            # 52.3: the one thing meant to be SHARED. The bytes are malloc'd
            # and never move, so the handle crosses and the isolation of 18.1
            # still holds for everything the collector owns.
            return
        seen: **char = self->a->alloc(usize(PS_SEND_DEPTH) * sizeof(*seen))
        self->sendable_in(t, pos, what, seen, 0)

    private def sendable_in(self: *PsSema, t: *PsType, pos: Pos, what: const *char, seen: **char, n: i32):
        if t == None:
            return
        match t->kind:
            case PT_INT, PT_FLOAT, PT_BOOL, PT_VOID, PT_STR:
                return
            case PT_LIST, PT_SET:
                self->sendable_in(t->inner, pos, self->a->printf("the element of %s in %s", ps_type_str(self->a, t), what), seen, n)
                return
            case PT_DICT:
                self->key_ok(t->key, pos, self->a->printf("the key of %s in %s", ps_type_str(self->a, t), what))
                self->sendable_in(t->inner, pos, self->a->printf("the value of %s in %s", ps_type_str(self->a, t), what), seen, n)
                return
            case PT_NAME:
                if self->enums.has(t->name):
                    return
                if self->records.has(t->name):
                    rd6: *PsDecl = self->records.get_or(t->name, None)
                    if rd6->kind == PD_RECORD:
                        return          # pure bytes by construction (58.2)
                    for i in range(n):
                        if strcmp(seen[i], t->name) == 0:
                            return      # already on the way down: a type may
                                        # contain itself, and the cycle guard
                                        # at run time is what answers for it
                    if n >= PS_SEND_DEPTH:
                        fatal_at(self->file, pos, "%s nests structs more than %d deep, which is more than the message walk follows", what, PS_SEND_DEPTH)
                    seen[n] = (*char)(t->name)
                    for i in range(rd6->nfields):
                        self->sendable_in(rd6->fields[i].type, pos, self->a->printf("field '%s' of %s", rd6->fields[i].name, t->name), seen, n + 1)
                    return
            case _:
                pass
        fatal_at(self->file, pos, "%s is %s, which a message cannot carry (34.3): numbers, bools, enums, records, str, List, Set, Dict and `struct` cross — a Worker, a Task, a File, a lambda or an `any` do not, because what they name is not the receiver's to have", what, ps_type_str(self->a, t))

    private def copyable(self: *PsSema, t: *PsType, pos: Pos, what: const *char):
        if t != None and t->kind == PT_STR:
            return
        self->pod_only(t, pos, what)

    # What may cross by `out`/`ref` (65.12). The reason the trio came back is
    # the RECORD: it is a value (52.1), so a big one is copied in and copied
    # back, and `ref` is how you skip both copies. A `str`, a `list`, a `dict`
    # or a `struct` is ALREADY a reference — mutating it in place is what `ref`
    # would be for, and rebinding the caller's variable is what a return value
    # is for. So they are refused, and the message says which of the two the
    # writer probably wants.
    private def byref_ok(self: *PsSema, t: *PsType, pos: Pos, kw: const *char):
        if t == None:
            return
        match t->kind:
            case PT_INT, PT_FLOAT, PT_BOOL:
                return
            case PT_ARRAY:
                # An array parameter is ALREADY a reference in both languages —
                # C decays it to a pointer, and a write through it reaches the
                # caller's array. `ref` would be a second level of indirection
                # that buys nothing.
                fatal_at(self->file, pos, "`%s` on a fixed array says nothing: `xs: %s` is already handed over as a reference, and writing into it reaches the caller's array (33.4)", kw, ps_type_str(self->a, t))
            case PT_NAME:
                if self->enums.has(t->name):
                    return
                if self->records.has(t->name):
                    rd8: *PsDecl = self->records.get_or(t->name, None)
                    if rd8->kind == PD_RECORD:
                        return
            case _:
                pass
        fatal_at(self->file, pos, "`%s` takes a number, a bool, an enum, a `record` or a fixed array of those — %s is already a reference, so writing through it is what mutating it does, and rebinding the caller's name is what a return value is for (65.12)", kw, ps_type_str(self->a, t))

    private def pod_only(self: *PsSema, t: *PsType, pos: Pos, what: const *char):
        if t == None:
            return
        match t->kind:
            case PT_INT, PT_FLOAT, PT_BOOL, PT_VOID:
                return
            case PT_BUFFER:
                # 52.3: the framebuffer is the one thing meant to be shared —
                # the bytes are malloc'd and never move, so what crosses is the
                # handle and the isolation of 18.1 still holds for everything
                # the collector owns
                return
            case PT_NAME:
                if self->enums.has(t->name):
                    return
                if self->records.has(t->name):
                    rd7: *PsDecl = self->records.get_or(t->name, None)
                    if rd7->kind == PD_RECORD:
                        return
            case _:
                pass
        fatal_at(self->file, pos, "%s is %s, and a message crosses heaps as BYTES (34.3): numbers, bools, enums and `record` do; anything the collector owns does not (yet)", what, ps_type_str(self->a, t))

    # 65.11: the predefined names of the P, folded here to a literal exactly as
    # `fold_predefined` does over there. There is no preprocessor in either
    # language, so a name that looks like C's dunder has to be resolved by the
    # front end that reads it — and a program that logs where it is needs this
    # more than it needs anything clever.
    private def predef(self: *PsSema, e: *PsExpr) -> *PsType:
        n: const *char = e->text
        if n == None or n[0] != '_' or n[1] != '_':
            return None
        if strcmp(n, "__FILE__") == 0:
            e->kind = PE_STR
            e->text = self->a->printf("\"%s\"", self->file)
            return ps_type(self->a, PT_STR, e->pos)
        if strcmp(n, "__LINE__") == 0:
            e->kind = PE_INT
            e->text = self->a->printf("%d", e->pos.line)
            return ps_type(self->a, PT_INT, e->pos)
        if strcmp(n, "__func__") == 0 or strcmp(n, "__FUNCTION__") == 0:
            # at the top level there is no function, and the implicit main is
            # what the program is in (6.2) — so that is what it says
            e->kind = PE_STR
            e->text = self->a->printf("\"%s\"", self->cur_fn if self->cur_fn != None else "<main>")
            return ps_type(self->a, PT_STR, e->pos)
        # 99.3: which platform, for the `const if` that chooses between two ways
        # of talking to the kernel. Same names and same answer as the P side —
        # one table, asked from two front ends.
        if strcmp(n, "__PLANG_OS__") == 0:
            e->kind = PE_STR
            e->text = self->a->printf("\"%s\"", parser_predef_os())
            return ps_type(self->a, PT_STR, e->pos)
        if strcmp(n, "__PLANG_LINUX__") == 0 or strcmp(n, "__PLANG_MACOS__") == 0 or strcmp(n, "__PLANG_BSD__") == 0 or strcmp(n, "__PLANG__") == 0:
            # BOOL and not int, because here a condition takes a bool and
            # nothing else (40.1) — "am I on linux" is a yes or a no, and the
            # `and`/`or` of a `const if` has to read like every other condition
            pk9: bool = True
            pv9: i64 = parser_predef_value(n, ref pk9)
            e->kind = PE_BOOL
            e->text = "True" if pv9 != 0 else "False"
            return ps_type(self->a, PT_BOOL, e->pos)
        if strcmp(n, "__COUNTER__") == 0:
            e->kind = PE_INT
            e->text = self->a->printf("%d", self->counter)
            self->counter += 1
            return ps_type(self->a, PT_INT, e->pos)
        return None

    # 61.3: `const` in a REFERENCE freezes deep — `const xs = [1, 2]` forbids
    # rebinding AND mutation. Rebinding is caught where the assignment is
    # checked; this is the other half: the NAME a mutation reaches through.
    #
    # It walks to the root of the expression, because `cfg.rows.append(x)`
    # mutates what `cfg` owns just as much as `cfg.append(x)` would.
    private def const_root(self: *PsSema, e: *PsExpr) -> const *char:
        cur: *PsExpr = e
        while cur != None:
            match cur->kind:
                case PE_NAME:
                    return cur->text
                case PE_FIELD, PE_INDEX, PE_OPTFIELD, PE_OPTINDEX, PE_SLICE:
                    cur = cur->lhs
                case _:
                    return None
        return None

    private def deny_const_mut(self: *PsSema, e: *PsExpr, what: const *char):
        n: const *char = self->const_root(e)
        if n == None:
            return
        li: i32 = self->find_local(n)
        if li >= 0:
            if self->locals[li].frozen:
                if strcmp(n, "self") == 0:
                    fatal_at(self->file, e->pos, "a method on a record takes `in self`, which READS the receiver (57.1): %s writes to it — a record is a value, so what a method can do is answer, not change", what)
                fatal_at(self->file, e->pos, "'%s' is const, and `const` freezes DEEP (61.3): %s is a mutation, and what a const forbids is rebinding AND writing", n, what)
            return
        if self->gconst.has(n) or self->gconst.has(self->gname_soft(n)):
            fatal_at(self->file, e->pos, "'%s' is const, and `const` freezes DEEP (61.3): %s is a mutation, and what a const forbids is rebinding AND writing", n, what)

    # 99: is this expression TRUE at compile time? Literals, `not`, `and`, `or`
    # and a comparison between two literals — which is everything a folded
    # predefine or an `is_defined` can leave behind. Anything else is "unknown",
    # and a `const if` says so instead of guessing.
    private def const_truth(self: *PsSema, e: *PsExpr, ref ok: bool) -> bool:
        if e == None:
            ok = False
            return False
        match e->kind:
            case PE_BOOL:
                return strcmp(e->text, "True") == 0
            case PE_INT:
                return strtoll(e->text, None, 0) != 0
            case PE_STR:
                return True            # a non-empty literal; `""` is written `== ""`
            case PE_UNARY:
                if e->op == TK_NOT:
                    return not self->const_truth(e->lhs, ref ok)
                ok = False
                return False
            case PE_BINARY:
                if e->op == TK_AND:
                    l: bool = self->const_truth(e->lhs, ref ok)
                    r: bool = self->const_truth(e->rhs, ref ok)
                    return l and r
                if e->op == TK_OR:
                    l2: bool = self->const_truth(e->lhs, ref ok)
                    r2: bool = self->const_truth(e->rhs, ref ok)
                    return l2 or r2
                if e->op == TK_EQ or e->op == TK_NE:
                    if e->lhs->kind == PE_STR and e->rhs->kind == PE_STR:
                        l3: usize = 0
                        r3: usize = 0
                        a3: *char = str_lit_decode_py(self->a, e->lhs->text, out l3)
                        b3: *char = str_lit_decode_py(self->a, e->rhs->text, out r3)
                        same: bool = strcmp(a3, b3) == 0
                        return same if e->op == TK_EQ else not same
                    if e->lhs->kind == PE_INT and e->rhs->kind == PE_INT:
                        same2: bool = strtoll(e->lhs->text, None, 0) == strtoll(e->rhs->text, None, 0)
                        return same2 if e->op == TK_EQ else not same2
                ok = False
                return False
            case _:
                ok = False
                return False

    private def key_ok(self: *PsSema, t: *PsType, pos: Pos, what: const *char):
        if t == None:
            fatal_at(self->file, pos, "%s has no type", what)
        if t->kind == PT_TUPLE:
            # 24.3: a tuple IS a key when its elements are. It is pure bytes
            # (58.2), so the dict copies it and compares it by content with the
            # machinery it already has — `d[(row, col)]`, which is the case 24.3
            # was written for.
            if not tuple_is_pure(t):
                fatal_at(self->file, pos, "%s is %s: a tuple is a key when its slots are pure bytes (24.3), and this one holds something the collector owns", what, ps_type_str(self->a, t))
            for i in range(t->nparams):
                self->key_ok(t->params[i], pos, "a slot of a tuple used as a key")
            return
        match t->kind:
            case PT_INT, PT_BOOL, PT_STR:
                return
            case PT_NAME:
                if self->enums.has(t->name):
                    return
                fatal_at(self->file, pos, "%s of type '%s' is not compiled yet — a record key needs a field-by-field hash, because its raw bytes include padding", what, t->name)
            case _:
                fatal_at(self->file, pos, "%s cannot be %s: a key is copied and compared by content (38.1)", what, ps_type_str(self->a, t))

    # ---------- records ----------
    # `record` is PURE BYTES (58.2): no collected reference anywhere inside. That
    # one property is what lets a value of it live on the stack, be copied by
    # assignment, be memcpy'd to another worker, be written to disk and be
    # compared by content — and it is why the collector may skip records
    # entirely when it traces.
    #
    # P checks the same rule on the lowered declaration (65.1), so this is not
    # the only guard; it is the one that points at the .psc line.
    private def check_record_bytes(self: *PsSema, d: *PsDecl):
        for i in range(d->nfields):
            f: *PsField = &d->fields[i]
            t: *PsType = f->type
            while t != None and t->kind == PT_ARRAY:
                t = t->inner      # `T[N]` of pure bytes is pure bytes
            if t == None:
                continue
            match t->kind:
                case PT_INT, PT_FLOAT, PT_BOOL:
                    pass
                case PT_NAME:
                    if self->enums.has(t->name):
                        pass      # an enum is an integer (29.2/53.2)
                    elif self->records.has(t->name):
                        rd: *PsDecl = self->records.get_or(t->name, None)
                        if rd->kind != PD_RECORD:
                            fatal_at(self->file, f->pos, "record '%s': field '%s' has type '%s', which is a struct — a struct is collected, and a record holds no reference (58.2)", d->name, f->name, t->name)
                    else:
                        fatal_at(self->file, f->pos, "record '%s': field '%s' has an unknown type '%s'", d->name, f->name, t->name)
                case _:
                    fatal_at(self->file, f->pos, "record '%s': field '%s' is %s, which is collected — a record holds only numbers, bools, enums, other records and fixed arrays of those (58.2)", d->name, f->name, ps_type_str(self->a, f->type))

    # A method on a value type takes `in self` (57.1): reads the receiver without
    # copying it and never mutates it. Producing a new value returns one — the
    # functional style the smallpt already uses.
    private def check_method(self: *PsSema, d: *PsDecl, f: *PsFunc):
        self->nlocals = 0
        self->depth = 0
        self->fn_gone.init()
        self->fn_nonlocals.init()
        self->fn_globals.init()
        # a method may be `async def` too (50.1): it is a function with a
        # receiver, and `await` inside it means what it means anywhere else
        self->in_async = f->is_async
        self->cur_ret = self->resolve_type(f->ret)
        self->cur_fn = self->a->printf("%s.%s", d->name, f->name)
        start: i32 = 0
        if f->nparams > 0 and strcmp(f->params[0].name, "self") == 0:
            if f->params[0].type != None:
                fatal_at(self->file, f->params[0].pos, "the receiver is written `%s`, with no type", "in self" if d->kind == PD_RECORD else "self")
            # A `record` is a VALUE, so its receiver is `in self` — read without
            # copying, never mutated (57.1). A `struct` is a REFERENCE (20.1):
            # the receiver IS the reference, so it is plain `self` and the
            # method may write through it.
            if d->kind == PD_RECORD and not f->params[0].is_in:
                fatal_at(self->file, f->params[0].pos, "a method on a record takes `in self`: it reads the receiver without copying it, and does not mutate it (57.1)")
            if d->kind == PD_STRUCT and f->params[0].is_in:
                fatal_at(self->file, f->params[0].pos, "a method on a struct takes plain `self`: a struct is a reference (20.1), and there is nothing to avoid copying")
            st: *PsType = self->named_type(d->name, f->params[0].pos)
            f->params[0].type = st
            self->add_local("self", st, True, True)
            if d->kind == PD_RECORD:
                # `in self` reads and does not write (57.1)
                self->locals[self->nlocals - 1].frozen = True
            start = 1
        elif not f->is_smethod:
            fatal_at(self->file, f->pos, "'%s.%s' has no receiver: write `in self` first, or `static def` for a function that needs none", d->name, f->name)
        for i in range(start, f->nparams):
            p: *PsParam = &f->params[i]
            if p->type == None:
                fatal_at(self->file, p->pos, "parameter '%s' needs a type", p->name)
            if p->dflt != None:
                # 44.1: the default is checked HERE, in the scope that WROTE it
                # (module only — one parameter is not in scope for another's
                # default), and evaluated at every CALL, which is what gives
                # `def f(xs=[])` a new list each time instead of Python's one.
                if p->is_varargs:
                    fatal_at(self->file, p->pos, "`*%s` collects what is left, so it cannot also have a default (44.2)", p->name)
                svd: i32 = self->nlocals
                self->nlocals = 0
                self->check_want(p->dflt, self->resolve_type(p->type), self->a->printf("the default of '%s'", p->name))
                self->nlocals = svd
            if p->is_varargs:
                # 44.2: `*xs` is sugar over `List<T>` — inside the function it
                # IS a list, and what the call site does is build one. Nothing
                # new in the type system, which is the point of the sugar.
                if p->type == None or p->type->kind != PT_LIST:
                    fatal_at(self->file, p->pos, "`*%s` needs a list type: `*%s: List<int>` (44.2)", p->name, p->name)
                if i != f->nparams - 1:
                    fatal_at(self->file, p->pos, "`*%s` has to be the last parameter", p->name)
            self->add_local(p->name, self->resolve_type(p->type), True, False)
        self->check_block(f->body)

    private def field_type(self: *PsSema, rt: *PsType, name: const *char, pos: Pos) -> *PsType:
        if rt != None and rt->kind == PT_NAME and strcmp(rt->name, "Error") == 0:
            if strcmp(name, "message") == 0:
                return ps_type(self->a, PT_STR, pos)
            if strcmp(name, "category") == 0:
                # 15.2: the category has a NAME — `e.category == IO` reads like
                # what it means, and the enum is in the prelude so no program
                # has to declare it
                ct9: *PsType = ps_type(self->a, PT_NAME, pos)
                ct9->name = "Category"
                return ct9
            fatal_at(self->file, pos, "an error has 'message' and 'category'")
        if rt == None or rt->kind != PT_NAME or not self->records.has(rt->name):
            fatal_at(self->file, pos, "'.%s' on %s, which has no fields", name, ps_type_str(self->a, rt))
        rd: *PsDecl = self->records.get_or(rt->name, None)
        for i in range(rd->nfields):
            if strcmp(rd->fields[i].name, name) == 0:
                return rd->fields[i].type
        fatal_at(self->file, pos, "'%s' has no field '%s'", rt->name, name)
        return None

    private def find_method(self: *PsSema, rd: *PsDecl, name: const *char) -> *PsFunc:
        for i in range(rd->nmethods):
            if strcmp(rd->methods[i]->name, name) == 0:
                return rd->methods[i]
        return None

    # `Vec(1.0, 2.0)` / `Vec(y=2.0, x=1.0)` — the type-call constructor (54.2).
    # The named form must name every field; P's lowering of the same construct
    # explains why (a partial named form needs a designated initializer, which
    # C89 does not have).
    # `async lambda p: body` becomes an `async def __alam<N>(<caps>, p)` plus a
    # plain lambda `lambda p: __alam<N>(caps..., p)`. The captures are found the
    # way a lambda's always are (19.2) and travel as leading PARAMETERS, which
    # is exactly how the `async:` block does it (78.3).
    private def check_async_lambda(self: *PsSema, e: *PsExpr, lh: *PsType):
        fr: PsLamF = {0}
        fr.base = self->nlocals
        fr.caps.init()
        self->lam_fr.push(fr)
        self->depth += 1
        prevret: *PsType = self->cur_ret
        previn: bool = self->in_async
        self->cur_ret = lh->inner->inner
        self->in_async = True
        for i in range(e->nparams):
            e->params[i].type = lh->params[i]
            self->add_local(e->params[i].name, lh->params[i], True, True)
        prevh: *PsType = self->hint
        self->hint = lh->inner->inner
        bt: *PsType = self->check_expr(e->lhs)
        self->hint = prevh
        if lh->inner->inner != None and lh->inner->inner->kind != PT_VOID:
            self->want(e->lhs, bt, lh->inner->inner, "the body of this async lambda")
        self->cur_ret = prevret
        self->in_async = previn
        self->pop_scope()
        self->depth -= 1
        top: i32 = self->lam_fr.len - 1
        caps: *PsParam = self->lam_fr.data[top].caps.data
        nc: i32 = self->lam_fr.data[top].caps.len
        self->lam_fr.len -= 1

        np: i32 = nc + e->nparams
        ps: *PsParam = self->a->alloc(usize(np + 1) * sizeof(PsParam))
        for i in range(nc):
            ps[i] = caps[i]
        for i in range(e->nparams):
            ps[nc + i] = e->params[i]
        fn: *PsFunc = self->a->alloc(sizeof(PsFunc))
        fn->name = self->a->printf("__alam%d", self->nablk)
        self->nablk += 1
        fn->params = ps
        fn->nparams = np
        fn->ret = lh->inner->inner
        fn->is_async = True
        fn->pos = e->pos
        # the body is `return <the expression>`
        rs: *PsStmt = ps_stmt(self->a, PS_RETURN, e->pos)
        rs->expr = e->lhs
        bl: *PsBlock = self->a->alloc(sizeof(PsBlock))
        bl->stmts = self->a->alloc(sizeof(*bl->stmts))
        bl->stmts[0] = rs
        bl->n = 1
        fn->body = bl
        d: *PsDecl = ps_decl(self->a, PD_FUNC, e->pos)
        d->name = fn->name
        d->func = fn
        self->ablks.push(d)
        self->funcs.put(fn->name, fn)

        # ... and this node becomes the plain lambda that calls it
        args: **PsExpr = self->a->alloc(usize(np + 1) * sizeof(*args))
        for i in range(np):
            nm: *PsExpr = ps_expr(self->a, PE_NAME, e->pos)
            nm->text = ps[i].name
            nm->type = ps[i].type
            args[i] = nm
        callee: *PsExpr = ps_expr(self->a, PE_NAME, e->pos)
        callee->text = fn->name
        call: *PsExpr = ps_expr(self->a, PE_CALL, e->pos)
        call->lhs = callee
        call->args = args
        call->nargs = np
        e->lhs = call
        e->is_async_lam = False
        # checked again as an ORDINARY lambda, so its own capture analysis runs
        # and the call's arguments resolve where they are written
        self->check_lambda_body(e, lh)

    # the ordinary lambda path, factored so the async one can reuse it
    private def check_lambda_body(self: *PsSema, e: *PsExpr, lh: *PsType):
        fr2: PsLamF = {0}
        fr2.base = self->nlocals
        fr2.caps.init()
        self->lam_fr.push(fr2)
        self->depth += 1
        for i in range(e->nparams):
            e->params[i].type = lh->params[i]
            self->add_local(e->params[i].name, lh->params[i], True, True)
        prevh2: *PsType = self->hint
        self->hint = lh->inner
        self->check_expr(e->lhs)
        self->hint = prevh2
        self->pop_scope()
        self->depth -= 1
        tp2: i32 = self->lam_fr.len - 1
        e->caps = self->lam_fr.data[tp2].caps.data
        e->ncaps = self->lam_fr.data[tp2].caps.len
        self->lam_fr.len -= 1

    private def check_ctor(self: *PsSema, e: *PsExpr, rd: *PsDecl) -> *PsType:
        named: bool = False
        positional: bool = False
        for i in range(e->nargs):
            if e->args[i]->kind == PE_DESIG:
                named = True
            else:
                positional = True
        if named and positional:
            fatal_at(self->file, e->pos, "%s(...): mixing named and positional fields", rd->name)
        if positional and e->nargs != rd->nfields:
            fatal_at(self->file, e->pos, "%s(...) takes %d field(s), %d given", rd->name, rd->nfields, e->nargs)
        seen: *bool = calloc(usize(rd->nfields + 1), sizeof(bool))
        defer free(seen)
        for i in range(e->nargs):
            a: *PsExpr = e->args[i]
            slot: i32 = i
            val: *PsExpr = a
            if named:
                slot = -1
                for fi in range(rd->nfields):
                    if strcmp(rd->fields[fi].name, a->text) == 0:
                        slot = fi
                        break
                if slot < 0:
                    fatal_at(self->file, a->pos, "'%s' has no field '%s'", rd->name, a->text)
                if seen[slot]:
                    fatal_at(self->file, a->pos, "'%s' is given twice", a->text)
                val = a->lhs
            seen[slot] = True
            # the FIELD's type is context for the value (54.2), the same way a
            # declaration's is: `UndoGroup([], ...)` says what the empty list holds
            self->check_want(val, rd->fields[slot].type, self->a->printf("field '%s'", rd->fields[slot].name))
            at: *PsType = val->type
            a->type = rd->fields[slot].type
        if named:
            for fi in range(rd->nfields):
                if not seen[fi]:
                    fatal_at(self->file, e->pos, "%s(...): field '%s' is missing (the named form names every field)", rd->name, rd->fields[fi].name)
        return self->named_type(rd->name, e->pos)

    # ---------- statements ----------
    # A block is a SCOPE (64.1): what it declares dies with it, and a name it
    # pinned with `nonlocal` does not.
    # ---------- 104: `enumerate`, `zip` e `reversed` ----------
    #
    # Os três são AÇÚCAR, reescrito para o laço de índice que já funciona — pela
    # mesma razão que `range` e `d.items()` são reconhecidos por FORMA e não são
    # valores: um iterador de verdade precisaria de um objeto com cursor, e o par
    # que `enumerate` rende precisaria da tupla como valor dentro de contêiner.
    # Reescrever aqui custa zero de runtime e dá o mesmo que o Python dá.
    private def sug_name(self: *PsSema, t: const *char, pos: Pos) -> *PsExpr:
        e: *PsExpr = ps_expr(self->a, PE_NAME, pos)
        e->text = t
        return e

    private def sug_int(self: *PsSema, v: i32, pos: Pos) -> *PsExpr:
        e: *PsExpr = ps_expr(self->a, PE_INT, pos)
        e->text = self->a->printf("%d", v)
        return e

    private def sug_call1(self: *PsSema, fn: const *char, a1: *PsExpr, pos: Pos) -> *PsExpr:
        c: *PsExpr = ps_expr(self->a, PE_CALL, pos)
        c->lhs = self->sug_name(fn, pos)
        c->args = self->a->alloc(sizeof(*c->args))
        c->args[0] = a1
        c->nargs = 1
        return c

    private def sug_bin(self: *PsSema, op: i32, l: *PsExpr, r: *PsExpr, pos: Pos) -> *PsExpr:
        e: *PsExpr = ps_expr(self->a, PE_BINARY, pos)
        e->op = op
        e->lhs = l
        e->rhs = r
        return e

    private def sug_index(self: *PsSema, l: *PsExpr, r: *PsExpr, pos: Pos) -> *PsExpr:
        e: *PsExpr = ps_expr(self->a, PE_INDEX, pos)
        e->lhs = l
        e->rhs = r
        return e

    private def sug_bind(self: *PsSema, name: const *char, val: *PsExpr, pos: Pos) -> *PsStmt:
        v: *PsStmt = ps_stmt(self->a, PS_VAR, pos)
        v->name = name
        v->rhs = val
        return v

    # Qual dos três (0 = nenhum): reconhecido pela FORMA da chamada, sem tipos.
    private def sug_kind(self: *PsSema, s: *PsStmt) -> i32:
        if s->kind != PS_FOR or s->iter == None or s->iter->kind != PE_CALL:
            return 0
        f: *PsExpr = s->iter->lhs
        if f == None or f->kind != PE_NAME:
            return 0
        if strcmp(f->text, "enumerate") == 0:
            return 1
        if strcmp(f->text, "zip") == 0:
            return 2
        if strcmp(f->text, "reversed") == 0:
            return 3
        return 0

    # `range` e os próprios açúcares não são VALORES, então não dá para guardá-los
    # num temporário — o que se pode dar aqui é o motivo, no lugar onde a pessoa
    # escreveu, em vez de "função desconhecida" depois da reescrita.
    private def sug_deny(self: *PsSema, a: *PsExpr, outer: const *char):
        if a->kind != PE_CALL or a->lhs == None or a->lhs->kind != PE_NAME:
            return
        w: const *char = a->lhs->text
        if strcmp(w, "range") == 0:
            if strcmp(outer, "zip") == 0:
                fatal_at(self->file, a->pos, "zip() over a range: `for i, x in enumerate(xs)` IS that loop, and it needs no zip")
            fatal_at(self->file, a->pos, "%s() over a range: a range is not a value here — `for i in range(...)` iterates it, and `range(hi - 1, lo - 1, -1)` walks it backwards", outer)
        if strcmp(w, "enumerate") == 0 or strcmp(w, "zip") == 0 or strcmp(w, "reversed") == 0:
            fatal_at(self->file, a->pos, "%s(%s(...)): the two are sugar over the index loop, not iterator objects, so they do not nest — put the inner result in a list first (a list has `reverse`)", outer, w)

    # As amarrações entram como PRIMEIROS statements do corpo do laço, e por
    # isso nascem e morrem no escopo dele, como a variável de laço (64.1).
    private def sug_body(self: *PsSema, s: *PsStmt, names: **char, vals: **PsExpr, n: i32):
        old: i32 = s->body->n if s->body != None else 0
        body: **PsStmt = self->a->alloc(usize(n + old) * sizeof(*body))
        for j in range(n):
            body[j] = self->sug_bind(names[j], vals[j], s->pos)
        for i in range(old):
            body[n + i] = s->body->stmts[i]
        nb: *PsBlock = self->a->alloc(sizeof(PsBlock))
        nb->stmts = body
        nb->n = n + old
        s->body = nb

    # `for k, v in pares:` sobre uma lista de TUPLAS (104). O laço não muda —
    # ele continua andando a lista — e o que a reescrita faz é amarrar os nomes
    # aos slots da tupla, que é o que o Python chama de desempacotar. Vale para
    # `d.items()`, que desde a 98.5 é um valor: uma lista de pares.
    private def sug_unpack(self: *PsSema, s: *PsStmt) -> bool:
        t: *PsType = self->check_expr(s->iter)
        s->iter->sug_done = True
        if t == None or t->kind != PT_LIST or t->inner == None or t->inner->kind != PT_TUPLE:
            return False
        if t->inner->nparams != s->nnames:
            fatal_at(self->file, s->pos, "unpacking a %s takes %d names, found %d", ps_type_str(self->a, t->inner), t->inner->nparams, s->nnames)
        pn: const *char = self->a->printf("__sugp%d", self->counter)
        self->counter += 1
        names: **char = self->a->alloc(usize(s->nnames) * sizeof(*names))
        vals: **PsExpr = self->a->alloc(usize(s->nnames) * sizeof(*vals))
        for j in range(s->nnames):
            names[j] = s->names[j]
            vals[j] = self->sug_index(self->sug_name(pn, s->pos), self->sug_int(j, s->pos), s->pos)
        self->sug_body(s, names, vals, s->nnames)
        s->names = self->a->alloc(sizeof(*s->names))
        s->names[0] = (*char)(pn)
        s->nnames = 1
        return True

    # A mesma reescrita, na COMPREHENSION (104). Ela não tem corpo de statements
    # onde amarrar nomes, então a sema guarda as amarrações no nó — tipadas — e o
    # lowering as emite como os primeiros statements do laço que ele já constrói.
    #
    # Diferença honesta com a forma de statement: aqui o iterável tem de ser um
    # NOME (ou um campo), porque a reescrita o menciona duas vezes — no `len` do
    # limite e no índice do corpo — e não há statement anterior onde guardar um
    # temporário. É a mesma regra do `random.choice`.
    private def sug_comp(self: *PsSema, e: *PsExpr):
        it: *PsExpr = e->rhs
        k: i32 = 0
        if it != None and it->kind == PE_CALL and it->lhs != None and it->lhs->kind == PE_NAME:
            if strcmp(it->lhs->text, "enumerate") == 0:
                k = 1
            elif strcmp(it->lhs->text, "zip") == 0:
                k = 2
            elif strcmp(it->lhs->text, "reversed") == 0:
                k = 3
        if k == 0:
            if e->ncvars > 1:
                # `{v: k for k, v in d.items()}` — desempacotar a tupla, igual
                # ao que o `for` statement faz: o laço continua andando a lista
                ut: *PsType = self->check_expr(e->rhs)
                e->rhs->sug_done = True
                if ut == None or ut->kind != PT_LIST or ut->inner == None or ut->inner->kind != PT_TUPLE:
                    fatal_at(self->file, e->pos, "a comprehension binds ONE name per element; two names come from `enumerate(xs)`, `zip(a, b)` or a list of tuples (`d.items()`), not from %s", ps_type_str(self->a, ut))
                if ut->inner->nparams != e->ncvars:
                    fatal_at(self->file, e->pos, "unpacking a %s takes %d names, found %d", ps_type_str(self->a, ut->inner), ut->inner->nparams, e->ncvars)
                pn0: const *char = self->a->printf("__sugc%d", self->counter)
                self->counter += 1
                un: **char = self->a->alloc(usize(e->ncvars) * sizeof(*un))
                uv: **PsExpr = self->a->alloc(usize(e->ncvars) * sizeof(*uv))
                for j in range(e->ncvars):
                    un[j] = e->cvars[j]
                    uv[j] = self->sug_index(self->sug_name(pn0, e->pos), self->sug_int(j, e->pos), e->pos)
                e->sug_names = un
                e->sug_vals = uv
                e->nsug = e->ncvars
                e->var = pn0
            return
        w: const *char = it->lhs->text
        start: *PsExpr = None
        want: i32 = 1
        if k == 1:
            if it->nargs < 1 or it->nargs > 2:
                fatal_at(self->file, e->pos, "enumerate(xs) or enumerate(xs, start)")
            if it->nargs == 2:
                start = it->args[1]
            want = 2
        elif k == 2:
            if it->nargs < 2:
                fatal_at(self->file, e->pos, "zip(a, b) takes two or more iterables")
            want = it->nargs
        else:
            if it->nargs != 1:
                fatal_at(self->file, e->pos, "reversed(xs) takes one iterable")
        if e->ncvars != want:
            fatal_at(self->file, e->pos, "`for ... in %s(...)` binds %d name(s), found %d", w, want, e->ncvars)
        nit: i32 = 1 if k == 1 else it->nargs
        for j in range(nit):
            a: *PsExpr = it->args[j]
            self->sug_deny(a, w)
            if a->kind not in {PE_NAME, PE_FIELD, PE_INDEX, PE_STR}:
                fatal_at(self->file, e->pos, "%s() in a comprehension takes a plain variable: the rewrite reads it twice (its length and each element) and there is no statement before the comprehension to hold a temporary — put it in a variable first", w)
            at: *PsType = self->check_expr(a)
            if at == None or at->kind not in {PT_LIST, PT_STR, PT_ARRAY}:
                if at != None and at->kind == PT_DICT:
                    fatal_at(self->file, e->pos, "%s() over a dict: a dict is not indexed by position — write %s(d.keys()) or %s(d.values())", w, w, w)
                if at != None and at->kind == PT_SET:
                    fatal_at(self->file, e->pos, "%s() over a set: a set has no order to index — build a list from it first", w)
                fatal_at(self->file, e->pos, "%s() takes a list, a string or an array, found %s", w, ps_type_str(self->a, at))
        if start != None:
            self->check_want(start, ps_type(self->a, PT_INT, e->pos), "the start of enumerate()")
        cnt: *PsExpr = self->sug_call1("len", it->args[0], e->pos)
        if k == 2:
            for j in range(1, it->nargs):
                mn: *PsExpr = ps_expr(self->a, PE_CALL, e->pos)
                mn->lhs = self->sug_name("min", e->pos)
                mn->args = self->a->alloc(2 * sizeof(*mn->args))
                mn->args[0] = cnt
                mn->args[1] = self->sug_call1("len", it->args[j], e->pos)
                mn->nargs = 2
                cnt = mn
        # o nome do laço: no `enumerate` SEM start é o próprio índice que a
        # pessoa escreveu, e aí sobra uma amarração só
        iv: const *char = e->cvars[0] if (k == 1 and start == None) else self->a->printf("__sugc%d", self->counter)
        self->counter += 1
        names: **char = self->a->alloc(usize(want) * sizeof(*names))
        vals: **PsExpr = self->a->alloc(usize(want) * sizeof(*vals))
        ns: i32 = 0
        if k == 1:
            if start != None:
                names[ns] = e->cvars[0]
                vals[ns] = self->sug_bin(TK_PLUS, self->sug_name(iv, e->pos), start, e->pos)
                ns += 1
            names[ns] = e->cvars[1]
            vals[ns] = self->sug_index(it->args[0], self->sug_name(iv, e->pos), e->pos)
            ns += 1
        elif k == 2:
            for j in range(it->nargs):
                names[ns] = e->cvars[j]
                vals[ns] = self->sug_index(it->args[j], self->sug_name(iv, e->pos), e->pos)
                ns += 1
        else:
            back: *PsExpr = self->sug_bin(TK_MINUS, self->sug_bin(TK_MINUS, self->sug_call1("len", it->args[0], e->pos), self->sug_int(1, e->pos), e->pos), self->sug_name(iv, e->pos), e->pos)
            names[ns] = e->cvars[0]
            vals[ns] = self->sug_index(it->args[0], back, e->pos)
            ns += 1
        e->sug_names = names
        e->sug_vals = vals
        e->nsug = ns
        e->var = iv
        e->rhs = self->sug_call1("range", cnt, e->pos)

    # O iterável entra num TEMPORÁRIO antes do laço quando não é já um nome: a
    # reescrita o menciona duas vezes (`len(xs)` e `xs[i]`), e `enumerate(f())`
    # chamaria `f` a cada volta. Isto é puramente sintático — roda antes de
    # qualquer tipo existir — e por isso mora aqui e não na reescrita tipada.
    private def sug_hoist(self: *PsSema, b: *PsBlock):
        extra: i32 = 0
        for i in range(b->n):
            k: i32 = self->sug_kind(b->stmts[i])
            if k == 0:
                continue
            for j in range(b->stmts[i]->iter->nargs):
                a: *PsExpr = b->stmts[i]->iter->args[j]
                self->sug_deny(a, b->stmts[i]->iter->lhs->text)
                if a->kind != PE_NAME:
                    extra += 1
        if extra == 0:
            return
        out: **PsStmt = self->a->alloc(usize(b->n + extra) * sizeof(*out))
        n2: i32 = 0
        for i in range(b->n):
            st: *PsStmt = b->stmts[i]
            if self->sug_kind(st) != 0:
                for j in range(st->iter->nargs):
                    a: *PsExpr = st->iter->args[j]
                    if a->kind == PE_NAME:
                        continue
                    tn: const *char = self->a->printf("__sug%d", self->counter)
                    self->counter += 1
                    out[n2] = self->sug_bind(tn, a, st->pos)
                    n2 += 1
                    st->iter->args[j] = self->sug_name(tn, a->pos)
            out[n2] = st
            n2 += 1
        b->stmts = out
        b->n = n2

    # A reescrita, agora COM tipos: o iterável é um nome em escopo, então dá
    # para dizer o que ele é e recusar com a mensagem certa.
    private def sug_for(self: *PsSema, s: *PsStmt, k: i32):
        it: *PsExpr = s->iter
        w: const *char = it->lhs->text
        start: *PsExpr = None
        if k == 1:
            if it->nargs < 1 or it->nargs > 2:
                fatal_at(self->file, s->pos, "enumerate(xs) or enumerate(xs, start)")
            if s->nnames != 2:
                fatal_at(self->file, s->pos, "`for i, x in enumerate(xs)` takes TWO variables — the index and the element (there is no tuple to bind to one)")
            if it->nargs == 2:
                start = it->args[1]
        elif k == 2:
            if it->nargs < 2:
                fatal_at(self->file, s->pos, "zip(a, b) takes two or more iterables")
            if s->nnames != it->nargs:
                fatal_at(self->file, s->pos, "`for ... in zip(...)`: %d iterables need %d variables, found %d", it->nargs, it->nargs, s->nnames)
        else:
            if it->nargs != 1:
                fatal_at(self->file, s->pos, "reversed(xs) takes one iterable")
            if s->nnames != 1:
                fatal_at(self->file, s->pos, "`for x in reversed(xs)` takes one variable")
    # cada iterável tem de ser INDEXÁVEL: é o que a reescrita usa, e é o que
    # separa uma lista de um dict (que indexa por chave) ou de um set
        for j in range(1 if k == 1 else it->nargs):
            at: *PsType = self->check_expr(it->args[j])
            if at == None or at->kind not in {PT_LIST, PT_STR, PT_ARRAY}:
                if at != None and at->kind == PT_DICT:
                    fatal_at(self->file, s->pos, "%s() over a dict: a dict is not indexed by position — write %s(d.keys()) or %s(d.values())", w, w, w)
                if at != None and at->kind == PT_SET:
                    fatal_at(self->file, s->pos, "%s() over a set: a set has no order to index — build a list from it first", w)
                fatal_at(self->file, s->pos, "%s() takes a list, a string or an array, found %s", w, ps_type_str(self->a, at))
        if start != None:
            self->check_want(start, ps_type(self->a, PT_INT, s->pos), "the start of enumerate()")
        # o número de voltas: len do único iterável, ou o MENOR dos len (o `zip`
        # do Python para no mais curto)
        cnt: *PsExpr = self->sug_call1("len", it->args[0], s->pos)
        if k == 2:
            for j in range(1, it->nargs):
                mn: *PsExpr = ps_expr(self->a, PE_CALL, s->pos)
                mn->lhs = self->sug_name("min", s->pos)
                mn->args = self->a->alloc(2 * sizeof(*mn->args))
                mn->args[0] = cnt
                mn->args[1] = self->sug_call1("len", it->args[j], s->pos)
                mn->nargs = 2
                cnt = mn
        iv: const *char = self->a->printf("__sugi%d", self->counter)
        self->counter += 1
        # as amarrações entram como PRIMEIROS statements do corpo, então elas
        # nascem e morrem no escopo do laço, como a variável de laço (64.1)
        nb: i32 = s->nnames
        sn: **char = self->a->alloc(usize(nb) * sizeof(*sn))
        sv: **PsExpr = self->a->alloc(usize(nb) * sizeof(*sv))
        bn: i32 = 0
        if k == 1:
            ix: *PsExpr = self->sug_name(iv, s->pos)
            if start != None:
                ix = self->sug_bin(TK_PLUS, ix, start, s->pos)
            sn[bn] = s->names[0]
            sv[bn] = ix
            bn += 1
            sn[bn] = s->names[1]
            sv[bn] = self->sug_index(it->args[0], self->sug_name(iv, s->pos), s->pos)
            bn += 1
        elif k == 2:
            for j in range(it->nargs):
                sn[bn] = s->names[j]
                sv[bn] = self->sug_index(it->args[j], self->sug_name(iv, s->pos), s->pos)
                bn += 1
        else:
            # de trás para frente: `xs[len(xs) - 1 - i]`
            back: *PsExpr = self->sug_bin(TK_MINUS, self->sug_bin(TK_MINUS, self->sug_call1("len", it->args[0], s->pos), self->sug_int(1, s->pos), s->pos), self->sug_name(iv, s->pos), s->pos)
            sn[bn] = s->names[0]
            sv[bn] = self->sug_index(it->args[0], back, s->pos)
            bn += 1
        self->sug_body(s, sn, sv, bn)
        s->iter = self->sug_call1("range", cnt, s->pos)
        s->names = self->a->alloc(sizeof(*s->names))
        s->names[0] = iv
        s->nnames = 1

    # 114: este bloco SEMPRE sai? (return, raise, break, continue, ou um `if`
    # em que todos os ramos saem). É o que autoriza estreitar depois de uma
    # guarda — `if x == None: return` e o resto da função já sabe.
    private def blk_exits(self: *PsSema, b: *PsBlock) -> bool:
        if b == None or b->n == 0:
            return False
        last: *PsStmt = b->stmts[b->n - 1]
        if last->kind in {PS_RETURN, PS_RAISE, PS_BREAK, PS_CONTINUE}:
            return True
        if last->kind == PS_IF and last->else_block != None:
            for i in range(last->nconds):
                if not self->blk_exits(last->blocks[i]):
                    return False
            return self->blk_exits(last->else_block)
        return False

    private def check_block(self: *PsSema, b: *PsBlock):
        if b == None:
            return
        self->sug_hoist(b)
        # uma prova de guarda (114) vale até o fim DESTE bloco. O que já estava
        # estreitado ao ENTRAR é de um escopo de fora e continua valendo — sem
        # esta distinção, um `if` aninhado desfazia a prova do bloco que o contém.
        nw0: i32 = self->nlocals
        pre_narrow: *bool = calloc(usize(nw0 + 1), sizeof(bool))
        defer free(pre_narrow)
        for i in range(nw0):
            pre_narrow[i] = self->locals[i].opt_type != None
        self->depth += 1
        for i in range(b->n):
            self->check_stmt(b->stmts[i])
        for i in range(self->nlocals):
            if self->locals[i].opt_type != None and (i >= nw0 or not pre_narrow[i]):
                self->locals[i].type = self->locals[i].opt_type
                self->locals[i].opt_type = None
        self->pop_scope()
        self->depth -= 1

    private def check_stmt(self: *PsSema, s: *PsStmt):
        match s->kind:
            case PS_EXPR:
                self->check_expr(s->expr)
            case PS_VAR:
                vt: *PsType = self->resolve_type(s->type)
                prevh: *PsType = self->hint
                # 114: sem tipo escrito, o CONTEXTO é o do nome que já existe —
                # a 64.1 diz que um nome que já existe é ASSIGNADO, então o tipo
                # dele é quem manda. Sem isto, `f = lambda v: v * 2` num nome de
                # tipo função dizia "não consigo inferir a lambda", que é
                # exatamente a informação que estava ali do lado.
                if vt == None:
                    li9: i32 = self->find_local(s->name)
                    if li9 >= 0:
                        # o tipo DECLARADO, não o estreitado: dentro de um
                        # `while x != None:` o local vale `T`, mas `x = x.next`
                        # atribui um `T?` — e é o próprio caminho que desfaz a
                        # prova logo abaixo
                        vt = self->locals[li9].opt_type if self->locals[li9].opt_type != None else self->locals[li9].type
                    elif self->at_module:
                        # a variável de MÓDULO, e só no topo do próprio módulo:
                        # dentro de uma função o nome é local, e procurar global
                        # ali acharia o de OUTRO módulo (foi o que quebrou três
                        # testes do editor — um local `b` contra um global `b`)
                        gq9: const *char = self->gname_soft(s->name)
                        if gq9 != None and self->globals.has(gq9):
                            vt = self->globals.get_or(gq9, None)
                self->hint = vt
                it: *PsType = self->check_expr(s->rhs) if s->rhs != None else None
                self->hint = prevh
                if vt == None:
                    if it == None:
                        fatal_at(self->file, s->pos, "'%s' has neither a type nor a value", s->name)
                    if it->kind == PT_VOID:
                        fatal_at(self->file, s->pos, "'%s' is assigned the result of something that returns nothing", s->name)
                    vt = it
                elif it != None:
                    self->want(s->rhs, it, vt, self->a->printf("'%s'", s->name))
                # a module variable is reached by its RENAMED name (41.3); a
                # new local keeps the name as written, so the rewrite only
                # happens on the paths that really assign a module variable
                gn: const *char = self->gname_soft(s->name)
                if self->fn_globals.has(s->name):
                    # `global x` inside a function: the assignment goes to the
                    # module variable, never to a new local
                    s->name = gn
                    if not self->globals.has(s->name):
                        fatal_at(self->file, s->pos, "'%s' is not a module variable", s->name)
                    if self->gconst.has(s->name):
                        fatal_at(self->file, s->pos, "'%s' is const", s->name)
                    self->want(s->rhs, it, self->globals.get_or(s->name, None), self->a->printf("'%s'", s->name))
                    s->is_global = True
                    s->type = self->globals.get_or(s->name, None)
                    return
                li: i32 = self->find_local(s->name)
                # A `shared` written from inside a function without `global` is
                # almost never what was meant: the name would become a LOCAL and
                # the synchronized variable would never change — silently. The
                # rule is Python's, but this is the case where obeying it in
                # silence hides a race that is not even a race.
                if li < 0 and not self->at_module and self->shared.has(gn) and not self->fn_globals.has(s->name):
                    fatal_at(self->file, s->pos, "'%s' is a `shared` variable: to write it from here, declare `global %s` — without that this line would make a LOCAL and the shared one would never change (42.1/55.3)", s->name, s->name)
                if li < 0 and self->at_module and self->globals.has(gn):
                    s->name = gn
                    # At the TOP LEVEL a name that is already a module variable
                    # is rebound, not redeclared. Inside a FUNCTION the same
                    # line declares a LOCAL — Python's rule, and 55.3's: writing
                    # a module variable from a function is opted into with
                    # `global`, so that a function cannot change the program's
                    # state by accident.
                    if self->gconst.has(s->name):
                        fatal_at(self->file, s->pos, "'%s' is const", s->name)
                    if s->type != None:
                        fatal_at(self->file, s->pos, "'%s' is already a module variable; drop the type to assign it", s->name)
                    self->want(s->rhs, it, self->globals.get_or(s->name, None), self->a->printf("'%s'", s->name))
                    s->is_global = True
                    s->type = self->globals.get_or(s->name, None)
                    return
                # A top-level declaration is a MODULE variable (Python's
                # rule): the statement still runs where it is written, in
                # order, but the name belongs to the module and every function
                # can see it — which is what makes `global x` mean anything.
                if self->at_module and self->depth <= 1 and li < 0:
                    if vt == None:
                        fatal_at(self->file, s->pos, "'%s' has neither a type nor a value", s->name)
                    if self->preludes.has(s->name):
                        cdiag_at(self->file, s->pos, "shadow-prelude", WD_WARN, "'%s' shadows a name the prelude provides; from here on it is yours (68.3)", s->name)
                    self->globals.put(s->name, vt)
                    if self->root_ns != None:
                        self->root_ns->sym.add(s->name)
                    if s->is_const:
                        self->gconst.add(s->name)
                    s->type = vt
                    s->is_global = True
                    self->mvars.push(s)
                    # ALSO a local of the top level, and deliberately: the name
                    # is the same storage either way, and this is what keeps the
                    # flow analysis — narrowing above all (43.1) — working for
                    # the code that follows it, exactly as it did when a
                    # top-level name was nothing but a local.
                    self->add_local(s->name, vt, True, s->is_const)
                    if s->is_const:
                        self->locals[self->nlocals - 1].frozen = True
                    self->locals[self->nlocals - 1].is_module = True
                    return
                here: i32 = self->find_local_here(s->name)
                if here >= 0 and s->type != None:
                    fatal_at(self->file, s->pos, "'%s' is already declared in this block", s->name)
                if li >= 0 and self->locals[li].is_module:
                    # the same storage as the module variable, so the write goes
                    # there — and the lowering needs to be told (42.2)
                    s->is_global = True
                if li >= 0 and s->type == None:
                    # no annotation: this is a REassignment of whatever `%s`
                    # names right now, and its type may not change (2.3)
                    if self->locals[li].is_const:
                        fatal_at(self->file, s->pos, "'%s' is const", s->name)
                    # 43.1: reassigning inside the branch takes the proof away
                    if self->locals[li].opt_type != None:
                        self->locals[li].type = self->locals[li].opt_type
                        self->locals[li].opt_type = None
                    self->locals[li].any_type = None
                    self->want(s->rhs, it, self->locals[li].type, self->a->printf("'%s'", s->name))
                    self->locals[li].assigned = True
                    s->type = self->locals[li].type
                    s->is_assign = True
                    return
                self->add_local(s->name, vt, s->rhs != None, s->is_const)
                if s->is_const:
                    # 61.3: const freezes DEEP, and this is the OTHER declaration
                    # path — the one an annotated `const xs: List<int> = [...]`
                    # takes. Two paths, one rule.
                    self->locals[self->nlocals - 1].frozen = True
                s->type = vt
            case PS_UNPACK:
                ut: *PsType = self->check_expr(s->rhs)
                if ut == None or ut->kind != PT_TUPLE:
                    fatal_at(self->file, s->pos, "unpacking needs a tuple on the right, found %s", ps_type_str(self->a, ut))
                if s->lhs->nargs != ut->nparams:
                    fatal_at(self->file, s->pos, "unpacking %d name(s) from a tuple of %d", s->lhs->nargs, ut->nparams)
                for i in range(s->lhs->nargs):
                    n: *PsExpr = s->lhs->args[i]
                    if n->kind != PE_NAME:
                        fatal_at(self->file, n->pos, "only plain names can be unpacked into")
                    li3: i32 = self->find_local(n->text)
                    if li3 >= 0:
                        self->want(s->rhs, ut->params[i], self->locals[li3].type, self->a->printf("'%s'", n->text))
                        self->locals[li3].assigned = True
                    else:
                        self->add_local(n->text, ut->params[i], True, False)
                    n->type = ut->params[i]
                s->lhs->type = ut
            case PS_ASSIGN:
                # 61.3: writing THROUGH a const — `xs[0] = v`, `d[k] = v`,
                # `obj.field = v` — is a mutation, and a const forbids those too
                if s->lhs->kind in {PE_INDEX, PE_FIELD, PE_OPTFIELD, PE_OPTINDEX}:
                    self->deny_const_mut(s->lhs, "writing through it")
                if s->lhs->kind == PE_INDEX:
                    tgt9: *PsType = self->check_expr(s->lhs->lhs)
                    if tgt9 != None and tgt9->kind == PT_TUPLE:
                        # 38.2: a tuple is IMMUTABLE, and that is what makes it
                        # safe as a dict key — the hash cannot go stale
                        fatal_at(self->file, s->pos, "a tuple is immutable (38.2): `t[0] = x` is what makes a tuple-key hash go stale, so it is refused — build another tuple")
                if s->lhs->kind == PE_INDEX and s->op == TK_ASSIGN:
                    et3: *PsType = self->check_expr(s->lhs)
                    prevhi: *PsType = self->hint
                    self->hint = et3
                    vt4: *PsType = self->check_expr(s->rhs)
                    self->hint = prevhi
                    self->want(s->rhs, vt4, et3, "the assigned element")
                    return
                lt: *PsType = self->check_expr(s->lhs)
                # what is being ASSIGNED TO is context for the value, exactly as
                # a declaration's type is: `self.lines = []` says what the empty
                # list holds, and so does `d[k] = []`
                prevha: *PsType = self->hint
                self->hint = lt
                rt: *PsType = self->check_expr(s->rhs)
                self->hint = prevha
                if s->lhs->kind == PE_NAME:
                    li2: i32 = self->find_local(s->lhs->text)
                    if li2 >= 0 and self->locals[li2].is_const:
                        fatal_at(self->file, s->pos, "'%s' is const", s->lhs->text)
                if s->op == TK_COALESCE_EQ:
                    # `x ??= e` is `x = x ?? e` (43.2): the default lands only
                    # where the option is empty, and what is stored is the
                    # value — the variable keeps being the option it was
                    cz: *PsExpr = ps_expr(self->a, PE_COALESCE, s->pos)
                    cz->lhs = s->lhs
                    cz->rhs = s->rhs
                    rt = self->check_expr(cz)
                    self->want(s->rhs, rt, lt->inner if lt != None and lt->kind == PT_OPT else lt, "the default of '??='")
                    return
                if s->op != TK_ASSIGN:
                    # `x += e` means `x = x + e`, so it answers to the same rules
                    tmp: *PsExpr = ps_expr(self->a, PE_BINARY, s->pos)
                    tmp->op = ps_assign_binop(s->op)
                    tmp->lhs = s->lhs
                    tmp->rhs = s->rhs
                    if tmp->op == TK_EOF:
                        fatal_at(self->file, s->pos, "this compound assignment is not compiled yet")
                    rt = self->check_binary(tmp)
                self->want(s->rhs, rt, lt, "assignment")
            case PS_RETURN:
                if s->expr == None:
                    if self->cur_ret != None and self->cur_ret->kind != PT_VOID:
                        fatal_at(self->file, s->pos, "'%s' must return %s", self->cur_fn, ps_type_str(self->a, self->cur_ret))
                    return
                # the RETURN TYPE is context (19.2/28.2): a lambda handed back
                # from a function that says what it returns needs no annotation
                # of its own, exactly as an argument does not
                prevh: *PsType = self->hint
                self->hint = self->cur_ret
                et: *PsType = self->check_expr(s->expr)
                self->hint = prevh
                if self->cur_ret == None or self->cur_ret->kind == PT_VOID:
                    fatal_at(self->file, s->pos, "'%s' returns nothing, but a value is returned here", self->cur_fn)
                self->want(s->expr, et, self->cur_ret, "the return value")
            case PS_IF:
                # 99: a `const if` decides HERE, and only the branch taken is
                # checked — that is what lets a branch name what only its own
                # platform has. The condition has already folded its predefines
                # to literals, so what is left to evaluate is literals.
                if s->must_fold:
                    s->if_sel = -2
                    for i in range(s->nconds):
                        self->check_expr(s->conds[i])
                    for i in range(s->nconds):
                        cok9: bool = True
                        cv9: bool = self->const_truth(s->conds[i], ref cok9)
                        if not cok9:
                            fatal_at(self->file, s->conds[i]->pos, "a `const if` needs a condition known at compile time: this one is not (a predefine like `__PLANG_LINUX__`, `is_defined(...)`, or a literal)")
                        if cv9:
                            s->if_sel = i
                            break
                    if s->if_sel == -2 and s->else_block != None:
                        s->if_sel = s->nconds
                    if s->if_sel >= 0 and s->if_sel < s->nconds:
                        self->depth += 1
                        self->check_block(s->blocks[s->if_sel])
                        self->pop_scope()
                        self->depth -= 1
                    elif s->if_sel == s->nconds:
                        self->depth += 1
                        self->check_block(s->else_block)
                        self->pop_scope()
                        self->depth -= 1
                    return
                # A name assigned in EVERY branch (else included) is assigned
                # afterwards; anything less leaves it unassigned, which is the
                # static form of Python's UnboundLocalError that 40.2 bought.
                before: i32 = self->nlocals
                for i in range(s->nconds):
                    ct: *PsType = self->check_expr(s->conds[i])
                    self->want(s->conds[i], ct, ps_type(self->a, PT_BOOL, s->pos), "a condition")
                # `if x != None:` PROVES non-null, and inside the branch `x`
                # IS `T` (43.1) — Kotlin/TypeScript's smart cast. Only for
                # locals, and an assignment inside the branch takes the proof
                # away again (check_stmt PS_VAR/PS_ASSIGN restore it).
                nwi: i32[PS_NARROW_MAX]
                nwe: i32[PS_NARROW_MAX]
                nwb: i32[PS_NARROW_MAX]
                narrowed: i32 = self->narrow_from(s->conds[0], nwi) if s->nconds > 0 else 0
                # 114: `if x == None: ... else:` estreita no ELSE
                nelse: i32 = self->narrow_else(s->conds[0], nwe) if s->nconds == 1 and s->else_block != None else 0
                # A name counts as assigned after the statement only if EVERY
                # path assigns it — including the implicit empty path when
                # there is no `else`. That covers names born inside a branch
                # too: function scope (40.2) keeps them visible afterwards, so
                # they need the same proof as the ones that existed before.
                was: *bool = calloc(usize(before + 1), sizeof(bool))
                defer free(was)
                for i in range(before):
                    was[i] = self->locals[i].assigned
                merged: *bool = calloc(usize(before + 1), sizeof(bool))
                defer free(merged)
                for i in range(before):
                    merged[i] = True
                nbr: i32 = s->nconds + (1 if s->else_block != None else 0)
                for bi in range(nbr):
                    for i in range(before):
                        self->locals[i].assigned = was[i]
                    # 114: cada ramo é provado pela SUA condição — um `elif x
                    # != None:` estreita dentro dele, como o `if` sempre fez
                    nb: i32 = 0
                    if bi < s->nconds:
                        if bi == 0:
                            for q in range(narrowed):
                                nwb[q] = nwi[q]
                            nb = narrowed
                        else:
                            nb = self->narrow_from(s->conds[bi], nwb)
                    else:
                        for q in range(nelse):
                            nwb[q] = nwe[q]
                        nb = nelse
                    nb = self->narrow_push(nwb, nb)
                    self->check_block(s->blocks[bi] if bi < s->nconds else s->else_block)
                    self->narrow_pop(nwb, nb)
                    for i in range(before):
                        merged[i] = merged[i] and self->locals[i].assigned
                # 114: a GUARDA. `if x == None: return` (ou raise/break/
                # continue) e o resto do bloco fala de `x` como `T` — é a forma
                # que toda função com caso ausente tem, e sem isto ela obrigava
                # a aninhar o corpo inteiro num `else`.
                if s->nconds == 1 and s->else_block == None and self->blk_exits(s->blocks[0]):
                    nwg: i32[PS_NARROW_MAX]
                    # aplica e NÃO desfaz: a prova de uma guarda vale para o
                    # resto do bloco, que é a razão de ela existir
                    self->narrow_push(nwg, self->narrow_else(s->conds[0], nwg))
                if s->else_block == None:
                    # the path where no branch runs assigns nothing new
                    for i in range(before):
                        merged[i] = was[i]
                for i in range(before):
                    self->locals[i].assigned = merged[i]
            case PS_WHILE:
                ct2: *PsType = self->check_expr(s->cond)
                if self->at_module and ps_has_await(s->cond):
                    fatal_at(self->file, s->pos, "`await` in the condition of a top-level loop is not compiled yet: the top level is not a state machine, so the wait would be hoisted OUT of the loop. Move it into the body, or into an `async def` (39.4/50.1)")
                self->want(s->cond, ct2, ps_type(self->a, PT_BOOL, s->pos), "a condition")
                # `while x != None:` proves it non-null inside the body, the
                # same way `if` does (43.1) — and it has to, because walking a
                # chain (`cur = cur.next`) is the shape that asks for it. The
                # proof is retested every turn, and an assignment inside the
                # body takes it away, which is the machinery `if` already has.
                nww: i32[PS_NARROW_MAX]
                wn: i32 = self->narrow_push(nww, self->narrow_from(s->cond, nww))
                # the body may run zero times, so nothing it assigns counts after
                snapshot: i32 = self->nlocals
                self->loop_depth += 1
                self->check_block(s->body)
                self->loop_depth -= 1
                self->narrow_pop(nww, wn)
                for i in range(snapshot):
                    pass
            case PS_ASSERT:
                # 46.4: it exists and it is strippable, like Python's `-O`. The
                # style rule that goes with it — an assert never has an effect —
                # is the price of being able to remove them.
                act: *PsType = self->check_expr(s->expr)
                self->want(s->expr, act, ps_type(self->a, PT_BOOL, s->pos), "an assert")
                if s->rhs != None:
                    amt: *PsType = self->check_expr(s->rhs)
                    self->want(s->rhs, amt, ps_type(self->a, PT_STR, s->pos), "the message of an assert")
            case PS_DEFER:
                # 43.4: three ways to clean up — `finally`, `with` and `defer` —
                # and the language keeps all three because they read differently
                # at different distances from the acquisition.
                self->depth += 1
                self->check_block(s->body)
                self->pop_scope()
                self->depth -= 1
            case PS_WITH:
                # `with open(...) as f:` (48.1/19.4): the value is acquired, the
                # block runs, and it is released at the end — including when an
                # error leaves through the middle, because the release lowers to
                # P's `defer`. Only a file so far; the general protocol (what
                # `with` means for a type of your own) is not decided yet.
                self->in_with += 1
                wt9: *PsType = self->check_expr(s->expr)
                self->in_with -= 1
                closeable: bool = wt9 != None and (wt9->kind == PT_FILE or wt9->kind == PT_BUFFER or wt9->kind == PT_CONN or wt9->kind == PT_MAPPING or wt9->kind == PT_WATCHER or wt9->kind == PT_GROUP)
                if not closeable and wt9 != None and wt9->kind == PT_NAME and self->records.has(wt9->name):
                    # the protocol (68.4): `with` takes anything that DECLARES
                    # Closeable — nominal, like every use of a trait — and calls
                    # close() on every way out. file and buffer are simply the
                    # two implementations the runtime ships.
                    closeable = self->timpls.has(self->a->printf("Closeable|%s", wt9->name))
                if not closeable:
                    fatal_at(self->file, s->pos, "`with` takes something that implements Closeable (68.4) — a file, a buffer, or a type with `implement Closeable for T:` — not %s", ps_type_str(self->a, wt9))
                if s->name == None:
                    fatal_at(self->file, s->pos, "`with` needs a name: `with open(path, \"r\") as f:`")
                self->depth += 1
                self->add_local(s->name, wt9, True, True)
                self->check_block(s->body)
                self->pop_scope()
                self->depth -= 1
            case PS_GLOBAL:
                gn2: const *char = self->gname(s->name, s->pos)
                if not self->globals.has(gn2):
                    fatal_at(self->file, s->pos, "'%s' is not a module variable", s->name)
                # the set holds the name AS WRITTEN, because that is what the
                # assignments further down are spelled with
                self->fn_globals.add(s->name)
                s->name = gn2
            case PS_NONLOCAL:
                # the P rule, reused: the next `x = ...` declares x at the
                # FUNCTION's scope, so it survives the block that assigns it
                self->fn_nonlocals.add(s->name)
            case PS_FOR:
                sk: i32 = self->sug_kind(s)
                if sk != 0:
                    # 104: `enumerate`/`zip`/`reversed` viram o laço de índice, e
                    # o que segue é o mesmo caminho do `range`
                    self->sug_for(s, sk)
                # v1 iterates a RANGE. The general protocol of 40.3
                # (`has_next()`/`next()`) needs a mutable cursor, and the only
                # mutable aggregate is `struct`, which is collected — so it
                # arrives with the collector, not before it.
                isrange: bool = s->iter != None and s->iter->kind == PE_CALL and s->iter->lhs != None and s->iter->lhs->kind == PE_NAME and strcmp(s->iter->lhs->text, "range") == 0
                # `for k, v in d.items():` (61.4). Recognised by SHAPE, like
                # `range`, and for the same reason: the pair it yields would
                # need a tuple to exist as a value, and the tuple is half-built
                # (3.2). So the call never becomes a value — the sema replaces
                # it with the dict and marks the loop.
                if s->nnames == 2 and s->iter != None and s->iter->kind == PE_CALL and s->iter->lhs != None and s->iter->lhs->kind == PE_FIELD and strcmp(s->iter->lhs->text, "items") == 0:
                    dht: *PsType = self->check_expr(s->iter->lhs->lhs)
                    if dht != None and dht->kind == PT_DICT:
                        if s->iter->nargs != 0:
                            fatal_at(self->file, s->pos, "items() takes no arguments")
                        # ONE name over `items()` is not an error any more:
                        # since 98.5 `items()` is a real value (a list of pairs),
                        # so `for p in d.items()` iterates the list and `p[0]`
                        # works. Two names keep the shortcut below, which reads
                        # the dict directly and builds no list at all.
                        if s->nnames != 2:
                            pass
                        s->iter = s->iter->lhs->lhs
                        s->iter->type = dht
                        s->is_pairs = True
                        self->depth += 1
                        self->add_local(s->names[0], dht->key, True, False)
                        self->add_local(s->names[1], dht->inner, True, False)
                        self->loop_depth += 1
                        self->check_block(s->body)
                        self->loop_depth -= 1
                        self->pop_scope()
                        self->depth -= 1
                        return
                # 104: `for k, v in pares` sobre uma lista de TUPLAS — o
                # desempacotar do Python, amarrando os slots aos nomes
                if not isrange and s->nnames > 1:
                    if not self->sug_unpack(s):
                        fatal_at(self->file, s->pos, "`for a, b in ...` unpacks a list of tuples (or `d.items()`); over %s the loop binds one name", ps_type_str(self->a, s->iter->type))
                if not isrange:
                    lit4: *PsType = self->check_expr(s->iter)
                    # a value of a type that implements `Iterable` (40.3/D3):
                    # the loop is the protocol, written out — `has_next()` then
                    # `next()`, which is the pair that lets `List<int?>` tell
                    # the end from an element that is None
                    if lit4 != None and lit4->kind == PT_NAME and self->records.has(lit4->name):
                        ird: *PsDecl = self->records.get_or(lit4->name, None)
                        if not self->timpls.has(self->a->printf("Iterable|%s", lit4->name)):
                            fatal_at(self->file, s->pos, "`for x in ...` over %s: the type has to implement `Iterable` (66.2), which is `has_next()` and `next()` (40.3)", ps_type_str(self->a, lit4))
                        if ird->kind != PD_STRUCT:
                            fatal_at(self->file, s->pos, "`for x in ...` needs a struct: the cursor has to advance, and a method on a record cannot mutate its receiver (20.1/57.1)")
                        nx: *PsFunc = self->find_method(ird, "next")
                        if s->nnames != 1:
                            fatal_at(self->file, s->pos, "`for x in xs` takes one variable")
                        self->depth += 1
                        self->add_local(s->names[0], nx->ret, True, False)
                        self->loop_depth += 1
                        self->check_block(s->body)
                        self->loop_depth -= 1
                        self->pop_scope()
                        self->depth -= 1
                        return
                    if lit4 != None and lit4->kind == PT_ARRAY:
                        # `for x in xs` over a fixed array (33.4/60.2)
                        if s->nnames != 1:
                            fatal_at(self->file, s->pos, "`for x in xs` takes one variable")
                        self->depth += 1
                        self->add_local(s->names[0], lit4->inner, True, False)
                        self->loop_depth += 1
                        self->check_block(s->body)
                        self->loop_depth -= 1
                        self->pop_scope()
                        self->depth -= 1
                        return
                    if lit4 != None and lit4->kind == PT_STR:
                        # 72.3: over a string the loop yields CHARACTERS — each
                        # one a string of length 1, which is what `s[i]` gives
                        # and what `len` counts (3.4)
                        if s->nnames != 1:
                            fatal_at(self->file, s->pos, "`for ch in s` takes one variable")
                        self->depth += 1
                        self->add_local(s->names[0], ps_type(self->a, PT_STR, s->pos), True, False)
                        self->loop_depth += 1
                        self->check_block(s->body)
                        self->loop_depth -= 1
                        self->pop_scope()
                        self->depth -= 1
                        return
                    if lit4 != None and lit4->kind == PT_DIRITER:
                        # 140/F4: um nome de cada vez. A única coisa que se faz
                        # com um `scandir` é percorrê-lo, e por isso ele não tem
                        # nome que um programa escreva.
                        if s->nnames != 1:
                            fatal_at(self->file, s->pos, "`for name in os.scandir(d)` takes one variable")
                        self->depth += 1
                        self->add_local(s->names[0], ps_type(self->a, PT_STR, s->pos), True, False)
                        self->loop_depth += 1
                        self->check_block(s->body)
                        self->loop_depth -= 1
                        self->pop_scope()
                        self->depth -= 1
                        return
                    if lit4 == None or lit4->kind not in {PT_LIST, PT_VIEW, PT_BYTES, PT_BUFFER, PT_DICT, PT_SET}:
                        fatal_at(self->file, s->pos, "`for x in ...` takes a range, a string, `bytes`, a List, a View, a Dict, a Set or a type that implements `Iterable` (40.3), not %s", ps_type_str(self->a, lit4))
                    if s->nnames != 1:
                        fatal_at(self->file, s->pos, "`for x in xs` takes one variable")
                    self->depth += 1
                    # iterating a dict gives its KEYS, as Python does; iterating
                    # `bytes` gives NUMBERS, for the same reason `b[i]` is one
                    itel: *PsType = lit4->inner
                    if lit4->kind == PT_DICT:
                        itel = lit4->key
                    elif lit4->kind == PT_BYTES or lit4->kind == PT_BUFFER:
                        itel = ps_type(self->a, PT_INT, s->pos)
                        itel->width = 8
                        itel->uns = True
                    self->add_local(s->names[0], itel, True, False)
                    self->loop_depth += 1
                    self->check_block(s->body)
                    self->loop_depth -= 1
                    self->pop_scope()
                    self->depth -= 1
                    return
                if s->nnames != 1:
                    fatal_at(self->file, s->pos, "`for x in range(...)` takes one variable")
                r: *PsExpr = s->iter
                if r->nargs < 1 or r->nargs > 3:
                    fatal_at(self->file, s->pos, "range() takes 1 to 3 arguments")
                for i in range(r->nargs):
                    rt: *PsType = self->check_expr(r->args[i])
                    self->want(r->args[i], rt, ps_type(self->a, PT_INT, s->pos), "range()")
                # the loop variable belongs to the loop's own scope (64.1)
                self->depth += 1
                self->add_local(s->names[0], ps_type(self->a, PT_INT, s->pos), True, False)
                self->loop_depth += 1
                self->check_block(s->body)
                self->loop_depth -= 1
                self->pop_scope()
                self->depth -= 1
            case PS_RAISE:
                if s->expr == None:
                    fatal_at(self->file, s->pos, "a bare `raise` needs an error in scope — write `raise e` inside a catch")
                et: *PsType = self->check_expr(s->expr)
                if et == None or et->kind != PT_NAME or strcmp(et->name, "Error") != 0:
                    fatal_at(self->file, s->pos, "raise takes an error: `raise error(\"...\")` or `raise e`")
            case PS_TRY:
                self->check_block(s->body)
                if s->catch_block != None:
                    self->depth += 1
                    if s->name != None:
                        er: *PsType = ps_type(self->a, PT_NAME, s->pos)
                        er->name = "Error"
                        self->add_local(s->name, er, True, True)
                    self->check_block(s->catch_block)
                    self->pop_scope()
                    self->depth -= 1
                self->check_block(s->finally_block)
            case PS_MATCH:
                mt2: *PsType = self->check_expr(s->subject)
                if mt2 == None or mt2->kind in {PT_VOID, PT_UNKNOWN}:
                    fatal_at(self->file, s->pos, "match needs a value to match on")
                if s->is_typematch:
                    # `match type(x):` (68.5) — the question `as` enforces,
                    # asked instead: which of the kinds an `any` can hold is
                    # this one? Inside each case the subject IS that type.
                    if mt2->kind != PT_ANY:
                        fatal_at(self->file, s->pos, "`match type(x)` asks what an `any` holds (39.2), found %s", ps_type_str(self->a, mt2))
                    sname: const *char = s->subject->text if s->subject->kind == PE_NAME else None
                    sli: i32 = self->find_local(sname) if sname != None else -1
                    for ci in range(s->ncases):
                        c: *PsCase = s->cases[ci]
                        ct: *PsType = None
                        if not c->is_default:
                            if c->nvals != 1 or c->vals[0]->kind not in {PE_NAME, PE_NONE}:
                                fatal_at(self->file, s->pos, "a `match type` case is ONE type: int, float, bool, str, list, dict or None")
                            ct = ps_kind_of_name(self->a, self->file, c->vals[0], s->pos)
                            if ct == None:
                                fatal_at(self->file, c->vals[0]->pos, "'%s' is not a kind an `any` holds: int, float, bool, str, List, Dict or None", c->vals[0]->text)
                            c->vals[0]->type = ct
                        self->depth += 1
                        if sli >= 0 and ct != None:
                            self->locals[sli].any_type = ct
                        self->check_block(c->body)
                        if sli >= 0:
                            self->locals[sli].any_type = None
                        self->pop_scope()
                        self->depth -= 1
                    return
                ismatch_enum: bool = mt2->kind == PT_NAME and self->enums.has(mt2->name)
                if not ismatch_enum and mt2->kind not in {PT_INT, PT_STR, PT_BOOL}:
                    fatal_at(self->file, s->pos, "match on %s is not compiled yet (int, str, bool and enum work)", ps_type_str(self->a, mt2))
                ndef: i32 = 0
                seen_items: *bool = None
                ed2: *PsDecl = self->enums.get_or(mt2->name, None) if ismatch_enum else None
                if ed2 != None:
                    seen_items = calloc(usize(ed2->nitems + 1), sizeof(bool))
                defer free(seen_items)
                for ci in range(s->ncases):
                    c: *PsCase = s->cases[ci]
                    if c->is_default:
                        ndef += 1
                    for vi in range(c->nvals):
                        vt: *PsType = self->check_expr(c->vals[vi])
                        self->want(c->vals[vi], vt, mt2, "a match case")
                        if ed2 != None and c->vals[vi]->kind == PE_NAME:
                            for k in range(ed2->nitems):
                                if strcmp(ed2->items[k].name, c->vals[vi]->text) == 0:
                                    if seen_items[k]:
                                        fatal_at(self->file, c->vals[vi]->pos, "'%s' appears in two cases", c->vals[vi]->text)
                                    seen_items[k] = True
                    self->depth += 1
                    self->check_block(c->body)
                    self->pop_scope()
                    self->depth -= 1
                if ndef > 1:
                    fatal_at(self->file, s->pos, "match has more than one `case _`")
                # 29.2: over an enum the match is EXHAUSTIVE without `case _`,
                # so a new enumerator turns every match into a compile error
                # instead of a silent fallthrough
                if ed2 != None and ndef == 0:
                    for k in range(ed2->nitems):
                        if not seen_items[k]:
                            fatal_at(self->file, s->pos, "match on '%s' does not cover '%s' (add the case, or `case _`)", mt2->name, ed2->items[k].name)
                if ed2 == None and ndef == 0:
                    fatal_at(self->file, s->pos, "match on %s needs a `case _`: only an enum can be covered completely", ps_type_str(self->a, mt2))
            case PS_BREAK, PS_CONTINUE:
                if self->loop_depth == 0:
                    fatal_at(self->file, s->pos, "'%s' outside a loop", "break" if s->kind == PS_BREAK else "continue")
            case PS_NOGC:
                # 26: the collector stops for the block. The budget is optional
                # and a CONSTANT — a promise the block makes before it starts,
                # so it cannot be a value the block itself computes (26.2).
                if s->expr != None:
                    bt: *PsType = self->check_expr(s->expr)
                    self->want(s->expr, bt, ps_type(self->a, PT_INT, s->pos), "the budget of nogc")
                    if s->expr->kind != PE_INT:
                        fatal_at(self->file, s->pos, "the budget of `nogc(...)` is a constant number of bytes (26.2)")
                # 26.5.1: `await` inside would suspend the task, another task
                # would run in the SAME heap and allocate with the collector
                # off. It is checkable here, so it is refused here.
                self->nogc_depth += 1
                self->check_block(s->body)
                self->nogc_depth -= 1
            case PS_PASS:
                pass
            case _:
                fatal_at(self->file, s->pos, "%s is parsed but not compiled yet", ps_stmt_what(s->kind))

    # ---------- declarations ----------
    private def check_func(self: *PsSema, f: *PsFunc):
        self->in_async = f->is_async
        self->nlocals = 0
        self->depth = 0
        self->fn_gone.init()
        self->fn_nonlocals.init()
        self->fn_globals.init()
        self->cur_ret = self->resolve_type(f->ret)
        self->cur_fn = f->name
        for i in range(f->nparams):
            p: *PsParam = &f->params[i]
            if p->type == None:
                fatal_at(self->file, p->pos, "parameter '%s' needs a type", p->name)
            if p->dflt != None:
                # 44.1: the default is checked HERE, in the scope that WROTE it
                # (module only — one parameter is not in scope for another's
                # default), and evaluated at every CALL, which is what gives
                # `def f(xs=[])` a new list each time instead of Python's one.
                if p->is_varargs:
                    fatal_at(self->file, p->pos, "`*%s` collects what is left, so it cannot also have a default (44.2)", p->name)
                svd: i32 = self->nlocals
                self->nlocals = 0
                self->check_want(p->dflt, self->resolve_type(p->type), self->a->printf("the default of '%s'", p->name))
                self->nlocals = svd
            if p->is_varargs:
                # 44.2: `*xs` is sugar over `List<T>` — inside the function it
                # IS a list, and what the call site does is build one. Nothing
                # new in the type system, which is the point of the sugar.
                if p->type == None or p->type->kind != PT_LIST:
                    fatal_at(self->file, p->pos, "`*%s` needs a list type: `*%s: List<int>` (44.2)", p->name, p->name)
                if i != f->nparams - 1:
                    fatal_at(self->file, p->pos, "`*%s` has to be the last parameter", p->name)
            self->add_local(p->name, self->resolve_type(p->type), True, False)
        self->check_block(f->body)


private def ps_assign_binop(op: i32) -> i32:
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
        case TK_FLOORDIV_EQ:
            return TK_FLOORDIV
        case TK_POW_EQ:
            return TK_POW
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
            return TK_EOF

# names for the diagnostics, so "not compiled yet" always says WHAT
# a plain designator: reading it twice costs nothing and has no side effect
# what another module is allowed to name. `private` at the top level is private
# to the module (44.4) — the same rule P has, and the message says so instead of
# pretending the name is not there.
private def ns_check_visible(ns: *PsNs, name: const *char, file: const *char, pos: Pos, spelled: const *char):
    if ns->priv.has(name):
        fatal_at(file, pos, "'%s' is private to module '%s': it is declared `private` (44.4)", name, spelled)
    if not ns->sym.has(name):
        fatal_at(file, pos, "module '%s' declares no '%s'", spelled, name)

# A type as a piece of an identifier: `List<int>` -> `list_int`. The instance
# name is what the reader sees in the generated C, so it spells the type out
# instead of a number.
def ps_mangle_type(a: *Arena, t: *PsType) -> const *char:
    s: const *char = ps_type_str(a, t)
    b: *char = (*char)(a->alloc(strlen(s) + 1))
    n: usize = 0
    for i in range(usize(0), strlen(s)):
        c: char = s[i]
        if (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_':
            b[n] = c
            n += 1
        elif n > 0 and b[n - 1] != '_':
            b[n] = '_'
            n += 1
    while n > 0 and b[n - 1] == '_':
        n -= 1
    b[n] = '\0'
    return b if n > 0 else "x"

# a type, copied so that resolving it does not write on the original
private def ps_type_clone(a: *Arena, t: *PsType) -> *PsType:
    if t == None:
        return None
    c: *PsType = a->alloc(sizeof(PsType))
    *c = *t
    c->inner = ps_type_clone(a, t->inner)
    c->key = ps_type_clone(a, t->key)
    if t->nparams > 0:
        c->params = a->alloc(usize(t->nparams) * sizeof(*c->params))
        for i in range(t->nparams):
            c->params[i] = ps_type_clone(a, t->params[i])
    return c

# `Self` in a trait signature is the implementing type (66.4) — without it,
# `Comparable` would have to name the type twice and leak it into the signature,
# which is the F-bounded shape Java is stuck with.
private def ps_subst_self(t: *PsType, name: const *char):
    if t == None:
        return
    if t->kind == PT_NAME and t->qual == None and strcmp(t->name, "Self") == 0:
        t->name = name
    ps_subst_self(t->inner, name)
    ps_subst_self(t->key, name)
    for i in range(t->nparams):
        ps_subst_self(t->params[i], name)

# the associated type, substituted by NODE: `List<Item>` with `Item = int` has
# to become `List<int>`, so every site takes back what this returns
private def ps_subst_named(a: *Arena, t: *PsType, name: const *char, conc: *PsType) -> *PsType:
    if t == None:
        return None
    if t->kind == PT_NAME and t->qual == None and strcmp(t->name, name) == 0:
        return ps_type_clone(a, conc)
    t->inner = ps_subst_named(a, t->inner, name, conc)
    t->key = ps_subst_named(a, t->key, name, conc)
    for i in range(t->nparams):
        t->params[i] = ps_subst_named(a, t->params[i], name, conc)
    return t

# is there an `await` anywhere in this expression?
def ps_has_await(e: *PsExpr) -> bool:
    if e == None:
        return False
    if e->kind == PE_AWAIT:
        return True
    if ps_has_await(e->lhs) or ps_has_await(e->rhs) or ps_has_await(e->cond):
        return True
    for i in range(e->nargs):
        if ps_has_await(e->args[i]):
            return True
    return False

# is this element type a collected REFERENCE? (the same question the lowering
# asks to decide whether a list traces its elements)
def opt_is_ref_ps(t: *PsType) -> bool:
    return ps_is_ref_type(t)

# a `match type` case, read off its spelling: the kinds an `any` can hold.
# `list` and `dict` come back with `any` inside, because that is the only thing
# a list INSIDE an any can hold (39.2).
private def ps_kind_of_name(a: *Arena, file: const *char, e: *PsExpr, pos: Pos) -> *PsType:
    if e->kind == PE_NONE:
        return ps_type(a, PT_OPT, pos)      # the empty: what a boxed None is
    n: const *char = e->text
    if strcmp(n, "int") == 0:
        return ps_type(a, PT_INT, pos)
    if strcmp(n, "float") == 0:
        return ps_type(a, PT_FLOAT, pos)
    if strcmp(n, "bool") == 0:
        return ps_type(a, PT_BOOL, pos)
    if strcmp(n, "str") == 0:
        return ps_type(a, PT_STR, pos)
    if ps_renamed_name(file, pos, n, "list", "List"):
        t: *PsType = ps_type(a, PT_LIST, pos)
        t->inner = ps_type(a, PT_ANY, pos)
        return t
    if ps_renamed_name(file, pos, n, "dict", "Dict"):
        t2: *PsType = ps_type(a, PT_DICT, pos)
        t2->key = ps_type(a, PT_STR, pos)
        t2->inner = ps_type(a, PT_ANY, pos)
        return t2
    return None

# does this integer LITERAL fit the width? Checked at compile time (68.2):
# `x: u8 = 300` is a mistake the compiler can see whole, so it says so here.
private def ps_lit_fits(file: const *char, e: *PsExpr, t: *PsType):
    neg: bool = e->kind == PE_UNARY
    lex: const *char = e->lhs->text if neg else e->text
    uv: u64 = strtoull(lex, None, 0)
    w: i32 = t->width
    if t->uns:
        if neg and uv != 0:
            fatal_at(file, e->pos, "-%s does not fit u%d: it is unsigned", lex, w)
        hi: u64 = ~u64(0) if w == 64 else (u64(1) << u64(w)) - 1
        if uv > hi:
            fatal_at(file, e->pos, "%s does not fit u%d", lex, w)
    else:
        hi2: u64 = (u64(1) << u64(w - 1)) - (0 if neg else 1)
        if uv > hi2:
            fatal_at(file, e->pos, "%s%s does not fit i%d", "-" if neg else "", lex, w)

# lossless WIDENING (68.2): signed grows into wider signed, unsigned into wider
# unsigned or into STRICTLY wider signed. Nothing narrows implicitly, and i64
# never becomes u64 by itself — those are the conversions, written by name.
private def ps_int_widens(from2: *PsType, to: *PsType) -> bool:
    if from2 == None or to == None or from2->kind != PT_INT or to->kind != PT_INT:
        return False
    fw: i32 = 64 if from2->width == 0 else from2->width
    tw: i32 = 64 if to->width == 0 else to->width
    if not from2->uns and not to->uns:
        return fw <= tw
    if from2->uns and to->uns:
        return fw <= tw
    if from2->uns and not to->uns:
        return fw < tw
    return False

# The COMMON type of two integer operands (68.2): the wider one, when one
# widens losslessly into the other; nothing otherwise. Mixed signedness of the
# same width has no lossless common ground, so it converts by name — which is
# the rule that keeps `u32 + i32` from silently meaning something.
private def ps_int_common(a: *PsType, b: *PsType) -> *PsType:
    if ps_type_eq(a, b):
        return a
    if ps_int_widens(a, b):
        return b
    if ps_int_widens(b, a):
        return a
    return None

# a bare integer literal (or its negation) used against an exact width: retype
# it in place, with the range checked. It is what makes `x + 1` work on a u8
# without a cast on the 1.
private def ps_adapt_lit(file: const *char, e: *PsExpr, t: *PsType) -> bool:
    if t == None or t->kind != PT_INT or t->width == 0:
        return False
    if e == None:
        return False
    lit: bool = e->kind == PE_INT or (e->kind == PE_UNARY and e->op == TK_MINUS and e->lhs != None and e->lhs->kind == PE_INT)
    if not lit or e->type == None or e->type->kind != PT_INT or e->type->width != 0:
        return False
    ps_lit_fits(file, e, t)
    e->type = t
    return True

# S5: the name a BUILT-IN type answers to when a trait asks who it is.
#
# Conformance is keyed by NAME (`"Reader|File"`), and a built-in has no `name`
# field — its identity is its KIND. This is the one place that translates, and
# the reason it is a function rather than a field is that the answer must be
# the same string the trait registration used, and one function is how you make
# sure of that.
#
# None for a type that cannot implement anything: a number has no methods to
# implement one with.
def ps_builtin_tname(t: *PsType) -> const *char:
    if t == None:
        return None
    match t->kind:
        case PT_FILE:
            return "File"
        case PT_CONN:
            return "Socket"
        case PT_BUFFER:
            return "Buffer"
        case PT_MAPPING:
            return "Mapping"
        case PT_BYTES:
            return "bytes"
        case PT_STR:
            return "str"
        case _:
            return None


# does a value of this type have an IDENTITY? Only a reference does (22.2).
def ps_is_ref_type(t: *PsType) -> bool:
    if t == None:
        return False
    match t->kind:
        case PT_STR, PT_BYTES, PT_LIST, PT_VIEW, PT_DICT, PT_SET, PT_ANY, PT_TASK, PT_WORKER, PT_FILE, PT_MAPPING, PT_DECODER, PT_DIRITER, PT_WATCHER, PT_CONN, PT_PROC, PT_FUNC, PT_DYN, PT_CHAN, PT_GROUP:
            return True
        case PT_NAME:
            return t->is_ref
        case PT_OPT:
            # 113: `T?` de referência É referência nua (9.4) — a mesma correção
            # que o `opt_is_ref` do lowering, no predicado que a sema usa
            return ps_is_ref_type(t->inner)
        case _:
            return False

# does the PROGRAM declare this name? — a decl, one of its enum items, or a
# `from ... import` binding. Used to decide what the prelude steps aside for,
# and the decl that comes back is where the shadow warning points.
private def ps_prog_shadows(m: *PsModule, name: const *char) -> *PsDecl:
    for j in range(m->ndecls):
        d: *PsDecl = m->decls[j]
        # an `implement X for T:` USES the name X, it does not declare it —
        # implementing a prelude trait is the normal case, not a shadow
        if d->kind == PD_IMPL:
            continue
        if d->name != None and strcmp(d->name, name) == 0:
            return d
        for jj in range(d->nitems):
            if strcmp(d->items[jj].name, name) == 0:
                return d
        if d->kind == PD_FROM_IMPORT:
            for ni in range(d->nnames):
                nm: const *char = d->aliases[ni] if d->aliases[ni] != None else d->names[ni]
                if strcmp(nm, name) == 0:
                    return d
    return None

# the length of a `T[N]`, when it is written as a plain number — which is the
# only form a fixed array takes so far
def ps_const_len(e: *PsExpr, ref out: i64) -> bool:
    if e == None or e->kind != PE_INT:
        return False
    out = strtoll(e->text, None, 0)
    return True

# a namespace entry by the spelling used at the import site
private def ns_find(v: *PsNsEnt, n: i32, name: const *char) -> *PsNsEnt:
    for i in range(n):
        if strcmp(v[i].name, name) == 0:
            return v + i
    return None

def zero_ps_pos() -> Pos:
    p: Pos = {0, 0}
    return p

def is_ps_designator(e: *PsExpr) -> bool:
    if e == None:
        return False
    match e->kind:
        case PE_NAME:
            return True
        case PE_FIELD:
            return is_ps_designator(e->lhs)
        case _:
            return False

private def ps_expr_what(k: PsExprKind) -> const *char:
    match k:
        case PE_FSTR:
            return "an f-string"
        case PE_NONE:
            return "None"
        case PE_INDEX:
            return "indexing"
        case PE_SLICE:
            return "slicing"
        case PE_OPTFIELD, PE_OPTINDEX:
            return "optional navigation"
        case PE_COALESCE:
            return "'??'"
        case PE_CAST:
            return "'as'"
        case PE_CONVERT:
            return "a conversion"
        case PE_TUPLE:
            return "a tuple"
        case PE_LIST:
            return "a list literal"
        case PE_DICT:
            return "a dict literal"
        case PE_SET:
            return "a set literal"
        case PE_COMPREHEND:
            return "a comprehension"
        case PE_LAMBDA:
            return "a lambda"
        case PE_WALRUS:
            return "':='"
        case PE_AWAIT:
            return "'await'"
        case PE_SPAWN:
            return "'spawn'"
        case PE_IN:
            return "'in'"
        case PE_IS:
            return "'is'"
        case PE_DESIG:
            return "a named argument"
        case _:
            return "this expression"

private def ps_stmt_what(k: PsStmtKind) -> const *char:
    match k:
        case PS_UNPACK:
            return "tuple unpacking"
        case PS_FOR:
            return "'for'"
        case PS_MATCH:
            return "'match'"
        case PS_RAISE:
            return "'raise'"
        case PS_TRY:
            return "'try'"
        case PS_WITH:
            return "'with'"
        case PS_DEFER:
            return "'defer'"
        case PS_ASSERT:
            return "'assert'"
        case PS_GLOBAL:
            return "'global'"
        case PS_NONLOCAL:
            return "'nonlocal'"
        case PS_UNSAFE:
            return "'unsafe'"
        case PS_NOGC:
            return "'nogc'"
        case _:
            return "this statement"

def ps_type_eq(x: *PsType, y: *PsType) -> bool:
    if x != None and y != None and x->kind == PT_FUNC and y->kind == PT_FUNC and x->wide != y->wide:
        return False        # a bare `def` and a signed one are not the same type
    # 114: `void` e "nada" são a MESMA coisa. Um `def(int, int)` escrito num tipo
    # tem retorno NULO; o valor de uma função sem retorno tem retorno `PT_VOID`.
    # Os dois imprimiam igual ("-> nothing") e comparavam DIFERENTE, e a
    # mensagem ficava `expects def(int, int) -> nothing, found def(int, int) ->
    # nothing` — que não diz nada a ninguém.
    if x == None and y != None and y->kind == PT_VOID:
        return True
    if y == None and x != None and x->kind == PT_VOID:
        return True
    if x == None or y == None:
        return x == y
    if x->kind != y->kind:
        return False
    match x->kind:
        case PT_NAME, PT_DYN:
            return strcmp(x->name, y->name) == 0
        case PT_INT, PT_FLOAT:
            return x->width == y->width and x->uns == y->uns
        case PT_TASK, PT_WORKER:
            return ps_type_eq(x->inner, y->inner)
        case PT_LIST, PT_SET, PT_OPT, PT_ARRAY, PT_SEQ:
            return ps_type_eq(x->inner, y->inner)
        case PT_DICT:
            return ps_type_eq(x->key, y->key) and ps_type_eq(x->inner, y->inner)
        case PT_TUPLE, PT_FUNC:
            if x->nparams != y->nparams:
                return False
            for i in range(x->nparams):
                if not ps_type_eq(x->params[i], y->params[i]):
                    return False
            return ps_type_eq(x->inner, y->inner)
        case _:
            return True

def ps_type_str(a: *Arena, t: *PsType) -> const *char:
    if t == None:
        return "nothing"
    match t->kind:
        case PT_UNKNOWN:
            return "an unknown type"
        case PT_INT:
            if t->width == 0:
                return "int"
            return a->printf("%s%d", "u" if t->uns else "i", t->width)
        case PT_FLOAT:
            return "float" if t->width == 0 else "f32"
        case PT_BOOL:
            return "bool"
        case PT_STR:
            return "str"
        case PT_ANY:
            return "any"
        case PT_VOID:
            return "nothing"
        case PT_NAME:
            return ps_disp(t->name)
        case PT_DYN:
            return a->printf("dyn %s", ps_disp(t->name))
        case PT_TASK:
            return a->printf("Task<%s>", ps_type_str(a, t->inner))
        case PT_WORKER:
            return a->printf("Worker<%s>", ps_type_str(a, t->inner))
        case PT_BYTES:
            return "bytes"
        case PT_MAPPING:
            return "Mapping"
        case PT_DECODER:
            return "Decoder"
        case PT_WATCHER:
            return "Watcher"
        case PT_DIRITER:
            return "a directory walk"
        case PT_VIEW:
            return a->printf("View<%s>", ps_type_str(a, t->inner))
        case PT_SEQ:
            return a->printf("Sequence<%s>", ps_type_str(a, t->inner))
        case PT_FILE:
            return "File"
        case PT_BUFFER:
            return "Buffer"
        case PT_CONN:
            return "Socket"
        case PT_PROC:
            return "a finished process"
        case PT_TIMER:
            return "a timer"
        case PT_CHAN:
            return a->printf("Channel<%s>", ps_type_str(a, t->inner))
        case PT_GROUP:
            return "a task group"
        case PT_LIST:
            return a->printf("List<%s>", ps_type_str(a, t->inner))
        case PT_SET:
            return a->printf("Set<%s>", ps_type_str(a, t->inner))
        case PT_DICT:
            return a->printf("Dict<%s, %s>", ps_type_str(a, t->key), ps_type_str(a, t->inner))
        case PT_ARRAY:
            # the SIZE belongs in the message: `int[3]` and `int[4]` are two
            # different types, and a diagnostic that prints both as `int[]`
            # states the mismatch and then hides it. Sema normalizes the count
            # to a literal (33.4); before that — a parse-time error — there is
            # no number to print and the bare form is the honest one.
            if t->count != None and t->count->kind == PE_INT:
                return a->printf("%s[%s]", ps_type_str(a, t->inner), t->count->text)
            return a->printf("%s[]", ps_type_str(a, t->inner))
        case PT_OPT:
            return a->printf("%s?", ps_type_str(a, t->inner))
        case PT_TUPLE:
            return "a tuple"
        case PT_FUNC:
            # the CANONICAL spelling: it is what a `def` value carries as its
            # descriptor (29.3), so the two sides of a narrowing compare the
            # same text for the same type
            if t->wide:
                return "def"
            fb: const *char = "def("
            for i in range(t->nparams):
                fb = a->printf("%s%s%s", fb, ", " if i != 0 else "", ps_type_str(a, t->params[i]))
            return a->printf("%s) -> %s", fb, ps_type_str(a, t->inner))
    return "?"


# Decorators (28.3), applied before anything is registered.
#
# `@twice def inc(...)` means exactly `inc = twice(inc)`, so that is what this
# writes: the function keeps its body under a private name, and the NAME the
# program uses becomes a module variable holding whatever the decorator gave
# back. Everything after this point sees an ordinary function value (28.1) —
# no new rule in the checker, none in the lowering, and a decorator that wraps
# for real (a `@memo` with a cache of its own) works because a closure is a
# reference and copying it copies the reference (22.5).
#
# The bindings go FIRST in the top-level block: a `def` is visible before its
# line in pscript, so its decorated form has to be too.
private def ps_apply_decorators(a: *Arena, m: *PsModule):
    binds: Vec<*PsStmt>
    binds.init()
    for i in range(m->ndecls):
        d: *PsDecl = m->decls[i]
        for j in range(d->nmethods):
            if d->methods[j] != None and d->methods[j]->ndecorators > 0:
                fatal_at(m->path, d->methods[j]->pos, "a decorator on a method is not compiled yet: it would have to rebind a name that lives on the type (28.3)")
        if d->kind != PD_FUNC or d->func == None or d->func->ndecorators == 0:
            continue
        f: *PsFunc = d->func
        if f->is_async:
            fatal_at(m->path, f->pos, "a decorator on an `async def` is not compiled yet: what the decorator would receive is a function that STARTS a task (35.3)")
        orig: const *char = f->name
        inner: const *char = a->printf("__deco_%s", orig)
        d->name = inner
        f->name = inner
        val: *PsExpr = ps_expr(a, PE_NAME, f->pos)
        val->text = inner
        k: i32 = f->ndecorators - 1
        while k >= 0:
            c: *PsExpr = ps_expr(a, PE_CALL, f->decorators[k]->pos)
            c->lhs = f->decorators[k]
            c->args = a->alloc(sizeof(*c->args))
            c->args[0] = val
            c->nargs = 1
            val = c
            k -= 1
        b: *PsStmt = ps_stmt(a, PS_VAR, f->pos)
        b->name = orig
        b->rhs = val
        binds.push(b)
    if binds.len == 0:
        return
    n: i32 = m->main->n if m->main != None else 0
    st: **PsStmt = a->alloc(usize(binds.len + n) * sizeof(*st))
    for i in range(binds.len):
        st[i] = binds.data[i]
    for i in range(n):
        st[binds.len + i] = m->main->stmts[i]
    if m->main == None:
        m->main = a->alloc(sizeof(PsBlock))
    m->main->stmts = st
    m->main->n = binds.len + n

def ps_sema_run(a: *Arena, m: *PsModule, cpp_cmd: const *char, roots: **char, nroots: i32):
    ps_apply_decorators(a, m)
    s: PsSema = {0}
    s.a = a
    s.file = m->path
    s.m = m
    s.pkgroots = roots
    s.npkgroots = nroots
    s.funcs.init()
    s.records.init()
    s.enums.init()
    s.enumof.init()
    s.globals.init()
    s.gconst.init()
    s.gconst_num.init()
    s.cbudget = CEVAL_BUDGET
    s.cdepth = 0
    s.cfuncs.init()
    s.cconsts.init()
    s.nsof.init()
    s.prefixes.init()
    PS_DISP.init()
    PS_DISP_READY = True
    s.traits.init()
    s.timpls.init()
    s.insts.init()
    s.pending.init()
    s.preludes.init()
    s.shared.init()
    s.lam_fr.init()
    s.mvars.init()
    s.dseen.init()
    s.dtraits.init()
    s.ablks.init()
    s.hdrrecs.init()
    s.dpairs.init()
    s.cpp = cpp_cmd
    # imports FIRST (41.3): every imported module is read, its declarations are
    # RENAMED to unique global names and prepended to this one, and what stays
    # behind is a namespace that says which of those names this module — or any
    # other — is allowed to see, and by which spelling.
    # the system traits come first, as declarations of this module: they are
    # part of the language, so nothing has to be imported to name them (D3)
    ptl: TokenList = ps_lex("<prelude>", PS_PRELUDE, strlen(PS_PRELUDE), a)
    pm: *PsModule = ps_parse(a, "<prelude>", ptl)
    if pm->ndecls > 0:
        pd: **PsDecl = a->alloc(usize(pm->ndecls + m->ndecls) * sizeof(*pd))
        np2: i32 = 0
        for k in range(pm->ndecls):
            # The program's own names WIN over the prelude's — the Python rule
            # for builtins (68.3) — but not in silence: shadowing a default is
            # legal and worth a warning, because the program that declares
            # `TYPE` probably still expects `e.category == TYPE` to mean the
            # category. And the collision drops only WHAT collided: one enum
            # item shadowed must not take its siblings down with it.
            pdc: *PsDecl = pm->decls[k]
            shadow: *PsDecl = ps_prog_shadows(m, pdc->name)
            if shadow != None:
                cdiag_at(m->path, shadow->pos, "shadow-prelude", WD_WARN, "'%s' shadows the prelude's %s of the same name", pdc->name, "enum" if pdc->kind == PD_ENUM else "trait")
                continue
            if pdc->kind == PD_ENUM:
                kept: *PsEnumItem = a->alloc(usize(pdc->nitems) * sizeof(*kept))
                nk: i32 = 0
                for ii in range(pdc->nitems):
                    ish: *PsDecl = ps_prog_shadows(m, pdc->items[ii].name)
                    if ish != None:
                        cdiag_at(m->path, ish->pos, "shadow-prelude", WD_WARN, "'%s' shadows the prelude's %s.%s — the item steps aside; its siblings stay", pdc->items[ii].name, pdc->name, pdc->items[ii].name)
                        continue
                    kept[nk] = pdc->items[ii]
                    nk += 1
                pdc->items = kept
                pdc->nitems = nk
            pd[np2] = pdc
            np2 += 1
            s.preludes.add(pdc->name)
            for ii2 in range(pdc->nitems):
                s.preludes.add(pdc->items[ii2].name)
        for k in range(m->ndecls):
            pd[np2 + k] = m->decls[k]
        m->decls = pd
        m->ndecls = np2 + m->ndecls
    s.root_ns = s.build_ns(m, "", m->name if m->name != None else m->path)
    s.cur_ns = s.root_ns

    # S5: what the RUNTIME already implements. `File` and `Socket` have
    # `read_into` and `write_from` — the branches above give them exactly the
    # signature the prelude's traits declare — so the pair is registered rather
    # than checked: the implementation is the runtime's, and the proof that it
    # matches is that both are written here, in this file, side by side.
    #
    # It is registered even when the program shadows the trait, and that is
    # right: `timpls` is keyed by the trait's NAME, so a program that declares
    # its own `Reader` gets its own key and this one simply never matches.
    s.timpls.add("Reader|File")
    s.timpls.add("Writer|File")
    s.timpls.add("Reader|Socket")
    s.timpls.add("Writer|Socket")

    s.fn_gone.init()
    s.fn_nonlocals.init()
    s.fn_globals.init()

    # every declaration is registered BEFORE any body is checked, so a function
    # may call one defined further down — a module is a set of definitions, not
    # a sequence of them
    for i in range(m->ndecls):
        d: *PsDecl = m->decls[i]
        s.enter_decl(d)
        match d->kind:
            case PD_FUNC:
                if s.funcs.has(d->name):
                    fatal_at(m->path, d->pos, "'%s' is defined twice", d->name)
                s.desugar_sequence(d)
                s.funcs.put(d->name, d->func)
            case PD_RECORD, PD_STRUCT:
                s.records.put(d->name, d)
            case PD_ENUM:
                if s.enums.has(d->name) or s.records.has(d->name):
                    fatal_at(m->path, d->pos, "'%s' is declared twice", d->name)
                s.enums.put(d->name, d)
                for j in range(d->nitems):
                    s.enumof.put(d->items[j].name, d)
            case PD_VAR, PD_SHARED:
                pass   # checked below, in order: an initializer may use a type
            case PD_INCLUDE:
                if d->is_pmod:
                    s.ingest_pmodule(m, d)
                else:
                    s.ingest_header(m, d)
            case PD_TRAIT:
                if s.traits.has(d->name) or s.records.has(d->name) or s.enums.has(d->name):
                    fatal_at(m->path, d->pos, "'%s' is declared twice", d->name)
                s.traits.put(d->name, d)
            case PD_IMPL:
                pass   # checked below, once every type is registered
            case PD_IMPORT, PD_FROM_IMPORT:
                pass   # already handled by build_ns

    # 72.6: the records an imported header declared join this module, so the
    # lowering finds them where it finds every other type. They carry
    # `from_hdr`, and nothing is emitted for them — the declaration stays in
    # the header, which is what keeps one layout instead of two.
    if s.hdrrecs.len > 0:
        nd7: **PsDecl = a->alloc(usize(m->ndecls + i32(s.hdrrecs.len)) * sizeof(*nd7))
        for k7 in range(m->ndecls):
            nd7[k7] = m->decls[k7]
        for k7 in range(i32(s.hdrrecs.len)):
            nd7[m->ndecls + k7] = s.hdrrecs.data[k7]
        m->decls = nd7
        m->ndecls += i32(s.hdrrecs.len)

    for i in range(m->ndecls):
        d: *PsDecl = m->decls[i]
        s.enter_decl(d)
        if d->kind == PD_VAR or d->kind == PD_SHARED:
            if d->kind == PD_SHARED:
                # 42.1: what crosses between heaps is a COPY, so a `shared` holds
                # bytes — a collected value would be a pointer crossing heaps,
                # and that is what 18.1 exists to prevent
                sdt: *PsType = s.resolve_type(d->type) if d->type != None else None
                if sdt != None and sdt->kind == PT_DICT:
                    # the ETS table of 42.1: it lives outside every heap, so the
                    # KEY and the VALUE are what have to fit the copy ladder —
                    # and a string does, because the table keeps bytes of its
                    # own and hands back a fresh one to whoever reads
                    s.copyable(sdt->key, d->pos, "the key of a `shared dict`")
                    s.copyable(sdt->inner, d->pos, "the value of a `shared dict`")
                else:
                    # 42.1: the copy ladder — a `str` is on it, because the
                    # variable keeps BYTES of its own and hands back a fresh
                    # string to whoever reads
                    s.copyable(sdt, d->pos, "a `shared` variable")
            s.nlocals = 0
            s.cur_ret = None
            s.cur_fn = "the module"
            gt: *PsType = s.resolve_type(d->type)
            # the DECLARED type is context for the value, exactly as it is for a
            # local: `d: Dict<str, int> = {}` says what the empty one holds
            s.hint = gt
            it: *PsType = s.check_expr(d->init)
            s.hint = None
            if gt == None:
                gt = it
            elif it != None:
                s.want(d->init, it, gt, self_name(a, d->name))
            d->type = gt
            if d->kind == PD_SHARED:
                if gt != None and gt->kind == PT_DICT:
                    s.copyable(gt->key, d->pos, "the key of a `shared dict`")
                    s.copyable(gt->inner, d->pos, "the value of a `shared dict`")
                    if d->init != None and not (d->init->kind == PE_DICT and d->init->nargs == 0):
                        fatal_at(m->path, d->pos, "a `shared dict` starts empty: it lives outside every heap, so there is nothing yet to copy into it (42.1)")
                else:
                    s.copyable(gt, d->pos, "a `shared` variable")
                s.shared.add(d->name)
            s.globals.put(d->name, gt)
            if d->is_const:
                s.gconst.add(d->name)
                # the value, when it is one a size can be written with
                if d->init != None and d->init->kind == PE_INT:
                    s.gconst_num.put(d->name, strtoll(d->init->text, None, 0))

    for i in range(m->ndecls):
        d: *PsDecl = m->decls[i]
        s.enter_decl(d)
        if d->kind == PD_RECORD or d->kind == PD_STRUCT:
            for j in range(d->nfields):
                d->fields[j].type = s.resolve_type(d->fields[j].type)
            # only a `record` is pure bytes (52.1/58.2); a `struct` is the
            # collected reference type (20.1) and its fields hold anything
            if d->kind == PD_RECORD:
                s.check_record_bytes(d)

    # Traits (66/67) before any body: an `implement ... for` block adds methods
    # to the type, and a body checked after that resolves calls to them the same
    # way it resolves the ones written inside the record.
    for i in range(m->ndecls):
        if m->decls[i]->kind == PD_IMPL:
            s.check_impl(m->decls[i])
    for i in range(m->ndecls):
        d: *PsDecl = m->decls[i]
        if (d->kind == PD_RECORD or d->kind == PD_STRUCT) and d->nimplements > 0:
            s.check_implements(d)

    # Every SIGNATURE is resolved here, before anything calls it. Naming a type
    # from another module leaves a qualifier on the node (41.3), and resolving
    # is what strips it and renames it to the global everyone knows — so a call
    # checked before this compared `Vec2` against `lib_geom.Vec2` and refused a
    # value of the very type it asked for. It used to happen as a side effect of
    # checking the BODY, which is far too late: the top level runs first (39.4).
    # Bodies still wait for the pass below; only the signatures move.
    for i in range(m->ndecls):
        dm: *PsDecl = m->decls[i]
        s.enter_decl(dm)
        if dm->kind == PD_FUNC and dm->func != None and dm->func->ntparams == 0:
            s.resolve_sig(dm->func)
        if dm->kind != PD_RECORD and dm->kind != PD_STRUCT:
            continue
        for j in range(dm->nmethods):
            s.resolve_sig(dm->methods[j])

    # The top-level statements ARE the program (39.4), and they are checked
    # BEFORE the function bodies for one reason: a declaration among them is a
    # module variable, and a function body has to be able to see every one of
    # them — including the ones written further down, which is what Python does
    # and what `global x` inside a function needs to be true.
    s.cur_ns = s.root_ns
    s.file = m->path
    s.nlocals = 0
    s.cur_ret = None
    s.cur_fn = "the module"
    s.at_module = True
    s.check_block(m->main)
    s.at_module = False

    for i in range(m->ndecls):
        s.enter_decl(m->decls[i])
        d2: *PsDecl = m->decls[i]
        if d2->kind == PD_RECORD or d2->kind == PD_STRUCT:
            for j in range(d2->nmethods):
                s.enter_func(d2, d2->methods[j])
                s.check_method(d2, d2->methods[j])
        # a generic is a TEMPLATE: what gets checked is each instance, where
        # the type parameter is a real type (66.3)
        #
        # 65.10: e um `const def` também não é verificado aqui, pela mesma razão
        # com outro nome — o corpo dele não é código que corre, é uma receita
        # que o AVALIADOR percorre. Verificá-lo como função normal dobrava a sua
        # própria recursão a meio do caminho: `fib(n - 1)` dentro do `fib` é uma
        # chamada a um `const def`, e a dobra disparava com o `n` ainda sem
        # valor nenhum. Quem confere um `const def` é a chamada que o usa, e o
        # que ele não sabe fazer sai com a posição e o nome.
        if d2->kind == PD_FUNC and d2->func->ntparams == 0 and not d2->func->is_ceval:
            s.check_func(d2->func)

    # one file-scope variable per module variable the top level declared: the
    # ASSIGNMENT stays where it was written, so the order the program runs in
    # does not change
    if s.mvars.len > 0:
        nd3: **PsDecl = a->alloc(usize(m->ndecls + s.mvars.len) * sizeof(*nd3))
        for k in range(m->ndecls):
            nd3[k] = m->decls[k]
        for k in range(s.mvars.len):
            mv: *PsStmt = s.mvars.data[k]
            vd: *PsDecl = ps_decl(a, PD_VAR, mv->pos)
            vd->name = mv->name
            vd->src_name = mv->name
            vd->type = mv->type
            vd->is_const = mv->is_const
            vd->ns = s.root_ns
            nd3[m->ndecls + k] = vd
        m->decls = nd3
        m->ndecls = m->ndecls + s.mvars.len

    # Generic instances, checked last and until the list stops growing: an
    # instance is an ordinary function, and checking it may ask for another one.
    # They are then appended to the module as plain declarations, so the
    # lowering never learns what a generic is.
    made: Vec<*PsFunc>
    made.init()
    pi: i32 = 0
    while pi < s.pending.len:
        inst: *PsFunc = s.pending.data[pi]
        pi += 1
        made.push(inst)
        s.cur_ns = inst->ns if inst->ns != None else s.root_ns
        s.file = s.cur_ns->m->path
        s.check_func(inst)
    if made.len > 0:
        nd2: **PsDecl = a->alloc(usize(m->ndecls + made.len) * sizeof(*nd2))
        for k in range(m->ndecls):
            nd2[k] = m->decls[k]
        for k in range(made.len):
            fd2: *PsDecl = ps_decl(a, PD_FUNC, made.data[k]->pos)
            fd2->name = made.data[k]->name
            fd2->src_name = made.data[k]->name
            fd2->func = made.data[k]
            fd2->ns = made.data[k]->ns
            nd2[m->ndecls + k] = fd2
        m->decls = nd2
        m->ndecls = m->ndecls + made.len

    # 78.3: the functions the `async:` blocks became. They join the module HERE
    # and not earlier, because their bodies were checked as the blocks were
    # met — in the scope that wrote them, which is what makes the capture by
    # value mean anything.
    if s.ablks.len > 0:
        na8: **PsDecl = a->alloc(usize(m->ndecls + i32(s.ablks.len)) * sizeof(*na8))
        for k8 in range(m->ndecls):
            na8[k8] = m->decls[k8]
        for k8 in range(i32(s.ablks.len)):
            na8[m->ndecls + k8] = s.ablks.data[k8]
        m->decls = na8
        m->ndecls += i32(s.ablks.len)

    # published last: an instance's body can be the first place a `dyn` appears
    m->dyns = s.dpairs.data
    m->ndyns = s.dpairs.len
    m->dtraits = s.dtraits.data
    m->ndtraits = s.dtraits.len

private def self_name(a: *Arena, n: const *char) -> const *char:
    return a->printf("'%s'", n)
