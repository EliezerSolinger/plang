# lexer.ph — stage 2 of the pipeline: UTF-32 -> tokens (indentation-sensitive)
import "plang.ph"
import "ast.ph"  # TokKind lives here (shared vocabulary)


struct Token:
    kind: TokKind
    pos: Pos
    text: const *char   # lexeme (NUL-terminated, in the arena); None for punctuation

struct TokenList:
    toks: *Token       # malloc'd array: the CALLER owns it (free it when
                       #   done). The LEXEMES live in the arena passed to lex.
    n: usize

def lex(file: const *char, bytes: const *char, nbytes: usize, a: *Arena) -> TokenList
# tolerant=True: modo editor — NUNCA fatal (recupera e segue); usado pelo pstudio
def lex_ex(file: const *char, bytes: const *char, nbytes: usize, a: *Arena, tolerant: bool) -> TokenList
def tok_kind_name(k: TokKind) -> const *char
