#include <stddef.h>

#include "ps_lexer.h"

static const Keyword PS_KEYWORDS[47] = {{"def", TK_DEF}, {"return", TK_RETURN}, {"if", TK_IF}, {"elif", TK_ELIF}, {"else", TK_ELSE}, {"while", TK_WHILE}, {"for", TK_FOR}, {"in", TK_IN}, {"match", TK_MATCH}, {"case", TK_CASE}, {"break", TK_BREAK}, {"continue", TK_CONTINUE}, {"const", TK_CONST}, {"struct", TK_STRUCT}, {"enum", TK_ENUM}, {"import", TK_IMPORT}, {"and", TK_AND}, {"or", TK_OR}, {"not", TK_NOT}, {"True", TK_TRUE}, {"False", TK_FALSE}, {"None", TK_NONE}, {"static", TK_STATIC}, {"private", TK_PRIVATE}, {"defer", TK_DEFER}, {"with", TK_WITH}, {"record", TK_RECORD}, {"shared", TK_SHARED}, {"spawn", TK_SPAWN}, {"async", TK_ASYNC}, {"await", TK_AWAIT}, {"raise", TK_RAISE}, {"try", TK_TRY}, {"catch", TK_CATCH}, {"finally", TK_FINALLY}, {"global", TK_GLOBAL}, {"nonlocal", TK_NONLOCAL}, {"lambda", TK_LAMBDA}, {"pass", TK_PASS}, {"assert", TK_ASSERT}, {"unsafe", TK_UNSAFE}, {"nogc", TK_NOGC}, {"from", TK_FROM}, {"as", TK_AS}, {"implements", TK_IMPLEMENTS}, {"is", TK_IS}, {NULL, TK_EOF}};

static const LexSpec PS_LEXSPEC = {PS_KEYWORDS, 1, 1, 1, 1};

TokenList ps_lex(const char *file, const char *bytes, size_t nbytes, Arena *a) {
    return lex_with(file, bytes, nbytes, a, 0, &PS_LEXSPEC);
}

TokenList ps_lex_ex(const char *file, const char *bytes, size_t nbytes, Arena *a, int tolerant) {
    return lex_with(file, bytes, nbytes, a, tolerant, &PS_LEXSPEC);
}
