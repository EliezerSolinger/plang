# `with` on an RVALUE. Pascal semantics say the target is evaluated exactly
# once, so it has to be materialized into a temporary: `&make()` is not C. The C
# backend used to emit that and let the C compiler reject it (the QBE backend
# refused outright) — the two backends disagreed, and the C one miscompiled.
#
# Also pins the parenthesisation: the materialization is a comma expression, and
# a declaration's initializer is an assignment-expression in the C grammar, so
# `T *p = a, &b;` without parens would parse as a DECLARATOR LIST.
include <stdio.h>

struct Pt:
    x: i32
    y: i32

calls: i32 = 0

def make() -> Pt:
    calls += 1
    p: Pt = {1, 2}
    return p

def main() -> i32:
    with make():
        .x = 10
        .y = .x * 2
        printf("%d %d\n", .x, .y)
    # an lvalue target still takes its address directly (no temporary)
    q: Pt = {3, 4}
    with q:
        .x += 1
    printf("calls=%d q=%d,%d\n", calls, q.x, q.y)
    return 0
