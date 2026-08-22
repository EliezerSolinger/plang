#pragma once

#include <stdint.h>

#include "plang.h"
#include "ast.h"

typedef struct Backend Backend;

struct Backend {
    const char *name;
    const char *out_ext;
    const char *hdr_ext;
    int pre_sema;
    uint64_t accepts_expr;
    uint64_t accepts_stmt;
};

const Backend *backend_find(const char *name);

const Backend *backend_default(void);

void backend_emit(const Backend *be, Module *m, StrBuf *out);

void emit_module_c(Module *m, StrBuf *out);

void emit_module_qbe(Module *m, StrBuf *out);

void emit_module_p(Module *m, StrBuf *out);

void backend_verify(const Backend *be, Module *m);

void backend_c_config(int std89, int32_t i64_mode);
