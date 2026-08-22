# backend.p — backend registration and dispatch (implements backend.ph)
include <string.h>
import "backend.ph"

# What P can SPELL. Everything else in the AST is reachable only from the C
# surface or from a sema lowering, and `backend_verify` refuses it rather than
# letting backend_p guess.
#
# Deliberately absent from the expressions: EX_INCDEC (`i++` — P writes
# `i += 1`, with no expression form), EX_COMMA (P sequences inside an expression
# with `({ a; b })` instead), EX_COMPOUND (`(T){...}`), EX_GENERIC (`_Generic`).
# Absent from the statements: ST_CFOR (C's three-part for), ST_SWITCH/ST_CASE
# (P has `match`, which always breaks — fallthrough is not expressible),
# ST_BLOCK (a bare `{ ... }`), ST_CPROTO (block-scope function declaration).
P_EXPRS: const u64 = ((1 << EX_IDENT) | (1 << EX_NUMBER) | (1 << EX_STRING)
                      | (1 << EX_CHARLIT) | (1 << EX_TRUE) | (1 << EX_FALSE)
                      | (1 << EX_NONE) | (1 << EX_UNARY) | (1 << EX_BINARY)
                      | (1 << EX_TERNARY) | (1 << EX_CALL) | (1 << EX_INDEX)
                      | (1 << EX_FIELD) | (1 << EX_CAST) | (1 << EX_INITLIST)
                      | (1 << EX_TYPEREF) | (1 << EX_DESIG) | (1 << EX_ASSIGN)
                      | (1 << EX_VAARG) | (1 << EX_STMTEXPR) | (1 << EX_WITHSELF)
                      | (1 << EX_WALRUS) | (1 << EX_IN) | (1 << EX_FSTRING)
                      | (1 << EX_LAMBDA))
P_STMTS: const u64 = ((1 << ST_VAR) | (1 << ST_ASSIGN) | (1 << ST_EXPR)
                      | (1 << ST_RETURN) | (1 << ST_IF) | (1 << ST_WHILE)
                      | (1 << ST_DO) | (1 << ST_FOR) | (1 << ST_MATCH)
                      | (1 << ST_BREAK) | (1 << ST_CONTINUE) | (1 << ST_GOTO)
                      | (1 << ST_LABEL) | (1 << ST_DEFER) | (1 << ST_WITH)
                      | (1 << ST_PASS) | (1 << ST_GLOBAL) | (1 << ST_NONLOCAL)
                      | (1 << ST_BLOCK))

# sentinel: name == None ends the table. Masks of 0 mean "accepts everything" —
# that is the code generators, whose input is the LOWERED AST by design.
backends: Backend[] = {{"c", "c", "h", False, 0, 0},
                       {"qbe", "ssa", None, False, 0, 0},
                       {"p", "p", "ph", True, P_EXPRS, P_STMTS},
                       {None, None, None, False, 0, 0}}

def backend_find(name: const *char) -> const *Backend:
    i = 0
    while backends[i].name != None:
        if strcmp(backends[i].name, name) == 0:
            return &backends[i]
        i += 1
    return None

def backend_default() -> const *Backend:
    return &backends[0]

def backend_emit(be: const *Backend, m: *Module, out: *StrBuf):
    backend_verify(be, m)
    if be->name == "c":
        emit_module_c(m, out)
        return
    if be->name == "qbe":
        emit_module_qbe(m, out)
        return
    if be->name == "p":
        emit_module_p(m, out)
        return
    fatal("backend '%s' has no registered emitter", be->name)
