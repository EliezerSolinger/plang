# ps_lexer.ph — pscript's tokenizer: P's lexing machinery, pscript's vocabulary.
#
# There is no second lexer. Indentation, strings, numbers, comments, positions
# and the tolerant editor recovery are language-neutral, so pscript hands the
# shared lexer a LexSpec (keywords + which extended operators exist) and gets
# its tokens back. What forks below this line is the parser, the AST and sema —
# the parts that actually encode a language.
import "lexer.ph"

def ps_lex(file: const *char, bytes: const *char, nbytes: usize, a: *Arena) -> TokenList
def ps_lex_ex(file: const *char, bytes: const *char, nbytes: usize, a: *Arena, tolerant: bool) -> TokenList
