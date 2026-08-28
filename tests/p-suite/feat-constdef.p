include <stdio.h>

# `const def`: função avaliada em COMPILE-TIME (comptime-only, não sai no
# binário). Domínio de valores: int, float e const char*. Chamada com args
# não-constantes é erro. O resultado dobra em literal.

const def factorial(n: i32) -> i32:
    if n <= 1:
        return 1
    return n * factorial(n - 1)          # recursão

const def sum_to(n: i32) -> i32:
    total: i32 = 0
    i: i32 = 0
    while i <= n:                        # loop + locais
        total += i
        i += 1
    return total

const def double_v(x: f64) -> f64:
    return x * 2.0                       # float

const def label() -> const *char:
    return "ctfe"                        # string

const SIZE = factorial(5)                  # 120 (const inferida do retorno)

def main() -> i32:
    buf: i32[factorial(4)]                # i32[24] fixo (não VLA)
    printf("fat5=%d soma10=%d sz=%zu\n", SIZE, sum_to(10), sizeof(buf))
    printf("dobra=%.1f msg=%s\n", double_v(3.5), label())
    return 0
