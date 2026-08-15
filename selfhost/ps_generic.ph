# ps_generic.ph — monomorphization for pscript's generic functions (66.3).
import "ps_ast.ph"

# a copy of `f` with its type parameter replaced by `conc`, named `iname`
def ps_instantiate(a: *Arena, f: *PsFunc, conc: *PsType, iname: const *char) -> *PsFunc

# the type the parameter stands for, read off one (declared, actual) pair
def ps_infer(pt: *PsType, at: *PsType, name: const *char) -> *PsType

# does a declared type mention the parameter?
def ps_mentions(t: *PsType, name: const *char) -> bool

# a deep copy of an expression, standing alone. The default of a parameter is
# evaluated ONCE PER CALL (44.1), so each call site gets its OWN tree to type
# and to lower — sharing one would make two call sites write over each other.
def ps_copy_expr(a: *Arena, e: *PsExpr) -> *PsExpr
