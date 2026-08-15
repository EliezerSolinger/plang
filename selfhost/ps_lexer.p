# ps_lexer.p — the LexSpec that turns the shared lexer into pscript's.
import "ps_lexer.ph"

# pscript's keywords. The overlap with P is deliberate — the two languages are
# meant to read as the same family — but the tables are SEPARATE: a word that
# is a keyword here and an identifier there (`record`, `shared`, `pass`) must
# stay an identifier there, and P must never start rejecting a variable called
# `record` because pscript wanted the word.
#
# Missing on purpose, and each for a reason:
#   `union`, `volatile`, `restrict`, `extern`, `inline`, `goto` — C's surface;
#       pscript has no C ABI to describe and no `goto` (50.1 resumes by match).
#   `declare`/`implement` — P's generic instantiation protocol, which is a
#       zero-runtime device; pscript's generics live in its own sema.
#   `do` — P's do/while; pscript's loops are Python's.
static const PS_KEYWORDS: Keyword[] = {
    # shared with P, same meaning
    {"def", TK_DEF}, {"return", TK_RETURN}, {"if", TK_IF},
    {"elif", TK_ELIF}, {"else", TK_ELSE}, {"while", TK_WHILE},
    {"for", TK_FOR}, {"in", TK_IN}, {"match", TK_MATCH},
    {"case", TK_CASE}, {"break", TK_BREAK}, {"continue", TK_CONTINUE},
    {"const", TK_CONST}, {"struct", TK_STRUCT}, {"enum", TK_ENUM},
    {"import", TK_IMPORT}, {"and", TK_AND}, {"or", TK_OR},
    {"not", TK_NOT}, {"True", TK_TRUE}, {"False", TK_FALSE},
    {"None", TK_NONE}, {"static", TK_STATIC}, {"defer", TK_DEFER},
    {"with", TK_WITH},
    # pscript's own
    {"record", TK_RECORD}, {"shared", TK_SHARED}, {"spawn", TK_SPAWN},
    {"async", TK_ASYNC}, {"await", TK_AWAIT}, {"raise", TK_RAISE},
    {"try", TK_TRY}, {"catch", TK_CATCH}, {"finally", TK_FINALLY},
    {"global", TK_GLOBAL}, {"nonlocal", TK_NONLOCAL}, {"lambda", TK_LAMBDA},
    {"pass", TK_PASS}, {"assert", TK_ASSERT}, {"unsafe", TK_UNSAFE},
    {"nogc", TK_NOGC}, {"from", TK_FROM}, {"as", TK_AS},
    {"implements", TK_IMPLEMENTS}, {"is", TK_IS},
    {None, TK_EOF}}

# f-strings, triple quotes and the extended operator set: all three are things
# pscript's surface has and P's does not.
static PS_LEXSPEC: const LexSpec = {PS_KEYWORDS, True, True, True}

def ps_lex(file: const *char, bytes: const *char, nbytes: usize, a: *Arena) -> TokenList:
    return lex_with(file, bytes, nbytes, a, False, &PS_LEXSPEC)

# editor mode, same contract as P's lex_ex: never fatal, always recover
def ps_lex_ex(file: const *char, bytes: const *char, nbytes: usize, a: *Arena, tolerant: bool) -> TokenList:
    return lex_with(file, bytes, nbytes, a, tolerant, &PS_LEXSPEC)
