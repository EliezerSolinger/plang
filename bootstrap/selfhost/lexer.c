#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include <string.h>
#include "lexer.h"
#include "../stl/vec.h"

typedef struct Vec_Token Vec_Token;
typedef struct Lx Lx;

struct Vec_Token {
    Token *data;
    int32_t len;
    int32_t cap;
};

void Vec_Token_init(Vec_Token *self);

void Vec_Token_reserve(Vec_Token *self, int32_t n);

void Vec_Token_push(Vec_Token *self, Token item);

Token Vec_Token_pop(Vec_Token *self);

Token Vec_Token_get(const Vec_Token *self, int32_t i);

void Vec_Token_set(Vec_Token *self, int32_t i, Token item);

Token Vec_Token_last(const Vec_Token *self);

int Vec_Token_is_empty(const Vec_Token *self);

void Vec_Token_insert_gap(Vec_Token *self, int32_t i, int32_t n);

void Vec_Token_insert_at(Vec_Token *self, int32_t i, Token item);

void Vec_Token_remove_range(Vec_Token *self, int32_t i, int32_t n);

void Vec_Token_remove_at(Vec_Token *self, int32_t i);

void Vec_Token_swap_remove(Vec_Token *self, int32_t i);

void Vec_Token_clear(Vec_Token *self);

void Vec_Token_deinit(Vec_Token *self);


void Vec_Token_init(Vec_Token *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_Token_reserve(Vec_Token *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(Token) * (size_t)nc);
    self->cap = nc;
}

