include <stdio.h>

# volatile/restrict/const + declarador de parâmetro qualificado C99 (T x[static N])
def sum3(a: i32[static 3]) -> i32:
    return a[0] + a[1] + a[2]

def copy(dst: *restrict i32, src: const *restrict i32, n: i32):
    i: i32 = 0
    while i < n:
        dst[i] = src[i]
        i += 1

def main() -> i32:
    x: volatile i32 = 5
    x += 1
    a: i32[3] = { 10, 20, 30 }
    b: i32[3]
    copy(b, a, 3)
    printf("x=%d sum=%d b=%d,%d,%d\n", x, sum3(a), b[0], b[1], b[2])
    return 0
