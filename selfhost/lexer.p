# lexer.p — tokenizes UTF-32 codepoints, emitting NEWLINE/INDENT/DEDENT
# (port of src/lexer.c, using structs with P methods)
import <string.h>
import "lexer.ph"
import "../stl/vec.ph"

declare Vec<Token>
implement Vec<Token>

# limit via enum: a real integer constant in C (const int would become a VLA
# in the struct's array field)
enum LxLimit:
    MAX_INDENT = 64

struct Keyword:
    word: const *char
    kind: TokKind

const keywords: Keyword[] = {
    {"def", TK_DEF}, {"return", TK_RETURN}, {"if", TK_IF},
    {"elif", TK_ELIF}, {"else", TK_ELSE}, {"while", TK_WHILE},
    {"for", TK_FOR}, {"in", TK_IN}, {"do", TK_DO},
    {"match", TK_MATCH}, {"case", TK_CASE}, {"break", TK_BREAK},
    {"continue", TK_CONTINUE}, {"goto", TK_GOTO}, {"const", TK_CONST},
    {"struct", TK_STRUCT}, {"enum", TK_ENUM}, {"union", TK_UNION},
    {"import", TK_IMPORT}, {"and", TK_AND}, {"or", TK_OR},
    {"not", TK_NOT}, {"True", TK_TRUE}, {"False", TK_FALSE},
    {"None", TK_NONE}, {"static", TK_STATIC}, {"inline", TK_INLINE},
    {"extern", TK_EXTERN}, {"volatile", TK_VOLATILE}, {"restrict", TK_RESTRICT},
    {"defer", TK_DEFER}, {"with", TK_WITH},
    {"declare", TK_DECLARE}, {"implement", TK_IMPLEMENT},
    {None, TK_EOF}}

def tok_kind_name(k: TokKind) -> const *char:
    match k:
        case TK_EOF:
            return "end of file"
        case TK_NEWLINE:
            return "end of line"
        case TK_INDENT:
            return "INDENT"
        case TK_DEDENT:
            return "DEDENT"
        case TK_IDENT:
            return "identifier"
        case TK_NUMBER:
            return "number"
        case TK_STRING:
            return "string"
        case TK_CHARLIT:
            return "char literal"
        case TK_HEADER:
            return "<header>"
        case TK_DEF:
            return "'def'"
        case TK_RETURN:
            return "'return'"
        case TK_IF:
            return "'if'"
        case TK_ELIF:
            return "'elif'"
        case TK_ELSE:
            return "'else'"
        case TK_WHILE:
            return "'while'"
        case TK_FOR:
            return "'for'"
        case TK_IN:
            return "'in'"
        case TK_DO:
            return "'do'"
        case TK_MATCH:
            return "'match'"
        case TK_CASE:
            return "'case'"
        case TK_BREAK:
            return "'break'"
        case TK_CONTINUE:
            return "'continue'"
        case TK_GOTO:
            return "'goto'"
        case TK_CONST:
            return "'const'"
        case TK_STRUCT:
            return "'struct'"
        case TK_ENUM:
            return "'enum'"
        case TK_UNION:
            return "'union'"
        case TK_IMPORT:
            return "'import'"
        case TK_AND:
            return "'and'"
        case TK_OR:
            return "'or'"
        case TK_NOT:
            return "'not'"
        case TK_TRUE:
            return "'True'"
        case TK_FALSE:
            return "'False'"
        case TK_NONE:
            return "'None'"
        case TK_STATIC:
            return "'static'"
        case TK_INLINE:
            return "'inline'"
        case TK_DEFER:
            return "'defer'"
        case TK_WITH:
            return "'with'"
        case TK_DECLARE:
            return "'declare'"
        case TK_IMPLEMENT:
            return "'implement'"
        case TK_LPAREN:
            return "'('"
        case TK_RPAREN:
            return "')'"
        case TK_LBRACKET:
            return "'['"
        case TK_RBRACKET:
            return "']'"
        case TK_LBRACE:
            return "'{'"
        case TK_RBRACE:
            return "'}'"
        case TK_COMMA:
            return "','"
        case TK_COLON:
            return "':'"
        case TK_SEMI:
            return "';'"
        case TK_DOT:
            return "'.'"
        case TK_ARROW:
            return "'->'"
        case TK_ELLIPSIS:
            return "'...'"
        case TK_PLUS:
            return "'+'"
        case TK_MINUS:
            return "'-'"
        case TK_STAR:
            return "'*'"
        case TK_SLASH:
            return "'/'"
        case TK_PERCENT:
            return "'%'"
        case TK_AMP:
            return "'&'"
        case TK_PIPE:
            return "'|'"
        case TK_CARET:
            return "'^'"
        case TK_TILDE:
            return "'~'"
        case TK_SHL:
            return "'<<'"
        case TK_SHR:
            return "'>>'"
        case TK_LT:
            return "'<'"
        case TK_LE:
            return "'<='"
        case TK_GT:
            return "'>'"
        case TK_GE:
            return "'>='"
        case TK_EQ:
            return "'=='"
        case TK_NE:
            return "'!='"
        case TK_ASSIGN:
            return "'='"
        case TK_PLUS_EQ:
            return "'+='"
        case TK_MINUS_EQ:
            return "'-='"
        case TK_STAR_EQ:
            return "'*='"
        case TK_SLASH_EQ:
            return "'/='"
        case TK_PERCENT_EQ:
            return "'%='"
        case TK_AMP_EQ:
            return "'&='"
        case TK_PIPE_EQ:
            return "'|='"
        case TK_CARET_EQ:
            return "'^='"
        case TK_SHL_EQ:
            return "'<<='"
        case TK_SHR_EQ:
            return "'>>='"
        case _:
            return "token"

