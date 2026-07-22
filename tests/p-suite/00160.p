include <stdio.h>

def main() -> int:
    a: int = 1
    p: int = 0
    t: int = 0
    while a < 100:
        printf("%d\n", a)
        t = a
        a = t + p
        p = t
    return 0
