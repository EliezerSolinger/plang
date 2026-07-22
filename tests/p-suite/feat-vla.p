# VLA (array local com dimensão em runtime).
#   - c99 (backend C): array nativo `int a[n]`.
#   - QBE: alocação dinâmica na pilha (alloc com tamanho runtime).
#   - c89 (--std=c89): rebaixado p/ malloc(n*sizeof(T)) + defer free().
include <stdio.h>
include <stdlib.h>

def soma_quadrados(n: int) -> int:
    a: int[n]
    i: int = 0
    while i < n:
        a[i] = i * i
        i += 1
    total: int = 0
    i = 0
    while i < n:
        total += a[i]
        i += 1
    return total

# VLA + goto na mesma função: em c89 o ponteiro é içado p/ a entrada e o free
# vira um defer de escopo de função (goto-safe); em c99/QBE o VLA é nativo.
def com_goto(n: int) -> int:
    a: int[n]
    i: int = 0
    while i < n:
        a[i] = i + 1
        i += 1
    total: int = 0
    goto skip
    total = 999          # pulado pelo goto
    skip:
    i = 0
    while i < n:
        total += a[i]
        i += 1
    return total

def main() -> int:
    # dimensões constantes via operadores de P (and/or/comparação): dobram em
    # compile-time — NÃO são VLA (viram arrays fixos de tamanho 1).
    fixo: int[2 and 3]
    fixo[0] = 7
    printf("%d\n", fixo[0])              # 7
    printf("%d\n", soma_quadrados(5))    # 0+1+4+9+16 = 30
    printf("%d\n", soma_quadrados(1))    # 0
    printf("%d\n", com_goto(5))          # 1+2+3+4+5 = 15
    return 0
