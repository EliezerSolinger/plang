def foo(x: int[100]) -> int:
    y: int[100]
    p: *int
    pv: *void
    y[0] = 2000
    if x[0] != 1000:
        return 1
    p = x
    if p[0] != 1000:
        return 2
    p = y
    if p[0] != 2000:
        return 3
    if sizeof(x) != sizeof(pv):
        return 4
    if sizeof(y) <= sizeof(x):
        return 5
    return 0

def main() -> int:
    x: int[100]
    x[0] = 1000
    return foo(x)
