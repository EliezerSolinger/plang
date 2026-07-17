#pragma once

#include <stdint.h>

#include "plang.h"
#include "ast.h"

typedef struct Backend Backend;

struct Backend {
    const char *name;
    const char *out_ext;
    const char *hdr_ext;
};

const Backend *backend_find(const char *name);

const Backend *backend_default(void);

void backend_emit(const Backend *be, Module *m, StrBuf *out);

void emit_module_c(Module *m, StrBuf *out);

void emit_module_qbe(Module *m, StrBuf *out);

void backend_c_config(int std89, int32_t i64_mode);
