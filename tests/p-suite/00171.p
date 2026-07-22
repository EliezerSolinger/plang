include <stdio.h>

def main() -> int:
    a: int
    b: *int
    c: *int

    a = 42
    b = &a
    c = None

    printf("%d\n", *b)

    if b == None:
        printf("b is NULL\n")
    else:
        printf("b is not NULL\n")

    if c == None:
        printf("c is NULL\n")
    else:
        printf("c is not NULL\n")

    return 0
