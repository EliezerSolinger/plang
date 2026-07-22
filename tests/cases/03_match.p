include <stdio.h>

def nome(x: int) -> *char:
    match x:
        case 0:
            return "zero"
        case 1, 2:
            return "poucos"
        case _:
            return "muitos"

def main() -> int:
    i: int
    for i in range(0, 4):
        printf("%d=%s\n", i, nome(i))
    # match sem default e sem fallthrough
    m: int = 0
    match m:
        case 0:
            m += 10
        case 1:
            m += 100
    printf("m=%d\n", m)
    return 0
