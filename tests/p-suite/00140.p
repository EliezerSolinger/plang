struct foo:
    i: int
    j: int
    k: int
    p: *char
    v: float

def f1(f: foo, p: *foo, n: int, ...) -> int:
    if f.i != p->i:
        return 0
    return p->j + n

def main() -> int:
    f: foo
    f.j = 1
    f.i = 1
    f1(f, &f, 2)
    f1(f, &f, 2, 1, f, &f)
    return 0
