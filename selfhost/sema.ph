# sema.ph — stage 5 of the pipeline: semantic analysis.
# Resolves casts T(x), method sugar p.m() -> Struct_m(&p),
# fixes ./->, registers symbols and loads imported modules (.ph).
import "plang.ph"
import "ast.ph"

# Global compiler context: arena + cache of parsed modules.
struct Cc:
    arena: Arena
    mods: **Module
    nmods: i32
    cmods: i32
    defines: **char      # consts injected by the driver (-D NAME=VALUE)
    ndefines: i32
    backend_name: const *char   # active backend ("c"/"qbe") for __PLANG_BACKEND__
    std_version: i32     # target of the C backend: 99 (default) or 89 (--std=c89)
    cpp: const *char     # C compiler used to preprocess `include <h>` headers
                         #   (--cpp flag / PLANGC_CPP env; default "cc")

# Reads, decodes, lexes and parses a file (with cache by path).
def cc_load_module(cc: *Cc, path: const *char) -> *Module

# Runs sema on the module (resolving local .ph imports recursively).
# Mutates the AST: rewrites casts, method calls and ./-> operators.
def sema_run(cc: *Cc, m: *Module)
