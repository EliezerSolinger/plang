# A statement expression with DECLARATIONS in a nested position. Standard C has
# no form for it (the comma operator only sequences expressions), and the C
# backend could only restructure a few statement-position shapes — anything
# deeper was a hard error telling you to use the QBE backend.
#
# Sema now hoists it: the block becomes a real statement in front of the
# enclosing one and the expression becomes a temporary. That works in every
# EAGER position and in all three modes (C, C89, QBE).
#
# It also covers a latent QBE bug the hoist exposed: the block is an ST_BLOCK,
# and QBE's local collection did not descend into one, so the inner declaration
# was never given a slot and the emitted code referenced the name as a GLOBAL
# symbol (a link error). A bare `{ int x; }` from C input failed the same way.
include <stdio.h>

def soma(a: i32, b: i32) -> i32:
    return a + b

def main() -> i32:
    # two of them in the SAME call: each gets its own temporary
    r: i32 = soma(({ t: i32 = 20; t + 1 }), ({ u: i32 = 20; u + 1 }))
    # both operands of a binary
    v: i32 = ({ w: i32 = 5; w * 2 }) + ({ z: i32 = 3; z })
    # inside an index
    a: i32[3] = {10, 20, 30}
    ix: i32 = a[({ k: i32 = 1; k + 1 })]
    # nested one inside another
    n: i32 = ({ outer: i32 = ({ inner: i32 = 3; inner * 2 }); outer + 1 })
    # several statements in one block. Control flow inside `({ ... })` is not
    # spellable in P at all: the '(' suppresses NEWLINE (implicit continuation),
    # so only ';' separates and a loop needs an indented block. That shape
    # reaches the AST only from ingested C.
    c: i32 = soma(1, ({ acc: i32 = 4; acc = acc * 2; acc + 1 }))
    printf("%d %d %d %d %d\n", r, v, ix, n, c)
    return 0
