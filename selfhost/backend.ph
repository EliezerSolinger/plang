# backend.ph — stage 6 of the pipeline: code generation interface.
#
# The AST annotated by sema is the contract between the front-end and the backends.
# To add a new target (QBE, LLVM IR, ...):
#   1. create backend_<target>.p with a function emit_module_<target>(m, out)
#   2. register it in the backends[] table and in the backend_emit dispatch (backend.p)
#   3. select it with `plangc --backend <target>`
import "plang.ph"
import "ast.ph"

struct Backend:
    name: const *char     # name used in --backend
    out_ext: const *char  # extension of the generated file for .p (e.g. "c")
    hdr_ext: const *char  # extension for .ph (e.g. "h"); None if not applicable

def backend_find(name: const *char) -> const *Backend
def backend_default() -> const *Backend

# dispatches to the chosen backend's emitter
def backend_emit(be: const *Backend, m: *Module, out: *StrBuf)

# available emitters
def emit_module_c(m: *Module, out: *StrBuf)
def emit_module_qbe(m: *Module, out: *StrBuf)

# --std=c89 (C backend only): strict C89. i64_mode: policy for 64 bits —
# 0 = error (default), 1 = --i64-downgrade (64->32), 2 = --i64-longlong
# (long long/__int64 extension of old compilers).
def backend_c_config(std89: bool, i64_mode: i32)
