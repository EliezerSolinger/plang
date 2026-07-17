# vecs.ph — Vec<T> instances over AST nodes, centralized (neutral).
# The `declare`s here make the types/prototypes available to whoever imports;
# the bodies (`implement`) live in vecs.p (one per binary). This decouples:
# the C frontend and the backends use these Vecs without depending on P's parser.
import "ast.ph"
import "../stl/vec.ph"

declare Vec<*Expr>
declare Vec<*Stmt>
declare Vec<*Block>
declare Vec<*Decl>
declare Vec<*Type>
declare Vec<*Func>
declare Vec<*MatchCase>
declare Vec<*char>
declare Vec<Param>
declare Vec<Field>
declare Vec<EnumItem>
