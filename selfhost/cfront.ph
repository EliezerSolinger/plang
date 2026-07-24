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
