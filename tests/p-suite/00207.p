include <stdio.h>

def f1(argc: int) -> void:
    test: char[argc]
    if False:
        label:
        printf("boom!\n")
    old: int = argc
    argc -= 1
    if old == 0:
        return
    goto label

def f2() -> void:
    goto start
    a: int[1]
    b: int[1]
    c: int[1]
    start:
    a[0] = 0
    b[0] = 0
    c[0] = 0

def f3() -> void:
    printf("%d\n", printf("x1\n") if 0 else 11)
    printf("%d\n", 12 if 1 else printf("x2\n"))
    printf("%d\n", 0 and printf("x3\n"))
    printf("%d\n", 1 or printf("x4\n"))

def main() -> int:
    f1(2)
    f2()
    f3()
    return 0
