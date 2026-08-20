# a condição de um `const if` (99.1) tem de ser constante: sem isso ela vira de
# runtime e os DOIS ramos passam a ter de compilar, que é exatamente o que um
# guarda de plataforma não pode fazer
def f(n: i32) -> i32:
    const if n > 1:
        return 1
    return 0
