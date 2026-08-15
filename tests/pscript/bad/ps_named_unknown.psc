# a named argument has to name a parameter (44.1)
def f(a: int, b: int = 2) -> int:
    return a + b
n = f(1, c=3)
