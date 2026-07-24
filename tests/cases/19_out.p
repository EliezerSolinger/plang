include <stdio.h>

def divmod(a: i32, b: i32, out resto: i32) -> i32:
    resto = a % b
    return a / b

def try_parse(s: const *char, out v: i32) -> bool:
    if s[0] < '0' or s[0] > '9':
        v = 0
        return False
    v = i32(s[0] - '0')
    return True

def chain(x: i32, out dobro: i32) -> bool:
    return try_parse("7", out dobro)   # repassa o próprio out adiante

def main() -> int:
    r: i32
    q: i32 = divmod(17, 5, out r)
    printf("%d %d\n", q, r)
    n: i32
    if try_parse("8", out n):
        printf("ok %d\n", n)
    d: i32
    chain(1, out d)
    printf("%d\n", d)
    # compat: ponteiro cru continua funcionando (é a MESMA ABI)
    r2: i32
    divmod(9, 4, &r2)
    printf("%d\n", r2)
    return 0
