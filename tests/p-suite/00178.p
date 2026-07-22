include <stdio.h>

def main() -> int:
    a: char
    b: int
    c: double

    printf("%d\n", sizeof(a))
    printf("%d\n", sizeof(b))
    printf("%d\n", sizeof(c))

    printf("%d\n", sizeof(not a))

    return 0
