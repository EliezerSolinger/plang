include <stdio.h>

struct Config:
    largura: i32
    altura: i32

def area(in cfg: Config) -> i32:
    return cfg.largura * cfg.altura     # leitura por referência, sem cópia

def dobra(ref v: i32):
    v = v * 2                            # lê E escreve a var do chamador

def divmod(a: i32, b: i32, out resto: i32) -> i32:
    resto = a % b
    return a / b

def main() -> int:
    c: Config = {3, 4}
    printf("%d\n", area(in c))
    x: i32 = 10
    dobra(ref x)
    printf("%d\n", x)
    r: i32
    q: i32 = divmod(17, 5, out r)
    printf("%d %d\n", q, r)
    # compat: ponteiro cru continua igual
    dobra(&x)
    printf("%d\n", x)
    return 0
