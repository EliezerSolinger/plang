"""`nonlocal` inside a `try` — the value has to survive the block.

64.1 gave pscript P's rule: a name declared inside a block dies with the block,
and `nonlocal` is the opt-in that pins it to the function. The compiler even says
so in the error. So a `nonlocal` that the compiler then LOSES is worse than no
`nonlocal` at all — the diagnostic sends you straight at it.

And `try` was the one block where it was lost. The body's declarations are
hoisted to the try's own block (they have to be: each statement is wrapped in
`if <flag>:`, and a P block is a scope), and the hoist did not ask whether the
name was already function-scoped. It declared a second one, the assignment went
into that, and the outer name kept the zero it was born with:

    def f() -> int:
        nonlocal n
        try:
            n = 300
        catch e:
            return -1
        return n        # <- was 0

Silently. Which is how `.pstudio.json` came back with every setting at zero and
a segmentation fault on the first string.
"""


def in_try() -> int:
    nonlocal n
    try:
        n = 5
    catch e:
        return -1
    return n


def in_finally() -> int:
    # the finally is P's `defer` and runs at the END of the try's own block, so
    # it was assigning the shadow too
    nonlocal n
    try:
        n = 70
    finally:
        n = 7
    return n


def a_string() -> str:
    # the integer case came back zero; a collected type came back NULL, which is
    # a segmentation fault at the first use rather than a wrong answer
    nonlocal s
    try:
        s = "kept"
    catch e:
        return "-"
    return s


def nested() -> int:
    nonlocal n
    try:
        try:
            n = 11
        catch e:
            n = -1
    catch e2:
        return -2
    return n


def after_a_raise() -> int:
    # the flag model skips the rest of the body, so the assignment before the
    # raise must still be the one that survives
    nonlocal n
    n = 0
    try:
        n = 1
        raise error("stop")
        n = 2
    catch e:
        pass
    return n


def two_names() -> int:
    nonlocal a
    nonlocal b
    try:
        a = 3
        b = 4
    catch e:
        return -1
    return a * b


def still_dies() -> int:
    # and the OTHER half of the rule is unchanged: without `nonlocal` the name
    # still belongs to the try's block, which is what the hoist is for — two
    # statements of the body can share it
    total = 0
    try:
        step = 6
        total = step * 7
    catch e:
        return -1
    return total


def a_list() -> int:
    nonlocal xs
    try:
        xs = [1, 2, 3]
    catch e:
        return -1
    xs.append(4)
    return len(xs)


def unpack_in_if() -> int:
    # and the OTHER half of the same defect: the unpacking lowered its names
    # without ever asking the `nonlocal` list, in ANY block. That one did not go
    # quiet — it failed to compile, with `use of undeclared identifier` at the
    # line that read the name back.
    nonlocal a
    nonlocal b
    if True:
        a, b = 10, 20
    return a + b


def unpack_in_try() -> str:
    nonlocal s
    nonlocal n
    try:
        s, n = "kept", 2
    catch e:
        return "-"
    return s + str(n)


def unpack_plain() -> int:
    # unchanged: no `nonlocal`, so both names belong to the function's own body
    c, d = 5, 6
    return c * d


print("try=" + str(in_try()))
print("finally=" + str(in_finally()))
print("string=[" + a_string() + "]")
print("nested=" + str(nested()))
print("after a raise=" + str(after_a_raise()))
print("two names=" + str(two_names()))
print("block scope still dies=" + str(still_dies()))
print("list=" + str(a_list()))
print("unpack in if=" + str(unpack_in_if()))
print("unpack in try=[" + unpack_in_try() + "]")
print("unpack plain=" + str(unpack_plain()))
