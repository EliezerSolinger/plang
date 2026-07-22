include <stdio.h>

# Múltiplos statements na mesma linha separados por ';' (como C e Python).
# ';' final e ';;' são tolerados; a indentação continua dirigida só por newlines.

def add(a: i32, b: i32) -> i32:
    return a + b

def main() -> i32:
    x: i32 = 0; y: i32 = 10
    x += 1; printf("x=%d y=%d\n", x, y)
    s: i32 = add(x, y); printf("s=%d\n", s)
    x += 2;
    y += 3;;
    printf("x=%d y=%d\n", x, y)
    i: i32 = 0
    while i < 3:
        printf("i=%d ", i); i += 1
    printf("\n")
    if x > 0:
        a: i32 = 5; b: i32 = 6; printf("a+b=%d\n", a + b)
    return 0
