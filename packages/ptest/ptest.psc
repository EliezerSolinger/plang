"""`ptest` — o teste de uma FUNÇÃO, e o `assert_eq` que diz o que mudou.

O que já existe é o teste de SAÍDA de um programa: um `.psc` e um `.expected`, e
o portão compara os dois. Isso continua a ser o certo para um programa. **Isto é
outra pergunta**: uma função, muitos casos, e um relatório que diz qual falhou.

**O `assert` da linguagem e o `assert_eq` daqui são DOIS, e a regra diz porquê:**

> O `assert` fala com o **programador do módulo** — é um contrato interno,
> *"isto não pode acontecer"* — e **some em release** (46.4, o `-O`), porque já
> foi verificado.
> O `assert_eq` fala com **quem lê o relatório**, e é a razão de o processo
> existir. **Nunca** pode ser removido.

**A razão de o pacote existir é a DIFERENÇA LEGÍVEL.** Um booleano não diz o que
mudou; `assert_eq` diz o que deu, o que devia, e — quando são textos parecidos —
em que caractere eles divergem. Sem isso, um teste que falha manda-nos abrir o
depurador, que é o trabalho que ele devia poupar.

**O nome é `ptest` e não `test`** porque `test` é um comando do `pforge` e um
utilitário do POSIX: um `import test` num ficheiro ao lado de um `pforge test`
seria uma confusão paga todos os dias.

**O acumulador é um PUNHO, e não uma global**, pela mesma razão que o `log`:
um módulo importado não pode ter estado no topo — só um programa pode, porque só
ele tem uma ordem de execução definida. Um pacote é um conjunto de definições.

Isso não é uma limitação a contornar: torna visível quem acumula o quê, e é o que
permite dois `Runner` ao mesmo tempo sem que um veja as falhas do outro.

    import <ptest/ptest.psc> as t

    def soma_certa(r: t.Runner):
        t.eq_int(r, soma(2, 2), 4, "dois mais dois")

    t.run("aritmetica", [t.Case("soma", soma_certa)])
"""


struct Runner:
    """Onde as falhas de um caso se juntam. Um por execução."""
    failures: List<str>


struct Case:
    """Um caso: o nome que aparece no relatório, e o que correr.

    O nome é EXPLÍCITO e não vem do identificador da função, e é de propósito: o
    que se lê num relatório é uma frase, e `check_soma_2` é pior do que
    "dois mais dois".
    """
    name: str
    body: def(Runner)


def fail(r: Runner, what: str):
    r.failures.append(what)


def is_true(r: Runner, got: bool, what: str):
    if not got:
        fail(r, what + ": deu False, devia dar True")


def is_false(r: Runner, got: bool, what: str):
    if got:
        fail(r, what + ": deu True, devia dar False")


def eq_int(r: Runner, got: int, want: int, what: str):
    if got != want:
        fail(r, what + ": deu " + str(got) + ", devia dar " + str(want))


def eq_str(r: Runner, got: str, want: str, what: str):
    if got == want:
        return
    # a DIFERENÇA LEGÍVEL, que é a razão de o pacote existir: dizer que dois
    # textos de duzentos caracteres são diferentes não ajuda ninguém; dizer em
    # QUE caractere divergem resolve o caso sem abrir o depurador
    n = len(got) if len(got) < len(want) else len(want)
    at = n
    for i in range(n):
        if got[i] != want[i]:
            at = i
            break
    if at == n and len(got) != len(want):
        fail(r, what + ": os primeiros " + str(n) + " caracteres batem, mas deu "
             + str(len(got)) + " e devia dar " + str(len(want))
             + "\n    deu   " + around(got, n) + "\n    devia " + around(want, n))
        return
    fail(r, what + ": diferem no caractere " + str(at)
         + "\n    deu   " + around(got, at) + "\n    devia " + around(want, at))


def around(s: str, at: int) -> str:
    """Uma janela à volta do sítio, com reticências quando há mais.

    Vinte caracteres de cada lado: chega para se reconhecer o sítio e não enche
    o relatório, que é o equilíbrio que um `diff` inteiro perde.
    """
    lo = at - 20
    hi = at + 20
    pre = "..."
    post = "..."
    if lo <= 0:
        lo = 0
        pre = ""
    if hi >= len(s):
        hi = len(s)
        post = ""
    return pre + s[lo:hi] + post


def eq_float(r: Runner, got: float, want: float, tol: float, what: str):
    """Com TOLERÂNCIA, e obrigatoriamente: comparar dois `float` por igualdade é
    o erro que toda a gente comete uma vez, e uma API que o permitisse
    silenciosamente estaria a convidá-lo."""
    d = got - want
    if d < 0.0:
        d = -d
    if d > tol:
        fail(r, what + ": deu " + str(got) + ", devia dar " + str(want)
             + " (tolerancia " + str(tol) + ", diferenca " + str(d) + ")")


def eq_any(r: Runner, got: any, want: any, what: str):
    """Para o que não é `int`, `str` nem `float`: compara o TEXTO dos dois.

    Não é preguiça — é o que um `any` permite hoje (39.2), e o texto de um valor
    é exactamente o que se quer ver num relatório. Quando um genérico com limite
    de trait puder receber qualquer `Printable`, esta função ganha o tipo e o
    corpo fica igual.
    """
    g = str(got)
    w = str(want)
    if g != w:
        eq_str(r, g, w, what)


def run(suite: str, cases: List<Case>) -> int:
    """Corre os casos e escreve o relatório. Devolve quantos falharam.

    **Cada caso corre inteiro**, mesmo depois de uma asserção falhar: um caso que
    parasse na primeira mostraria um problema de cada vez, e quem corrige quer
    ver os três de uma vez. O que PARA um caso é uma excepção, que é outra coisa
    — e essa é apanhada e contada como falha, com a mensagem.
    """
    ok = 0
    bad = 0
    for c in cases:
        r = Runner([])
        try:
            c.body(r)
        catch e:
            r.failures.append("levantou: " + e.message)
        if len(r.failures) == 0:
            ok += 1
        else:
            bad += 1
            print("FALHOU " + suite + "/" + c.name)
            for f in r.failures:
                print("  " + f)
    print(suite + ": " + str(ok) + " ok, " + str(bad) + " falharam")
    return bad
