include <stdio.h>

def main() -> int:
    a: int = 24680
    # o porte de 00166: em C um zero à esquerda é octal, e em P isso é ERRO —
    # a mesma armadilha que o Python fechou. O octal escreve-se `0o`, e o valor
    # é o mesmo, que é o que o `.expected` confere.
    b: int = 0o1234567
    c: int = 0x2468ac
    d: int = 0x2468AC

    printf("%d\n", a)
    printf("%d\n", b)
    printf("%d\n", c)
    printf("%d\n", d)

    return 0