static def is_ident_start(c: u32) -> bool:
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'

static def is_ident_cont(c: u32) -> bool:
    return is_ident_start(c) or (c >= '0' and c <= '9')

static def is_digit(c: u32) -> bool:
    return c >= '0' and c <= '9'

static def is_hex(c: u32) -> bool:
    return is_digit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')

struct Lx:
    file: const *char
    bytes: const *char
    nbytes: usize
    cp: *u32           # codepoints
    off: *u32          # byte offset of each codepoint
    n: usize           # number of codepoints
    i: usize           # current codepoint
    line: i32
    line_start: usize  # index of the codepoint that starts the current line
    a: *Arena
    toks: Vec<Token>
    indents: i32[MAX_INDENT]
    nindents: i32
    paren: i32         # depth of () [] {} — implicit continuation
    prev_import: bool

    static def cur(self: *Lx) -> u32:
        return self->cp[self->i] if self->i < self->n else 0

    static def peek(self: *Lx, k: usize) -> u32:
        return self->cp[self->i + k] if self->i + k < self->n else 0

    static def here(self: *Lx) -> Pos:
        p: Pos = {self->line, i32(self->i - self->line_start) + 1}
        return p

    # slices the original bytes between codepoints [start, end)
    static def slice(self: *Lx, start: usize, end: usize) -> const *char:
        b0: usize = self->off[start]
        b1: usize = self->off[end] if end < self->n else self->nbytes
        return arena_strndup(self->a, self->bytes + b0, b1 - b0)

    static def push_tok(self: *Lx, k: TokKind, pos: Pos, text: const *char):
        t: Token = {k, pos, text}
        self->toks.push(t)
        self->prev_import = k == TK_IMPORT

    # consumes the line break and measures the indentation of the next lines,
    # skipping blank/comment-only lines; emits INDENT/DEDENT
    static def lex_newline_and_indent(self: *Lx):
        while True:
            # we're at the start of a logical line
            save: usize = self->i
            while True:
                ws: u32 = self->cur()
                if ws == ' ' or ws == '\t':
                    self->i += 1
                else:
                    break
            c: u32 = self->cur()
            if c == '#':  # comment-only line
                while self->i < self->n and self->cur() != '\n':
                    self->i += 1
                c = self->cur()
            if c == '\r' and self->peek(1) == '\n':
                self->i += 1
                c = self->cur()
            if c == '\n':  # blank line
                self->i += 1
                self->line += 1
                self->line_start = self->i
                continue
            if self->i >= self->n:
                return  # EOF: trailing dedents are handled outside

            # line with content: measures the column and compares with the stack
            self->i = save
            col = 0
            while True:
                d: u32 = self->cur()
                if d == ' ':
                    col += 1
                    self->i += 1
                elif d == '\t':
                    col += 8 - (col % 8)
                    self->i += 1
                else:
                    break
            top: i32 = self->indents[self->nindents - 1]
            p: Pos = self->here()
            if col > top:
                if self->nindents >= MAX_INDENT:
                    fatal_at(self->file, p, "indentation too deep")
                self->indents[self->nindents] = col
                self->nindents += 1
                self->push_tok(TK_INDENT, p, None)
            else:
                while col < self->indents[self->nindents - 1]:
                    self->nindents -= 1
                    self->push_tok(TK_DEDENT, p, None)
                if col != self->indents[self->nindents - 1]:
                    fatal_at(self->file, p, "inconsistent indentation")
            return

    # lexes the literal body assuming self->i is positioned ON the opening quote;
    # the token text goes from `start` (which may include an L/u/U/u8 prefix) to
    # the end, verbatim — the C backend emits it as-is, and QBE decodes the wide.
    static def lex_str_at(self: *Lx, start: usize, p: Pos, quote: u32, kind: TokKind):
        self->i += 1  # open quote
        while True:
            c: u32 = self->cur()
            if self->i >= self->n or c == '\n':
                fatal_at(self->file, p, "unterminated literal (missing %c)", char(quote))
            if c == '\\':
                self->i += 2  # escape: copy verbatim
                continue
            self->i += 1
            if c == quote:
                break
        self->push_tok(kind, p, self->slice(start, self->i))

    static def lex_string(self: *Lx, quote: u32, kind: TokKind):
        self->lex_str_at(self->i, self->here(), quote, kind)

    static def lex_number(self: *Lx):
        p: Pos = self->here()
        start: usize = self->i
        if self->cur() == '0' and (self->peek(1) == 'x' or self->peek(1) == 'X'):
            self->i += 2
            if not is_hex(self->cur()):
                fatal_at(self->file, p, "invalid hexadecimal number")
            while is_hex(self->cur()):
                self->i += 1
        else:
            while is_digit(self->cur()):
                self->i += 1
            if self->cur() == '.' and is_digit(self->peek(1)):
                self->i += 1
                while is_digit(self->cur()):
                    self->i += 1
            if self->cur() == 'e' or self->cur() == 'E':
                save: usize = self->i
                self->i += 1
                if self->cur() == '+' or self->cur() == '-':
                    self->i += 1
                if is_digit(self->cur()):
                    while is_digit(self->cur()):
                        self->i += 1
                else:
                    self->i = save  # wasn't an exponent
        # C suffixes (u, l, f) are passed through verbatim
        while self->cur() == 'u' or self->cur() == 'U' or self->cur() == 'l' or self->cur() == 'L' or self->cur() == 'f' or self->cur() == 'F':
            self->i += 1
        self->push_tok(TK_NUMBER, p, self->slice(start, self->i))

    static def lex_op(self: *Lx):
        p: Pos = self->here()
        c: u32 = self->cur()
        c1: u32 = self->peek(1)
        c2: u32 = self->peek(2)
        k: TokKind = TK_EOF  # always overwritten; error cases call fatal_at
        len = 1

        match c:
            case '(':
                k = TK_LPAREN
                self->paren += 1
            case ')':
                k = TK_RPAREN
                self->paren -= 1
            case '[':
                k = TK_LBRACKET
                self->paren += 1
            case ']':
                k = TK_RBRACKET
                self->paren -= 1
            case '{':
                k = TK_LBRACE
                self->paren += 1
            case '}':
                k = TK_RBRACE
                self->paren -= 1
            case ',':
                k = TK_COMMA
            case ':':
                k = TK_COLON
            case ';':
                k = TK_SEMI
            case '.':
                if c1 == '.' and c2 == '.':
                    k = TK_ELLIPSIS; len = 3
                else:
                    k = TK_DOT
            case '~':
                k = TK_TILDE
            case '+':
                if c1 == '=':
                    k = TK_PLUS_EQ; len = 2
                else:
                    k = TK_PLUS
            case '-':
                if c1 == '>':
                    k = TK_ARROW; len = 2
                elif c1 == '=':
                    k = TK_MINUS_EQ; len = 2
                else:
                    k = TK_MINUS
            case '*':
                if c1 == '=':
                    k = TK_STAR_EQ; len = 2
                else:
                    k = TK_STAR
            case '/':
                if c1 == '=':
                    k = TK_SLASH_EQ; len = 2
                else:
                    k = TK_SLASH
            case '%':
                if c1 == '=':
                    k = TK_PERCENT_EQ; len = 2
                else:
                    k = TK_PERCENT
            case '&':
                if c1 == '=':
                    k = TK_AMP_EQ; len = 2
                else:
                    k = TK_AMP
            case '|':
                if c1 == '=':
                    k = TK_PIPE_EQ; len = 2
                else:
                    k = TK_PIPE
            case '^':
                if c1 == '=':
                    k = TK_CARET_EQ; len = 2
                else:
                    k = TK_CARET
            case '=':
                if c1 == '=':
                    k = TK_EQ; len = 2
                else:
                    k = TK_ASSIGN
            case '<':
                if c1 == '<' and c2 == '=':
                    k = TK_SHL_EQ; len = 3
                elif c1 == '<':
                    k = TK_SHL; len = 2
                elif c1 == '=':
                    k = TK_LE; len = 2
                else:
                    k = TK_LT
            case '>':
                if c1 == '>' and c2 == '=':
                    k = TK_SHR_EQ; len = 3
                elif c1 == '>':
                    k = TK_SHR; len = 2
                elif c1 == '=':
                    k = TK_GE; len = 2
                else:
                    k = TK_GT
            case '!':
                if c1 == '=':
                    k = TK_NE; len = 2
                else:
                    fatal_at(self->file, p, "'!' does not exist in P — use 'not'")
            case _:
                fatal_at(self->file, p, "unexpected character (U+%04X)", c)
        self->i += usize(len)
        self->push_tok(k, p, None)

