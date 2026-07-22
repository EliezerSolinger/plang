# defer: roda na saída do bloco (fim, return, break, continue), em LIFO
include <stdio.h>
include <stdlib.h>

def f(x: int) -> int:
    printf("inicio\n")
    defer printf("defer 1\n")
    defer:
        printf("defer 2a\n")
        printf("defer 2b\n")
    if x > 0:
        defer printf("defer if\n")
        printf("dentro if\n")
    i: int
    for i in range(4):
        defer printf("defer loop %d\n", i)
        if i == 1:
            continue
        if i == 3:
            break
        printf("i=%d\n", i)
    if x > 1:
        return x * 10
    printf("fim\n")
    return 0

def aloca() -> int:
    p: *int = malloc(4 * sizeof(int))
    defer free(p)
    p[0] = 7
    return p[0]

def main() -> int:
    printf("ret=%d\n", f(2))
    printf("aloca=%d\n", aloca())
    return 0
