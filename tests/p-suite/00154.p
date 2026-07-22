include <stdio.h>

struct fred:
    boris: int
    natasha: int

def main() -> int:
    bloggs: fred

    bloggs.boris = 12
    bloggs.natasha = 34

    printf("%d\n", bloggs.boris)
    printf("%d\n", bloggs.natasha)

    jones: fred[2]
    jones[0].boris = 12
    jones[0].natasha = 34
    jones[1].boris = 56
    jones[1].natasha = 78

    printf("%d\n", jones[0].boris)
    printf("%d\n", jones[0].natasha)
    printf("%d\n", jones[1].boris)
    printf("%d\n", jones[1].natasha)

    return 0
