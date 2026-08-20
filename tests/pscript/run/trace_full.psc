"""The same file as `trace.psc`, built with `-g` (see the `.flags` file).

The flag gives EVERY pscript function a frame, so the trace names the ones that
hold nothing collected too — here `<main>`, which holds nothing at all. The
price is a push and a pop per call: on fib(35), the benchmark that is nothing
but calls, 0.03s becomes 0.05s. Everywhere else it is noise.
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
