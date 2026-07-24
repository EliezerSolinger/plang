# int[] = {...} infere o tamanho; len(); for v in xs; enumerate
include <stdio.h>

def main() -> int:
    xs: int[] = {5, 6, 7, 8}
    printf("%zu %d\n", len(xs), xs[3])
    total = 0
    for v in xs:
        total = total + v
    printf("%d\n", total)
    for i, v2 in enumerate(xs):
        if v2 == 7:
            printf("7@%zu\n", i)
    return 0
