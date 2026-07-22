include <stdio.h>

def myfunc(x: int) -> int:
    return x * x

def vfunc(a: int) -> void:
    printf("a=%d\n", a)

def qfunc() -> void:
    printf("qfunc()\n")

def main() -> int:
    printf("%d\n", myfunc(3))
    printf("%d\n", myfunc(4))

    vfunc(1234)

    qfunc()

    return 0
