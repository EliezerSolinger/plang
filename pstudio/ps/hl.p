# hl.p — the adapter (see hl.ph). Lexes with the compiler's lexer and answers in
# numbers; the highlighting and completion logic lives in pscript.
include <stdlib.h>
include <string.h>
import "hl.ph"
import "../../selfhost/lexer.ph"


# one token, with only what crosses
struct HlTok:
    line: i32
    col: i32
    cp: i32
    cls: i32
    kind: i32

private g_toks: *HlTok = None
private g_n: i32 = 0
private g_cap: i32 = 0

private def cp_count(s: const *char) -> i32:
    n: i32 = 0
    for i in range(strlen(s)):
        if (u8(s[i]) & 0xC0) != 0x80:
            n += 1
    return n

# the arena the tolerant lexer fills (the blocks are plain malloc)
private def arena_drop_hl(a: *Arena):
    blk: *ArenaBlock = a->head
    while blk != None:
        nx: *ArenaBlock = blk->next
        free(blk)
        blk = nx
    a->head = None

private def kind_of(k: TokKind) -> i32:
    match k:
        case TK_EOF:
            return HLK_EOF
        case TK_NEWLINE:
            return HLK_NEWLINE
        case TK_INDENT:
            return HLK_INDENT
        case TK_DEDENT:
            return HLK_DEDENT
        case TK_IDENT:
            return HLK_IDENT
        case TK_NUMBER:
            return HLK_NUMBER
        case TK_STRING:
            return HLK_STRING
        case TK_DEF:
            return HLK_DEF
        case TK_STRUCT:
            return HLK_STRUCT
        case TK_ENUM:
            return HLK_ENUM
        case TK_UNION:
            return HLK_UNION
        case TK_IMPORT:
            return HLK_IMPORT
        case TK_COLON:
            return HLK_COLON
        case TK_LPAREN:
            return HLK_LPAREN
        case TK_RPAREN:
            return HLK_RPAREN
        case TK_STAR:
            return HLK_STAR
        case TK_CONST:
            return HLK_CONST
        case _:
            return HLK_OTHER

# The DISPLAY class, decided structurally instead of from a word list: a token
# that carries a lexeme and is not an identifier, a number or a string is a word
# of the language, and punctuation (no lexeme) stands apart. That is why a new
# keyword — `private`, in 118 — colours itself with no edit here.
private def class_of(t: *Token) -> i32:
    if t->kind == TK_IDENT:
        return HLC_TEXT
    if t->kind == TK_NUMBER:
        return HLC_NUM
    if t->kind in {TK_STRING, TK_CHARLIT, TK_HEADER}:
        return HLC_STR
    if t->text == None:
        return HLC_PUNCT
    return HLC_KW

def hl_release():
    free(g_toks)
    g_toks = None
    g_n = 0
    g_cap = 0

def hl_lex(in text: CStr) -> i32:
    hl_release()
    # the lexer wants zero-terminated bytes, and a `CStr` borrow is only the pair
    # (pointer, length): the copy happens here, once per lex — which is what the
    # editor in P did too (`save_text`)
    buf: *char = malloc(text.len + 1)
    if buf == None:
        return 0
    memcpy(buf, text.ptr, text.len)
    buf[text.len] = '\0'
    a: Arena = {0}
    tl: TokenList = lex_ex("<buffer>", buf, text.len, &a, True)
    n: i32 = i32(tl.n)
    if n > 0:
        g_toks = (*HlTok)(malloc(usize(n) * sizeof(HlTok)))
        g_cap = n
    for i in range(n):
        t: *Token = &tl.toks[i]
        g_toks[g_n].line = t->pos.line - 1
        g_toks[g_n].col = t->pos.col - 1
        g_toks[g_n].cp = cp_count(t->text) if t->text != None else 1
        g_toks[g_n].cls = class_of(t)
        g_toks[g_n].kind = kind_of(t->kind)
        g_n += 1
    # the token list belongs to the CALLER (lexer.ph) and the lexemes to the
    # arena: both go away here, because what is kept is only the copied numbers
    free(tl.toks)
    arena_drop_hl(&a)
    free(buf)
    return g_n

def hl_tok_line(i: i32) -> i32:
    return g_toks[i].line if i >= 0 and i < g_n else 0

def hl_tok_col(i: i32) -> i32:
    return g_toks[i].col if i >= 0 and i < g_n else 0

def hl_tok_cp(i: i32) -> i32:
    return g_toks[i].cp if i >= 0 and i < g_n else 0

def hl_tok_class(i: i32) -> i32:
    return g_toks[i].cls if i >= 0 and i < g_n else HLC_TEXT

def hl_tok_kind(i: i32) -> i32:
    return g_toks[i].kind if i >= 0 and i < g_n else HLK_OTHER
