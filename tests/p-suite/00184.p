include <stdio.h>

def main() -> int:
    a: char
    b: short

    printf("%d %d\n", sizeof(char), sizeof(a))
    printf("%d %d\n", sizeof(short), sizeof(b))

    return 0
