struct S:
    x: int
    y: int

def main() -> int:
    s: S
    p: *S
    p = &s
    s.x = 1
    p->y = 2
    return p->y + p->x - 3
