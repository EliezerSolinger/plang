include <stdio.h>

def charfunc(a: char) -> void:
    printf("char: %c\n", a)

def intfunc(a: int) -> void:
    printf("int: %d\n", a)

def floatfunc(a: float) -> void:
    printf("float: %f\n", a)

def main() -> int:
    charfunc('a')
    charfunc(98)
    charfunc(99.0)

    intfunc('a')
    intfunc(98)
    intfunc(99.0)

    floatfunc('a')
    floatfunc(98)
    floatfunc(99.0)

    b: char = 97
    c: char = 97.0

    printf("%d %d\n", b, c)

    d: int = 'a'
    e: int = 97.0

    printf("%d %d\n", d, e)

    f: float = 'a'
    g: float = 97

    printf("%f %f\n", f, g)

    return 0
