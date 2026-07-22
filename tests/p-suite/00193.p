include <stdio.h>

def fred(x: int) -> void:
    match x:
        case 1:
            printf("1\n")
            return
        case 2:
            printf("2\n")
        case 3:
            printf("3\n")
            return
    printf("out\n")

def main() -> int:
    fred(1)
    fred(2)
    fred(3)
    return 0
