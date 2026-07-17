#include <string.h>
#include "backend.h"

Backend backends[] = {{"c", "c", "h"}, {"qbe", "ssa", NULL}, {NULL, NULL, NULL}};

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
    if (strcmp(be->name, "c") == 0) {
        emit_module_c(m, out);
        return;
    }
    if (strcmp(be->name, "qbe") == 0) {
        emit_module_qbe(m, out);
        return;
    }
    fatal("backend '%s' has no registered emitter", be->name);
}
