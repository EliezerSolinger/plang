struct S1:
    x: int

struct S2:
    s1: S1

def main() -> int:
    s2: S2
    s2.s1.x = 1
    return 0
