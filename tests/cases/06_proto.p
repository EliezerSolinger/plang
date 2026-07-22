# protótipos manuais (spec §5.1) + enum + goto/label
include <stdio.h>

enum Color:
    RED = 1
    GREEN
    BLUE

def par(n: int) -> bool

def impar(n: int) -> bool:
    return not par(n)

def par(n: int) -> bool:
    return n % 2 == 0

def main() -> int:
    printf("%d %d\n", par(4), impar(4))
    printf("%d %d %d\n", RED, GREEN, BLUE)
    c: Color = GREEN
    if c == GREEN:
        printf("verde\n")
    k: int = 0
    denovo:
    k += 1
    if k < 3:
        goto denovo
    printf("k=%d\n", k)
    return 0
