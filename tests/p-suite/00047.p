struct S:
    a: int
    b: int
    c: int

s: S = {1, 2, 3}

def main() -> int:
    if s.a != 1:
        return 1
    if s.b != 2:
        return 2
    if s.c != 3:
        return 3

    return 0
