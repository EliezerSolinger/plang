# ps_sema.ph — pscript's semantic analysis: types, names, flow.
import "ps_ast.ph"

# Annotates the tree in place (every expression gets its `type`) and rejects
# what the language forbids. Runs before the lowering, so ps_lower can trust
# that what it walks type-checks.
def ps_sema_run(a: *Arena, m: *PsModule, cpp_cmd: const *char)

# the resolved type of an expression, valid after ps_sema_run
def ps_type_str(a: *Arena, t: *PsType) -> const *char

# the name AS THE PROGRAM WROTE IT: a module rename (41.3) is a compiler
# detail, and a message — or a derived repr (44.3) — has to say it back
def ps_disp(name: const *char) -> const *char

# the typed views over a shared buffer (18.3): the element size a view method
# names, and the element type that goes with it
def ps_view_esize(name: const *char) -> i32
def ps_view_elem(a: *Arena, name: const *char, pos: Pos) -> *PsType
def zero_ps_pos() -> Pos
def is_ps_designator(e: *PsExpr) -> bool
def ps_type_eq(x: *PsType, y: *PsType) -> bool

# the length of a `T[N]` when it is a plain number — which is the only form a
# fixed array takes, and what lets pack unroll one (59.2)
def ps_const_len(e: *PsExpr, ref out: i64) -> bool
