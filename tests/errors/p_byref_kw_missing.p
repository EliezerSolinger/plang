# O parâmetro é `in` e a chamada não disse a palavra. Antes disto a queixa vinha
# da conversão de tipos — "incompatible types in assignment (scalar from 'Ponto')"
# —, que é verdade e não fala do problema: o valor não entra num ponteiro porque
# falta o `in`.
include <stdio.h>

struct Point:
    x: i32
    y: i32

private def sum_v(in p: Point) -> i32:
    return p.x + p.y

def main() -> int:
    a: Point = {1, 2}
    printf("%d\n", sum_v(a))
    return 0
