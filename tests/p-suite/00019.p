struct S:
    p: *S
    x: int

def main() -> int:
    s: S
    s.x = 0
    s.p = &s
    return s.p->p->p->p->p->x
