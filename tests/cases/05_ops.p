# casts, ternário, lógicos, do-while, arrays, range com passo negativo
include <stdio.h>

def main() -> int:
    x: int = 10
    y: float = float(x) / 4
    printf("%.2f\n", y)

    s: *char = "sim" if x > 5 and not (x == 7) else "nao"
    printf("%s\n", s)

    i: int = 0
    do:
        i += 1
    while i < 3
    printf("%d\n", i)

    v: int[3] = {1, 2, 4}
    soma: int = 0
    j: int
    for j in range(3):
        soma += v[j]
    printf("%d\n", soma)

    for j in range(10, 0, -2):
        soma += 1
    printf("%d\n", soma)

    mask: int = (1 << 3) | 1
    printf("%d\n", mask & 15)
    return 0
