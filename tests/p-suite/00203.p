include <stdio.h>

def main() -> int:
    res: long long = 0
    if res < -2147483648:
        printf("Error: 0 < -2147483648\n")
        return 1
    elif 2147483647 < res:
        printf("Error: 2147483647 < 0\n")
        return 2
    else:
        printf("long long constant test ok.\n")
    return 0
