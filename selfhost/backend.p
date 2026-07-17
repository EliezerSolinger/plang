# backend.p — backend registration and dispatch (implements backend.ph)
import <string.h>
import "backend.ph"

# sentinel: name == None ends the table
backends: Backend[] = {{"c", "c", "h"}, {"qbe", "ssa", None}, {None, None, None}}

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
    if strcmp(be->name, "c") == 0:
        emit_module_c(m, out)
        return
    if strcmp(be->name, "qbe") == 0:
        emit_module_qbe(m, out)
        return
    fatal("backend '%s' has no registered emitter", be->name)
