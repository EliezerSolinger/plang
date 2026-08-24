# hl.ph — THE COMPILER's lexer crossing the boundary, as scalars.
#
# 113: the editor's highlighting has always used the real lexer (`lex_ex` in
# tolerant mode), and that is what makes the editor paint what the COMPILER sees
# — not what a second lexer, written for display, would think. Migrating the
# editor to pscript does not change that decision: the lexer stays in P, and what
# crosses is scalar.
#
# Your decision (2026-08-21): *"I would have to make an interface/header/layer
# in the compiler in P for that, right"* — yes, and this is it, with two
# corrections relative to what that phrase suggests:
#
#   * it is NOT touching the compiler: the lexer is already a header
#     (`selfhost/lexer.ph`), and this file is an ADAPTER next to the editor, of
#     the same kind `shim.p` is for SDL;
#   * it is NOT a codepoint-by-codepoint conversation: a `CStr` (81/84/85) is a
#     pointer PLUS a length, as a value, and allocates nothing — the whole text
#     crosses in one call.
#
# What this adapter does NOT do, on purpose: classify comments, build per-line
# spans, recover declarations, rank candidates. That is LOGIC and lives in
# pscript (`lib_hl.psc`, `lib_complete.psc`). Here it only lexes and states
# numbers — and a token's text does not come back: whoever wants an identifier's
# name slices their own text by (line, column, length), which they already have.
include <stddef.h>
import <stl/cstr.ph>

# ---- the DISPLAY classes ----
HLC_TEXT: const i32 = 0
HLC_KW: const i32 = 1
HLC_STR: const i32 = 2
HLC_NUM: const i32 = 3
HLC_PUNCT: const i32 = 4
# The two below only ever come out of `hl_lex_c`. On the P side the lexer eats
# comments, so the pscript layer finds the `#` itself; on the C side the tokenizer
# can hand them over, and there is no reason to look for `/*` twice.
HLC_COMMENT: const i32 = 5
HLC_PP: const i32 = 6          # a `#` line: `#include`, `#define`, `#if`

# ---- the `kind`s completion needs to tell apart (the rest is OTHER) ----
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

# Lexes the whole text and KEEPS the tokens until the next call (`strerror`'s
# convention, which is the same as 84's `pmod_text`: nothing for anybody to
# free). Returns how many tokens came out.
#
# TWO doors, because there are two lexers and both are the compiler's: `hl_lex`
# is P and pscript, `hl_lex_c` is C. What comes back is the same numbers, so the
# layer above picks the door by extension and then stops caring which language it
# is looking at.
def hl_lex(in text: CStr) -> i32
def hl_lex_c(in text: CStr) -> i32
# (line, column, length) ZERO-based and in CODEPOINTS — which is the unit the
# editor measures in, because `len(s)` in pscript is codepoints (3.4)
def hl_tok_line(i: i32) -> i32
def hl_tok_col(i: i32) -> i32
def hl_tok_cp(i: i32) -> i32
def hl_tok_class(i: i32) -> i32
def hl_tok_kind(i: i32) -> i32
# releases what the last lex kept (the editor calls this when it closes the file)
def hl_release()
