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

struct Keyword:
    word: const *char   # None ends the table
    kind: TokKind

# What the lexing MACHINERY has to know about the language it is reading.
# Everything else in the lexer — the indentation stack, the string and number
# scanners, position tracking, the tolerant recovery — is language-neutral, so
# a second language reuses it by handing over a different spec instead of
# forking 600 lines. The flags are real differences in what a byte sequence
# MEANS, which is why they are not just more keywords.
struct LexSpec:
    keywords: const *Keyword
    fstrings: bool     # f"..." is an interpolation prefix, not an identifier
    bytestr: bool      # b"..." is a bytes literal (135.7), not an identifier
    triple_str: bool   # """...""" spans lines
    ext_ops: bool      # ?? ??= ?. ** // %* %+ %- @

# P's own spec stays private to the lexer: `lex`/`lex_ex` are its entry points,
# and a second language brings its own table rather than referring to P's.

def lex(file: const *char, bytes: const *char, nbytes: usize, a: *Arena) -> TokenList
# tolerant=True: modo editor — NUNCA fatal (recupera e segue); usado pelo pstudio
def lex_ex(file: const *char, bytes: const *char, nbytes: usize, a: *Arena, tolerant: bool) -> TokenList
# the general entry point: same machinery, a different language
def lex_with(file: const *char, bytes: const *char, nbytes: usize, a: *Arena, tolerant: bool, spec: const *LexSpec) -> TokenList
def tok_kind_name(k: TokKind) -> const *char
def spell_tok(t: *Token) -> const *char
