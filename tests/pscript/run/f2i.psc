"""A travessia de float para int, que era o furo gêmeo do `ps_mul`.

`int(x)` emitia `(int64_t)x`, e em C isso é comportamento INDEFINIDO quando `x` é
NaN, infinito, ou finito mas fora da faixa do i64. Medido antes do conserto, o
mesmo programa na mesma máquina:

    int(1e300)      -O0   -9223372036854775808
                    -O2    9223372036854775807

E não é só a otimização: no x86 o `cvttsd2si` devolve o "integer indefinite" e no
ARM64 o `fcvtzs` SATURA, então a mesma linha dá INT64_MIN num Linux de mesa e
INT64_MAX num Apple Silicon.

O detalhe que dói: a checagem JÁ EXISTIA para quem estreita — `i32(nan)` sempre
levantou, pelo `ps_f_to_iw`. Era só a largura padrão que passava sem conferir.

As palavras são as do Python, que é o oráculo da linguagem: `ValueError` no NaN e
`OverflowError` no infinito. O terceiro caso é nosso, porque o `int` do Python é
de precisão arbitrária e aceita `1e300`; o nosso é i64, e a 7.2 diz que estouro
levanta.

Os que devolvem int — `math.floor`, `math.ceil`, `math.trunc` e `round(x)` —
passam pela mesma travessia, porque um índice é o uso normal deles e INT64_MIN
como índice não é um erro de índice: é uma leitura em qualquer sítio.
"""

import math


def f2i(x: float) -> int:
    return int(x)


def narrow(x: float) -> i32:
    return i32(x)


def show(name_s: str, x: float):
    try:
        print(f"{name_s} = {f2i(x)}")
    catch e:
        print(f"{name_s} levantou: {e.message}")


print("-- o furo --")
show("int(nan)", math.nan)
show("int(inf)", math.inf)
show("int(-inf)", -math.inf)
show("int(1e300)", 1e300)
show("int(-1e300)", -1e300)

print("-- o que tem de continuar a passar --")
show("int(2.7)", 2.7)
show("int(-2.7)", -2.7)
show("int(0.0)", 0.0)
show("int(9.2e18)", 9.2e18)

print("-- estreitar ja era checado (ps_f_to_iw) --")
try:
    print(f"i32(1e30) = {narrow(1e30)}")
catch e:
    print(f"i32(1e30) levantou (a mensagem vem do caminho antigo)")

print("-- os que devolvem int --")
try:
    print(f"floor(nan) = {math.floor(math.nan)}")
catch e:
    print(f"floor(nan) levantou: {e.message}")
try:
    print(f"ceil(inf) = {math.ceil(math.inf)}")
catch e:
    print(f"ceil(inf) levantou: {e.message}")
try:
    print(f"round(nan) = {round(math.nan)}")
catch e:
    print(f"round(nan) levantou: {e.message}")
print(f"floor(2.7)={math.floor(2.7)} ceil(2.1)={math.ceil(2.1)} trunc(-2.7)={math.trunc(-2.7)}")
print(f"round(0.5)={round(0.5)} round(1.5)={round(1.5)} round(-0.5)={round(-0.5)}")
print(f"round(2.675, 2)={round(2.675, 2)}")
