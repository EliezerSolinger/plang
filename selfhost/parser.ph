# parser.ph — stage 4 of the pipeline: tokens -> AST
import "plang.ph"
import "ast.ph"
import "lexer.ph"

def parse_tokens(a: *Arena, file: const *char, tl: TokenList, is_header: i32) -> *Module
# 99.2: what a top-level `const if` may look at — the host and the -D list. Set
# once by the driver, before anything is parsed.
def parser_config_predef(os: const *char, defs: **char, ndefs: i32)
# ... and what it knows, for the pscript parser to ask the same questions (99)
def parser_predef_os() -> const *char
def parser_predef_value(name: const *char, ref known: bool) -> i64
