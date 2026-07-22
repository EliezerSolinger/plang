x: int = 10

struct S:
    a: int
    p: *int

s: S = {1, &x}

def main() -> int:
    if s.a != 1:
        return 1
    if *s.p != 10:
        return 2
    return 0
