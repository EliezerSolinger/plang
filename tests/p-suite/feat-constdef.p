include <stdio.h>

# `const def`: função avaliada em COMPILE-TIME (comptime-only, não sai no
# binário). Domínio de valores: int, float e const char*. Chamada com args
# não-constantes é erro. O resultado dobra em literal.

const def fatorial(n: i32) -> i32:
    if n <= 1:
        return 1
    return n * fatorial(n - 1)          # recursão

const def soma_ate(n: i32) -> i32:
    total: i32 = 0
    i: i32 = 0
    while i <= n:                        # loop + locais
        total += i
        i += 1
    return total

const def dobra(x: f64) -> f64:
    return x * 2.0                       # float

const def etiqueta() -> const *char:
    return "ctfe"                        # string

const TAM = fatorial(5)                  # 120 (const inferida do retorno)

def main() -> i32:
    buf: i32[fatorial(4)]                # i32[24] fixo (não VLA)
    printf("fat5=%d soma10=%d sz=%zu\n", TAM, soma_ate(10), sizeof(buf))
    printf("dobra=%.1f msg=%s\n", dobra(3.5), etiqueta())
    return 0
