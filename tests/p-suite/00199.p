include <stdio.h>

def fred() -> void:
    printf("In fred()\n")
    goto done
    printf("In middle\n")
    done:
    printf("At end\n")

def joe() -> void:
    b: int = 5678
    printf("In joe()\n")
    c: int = 1234
    printf("c = %d\n", c)
    goto outer
    printf("uh-oh\n")
    outer:
    printf("done\n")

def henry() -> void:
    a: int
    printf("In henry()\n")
    goto inner
    b: int
    inner:
    b = 1234
    printf("b = %d\n", b)
    printf("done\n")

def main() -> int:
    fred()
    joe()
    henry()
    return 0
