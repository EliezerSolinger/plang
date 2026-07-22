include <stdio.h>
import "geometria.ph"

def main() -> int:
    a: Point
    a.x = 0
    a.y = 0
    b: Point
    b.x = 3
    b.y = 4
    a.move(1, 1)
    printf("%d\n", dist(&a, &b))
    return 0
