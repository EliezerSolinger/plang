include <stdio.h>

def main() -> int:
    Count: int

    for Count in range(0, 10):
        printf("%d\n", (Count * Count) if Count < 5 else (Count * 3))

    return 0
