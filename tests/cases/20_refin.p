include <stdio.h>

struct Config:
    width: i32
    height: i32

def area(in cfg: Config) -> i32:
    return cfg.width * cfg.height     # leitura por referência, sem cópia

def double_v(ref v: i32):
    v = v * 2                            # lê E escreve a var do chamador

def divmod(a: i32, b: i32, out rest: i32) -> i32:
    rest = a % b
    return a / b

def main() -> int:
    c: Config = {3, 4}
    printf("%d\n", area(in c))
    x: i32 = 10
    double_v(ref x)
    printf("%d\n", x)
    r: i32
    q: i32 = divmod(17, 5, out r)
    printf("%d %d\n", q, r)
    # compat: ponteiro cru continua igual
    double_v(&x)
    printf("%d\n", x)
    return 0
