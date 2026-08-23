"""The MODULE's docstring: a lone string, before everything else.

It goes into the tree and generates no code — a binary does not carry
documentation. Whoever reads it is the protocol's answer 5 (`--api`) and the IDE,
and that is why it comes out AFTER the interface hash: changing a text does not
change what its users see.

The rule is POSITIONAL, and it is the same one as pscript's and Python's: a lone
string as the first thing in a module, in a body, in a `struct`, in an `enum` or
in a `trait`. Anywhere else, `\"\"\"...\"\"\"` is just a string literal that spans
lines — which is also new in P, and is what the last function here uses.
"""
include <stdio.h>


def twice(x: i32) -> i32:
    """Twice x.

    The second line exists to prove that a docstring spans lines.
    """
    return x * 2


struct Point:
    """A pair of integers."""
    x: i32
    y: i32

    def sum(self: *Point) -> i32:
        """The sum of the two coordinates — a METHOD's docstring."""
        return self->x + self->y


enum Shape:
    """The shapes this module knows."""
    SHAPE_BOX = 1
    SHAPE_BALL = 2


def multiline() -> const *char:
    # here the triple string is NOT a docstring: it is not the first statement,
    # and what it is, is an ordinary string that spans lines
    n: i32 = 1
    s: const *char = """first
second"""
    return s if n == 1 else "other"


def main() -> int:
    p: Point = {3, 4}
    printf("%d %d %d\n", twice(21), p.sum(), SHAPE_BALL)
    printf("%s\n", multiline())
    return 0
