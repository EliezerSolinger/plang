# ps_parser.ph — pscript's parser: tokens -> PsModule.
import "ps_ast.ph"
import "ps_lexer.ph"

def ps_parse(a: *Arena, file: const *char, tl: TokenList) -> *PsModule

# `i8`…`u32`, `f32`: the exact-width spellings (68.2); 0 = not one of them
def ps_width_name(n: const *char) -> i32

# a template file read as an f-string (63.2): the bytes come in as a string
# LITERAL spelling, and what comes back is the same tree `f"..."` would give
def ps_template(a: *Arena, file: const *char, lexeme: const *char, pos: Pos) -> *PsExpr
