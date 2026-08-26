"""A LINHA de cada frame do rastro (34.2), e a fusão que a torna precisa.

Um rastro que diz `in edit (codeview.psc)` conta ao leitor o FICHEIRO, que é a
metade que ele já sabia. A linha é a outra metade, e custa um STORE num campo de
uma struct local — sem chamada, sem desvio, e nada que o coletor tenha de saber.

**Todas as instruções, e não só as que CHAMAM.** A linha mais interna é onde o
erro é levantado, e `xs[5]`, uma divisão por zero e um transbordo levantam sem
chamar coisa nenhuma.

**A fusão, que é o que torna isto correcto.** A instrução a correr está no bloco
mais interno, e o frame que ela alcança é o DESSE bloco — não o da função. Como
um frame de bloco não tem nome, ele não aparece no rastro; o que o
`ps_trace_capture` faz é levar a linha para fora até haver um frame com nome onde
a pousar. É por isso que a linha aqui é a de DENTRO do `if`, e não a do `for`.
"""


def fundo(xs: List<int>, k: int) -> int:
    marca: str = "fundo"
    for i in range(3):
        if i == k:
            zero: List<int> = []
            return len(marca) + zero[7]
    return 0


def meio(k: int) -> int:
    guarda: str = "meio"
    xs: List<int> = [1, 2, 3]
    return fundo(xs, k) + len(guarda)


def topo() -> int:
    nome: str = "topo"
    return meio(2) + len(nome)


print(topo())
