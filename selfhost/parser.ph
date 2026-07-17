# parser.ph — stage 4 of the pipeline: tokens -> AST
import "plang.ph"
import "ast.ph"
import "lexer.ph"

def parse_tokens(a: *Arena, file: const *char, tl: TokenList, is_header: i32) -> *Module