void Vec_Token_push(Vec_Token *self, Token item) {
    Vec_Token_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

Token Vec_Token_pop(Vec_Token *self) {
    self->len -= 1;
    return self->data[self->len];
}

Token Vec_Token_get(const Vec_Token *self, int32_t i) {
    return self->data[i];
}

void Vec_Token_set(Vec_Token *self, int32_t i, Token item) {
    self->data[i] = item;
}

Token Vec_Token_last(const Vec_Token *self) {
    return self->data[self->len - 1];
}

int Vec_Token_is_empty(const Vec_Token *self) {
    return self->len == 0;
}

void Vec_Token_insert_gap(Vec_Token *self, int32_t i, int32_t n) {
    Vec_Token_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(Token) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_Token_insert_at(Vec_Token *self, int32_t i, Token item) {
    Vec_Token_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_Token_remove_range(Vec_Token *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(Token) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_Token_remove_at(Vec_Token *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(Token) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_Token_swap_remove(Vec_Token *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_Token_clear(Vec_Token *self) {
    self->len = 0;
}

void Vec_Token_deinit(Vec_Token *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

typedef enum { MAX_INDENT = 64 } LxLimit;

static const Keyword P_KEYWORDS[37] = {{"def", TK_DEF}, {"return", TK_RETURN}, {"if", TK_IF}, {"elif", TK_ELIF}, {"else", TK_ELSE}, {"while", TK_WHILE}, {"for", TK_FOR}, {"in", TK_IN}, {"do", TK_DO}, {"match", TK_MATCH}, {"case", TK_CASE}, {"break", TK_BREAK}, {"continue", TK_CONTINUE}, {"goto", TK_GOTO}, {"const", TK_CONST}, {"struct", TK_STRUCT}, {"enum", TK_ENUM}, {"union", TK_UNION}, {"import", TK_IMPORT}, {"and", TK_AND}, {"or", TK_OR}, {"not", TK_NOT}, {"True", TK_TRUE}, {"False", TK_FALSE}, {"None", TK_NONE}, {"static", TK_STATIC}, {"private", TK_PRIVATE}, {"inline", TK_INLINE}, {"extern", TK_EXTERN}, {"volatile", TK_VOLATILE}, {"restrict", TK_RESTRICT}, {"defer", TK_DEFER}, {"with", TK_WITH}, {"declare", TK_DECLARE}, {"implement", TK_IMPLEMENT}, {"lambda", TK_LAMBDA}, {NULL, TK_EOF}};

static const LexSpec P_LEXSPEC = {P_KEYWORDS, 1, 0, 0};

const char *spell_tok(Token *t) {
    if (t->text != NULL) {
        return t->text;
    }
    switch (t->kind) {
        case TK_DOT: {
            return ".";
        }
        case TK_SLASH: {
            return "/";
        }
        case TK_MINUS: {
            return "-";
        }
        default: {
            return "";
        }
    }
}

const char *tok_kind_name(TokKind k) {
    switch (k) {
        case TK_EOF: {
            return "end of file";
        }
        case TK_NEWLINE: {
            return "end of line";
        }
        case TK_INDENT: {
            return "INDENT";
        }
        case TK_DEDENT: {
            return "DEDENT";
        }
        case TK_IDENT: {
            return "identifier";
        }
        case TK_NUMBER: {
            return "number";
        }
        case TK_STRING: {
            return "string";
        }
        case TK_CHARLIT: {
            return "char literal";
        }
        case TK_HEADER: {
            return "<header>";
        }
        case TK_DEF: {
            return "'def'";
        }
        case TK_RETURN: {
            return "'return'";
        }
        case TK_IF: {
            return "'if'";
        }
        case TK_ELIF: {
            return "'elif'";
        }
        case TK_ELSE: {
            return "'else'";
        }
        case TK_WHILE: {
            return "'while'";
        }
        case TK_FOR: {
            return "'for'";
        }
        case TK_IN: {
            return "'in'";
        }
        case TK_DO: {
            return "'do'";
        }
        case TK_MATCH: {
            return "'match'";
        }
        case TK_CASE: {
            return "'case'";
        }
        case TK_BREAK: {
            return "'break'";
        }
        case TK_CONTINUE: {
            return "'continue'";
        }
        case TK_GOTO: {
            return "'goto'";
        }
        case TK_CONST: {
            return "'const'";
        }
        case TK_STRUCT: {
            return "'struct'";
        }
        case TK_ENUM: {
            return "'enum'";
        }
        case TK_UNION: {
            return "'union'";
        }
        case TK_IMPORT: {
            return "'import'";
        }
        case TK_AND: {
            return "'and'";
        }
        case TK_OR: {
            return "'or'";
        }
        case TK_NOT: {
            return "'not'";
        }
        case TK_TRUE: {
            return "'True'";
        }
        case TK_FALSE: {
            return "'False'";
        }
        case TK_NONE: {
            return "'None'";
        }
        case TK_STATIC: {
            return "'static'";
        }
        case TK_PRIVATE: {
            return "'private'";
        }
        case TK_INLINE: {
            return "'inline'";
        }
        case TK_DEFER: {
            return "'defer'";
        }
        case TK_WITH: {
            return "'with'";
        }
        case TK_DECLARE: {
            return "'declare'";
        }
        case TK_IMPLEMENT: {
            return "'implement'";
        }
        case TK_LPAREN: {
            return "'('";
        }
        case TK_RPAREN: {
            return "')'";
        }
        case TK_LBRACKET: {
            return "'['";
        }
        case TK_RBRACKET: {
            return "']'";
        }
        case TK_LBRACE: {
            return "'{'";
        }
        case TK_RBRACE: {
            return "'}'";
        }
        case TK_COMMA: {
            return "','";
        }
        case TK_COLON: {
            return "':'";
        }
        case TK_SEMI: {
            return "';'";
        }
        case TK_DOT: {
            return "'.'";
        }
        case TK_ARROW: {
            return "'->'";
        }
        case TK_ELLIPSIS: {
            return "'...'";
        }
        case TK_PLUS: {
            return "'+'";
        }
        case TK_MINUS: {
            return "'-'";
        }
        case TK_STAR: {
            return "'*'";
        }
        case TK_SLASH: {
            return "'/'";
        }
        case TK_PERCENT: {
            return "'%'";
        }
        case TK_AMP: {
            return "'&'";
        }
        case TK_PIPE: {
            return "'|'";
        }
        case TK_CARET: {
            return "'^'";
        }
        case TK_TILDE: {
            return "'~'";
        }
        case TK_SHL: {
            return "'<<'";
        }
        case TK_SHR: {
            return "'>>'";
        }
        case TK_LT: {
            return "'<'";
        }
        case TK_LE: {
            return "'<='";
        }
        case TK_GT: {
            return "'>'";
        }
        case TK_GE: {
            return "'>='";
        }
        case TK_EQ: {
            return "'=='";
        }
        case TK_NE: {
            return "'!='";
        }
        case TK_ASSIGN: {
            return "'='";
        }
        case TK_PLUS_EQ: {
            return "'+='";
        }
        case TK_MINUS_EQ: {
            return "'-='";
        }
        case TK_STAR_EQ: {
            return "'*='";
        }
        case TK_SLASH_EQ: {
            return "'/='";
        }
        case TK_PERCENT_EQ: {
            return "'%='";
        }
        case TK_AMP_EQ: {
            return "'&='";
        }
        case TK_PIPE_EQ: {
            return "'|='";
        }
        case TK_CARET_EQ: {
            return "'^='";
        }
        case TK_SHL_EQ: {
            return "'<<='";
        }
        case TK_SHR_EQ: {
            return "'>>='";
        }
        case TK_ASYNC: {
            return "'async'";
        }
        case TK_AWAIT: {
            return "'await'";
        }
        case TK_RECORD: {
            return "'record'";
        }
        case TK_SHARED: {
            return "'shared'";
        }
        case TK_SPAWN: {
            return "'spawn'";
        }
        case TK_RAISE: {
            return "'raise'";
        }
        case TK_TRY: {
            return "'try'";
        }
        case TK_CATCH: {
            return "'catch'";
        }
        case TK_FINALLY: {
            return "'finally'";
        }
        case TK_GLOBAL: {
            return "'global'";
        }
        case TK_NONLOCAL: {
            return "'nonlocal'";
        }
        case TK_LAMBDA: {
            return "'lambda'";
        }
        case TK_PASS: {
            return "'pass'";
        }
        case TK_ASSERT: {
            return "'assert'";
        }
        case TK_UNSAFE: {
            return "'unsafe'";
        }
        case TK_NOGC: {
            return "'nogc'";
        }
        case TK_FROM: {
            return "'from'";
        }
        case TK_AS: {
            return "'as'";
        }
        case TK_IMPLEMENTS: {
            return "'implements'";
        }
        case TK_QUESTION: {
            return "'\?'";
        }
        case TK_COALESCE: {
            return "'\?\?'";
        }
        case TK_COALESCE_EQ: {
            return "'\?\?='";
        }
        case TK_OPTDOT: {
            return "'\?.'";
        }
        case TK_OPTINDEX: {
            return "'\?['";
        }
        case TK_POW: {
            return "'**'";
        }
        case TK_POW_EQ: {
            return "'**='";
        }
        case TK_FLOORDIV: {
            return "'//'";
        }
        case TK_FLOORDIV_EQ: {
            return "'//='";
        }
        case TK_WRAP_STAR: {
            return "'%*'";
        }
        case TK_WRAP_PLUS: {
            return "'%+'";
        }
        case TK_WRAP_MINUS: {
            return "'%-'";
        }
        case TK_AT: {
            return "'@'";
        }
        case TK_FSTRING: {
            return "f-string";
        }
        default: {
            return "token";
        }
    }
}

static int is_ident_start(uint32_t c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

static int is_ident_cont(uint32_t c) {
    return is_ident_start(c) || (c >= '0' && c <= '9');
}

static int is_digit(uint32_t c) {
    return c >= '0' && c <= '9';
}

static int is_hex(uint32_t c) {
    return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

struct Lx {
    const char *file;
    const char *bytes;
    size_t nbytes;
    uint32_t *cp;
    uint32_t *off;
    size_t n;
    size_t i;
    int32_t line;
    size_t line_start;
    Arena *a;
    Vec_Token toks;
    int32_t indents[MAX_INDENT];
    int32_t nindents;
    int32_t paren;
    int prev_import;
    int tolerant;
    const LexSpec *spec;
};

static uint32_t Lx_cur(Lx *self) {
    return (self->i < self->n ? self->cp[self->i] : 0);
}

static uint32_t Lx_peek(Lx *self, size_t k) {
    return (self->i + k < self->n ? self->cp[self->i + k] : 0);
}

static Pos Lx_here(Lx *self) {
    Pos p = {self->line, (int32_t)(self->i - self->line_start) + 1};
    return p;
}

static const char *Lx_slice(Lx *self, size_t start, size_t end) {
    size_t b0 = self->off[start];
    size_t b1 = (end < self->n ? self->off[end] : self->nbytes);
    return Arena_strndup(self->a, self->bytes + b0, b1 - b0);
}

static void Lx_push_tok(Lx *self, TokKind k, Pos pos, const char *text) {
    Token t = {k, pos, text};
    Vec_Token_push(&self->toks, t);
    self->prev_import = k == TK_IMPORT;
}

static void Lx_lex_newline_and_indent(Lx *self) {
    while (1) {
        size_t save = self->i;
        while (1) {
            uint32_t ws = Lx_cur(self);
            if (ws == ' ' || ws == '\t') {
                self->i += 1;
            } else {
                break;
            }
        }
        uint32_t c = Lx_cur(self);
        if (c == '#') {
            while (self->i < self->n && Lx_cur(self) != '\n') {
                self->i += 1;
            }
            c = Lx_cur(self);
        }
        if (c == '\r' && Lx_peek(self, 1) == '\n') {
            self->i += 1;
            c = Lx_cur(self);
        }
        if (c == '\n') {
            self->i += 1;
            self->line += 1;
            self->line_start = self->i;
            continue;
        }
        if (self->i >= self->n) {
            return;
        }
        self->i = save;
        int col = 0;
        while (1) {
            uint32_t d = Lx_cur(self);
            if (d == ' ') {
                col += 1;
                self->i += 1;
            } else if (d == '\t') {
                col += 8 - col % 8;
                self->i += 1;
            } else {
                break;
            }
        }
        int32_t top = self->indents[self->nindents - 1];
        Pos p = Lx_here(self);
        if (col > top) {
            if (self->nindents >= MAX_INDENT) {
                if (self->tolerant) {
                    return;
                }
                fatal_at(self->file, p, "indentation too deep");
            }
            self->indents[self->nindents] = col;
            self->nindents += 1;
            Lx_push_tok(self, TK_INDENT, p, NULL);
        } else {
            while (col < self->indents[self->nindents - 1]) {
                self->nindents -= 1;
                Lx_push_tok(self, TK_DEDENT, p, NULL);
            }
            if (col != self->indents[self->nindents - 1] && !self->tolerant) {
                fatal_at(self->file, p, "inconsistent indentation");
            }
        }
        return;
    }
}

static void Lx_lex_str_at(Lx *self, size_t start, Pos p, uint32_t quote, TokKind kind) {
    self->i += 1;
    while (1) {
        uint32_t c = Lx_cur(self);
        if (self->i >= self->n || c == '\n') {
            if (self->tolerant) {
                break;
            }
            fatal_at(self->file, p, "unterminated literal (missing %c)", (char)quote);
        }
        if (c == '\\') {
            self->i += 2;
            continue;
        }
        self->i += 1;
        if (c == quote) {
            break;
        }
    }
    Lx_push_tok(self, kind, p, Lx_slice(self, start, self->i));
}

static void Lx_lex_string(Lx *self, uint32_t quote, TokKind kind) {
    Lx_lex_str_at(self, self->i, Lx_here(self), quote, kind);
}

static void Lx_lex_triple_at(Lx *self, size_t start, Pos p, uint32_t quote, TokKind kind) {
    self->i += 3;
    while (1) {
        uint32_t c = Lx_cur(self);
        if (self->i >= self->n) {
            if (self->tolerant) {
                break;
            }
            fatal_at(self->file, p, "unterminated triple-quoted literal");
        }
        if (c == '\\') {
            self->i += 2;
            continue;
        }
        if (c == '\n') {
            self->line += 1;
            self->i += 1;
            self->line_start = self->i;
            continue;
        }
        if (c == quote && Lx_peek(self, 1) == quote && Lx_peek(self, 2) == quote) {
            self->i += 3;
            break;
        }
        self->i += 1;
    }
    Lx_push_tok(self, kind, p, Lx_slice(self, start, self->i));
}

static void Lx_lex_number(Lx *self) {
    Pos p = Lx_here(self);
    size_t start = self->i;
    if (Lx_cur(self) == '0' && (Lx_peek(self, 1) == 'x' || Lx_peek(self, 1) == 'X')) {
        self->i += 2;
        if (!is_hex(Lx_cur(self)) && !self->tolerant) {
            fatal_at(self->file, p, "invalid hexadecimal number");
        }
        while (is_hex(Lx_cur(self))) {
            self->i += 1;
        }
    } else {
        while (is_digit(Lx_cur(self))) {
            self->i += 1;
        }
        if (Lx_cur(self) == '.' && is_digit(Lx_peek(self, 1))) {
            self->i += 1;
            while (is_digit(Lx_cur(self))) {
                self->i += 1;
            }
        }
        if (Lx_cur(self) == 'e' || Lx_cur(self) == 'E') {
            size_t save = self->i;
            self->i += 1;
            if (Lx_cur(self) == '+' || Lx_cur(self) == '-') {
                self->i += 1;
            }
            if (is_digit(Lx_cur(self))) {
                while (is_digit(Lx_cur(self))) {
                    self->i += 1;
                }
            } else {
                self->i = save;
            }
        }
    }
    while (Lx_cur(self) == 'u' || Lx_cur(self) == 'U' || Lx_cur(self) == 'l' || Lx_cur(self) == 'L' || Lx_cur(self) == 'f' || Lx_cur(self) == 'F') {
        self->i += 1;
    }
    Lx_push_tok(self, TK_NUMBER, p, Lx_slice(self, start, self->i));
}

static void Lx_lex_op(Lx *self) {
    Pos p = Lx_here(self);
    uint32_t c = Lx_cur(self);
    uint32_t c1 = Lx_peek(self, 1);
    uint32_t c2 = Lx_peek(self, 2);
    TokKind k = TK_EOF;
    int len = 1;
    if (self->spec->ext_ops) {
        TokKind ek = TK_EOF;
        int elen = 0;
        switch (c) {
            case '\?': {
                if (c1 == '\?' && c2 == '=') {
                    ek = TK_COALESCE_EQ;
                    elen = 3;
                } else if (c1 == '\?') {
                    ek = TK_COALESCE;
                    elen = 2;
                } else if (c1 == '.') {
                    ek = TK_OPTDOT;
                    elen = 2;
                } else if (c1 == '[') {
                    ek = TK_OPTINDEX;
                    elen = 2;
                    self->paren += 1;
                } else {
                    ek = TK_QUESTION;
                    elen = 1;
                }
                break;
            }
            case '*': {
                if (c1 == '*' && c2 == '=') {
                    ek = TK_POW_EQ;
                    elen = 3;
                } else if (c1 == '*') {
                    ek = TK_POW;
                    elen = 2;
                }
                break;
            }
            case '/': {
                if (c1 == '/' && c2 == '=') {
                    ek = TK_FLOORDIV_EQ;
                    elen = 3;
                } else if (c1 == '/') {
                    ek = TK_FLOORDIV;
                    elen = 2;
                }
                break;
            }
            case '%': {
                if (c1 == '*') {
                    ek = TK_WRAP_STAR;
                    elen = 2;
                } else if (c1 == '+') {
                    ek = TK_WRAP_PLUS;
                    elen = 2;
                } else if (c1 == '-') {
                    ek = TK_WRAP_MINUS;
                    elen = 2;
                }
                break;
            }
            case '@': {
                ek = TK_AT;
                elen = 1;
                break;
            }
            default: {
                ;
                break;
            }
        }
        if (elen > 0) {
            self->i += (size_t)elen;
            Lx_push_tok(self, ek, p, NULL);
            return;
        }
    }
    switch (c) {
        case '(': {
            k = TK_LPAREN;
            self->paren += 1;
            break;
        }
        case ')': {
            k = TK_RPAREN;
            self->paren -= 1;
            break;
        }
        case '[': {
            k = TK_LBRACKET;
            self->paren += 1;
            break;
        }
        case ']': {
            k = TK_RBRACKET;
            self->paren -= 1;
            break;
        }
        case '{': {
            k = TK_LBRACE;
            self->paren += 1;
            break;
        }
        case '}': {
            k = TK_RBRACE;
            self->paren -= 1;
            break;
        }
        case ',': {
            k = TK_COMMA;
            break;
        }
        case ':': {
            if (c1 == '=') {
                k = TK_WALRUS;
                len = 2;
            } else {
                k = TK_COLON;
            }
            break;
        }
        case ';': {
            k = TK_SEMI;
            break;
        }
        case '.': {
            if (c1 == '.' && c2 == '.') {
                k = TK_ELLIPSIS;
                len = 3;
            } else {
                k = TK_DOT;
            }
            break;
        }
        case '~': {
            k = TK_TILDE;
            break;
        }
        case '\?': {
            if (c1 == '\?') {
                k = TK_COALESCE;
                len = 2;
            } else if (self->tolerant) {
                self->i += 1;
                return;
            } else {
                fatal_at(self->file, p, "unexpected character (U+003F)");
            }
            break;
        }
        case '+': {
            if (c1 == '=') {
                k = TK_PLUS_EQ;
                len = 2;
            } else {
                k = TK_PLUS;
            }
            break;
        }
        case '-': {
            if (c1 == '>') {
                k = TK_ARROW;
                len = 2;
            } else if (c1 == '=') {
                k = TK_MINUS_EQ;
                len = 2;
            } else {
                k = TK_MINUS;
            }
            break;
        }
        case '*': {
            if (c1 == '=') {
                k = TK_STAR_EQ;
                len = 2;
            } else {
                k = TK_STAR;
            }
            break;
        }
        case '/': {
            if (c1 == '=') {
                k = TK_SLASH_EQ;
                len = 2;
            } else {
                k = TK_SLASH;
            }
            break;
        }
        case '%': {
            if (c1 == '=') {
                k = TK_PERCENT_EQ;
                len = 2;
            } else {
                k = TK_PERCENT;
            }
            break;
        }
        case '&': {
            if (c1 == '=') {
                k = TK_AMP_EQ;
                len = 2;
            } else {
                k = TK_AMP;
            }
            break;
        }
        case '|': {
            if (c1 == '=') {
                k = TK_PIPE_EQ;
                len = 2;
            } else {
                k = TK_PIPE;
            }
            break;
        }
        case '^': {
            if (c1 == '=') {
                k = TK_CARET_EQ;
                len = 2;
            } else {
                k = TK_CARET;
            }
            break;
        }
        case '=': {
            if (c1 == '=') {
                k = TK_EQ;
                len = 2;
            } else {
                k = TK_ASSIGN;
            }
            break;
        }
        case '<': {
            if (c1 == '<' && c2 == '=') {
                k = TK_SHL_EQ;
                len = 3;
            } else if (c1 == '<') {
                k = TK_SHL;
                len = 2;
            } else if (c1 == '=') {
                k = TK_LE;
                len = 2;
            } else {
                k = TK_LT;
            }
            break;
        }
        case '>': {
            if (c1 == '>' && c2 == '=') {
                k = TK_SHR_EQ;
                len = 3;
            } else if (c1 == '>') {
                k = TK_SHR;
                len = 2;
            } else if (c1 == '=') {
                k = TK_GE;
                len = 2;
            } else {
                k = TK_GT;
            }
            break;
        }
        case '!': {
            if (c1 == '=') {
                k = TK_NE;
                len = 2;
            } else {
                if (self->tolerant) {
                    self->i += 1;
                    return;
                }
                fatal_at(self->file, p, "'!' does not exist in P — use 'not'");
            }
            break;
        }
        default: {
            if (self->tolerant) {
                self->i += 1;
                return;
            }
            fatal_at(self->file, p, "unexpected character (U+%04X)", c);
            break;
        }
    }
    self->i += (size_t)len;
    Lx_push_tok(self, k, p, NULL);
}

TokenList lex(const char *file, const char *bytes, size_t nbytes, Arena *a) {
    return lex_with(file, bytes, nbytes, a, 0, &P_LEXSPEC);
}

TokenList lex_ex(const char *file, const char *bytes, size_t nbytes, Arena *a, int tolerant) {
    return lex_with(file, bytes, nbytes, a, tolerant, &P_LEXSPEC);
}

TokenList lex_with(const char *file, const char *bytes, size_t nbytes, Arena *a, int tolerant, const LexSpec *spec) {
    Lx lx = {0};
    lx.spec = spec;
    lx.file = file;
    lx.bytes = bytes;
    lx.nbytes = nbytes;
    lx.a = a;
    lx.line = 1;
    lx.indents[0] = 0;
    lx.nindents = 1;
    lx.tolerant = tolerant;
    size_t err_off = 0;
    if (utf8_decode(bytes, nbytes, a, &lx.cp, &lx.off, &lx.n, &err_off) != 0) {
        if (!tolerant) {
            fatal("%s: invalid UTF-8 byte at offset %zu", file, err_off);
        }
        char *fixed = Arena_alloc(a, nbytes + 1);
        memcpy(fixed, bytes, nbytes);
        fixed[nbytes] = '\0';
        while (utf8_decode(fixed, nbytes, a, &lx.cp, &lx.off, &lx.n, &err_off) != 0) {
            fixed[err_off] = '\?';
        }
        lx.bytes = fixed;
    }
    Lx_lex_newline_and_indent(&lx);
    while (lx.i < lx.n) {
        uint32_t c = Lx_cur(&lx);
        if (c == ' ' || c == '\t' || c == '\r') {
            lx.i += 1;
            continue;
        }
        if (c == '#') {
            while (lx.i < lx.n && Lx_cur(&lx) != '\n') {
                lx.i += 1;
            }
            continue;
        }
        if (c == '\n') {
            lx.i += 1;
            lx.line += 1;
            lx.line_start = lx.i;
            if (lx.paren == 0) {
                Pos np = {lx.line - 1, 1};
                Lx_push_tok(&lx, TK_NEWLINE, np, NULL);
                Lx_lex_newline_and_indent(&lx);
            }
            continue;
        }
        if (lx.prev_import && c == '<') {
            Pos p = Lx_here(&lx);
            lx.i += 1;
            size_t start = lx.i;
            while (lx.i < lx.n && Lx_cur(&lx) != '>' && Lx_cur(&lx) != '\n') {
                lx.i += 1;
            }
            if (Lx_cur(&lx) != '>' && !lx.tolerant) {
                fatal_at(lx.file, p, "unterminated header (missing '>')");
            }
            const char *text = Lx_slice(&lx, start, lx.i);
            lx.i += 1;
            Lx_push_tok(&lx, TK_HEADER, p, text);
            continue;
        }
        if (c == 'L' || c == 'u' || c == 'U') {
            size_t plen = 1;
            if (c == 'u' && Lx_peek(&lx, 1) == '8') {
                plen = 2;
            }
            uint32_t q = Lx_peek(&lx, plen);
            if (q == '"' || (q == '\'' && plen == 1)) {
                size_t pstart = lx.i;
                Pos pp = Lx_here(&lx);
                lx.i += plen;
                TokKind k = (q == '"' ? TK_STRING : TK_CHARLIT);
                Lx_lex_str_at(&lx, pstart, pp, q, k);
                continue;
            }
        }
        if (lx.spec->fstrings && c == 'f' && Lx_peek(&lx, 1) == '"') {
            size_t fstart = lx.i;
            Pos fp = Lx_here(&lx);
            lx.i += 1;
            if (lx.spec->triple_str && Lx_peek(&lx, 1) == '"' && Lx_peek(&lx, 2) == '"') {
                Lx_lex_triple_at(&lx, fstart, fp, '"', TK_FSTRING);
            } else {
                Lx_lex_str_at(&lx, fstart, fp, '"', TK_FSTRING);
            }
            continue;
        }
        if (is_ident_start(c)) {
            Pos p = Lx_here(&lx);
            size_t start = lx.i;
            while (is_ident_cont(Lx_cur(&lx))) {
                lx.i += 1;
            }
            if (Lx_cur(&lx) >= 128 && !lx.tolerant) {
                fatal_at(lx.file, Lx_here(&lx), "identifiers must be ASCII ([A-Za-z0-9_])");
            }
            const char *text = Lx_slice(&lx, start, lx.i);
            TokKind k = TK_IDENT;
            const Keyword *kws = lx.spec->keywords;
            int j = 0;
            while (kws[j].word != NULL) {
                if (strcmp(text, kws[j].word) == 0) {
                    k = kws[j].kind;
                    break;
                }
                j += 1;
            }
            Lx_push_tok(&lx, k, p, text);
            continue;
        }
        if (c >= 128) {
            if (lx.tolerant) {
                lx.i += 1;
                continue;
            }
            fatal_at(lx.file, Lx_here(&lx), "Unicode character outside string/comment (U+%04X)", c);
        }
        if (is_digit(c)) {
            Lx_lex_number(&lx);
            continue;
        }
        if (c == '"' && lx.spec->triple_str && Lx_peek(&lx, 1) == '"' && Lx_peek(&lx, 2) == '"') {
            Lx_lex_triple_at(&lx, lx.i, Lx_here(&lx), '"', TK_STRING);
            continue;
        }
        if (c == '"') {
            Lx_lex_string(&lx, '"', TK_STRING);
            continue;
        }
        if (c == '\'') {
            Lx_lex_string(&lx, '\'', TK_CHARLIT);
            continue;
        }
        Lx_lex_op(&lx);
    }
    Pos end = {lx.line, (int32_t)(lx.i - lx.line_start) + 1};
    if (!Vec_Token_is_empty(&lx.toks) && Vec_Token_last(&lx.toks).kind != TK_NEWLINE && Vec_Token_last(&lx.toks).kind != TK_DEDENT) {
        Lx_push_tok(&lx, TK_NEWLINE, end, NULL);
    }
    while (lx.nindents > 1) {
        lx.nindents -= 1;
        Lx_push_tok(&lx, TK_DEDENT, end, NULL);
    }
    Lx_push_tok(&lx, TK_EOF, end, NULL);
    TokenList tl = {lx.toks.data, (size_t)lx.toks.len};
    return tl;
}
