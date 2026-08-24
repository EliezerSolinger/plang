"""Returning a collection built in place, from a function that has a defer.

The bug this locks: a `return <list literal>` in a function with a defer becomes
`T tmp = <expr>;` in C, and the list literal lowers to a COMMA chain. Without
parentheses that comma is a DECLARATOR LIST — `PsList *tmp = (...), __lst0;`
declares a second variable and the program does not even compile. Every other
initializer in the back end was already emitted at assignment precedence; this
one was not.
"""


def three() -> List<int>:
    return [1, 2, 3]


def names() -> List<str>:
    return ["a", "b"]


xs = three()
ss = names()
print(f"{len(xs)} {xs[2]} {len(ss)} {ss[1]}")
