# O parâmetro é `in` e a chamada não disse a palavra. Antes disto a queixa vinha
# da conversão de tipos — "incompatible types in assignment (scalar from 'Ponto')"
# —, que é verdade e não fala do problema: o valor não entra num ponteiro porque
# falta o `in`.
include <stdio.h>

struct Ponto:
    x: i32
    y: i32

private def soma(in p: Ponto) -> i32:
    return p.x + p.y

def main() -> int:
    a: Ponto = {1, 2}
    printf("%d\n", soma(a))
    return 0
