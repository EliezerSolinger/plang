include <stdio.h>

def main() -> int:
    printf("%d\n", '\1')
    printf("%d\n", '\10')
    printf("%d\n", '\100')
    printf("%d\n", '\x01')
    printf("%d\n", '\x0e')
    printf("%d\n", '\x10')
    printf("%d\n", '\x40')
    printf("test \x40\n")

    return 0
