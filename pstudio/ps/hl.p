# hl.p — o adaptador (ver hl.ph). Lexa com o lexer do compilador e responde em
# números; a lógica de realce e de completamento mora no pscript.
include <stdlib.h>
include <string.h>
import "hl.ph"
import "../../selfhost/lexer.ph"

implement CStr

# um token, só com o que atravessa
struct HlTok:
    line: i32
    col: i32
    cp: i32
    cls: i32
    kind: i32

static g_toks: *HlTok = None
static g_n: i32 = 0
static g_cap: i32 = 0

static def cp_count(s: const *char) -> i32:
    n: i32 = 0
    for i in range(strlen(s)):
        if (u8(s[i]) & 0xC0) != 0x80:
            n += 1
    return n

# a arena que o lexer tolerante enche (os blocos são malloc puro)
static def arena_drop_hl(a: *Arena):
    blk: *ArenaBlock = a->head
    while blk != None:
        nx: *ArenaBlock = blk->next
        free(blk)
        blk = nx
    a->head = None

static def kind_of(k: TokKind) -> i32:
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

# a classe de EXIBIÇÃO: a mesma regra do `core.p` do editor em P — um token com
# lexema que não é identificador, número nem cadeia é palavra da linguagem, e
# pontuação (lexema nenhum) fica à parte
static def class_of(t: *Token) -> i32:
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
    # o lexer quer bytes terminados em zero, e o empréstimo do `CStr` é só o par
    # (ponteiro, comprimento): a cópia acontece aqui, uma vez por lexada — que é
    # o que o editor em P também fazia (`save_text`)
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
    # a lista de tokens é do CHAMADOR (lexer.ph) e os lexemas são da arena: os
    # dois vão embora aqui, porque o que se guarda são só os números copiados
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
