# ps_lower.ph — pscript's tree becomes P's tree (49.1).
import "ps_ast.ph"

# `runtime_dir` is where psrt.ph lives, as written on the command line; the
# emitted import is expressed relative to the .psc so the generated C survives
# both being moved and --out-dir mirroring the source tree.
def tuple_is_pure(t: *PsType) -> bool
def ps_lower(a: *Arena, m: *PsModule, runtime_dir: const *char) -> *Module
def ps_lower_config(strip_asserts: bool)
