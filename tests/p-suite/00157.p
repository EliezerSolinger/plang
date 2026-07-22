include <stdio.h>

def main() -> int:
    Array: int[10]
    Count: int
    for Count in range(1, 11):
        Array[Count - 1] = Count * Count
    for Count in range(10):
        printf("%d\n", Array[Count])
    return 0
