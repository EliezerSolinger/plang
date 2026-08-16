# `break` dentro de um braço de `match`.
#
# O back end C imprime um `switch`, e ali `break` sai do switch — ou seja,
# termina o BRAÇO. O back end QBE não tinha alvo de break para um `match`: a
# pilha estava vazia e o salto ia para um bloco inexistente, o que o `qbe`
# recusava com "block @l0 is used undefined". Os dois têm de dizer a mesma
# coisa, e um `match` é interrompível nos dois.
#
# (Um `match` do P não cai de um braço para o outro, então este `break` só serve
# para sair mais cedo — que é exatamente o que ele faz.)
include <stdio.h>

def classify(n: i32) -> i32:
    r: i32 = 0
    match n:
        case 1:
            r = 10
            break
            r = 99          # inalcançável, de propósito
        case 2:
            r = 20
        case _:
            r = 30
    return r

# e dentro de um laço o `break` do braço continua sendo do MATCH, não do laço:
# quem quiser sair do laço usa uma condição, que é o que o C também faz
def conta_ate(limite: i32) -> i32:
    total: i32 = 0
    i: i32 = 0
    while i < limite:
        match i % 3:
            case 0:
                total += 1
                break
            case _:
                total += 10
        i += 1
    return total

def main() -> int:
    printf("%d %d %d\n", classify(1), classify(2), classify(7))
    printf("%d\n", conta_ate(6))
    return 0
