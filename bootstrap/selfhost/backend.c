#include <stdint.h>
#include <string.h>

#include <string.h>
#include "backend.h"

const uint64_t P_EXPRS = (1 << EX_IDENT) | (1 << EX_NUMBER) | (1 << EX_STRING) | (1 << EX_CHARLIT) | (1 << EX_TRUE) | (1 << EX_FALSE) | (1 << EX_NONE) | (1 << EX_UNARY) | (1 << EX_BINARY) | (1 << EX_TERNARY) | (1 << EX_CALL) | (1 << EX_INDEX) | (1 << EX_FIELD) | (1 << EX_CAST) | (1 << EX_INITLIST) | (1 << EX_TYPEREF) | (1 << EX_DESIG) | (1 << EX_ASSIGN) | (1 << EX_VAARG) | (1 << EX_STMTEXPR) | (1 << EX_WITHSELF) | (1 << EX_WALRUS) | (1 << EX_IN) | (1 << EX_FSTRING) | (1 << EX_LAMBDA);

const uint64_t P_STMTS = (1 << ST_VAR) | (1 << ST_ASSIGN) | (1 << ST_EXPR) | (1 << ST_RETURN) | (1 << ST_IF) | (1 << ST_WHILE) | (1 << ST_DO) | (1 << ST_FOR) | (1 << ST_MATCH) | (1 << ST_BREAK) | (1 << ST_CONTINUE) | (1 << ST_GOTO) | (1 << ST_LABEL) | (1 << ST_DEFER) | (1 << ST_WITH) | (1 << ST_PASS) | (1 << ST_GLOBAL) | (1 << ST_NONLOCAL) | (1 << ST_BLOCK);

Backend backends[4] = {{"c", "c", "h", 0, 0, 0}, {"qbe", "ssa", NULL, 0, 0, 0}, {"p", "p", "ph", 1, P_EXPRS, P_STMTS}, {NULL, NULL, NULL, 0, 0, 0}};

const Backend *backend_find(const char *name) {
    int i = 0;
    while (backends[i].name != NULL) {
        if (strcmp(backends[i].name, name) == 0) {
            return &backends[i];
        }
        i += 1;
    }
    return NULL;
}

const Backend *backend_default(void) {
    return &backends[0];
}

void backend_emit(const Backend *be, Module *m, StrBuf *out) {
    backend_verify(be, m);
    if (strcmp(be->name, "c") == 0) {
        emit_module_c(m, out);
        return;
    }
    if (strcmp(be->name, "qbe") == 0) {
        emit_module_qbe(m, out);
        return;
    }
    if (strcmp(be->name, "p") == 0) {
        emit_module_p(m, out);
        return;
    }
    fatal("backend '%s' has no registered emitter", be->name);
}
