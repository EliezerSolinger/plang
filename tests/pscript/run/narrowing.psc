"""O estreitamento (43.1/114): uma condição com `and` prova TODAS as suas partes.

A prova de não-nulidade já andava pelo `and` desde a 114 — mas **carregava um
nome só**. `if a != None and b != None:` provava o `a` e deixava o `b` como
estava, e quem escrevia a forma natural tinha de a aninhar à mão. Foi o portão do
`Channel<T>` que o cobrou: `if v1 != None and v2 != None:` não compilava.

A correcção é onde o defeito estava: a prova deixa de ser um índice e passa a ser
uma lista. Tudo o resto — o `if`, o `elif`, o `else`, o `while`, a guarda que sai
do bloco, e o curto-circuito dentro da própria condição — usa a mesma lista.

**E o que NÃO prova continua a não provar**, que é a metade que interessa: um
`or` com `!=` não prova nada (o ramo pode ter sido tomado por causa do outro
lado), e um `and` com `==` também não. Isso está no corpus `bad`, onde falhar é
passar.
"""


record Point:
    x: int
    y: int


def sum_v(a: int?, b: int?, c: int?) -> int:
    # a forma natural: uma condição, três provas
    if a != None and b != None and c != None:
        return a + b + c
    return -1


def guard(a: str?, b: str?) -> str:
    # o DUAL: se a guarda não saiu, nenhum dos lados valia — portanto depois
    # dela as duas estão provadas
    if a == None or b == None:
        return "faltou"
    return a + b


def short(a: int?, b: int?) -> bool:
    # o curto-circuito dentro da própria condição: o lado direito é checado com
    # a prova de TODOS os que estão à esquerda
    return a != None and b != None and a + b > 0


def nested(p: Point?, q: Point?) -> int:
    # e a forma antiga continua a valer, como tem de ser
    if p != None:
        if q != None:
            return p.x + q.y
    return 0


def ramos(a: int?, b: int?) -> str:
    if a != None and b != None:
        return "os dois: " + str(a + b)
    elif a != None:
        return "so a: " + str(a)
    else:
        return "nem a"


def main():
    print(sum_v(1, 2, 3), sum_v(1, None, 3))
    print(guard("ola", " mundo"), guard(None, "x"))
    print(short(1, 2), short(1, None), short(-5, 2))
    print(nested(Point(3, 4), Point(5, 6)), nested(None, Point(5, 6)))
    print(ramos(1, 2), "|", ramos(1, None), "|", ramos(None, 2))

    # o `while` estreita da mesma maneira, e a atribuição tira a prova
    n: int? = 3
    while n != None:
        print("n =", n)
        n = None

    print("narrowing-ok")


main()
