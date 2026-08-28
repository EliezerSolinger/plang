"""As cinco parciais que o levantamento da 163.4 achou (164).

Quatro delas eram dívida do avaliador que a 159 tinha acabado de escrever, e a
distinção que as tornou accionáveis foi esta: **`~`, `//=` e `&=` funcionavam
todos em tempo de execução.** Não era a linguagem que não os tinha — era o
avaliador de compilação que não os computava, e o compilador dizia-o na cara.
Uma linguagem menor dentro da linguagem, por uma lista por acabar.

**O piso e o resto sobre floats seguem a regra dos inteiros** (39.1/159.2): o
resto tem o sinal do DIVISOR, portanto `-7.5 % 2.0` é 0.5 e não -1.5. E o `floor`
é escrito à mão porque o compilador não liga a `libm` — foi o que travou o `pow`
na 159.2, e a mesma pedra apareceu aqui.

E o `match` sobre `float`: ele não desce para o `switch` do C, que só toma
inteiros, mas para a **mesma cadeia de comparações** que uma `str` já usava. Uma
função, duas comparações — a `str` compara por conteúdo, o `float` por valor.
"""


const def com_floordiv(n: int) -> int:
    x = n
    x //= 2
    return x


const def com_bits(n: int) -> int:
    x = n
    x &= 12
    x |= 1
    x ^= 2
    x <<= 2
    x >>= 1
    return x


const def com_pow(n: int) -> int:
    x = n
    x **= 3
    return x


const def com_til(n: int) -> int:
    return ~n


const def floor_float() -> int:
    # 7.5 // 2.0 = 3.0, e -7.5 // 2.0 = -4.0 (piso, nao truncatura)
    return int(7.5 // 2.0) * 100 + int(-7.5 // 2.0)


const def fmod_float() -> int:
    # o resto tem o sinal do DIVISOR: -7.5 % 2.0 = 0.5
    return int((7.5 % 2.0) * 10.0) * 100 + int((-7.5 % 2.0) * 10.0)


print(com_floordiv(9), com_bits(15), com_pow(3), com_til(5))
print(floor_float(), fmod_float())


# ---- e o `match` sobre float ----
def classify(x: float) -> str:
    match x:
        case 0.0:
            return "zero"
        case 1.5, 2.5:
            return "meio"
        case _:
            return "outro"


print(classify(0.0), classify(1.5), classify(2.5), classify(9.0))
