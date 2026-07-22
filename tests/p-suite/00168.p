include <stdio.h>

def factorial(i: int) -> int:
    if i < 2:
        return i
    else:
        return i * factorial(i - 1)

def main() -> int:
    Count: int
    for Count in range(1, 11):
        printf("%d\n", factorial(Count))

    return 0
