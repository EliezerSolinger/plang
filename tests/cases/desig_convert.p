"""Um literal com campos NOMEADOS baixa as conversões como qualquer outro.

`{.n = usize(64)}` saía em C tal e qual — uma chamada a uma função `usize` que
não existe — e o erro só aparecia no LINKER, longe do sítio e sem posição. A
forma posicional (`{p, usize(64)}`) sempre funcionou, o que fazia da diferença
entre as duas uma armadilha em vez de uma escolha de estilo.

A causa era pequena e o sítio é o que interessa: o `check_expr` de uma lista de
chaves percorria os argumentos, e um `.campo = valor` é um nó DESIGNADOR cujo
valor está lá dentro — portanto nunca chegava a ser visitado. Vale para o
`[i] = valor` de um array pela mesma razão.

Encontrado ao escrever o teste do `hmac` (S2).
"""
include <stdio.h>

struct Par:
    a: usize
    b: u32
    p: const *char

def main() -> int:
    s: const *char = "ola"
    x: Par = {.a = usize(3), .b = u32(4), .p = s}
    y: Par = {usize(5), u32(6), s}
    # ... e num array, com o índice designado
    v: u32[4] = {[0] = u32(7), [2] = u32(9)}
    # ... e aninhado
    z: Par[2] = {{.a = usize(1), .b = u32(2), .p = s}, {.a = usize(3), .b = u32(4), .p = s}}
    printf("%zu %u %s\n", x.a, x.b, x.p)
    printf("%zu %u\n", y.a, y.b)
    printf("%u %u %u\n", v[0], v[1], v[2])
    printf("%zu %u %zu %u\n", z[0].a, z[0].b, z[1].a, z[1].b)
    return 0
