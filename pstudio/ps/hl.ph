# hl.ph — o lexer DO COMPILADOR atravessando a fronteira, como escalares.
#
# 113: o realce do editor sempre usou o lexer de verdade (`lex_ex` em modo
# tolerante), e é isso que faz o editor pintar o que o COMPILADOR vê — não o que
# um segundo lexer, escrito para exibir, acharia. Migrar o editor para pscript
# não muda essa decisão: o lexer fica em P, e o que atravessa é escalar.
#
# Sua decisão (2026-08-21): *"eu teria que fazer uma interface/header/camada no
# compilador em P pra isso né"* — sim, e é esta, com duas correções em relação ao
# que eu tinha dito antes:
#
#   * NÃO é mexer no compilador: o lexer já é um header (`selfhost/lexer.ph`), e
#     este arquivo é um ADAPTADOR ao lado do editor, do mesmo tipo que o
#     `shim.p` é para o SDL;
#   * NÃO é conversa de codepoint em codepoint: o `CStr` (81/84/85) é ponteiro
#     MAIS comprimento, como valor, e não aloca nada — o texto inteiro atravessa
#     numa chamada.
#
# O que este adaptador NÃO faz, de propósito: classificar comentário, montar
# span por linha, recuperar declaração, ordenar candidato. Isso é LÓGICA e mora
# no pscript (`lib_hl.psc`, `lib_complete.psc`). Aqui só se lexa e se dizem
# números — e o texto do token não volta: quem quer o nome de um identificador
# fatia o próprio texto pela (linha, coluna, comprimento), que ele já tem.
include <stddef.h>
import <stl/cstr.ph>

# ---- as classes de EXIBIÇÃO ----
HLC_TEXT: const i32 = 0
HLC_KW: const i32 = 1
HLC_STR: const i32 = 2
HLC_NUM: const i32 = 3
HLC_PUNCT: const i32 = 4       # o comentário é do lado pscript: o lexer os come

# ---- os `kind` que o completamento precisa distinguir (o resto é OTHER) ----
HLK_OTHER: const i32 = 0
HLK_EOF: const i32 = 1
HLK_NEWLINE: const i32 = 2
HLK_INDENT: const i32 = 3
HLK_DEDENT: const i32 = 4
HLK_IDENT: const i32 = 5
HLK_NUMBER: const i32 = 6
HLK_STRING: const i32 = 7
HLK_DEF: const i32 = 8
HLK_STRUCT: const i32 = 9
HLK_ENUM: const i32 = 10
HLK_UNION: const i32 = 11
HLK_IMPORT: const i32 = 12
HLK_COLON: const i32 = 13
HLK_LPAREN: const i32 = 14
HLK_RPAREN: const i32 = 15
HLK_STAR: const i32 = 16
HLK_CONST: const i32 = 17

# Lexa o texto inteiro e GUARDA os tokens até a próxima chamada (a convenção do
# `strerror`, que é a mesma do `pmod_text` da 84: nada para ninguém liberar).
# Devolve quantos tokens saíram.
def hl_lex(in text: CStr) -> i32
# (linha, coluna, comprimento) em base ZERO e em CODEPOINTS — que é a unidade em
# que o editor mede, porque `len(s)` no pscript são codepoints (3.4)
def hl_tok_line(i: i32) -> i32
def hl_tok_col(i: i32) -> i32
def hl_tok_cp(i: i32) -> i32
def hl_tok_class(i: i32) -> i32
def hl_tok_kind(i: i32) -> i32
# solta o que a última lexada guardou (o editor chama quando fecha o arquivo)
def hl_release()
