"""Um `const if` sobre o resultado de um `const def` (163.2).

O `const def` da 159 já devolvia um literal, e o `check_expr` já o substituía no
sítio. O que faltava era o passo seguinte: o `const_truth` conhecia `==` e `!=`
entre literais e mais nada, portanto `const if fib(10) > 50` morria a dizer que a
condição não era conhecida em compilação — **depois de o `fib(10)` já ter virado
`55`**. Faltava a comparação, e faltava a conta: `12 + 1` também não dava `13`.

**A aritmética não foi reescrita.** Ela vive no avaliador da 159, com o piso e o
resto do Python que a 39.1 fixou, e uma segunda cópia era a maneira exacta de as
duas divergirem um dia. O que se acrescentou pré-confere: só chama o avaliador
quando os dois lados já são literais e o operador é um que ele trata — e aí ele
não pode levantar. Tudo o resto continua a ser "não é constante".

Isto é a mesma omissão da 159.3 pela segunda vez: liguei a dobra ao tamanho de um
`T[N]` e não fui ver os outros sítios que também querem uma constante.
"""


const def fib(n: int) -> int:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)


const def triplo(n: int) -> int:
    return n * 3


def compara() -> str:
    const if fib(10) > 50:
        return "maior"
    else:
        return "menor"


def com_conta() -> str:
    const if triplo(4) + 1 == 13:
        return "a conta dobrou"
    else:
        return "nao dobrou"


def encadeado() -> str:
    const if triplo(2) > 3 and fib(7) < 20:
        return "as duas"
    else:
        return "alguma falhou"


def piso() -> str:
    # o `//` do Python, com o mesmo resultado que teria em execução
    const if triplo(4) // 5 == 2 and -7 // 2 == -4:
        return "piso do Python"
    else:
        return "piso do C"


print(compara(), "|", com_conta(), "|", encadeado(), "|", piso())
