struct S1:
    a: int
    b: int

struct S2:
    s1: S1
    ps1: *S1
    arr: int[2]

gs1: S1 = {1, 2}
gs2: S2 = {{1, 2}, &gs1, {1, 2}}
s: *S2 = &gs2

def main() -> int:
    if s->s1.a != 1:
        return 1
    if s->s1.b != 2:
        return 2
    if s->ps1->a != 1:
        return 3
    if s->ps1->b != 2:
        return 4
    if s->arr[0] != 1:
        return 5
    if s->arr[1] != 2:
        return 6
    return 0
