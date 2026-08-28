# protótipos manuais (spec §5.1) + enum + goto/label
include <stdio.h>

enum Color:
    RED = 1
    GREEN
    BLUE

def par(n: int) -> bool

def odd(n: int) -> bool:
    return not par(n)

def par(n: int) -> bool:
    return n % 2 == 0

def main() -> int:
    printf("%d %d\n", par(4), odd(4))
    printf("%d %d %d\n", RED, GREEN, BLUE)
    c: Color = GREEN
    if c == GREEN:
        printf("verde\n")
    k: int = 0
    again:
    k += 1
    if k < 3:
        goto again
    printf("k=%d\n", k)
    return 0
