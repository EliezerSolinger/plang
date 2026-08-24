# cfront.ph — C frontend (F3): reads C that has ALREADY BEEN PREPROCESSED
# (ucpp output) and produces the SAME AST as plang (ast.ph), to be consumed
# by the same backends (C and QBE). Goal: plangc compiles P and C alike.
#
# Initial slice: functions, params, locals, int/char/void/pointers/arrays,
# return/if/else/while/for(lowered)/blocks, calls, literals, operators.
# Pending: typedef, full struct/union, function pointers, switch,
# storage classes, the full C type system (signed/unsigned widths).
import "plang.ph"
import "ast.ph"

# strict=True: the file is USER code — C constraint violations are errors.
# strict=False: ingested system headers — GNU noise is skipped tolerantly.
def c_parse(a: *Arena, file: const *char, bytes: const *char, nbytes: usize, strict: bool) -> *Module

# value of a C char literal ('a', '\n', '\x41', '\012') — the single source of
# truth for escapes (sema's comptime folding delegates here)
def cchar_val(lex: const *char) -> i32


# ---------- the tokens, for whoever wants to DISPLAY C ----------
#
# The editor paints what the COMPILER sees, in all three languages: P and pscript
# go through `lex_ex` and C goes through here. A second lexer written to display
# would drift from this one, and the day it did, the colours would stop meaning
# what the compiler means.
#
# Two kinds exist only for display. The parser's tokenizer EATS comments and
# preprocessor lines, because a parser has no use for them; `c_lex_display` emits
# them instead, and that is the whole difference between the two modes. The
# parser never sees them, because it never asks for them.
enum CtKind:
    CT_EOF = 0
    CT_ID
    CT_NUM
    CT_STR
    CT_CHAR
    CT_PUNCT
    CT_COMMENT      # display only: `//...` and `/*...*/`
    CT_PP           # display only: a `#` line, directive or marker

struct CTok:
    kind: CtKind
    text: const *char
    pos: Pos

struct CTokList:
    toks: *CTok
    n: usize

# Lexes for DISPLAY: tolerant (never fatal — an editor buffer is half-written by
# definition) and with comments and `#` lines kept. The tokens live in the arena.
def c_lex_display(a: *Arena, file: const *char, bytes: const *char, nbytes: usize) -> CTokList

# "is this WORD in this space-separated list" — the front end's own lookup, and
# the same one the display side needs. C has no single table of keywords to
# borrow: the parser recognises them where they matter, contextually. So the
# highlighter writes its own list, and at least asks the question the same way.
def word_in(s: const *char, w: const *char) -> bool
