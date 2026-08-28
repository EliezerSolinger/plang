# Fixture da regressão do `const` NEGATIVO num módulo importado.
#
# Um inicializador de módulo vira DADO ESTÁTICO em C, e dado estático não chama
# função. O `-1` era lowered para a negação CHECADA (`ps_neg(ctx, 1)`, que
# levanta no estouro), e no escopo do arquivo não há contexto nenhum: o
# compilador morria com "use of undeclared identifier '__ctx'", uma mensagem que
# não tem como levar ninguém à causa. O conserto dobra o sinal em tempo de
# compilação, que é o que um literal negativo é.
const MINUS_ONE: int = -1
const MINUS_THOUSAND: int = -1000
const POSITIVE: int = 7

def sum_v() -> int:
    return MINUS_ONE + MINUS_THOUSAND + POSITIVE
