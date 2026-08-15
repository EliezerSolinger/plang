include "stdio.h"

struct Pt:
    x: i32
    y: i32

g: Pt = {10, 20}

def bump(ref v: i32):
    v += 1

def pick(a: *Pt) -> ref Pt:
    if a != None:
        return *a
    return g

def gref() -> ref Pt:
    return g

def main() -> i32:
    # bind to a local place; store-through; auto-deref reads
    n: i32 = 5
    r: ref i32 = n
    r = 7
    printf("n=%d r=%d\n", n, r)
    # bind to a field
    fx: ref i32 = g.x
    fx = 99
    printf("gx=%d\n", g.x)
    # ref forwards into the byref trio
    bump(ref r)
    printf("after bump n=%d\n", n)
    # bind from a raw pointer under proof
    p: *Pt = &g
    if p != None:
        rp: ref Pt = *p
        rp.y = 44
    printf("gy=%d\n", g.y)
    # ref-returning call: value copy, field access, rebind chain
    c: Pt = gref()
    printf("copy=%d,%d\n", c.x, c.y)
    printf("direct=%d\n", gref().x)
    rr: ref Pt = pick(None)
    rr.x = 123
    printf("gx2=%d\n", g.x)
    # ?? on pointers, single evaluation
    q: *Pt = None
    w: *Pt = q ?? &g
    printf("wx=%d\n", w.x)
    q2: *Pt = &g
    fb: Pt = {1, 2}
    w2: *Pt = q2 ?? &fb
    printf("w2x=%d\n", w2.x)
    return 0
