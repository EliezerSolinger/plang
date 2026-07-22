include <stdlib.h>

N: int
t: *int

def chk(x: int, y: int) -> int:
    i: int
    r: int

    r = 0
    for i in range(0, 8):
        r = r + t[x + 8*i]
        r = r + t[i + 8*y]
        if (x+i < 8) & (y+i < 8):
            r = r + t[x+i + 8*(y+i)]
        if (x+i < 8) & (y-i >= 0):
            r = r + t[x+i + 8*(y-i)]
        if (x-i >= 0) & (y+i < 8):
            r = r + t[x-i + 8*(y+i)]
        if (x-i >= 0) & (y-i >= 0):
            r = r + t[x-i + 8*(y-i)]
    return r

def go(n: int, x: int, y: int) -> int:
    if n == 8:
        N += 1
        return 0
    while y < 8:
        while x < 8:
            if chk(x, y) == 0:
                t[x + 8*y] += 1
                go(n+1, x, y)
                t[x + 8*y] -= 1
            x += 1
        x = 0
        y += 1
    return 0

def main() -> int:
    t = calloc(64, sizeof(int))
    go(0, 0, 0)
    if N != 92:
        return 1
    return 0
