include <stdio.h>

def main() -> int:
    a: int
    b: char
    a = 0
    while a < 2:
        printf("%d", a)
        a += 1
        break
        b = 'A'
        while b < 'C':
            printf("%c", b)
            b += 1
        printf("e")
    printf("\n")
    return 0
