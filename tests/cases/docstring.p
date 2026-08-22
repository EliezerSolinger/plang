"""A docstring do MÓDULO: uma string sozinha, antes de tudo.

Ela vai para a árvore e não gera código — um binário não carrega documentação.
Quem a lê é a resposta 5 do protocolo (`--api`) e a IDE, e é por isso que ela
sai DEPOIS do hash de interface: mudar um texto não muda o que quem usa vê.

A regra é POSICIONAL, e é a mesma do pscript e a do Python: uma string sozinha
como primeira coisa de um módulo, de um corpo, de um `struct`, de um `enum` ou
de um `trait`. Em qualquer outro lugar, `\"\"\"...\"\"\"` é apenas uma string
literal que atravessa linhas — o que também é novo em P, e é o que a última
função aqui usa.
"""
include <stdio.h>


def dobro(x: i32) -> i32:
    """O dobro de x.

    A segunda linha existe para provar que a docstring atravessa linhas.
    """
    return x * 2


struct Ponto:
    """Um par de inteiros."""
    x: i32
    y: i32

    def soma(self: *Ponto) -> i32:
        """A soma das duas coordenadas — a docstring de um MÉTODO."""
        return self->x + self->y


enum Forma:
    """As formas que este módulo conhece."""
    FORMA_CAIXA = 1
    FORMA_BOLA = 2


def multilinha() -> const *char:
    # aqui a string tripla NÃO é docstring: não é a primeira instrução, e o que
    # ela é, é uma string comum que atravessa linhas
    n: i32 = 1
    s: const *char = """primeira
segunda"""
    return s if n == 1 else "outra"


def main() -> int:
    p: Ponto = {3, 4}
    printf("%d %d %d\n", dobro(21), p.soma(), FORMA_BOLA)
    printf("%s\n", multilinha())
    return 0
