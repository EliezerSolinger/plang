include <stdio.h>

# Constantes em compile-time: const (com tipo inferido) dobra em contexto
# constante — dimensão de array (sem virar VLA), label de case — e permite
# poda de branch em `if CONST:` (equivalente ao #ifdef).

const N = 4                # inferido: int
const VERSION = 2
const DEBUG = 0

def main() -> i32:
    a: i32[N]              # a[4] fixo (não VLA): sizeof = 16
    a[0] = 10
    a[N - 1] = 40

    if VERSION >= 2:
        printf("v2plus ")
    else:
        printf("v1 ")      # branch morta: podada

    if DEBUG:
        printf("dbg ")     # podada

    x: i32 = N
    match x:
        case N:            # label de case dobra p/ 4
            printf("x==N ")
        case _:
            printf("x!=N ")

    printf("sz=%zu a0=%d a3=%d\n", sizeof(a), a[0], a[N - 1])
    return 0
