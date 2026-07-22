struct S:
    a: int
    b: int

s: S = {1, 2}

def main() -> int:
    if s.a != 1:
        return 1
    if s.b != 2:
        return 2
    return 0
