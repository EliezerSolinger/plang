include <stdio.h>

enum fred:
    a
    b
    c
    d
    e = 54
    f = 73
    g
    h

enum Epositive:
    epos_one
    epos_two

def deref_uintptr(p: *unsigned int) -> unsigned int:
    return *p

def main() -> int:
    frod: fred
    epos: Epositive = epos_two

    printf("%d %d %d %d %d %d %d %d\n", a, b, c, d, e, f, g, h)
    frod = 12
    printf("%d\n", frod)
    frod = e
    printf("%d\n", frod)

    printf("enum to int: %u\n", deref_uintptr(&epos))

    return 0