def lex(file: const *char, bytes: const *char, nbytes: usize, a: *Arena) -> TokenList:
    lx: Lx = {0}
    lx.file = file
    lx.bytes = bytes
    lx.nbytes = nbytes
    lx.a = a
    lx.line = 1
    lx.indents[0] = 0
    lx.nindents = 1

    err_off: usize = 0
    if utf8_decode(bytes, nbytes, a, &lx.cp, &lx.off, &lx.n, &err_off) != 0:
        fatal("%s: invalid UTF-8 byte at offset %zu", file, err_off)

    # handles the indentation of the first line
    lx.lex_newline_and_indent()

    while lx.i < lx.n:
        c: u32 = lx.cur()

        if c == ' ' or c == '\t' or c == '\r':
            lx.i += 1
            continue
        if c == '#':
            while lx.i < lx.n and lx.cur() != '\n':
                lx.i += 1
            continue
        if c == '\n':
            lx.i += 1
            lx.line += 1
            lx.line_start = lx.i
            if lx.paren == 0:
                np: Pos = {lx.line - 1, 1}
                lx.push_tok(TK_NEWLINE, np, None)
                lx.lex_newline_and_indent()
            continue
        if lx.prev_import and c == '<':
            p: Pos = lx.here()
            lx.i += 1
            start: usize = lx.i
            while lx.i < lx.n and lx.cur() != '>' and lx.cur() != '\n':
                lx.i += 1
            if lx.cur() != '>':
                fatal_at(lx.file, p, "unterminated header (missing '>')")
            text: const *char = lx.slice(start, lx.i)
            lx.i += 1  # '>'
            lx.push_tok(TK_HEADER, p, text)
            continue
        # wide/unicode literal prefixes: L"..." u"..." U"..." u8"..." and
        # L'x' u'x' U'x'. The prefix goes into the token text and the backend handles it.
        if c == 'L' or c == 'u' or c == 'U':
            plen: usize = 1
            if c == 'u' and lx.peek(1) == '8':
                plen = 2
            q: u32 = lx.peek(plen)
            if q == '"' or (q == '\'' and plen == 1):
                pstart: usize = lx.i
                pp: Pos = lx.here()
                lx.i += plen  # consume the prefix; now on the quote
                k: TokKind = TK_STRING if q == '"' else TK_CHARLIT
                lx.lex_str_at(pstart, pp, q, k)
                continue
        if is_ident_start(c):
            p: Pos = lx.here()
            start: usize = lx.i
            while is_ident_cont(lx.cur()):
                lx.i += 1
            if lx.cur() >= 128:
                fatal_at(lx.file, lx.here(), "identifiers must be ASCII ([A-Za-z0-9_])")
            text: const *char = lx.slice(start, lx.i)
            k: TokKind = TK_IDENT
            j = 0
            while keywords[j].word != None:
                if strcmp(text, keywords[j].word) == 0:
                    k = keywords[j].kind
                    break
                j += 1
            lx.push_tok(k, p, text)
            continue
        if c >= 128:
            fatal_at(lx.file, lx.here(), "Unicode character outside string/comment (U+%04X)", c)
        if is_digit(c):
            lx.lex_number()
            continue
        if c == '"':
            lx.lex_string('"', TK_STRING)
            continue
        if c == '\'':
            lx.lex_string('\'', TK_CHARLIT)
            continue
        lx.lex_op()

    # end of file: closes the last line and pops the indentation
    end: Pos = {lx.line, i32(lx.i - lx.line_start) + 1}
    if not lx.toks.is_empty() and lx.toks.last().kind != TK_NEWLINE and lx.toks.last().kind != TK_DEDENT:
        lx.push_tok(TK_NEWLINE, end, None)
    while lx.nindents > 1:
        lx.nindents -= 1
        lx.push_tok(TK_DEDENT, end, None)
    lx.push_tok(TK_EOF, end, None)

    tl: TokenList = {lx.toks.data, usize(lx.toks.len)}
    return tl
