include <stdio.h>

struct Point:
    x: i32
    y: i32
    z: i32

def main() -> i32:
    p: Point = { .x = 1, .z = 3 }
    a: i32[6] = { [0] = 10, [5] = 60, [2 ... 4] = 7 }
    printf("p=(%d,%d,%d)\n", p.x, p.y, p.z)
    printf("a=%d,%d,%d,%d,%d,%d\n", a[0], a[1], a[2], a[3], a[4], a[5])
    return 0
