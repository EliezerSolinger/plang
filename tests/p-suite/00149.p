struct S:
    a: int
    b: int

gs: S = {1, 2}
s: *S = &gs

def main() -> int:
    if s->a != 1:
        return 1
    if s->b != 2:
        return 2
    return 0
