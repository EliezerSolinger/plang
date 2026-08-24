# ps_parser.ph — pscript's parser: tokens -> PsModule.
import "ps_ast.ph"
import "ps_lexer.ph"

def ps_parse(a: *Arena, file: const *char, tl: TokenList) -> *PsModule

# `i8`…`u32`, `f32`: the exact-width spellings (68.2); 0 = not one of them
def ps_width_name(n: const *char) -> i32

# 139: was this name written in the OLD spelling? Answers True for either one,
# and warns on the old — which is what makes the two coexist for exactly one
# commit (139.1). One implementation, because the parser is not the only place
# that reads a type off its name: `match type(x): case List:` does too.
def ps_renamed_name(file: const *char, pos: Pos, written: const *char, old: const *char, new_: const *char) -> bool

# a template file read as an f-string (63.2): the bytes come in as a string
# LITERAL spelling, and what comes back is the same tree `f"..."` would give
def ps_template(a: *Arena, file: const *char, lexeme: const *char, pos: Pos) -> *PsExpr
# The same template, with the values coming from a dict literal instead of the
# scope (75.2): `keys[i]` is what a hole may ask for and `vals[i]` is what gets
# spliced there. `used[i]` comes back True when some hole asked for that key,
# so the caller can complain about the ones nobody used.
def ps_template_dict(a: *Arena, file: const *char, lexeme: const *char, pos: Pos, keys: **char, vals: **PsExpr, used: *bool, n: i32) -> *PsExpr
