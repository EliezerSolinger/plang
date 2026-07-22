include <stdio.h>

def main() -> int:
    Count: int
    for Count in range(0, 4):
        printf("%d\n", Count)
        match Count:
            case 1:
                printf("%d\n", 1)
            case 2:
                printf("%d\n", 2)
            case _:
                printf("%d\n", 0)

    return 0
