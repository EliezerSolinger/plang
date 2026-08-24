# vecs.p — bodies of the AST's Vec<T> instances (one implement per binary).
import "vecs.ph"
import <stl/set.ph>
import <stl/map.ph>

# `StrSet` lives here and not in `sema.p` for the same reason the Vecs do: BOTH
# front ends use it, and whoever links only one of them should not have to bring
# the other. The editor links `cfront.p` to paint C, and `sema.p` is 7 332 lines
# it has no use for.
implement StrSet
declare StrMap<*Type>
implement StrMap<*Type>
declare StrMap<i64>
implement StrMap<i64>

implement Vec<*Expr>
implement Vec<*Stmt>
implement Vec<*Block>
implement Vec<*Decl>
implement Vec<*Type>
implement Vec<*Func>
implement Vec<*MatchCase>
implement Vec<*char>
implement Vec<Param>
implement Vec<Field>
implement Vec<EnumItem>
