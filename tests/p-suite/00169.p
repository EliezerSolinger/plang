include <stdio.h>

def main() -> int:
    x: int
    y: int
    z: int
    for x in range(0, 2):
        for y in range(0, 3):
            for z in range(0, 3):
                printf("%d %d %d\n", x, y, z)
    return 0
