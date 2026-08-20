"""The stack an error carries (15.2/34.2), and the zero value that made it safe.

Two things live in this file because one found the other.

**The trace.** An error captures the shadow stack where it is RAISED — by the
time anyone reports it the stack has unwound — and each frame that belongs to a
FUNCTION carries its name and file. A function with nothing collected in it has
no frame at all (the leaf optimisation of 49.4), so it cannot be named: what is
printed is what the shadow stack knew, never a guess. `--trace` gives every
function a frame and names them all, at the price of a push and a pop per call.

**The zero value.** Writing the test above crashed the compiler's own output,
and the cause was older than the trace: a function that RAISES returns the zero
value of its type, and for a collected type that zero was NULL. The caller is
mid-expression when it gets it — `t + deep(n)` hands the result straight to
`ps_str_concat` — and 49.2's promise that "every later call does nothing" holds
only for calls that CHECK. A runtime call that dereferences its argument does
not check, so the NULL was a segfault instead of a pending exception.

Now the zero of a collected type is a valid EMPTY object: one bump allocation on
a path that is about to unwind, and the invariant fits in a sentence.
"""


def raises(tag: str) -> str:
    return tag + " " + str(10 // (len(tag) - len(tag)))


def caught() -> str:
    try:
        # the raise happens INSIDE the concatenation, which is the shape that
        # used to take the process down
        return "before " + raises("x") + " after"
    catch e:
        return "caught: " + e.message


print(caught())


def deeper(n: int) -> str:
    s = "d"
    return s + raises("inner")


def middle(n: int) -> str:
    t = "m"
    return t + deeper(n)


print(middle(3))
print("never reached")
