# a descending `for` that REUSES an iterator promotes it to isize (an unsigned
# one would compile to `i > -1`, a loop that never runs)
include <stdio.h>

def main() -> i32:
    n: i32 = 4
    up: i32 = 0
    for i in range(n):
        up += i32(i)
    down: i32 = 0
    for i in range(n - 1, -1, -1):
        down += i32(i) * 10
    printf("%d %d\n", up, down)
    return 0
