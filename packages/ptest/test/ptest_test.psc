"""`ptest` (S8): o teste de uma FUNÇÃO, e o `assert_eq` que diz o que mudou.

**O `assert` da linguagem e o `eq_*` daqui são DOIS**, e a regra diz porquê: o
`assert` fala com o programador do módulo — é um contrato interno — e **some em
release** (46.4, o `-O`); estes falam com quem lê o relatório, e são a razão de o
processo existir.

**A razão de o pacote existir é a DIFERENÇA LEGÍVEL.** Um booleano não diz o que
mudou. Este portão prova-o ao contrário do costume: ele CORRE casos que falham de
propósito, e o que ele compara é o RELATÓRIO — porque é o relatório o produto.

E o acumulador é um punho, pela mesma razão que o `log`: um módulo importado não
pode ter estado no topo. O que se ganha é que dois `Runner` não se vêem.
"""
import <ptest/ptest.psc> as t


def passa(r: t.Runner):
    t.eq_int(r, 2 + 2, 4, "dois mais dois")
    t.eq_str(r, "ola", "ola", "iguais")
    t.is_true(r, True, "verdade")
    t.is_false(r, False, "mentira")
    t.eq_float(r, 1.0, 1.001, 0.01, "dentro da tolerancia")
    t.eq_any(r, 42, 42, "any igual")


def falha_numeros(r: t.Runner):
    t.eq_int(r, 2 + 2, 5, "dois mais dois")
    t.eq_float(r, 1.0, 1.1, 0.01, "fora da tolerancia")


def falha_texto(r: t.Runner):
    # difere no MEIO: o relatorio diz em que caractere
    t.eq_str(r, "o rapido cao castanho salta", "o rapido gato castanho salta", "no meio")
    # um e prefixo do outro: o relatorio diz que os primeiros batem
    t.eq_str(r, "abc", "abcdef", "prefixo")


def levanta(r: t.Runner):
    raise error("rebentou a meio", VALUE)


def continua_depois_de_falhar(r: t.Runner):
    # TRES falhas, e as tres saem: um caso que parasse na primeira mostraria um
    # problema de cada vez, e quem corrige quer ver os tres de uma vez
    t.eq_int(r, 1, 2, "um")
    t.eq_int(r, 3, 4, "dois")
    t.eq_int(r, 5, 6, "tres")


def main():
    n = t.run("exemplo", [t.Case("tudo bem", passa),
                          t.Case("numeros", falha_numeros),
                          t.Case("texto", falha_texto),
                          t.Case("levanta", levanta),
                          t.Case("nao para na primeira", continua_depois_de_falhar)])
    print("o run devolveu", n)

    # dois Runner nao se veem um ao outro, que e o que o punho compra
    a = t.Runner([])
    b = t.Runner([])
    t.eq_int(a, 1, 2, "so no A")
    print("A tem", len(a.failures), "e B tem", len(b.failures))
    print("ptest-ok")


main()
