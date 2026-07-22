include <stdio.h>

def main() -> int:
    x: int = 'a'
    y: char = x

    a: *char = "hello"

    printf("%s\n", a)

    c: int
    c = *a

    b: *char
    b = a
    while *b != 0:
        printf("%c: %d\n", *b, *b)
        b += 1

    destarray: char[10]
    dest: *char = &destarray[0]
    src: *char = a

    while *src != 0:
        *dest = *src
        dest += 1
        src += 1

    *dest = 0

    printf("copied string is %s\n", destarray)

    return 0
