include <stdio.h>

def main() -> int:
    Count: int = 0

    while True:
        Count += 1
        printf("%d\n", Count)
        if Count >= 10:
            break

    return 0
