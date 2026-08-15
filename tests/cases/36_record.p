# `record` (65.1): a struct the compiler CHECKS to be pure bytes — no pointer
# anywhere inside. The guarantee costs nothing at run time and is what makes a
# value safe to copy, write out and compare as itself.
include <stdio.h>

record Vec:
    x: f64
    y: f64

    def dot(self: Vec, b: Vec) -> f64:
        return self.x * b.x + self.y * b.y

record Ray:
    org: Vec              # a record inside a record stays pure bytes
    dir: Vec
    hits: i32[3]          # and so does a fixed array of them

# a struct is what holds a pointer; the two coexist and the rule is one line
struct Node:
    next: *Node
    tag: i32


def show(v: Vec):
    printf("(%g, %g)\n", v.x, v.y)


def add(a: Vec, b: Vec) -> Vec:
    return Vec(a.x + b.x, a.y + b.y)


def main() -> int:
    # the constructor: positional and named. Before this, P had no way to write
    # an aggregate VALUE inline — it needed a variable to live in.
    show(Vec(1.0, 2.0))
    show(Vec(y=4.0, x=3.0))
    show(add(Vec(1.0, 1.0), Vec(2.0, 3.0)))

    v: Vec = Vec(5.0, 6.0)
    w: Vec = {5.0, 6.0}          # the brace form keeps working
    printf("dot=%g\n", v.dot(w))

    # `==` compares CONTENT, field by field — never memcmp, because the padding
    # a C compiler inserts holds whatever was on the stack
    printf("%d %d\n", i32(v == w), i32(v != Vec(0.0, 0.0)))

    r: Ray = {{0.0, 0.0}, {1.0, 0.0}, {1, 2, 3}}
    s: Ray = {{0.0, 0.0}, {1.0, 0.0}, {1, 2, 3}}
    t: Ray = {{0.0, 0.0}, {1.0, 0.0}, {1, 2, 9}}
    printf("%d %d\n", i32(r == s), i32(r == t))

    n: Node = {None, 7}
    printf("tag=%d\n", n.tag)
    return 0
