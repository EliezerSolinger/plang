include <stdio.h>

def main() -> int:
    a: int
    b: int
    c: int
    d: int
    e: int
    f: int
    x: int
    y: int

    a = 12
    b = 34
    c = 56
    d = 78
    e = 0
    f = 1

    printf("%d\n", c + d)
    y = c + d
    printf("%d\n", y)
    printf("%d\n", e or e and f)
    printf("%d\n", e or f and f)
    printf("%d\n", e and e or f)
    printf("%d\n", e and f or f)
    printf("%d\n", a and f | f)
    printf("%d\n", a | b ^ c & d)
    printf("%d, %d\n", a == a, a == b)
    printf("%d, %d\n", a != a, a != b)
    printf("%d\n", a != b and c != d)
    printf("%d\n", a + b * c / f)
    printf("%d\n", a + b * c / f)
    printf("%d\n", (4 << 4))
    printf("%d\n", (64 >> 4))

    return 0
