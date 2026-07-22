include <stdio.h>

fred: int = 1234
joe: int
henry_fred: int = 4567

def henry() -> void:
    printf("%d\n", henry_fred)
    henry_fred += 1

def main() -> int:
    printf("%d\n", fred)
    henry()
    henry()
    henry()
    henry()
    printf("%d\n", fred)
    fred = 8901
    joe = 2345
    printf("%d\n", fred)
    printf("%d\n", joe)
    return 0
