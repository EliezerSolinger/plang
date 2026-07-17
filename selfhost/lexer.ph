# lexer.ph — stage 2 of the pipeline: UTF-32 -> tokens (indentation-sensitive)
import "plang.ph"
import "ast.ph"  # TokKind lives here (shared vocabulary)


struct Token:
    kind: TokKind
    pos: Pos
    text: const *char   # lexeme (NUL-terminated, in the arena); None for punctuation

struct TokenList:
    toks: *Token
    n: usize

def lex(file: const *char, bytes: const *char, nbytes: usize, a: *Arena) -> TokenList
def tok_kind_name(k: TokKind) -> const *char
