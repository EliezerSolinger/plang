"""DOCTEST: o exemplo que está na documentação é o exemplo que corre.

A ideia é a do Python e vale pela mesma razão: um exemplo numa docstring
envelhece em silêncio. Ele parece certo, ninguém o corre, e um dia alguém copia
uma linha que já não funciona. Aqui ele vira uma aresta do build como qualquer
outra — se a saída mudar, o build fica vermelho.

A sintaxe é a que toda a gente já conhece — três sinais de maior, a expressão, e
a saída esperada na linha seguinte. (O exemplo abaixo está com um sinal a menos
DE PROPÓSITO: este arquivo é ele próprio um módulo de um pacote, e um exemplo de
verdade aqui viraria um teste a chamar uma função que não existe. É o gerador a
apanhar-se a si mesmo, que é o melhor sinal de que funciona.)

    \"\"\"Soma dois números.

    >> soma(2, 3)
    5
    >> soma(-1, 1)
    0
    \"\"\"

Uma linha `>>> expr` é uma EXPRESSÃO a imprimir; as linhas seguintes, até ao
próximo `>>>` ou até uma linha vazia, são a saída esperada. Não há `...` de
continuação e não há blocos: um doctest que precisa de um `for` já não é
documentação, é teste — e testes têm um sítio, que é `test/`.

**De onde vêm as docstrings: da resposta 5** (`plangc --api`), e não de um
segundo leitor de fontes. É a mesma lista canónica que o `ppack doc` mostra e
que o índice do repositório carrega, o que quer dizer que o doctest de um pacote
PUBLICADO se pode correr sem ter o fonte à mão.

**Como corre**: os exemplos de um módulo viram UM programa gerado —
`from <pkg/mod.psc> import ...` com os nomes públicos do módulo, e um `print`
por exemplo — que se compila e se corre como qualquer outro teste da suíte. A
comparação é a de sempre: a saída inteira contra o esperado.
"""
import path
import lib_api as A

struct Exemplo:
    expr: str
    esperado: list<str>


def extrai(doc: str) -> list<Exemplo>:
    """Os exemplos de uma docstring, na ordem."""
    out: list<Exemplo> = []
    for linha in doc.split("\n"):
        t = linha.strip()
        if t.startswith(">>>"):
            out.append(Exemplo(t[3:].strip(), []))
        elif len(out) > 0 and len(t) > 0:
            out[len(out) - 1].esperado.append(t)
        elif len(t) == 0 and len(out) > 0 and len(out[len(out) - 1].esperado) > 0:
            # uma linha vazia FECHA a saída esperada: sem isto, o parágrafo que
            # vem a seguir ao exemplo virava parte dela
            out.append(Exemplo("", []))
    limpos: list<Exemplo> = []
    for e in out:
        if len(e.expr) > 0:
            limpos.append(e)
    return limpos


struct Programa:
    fonte: str          # o texto do programa gerado
    esperado: str       # o que ele tem de imprimir
    quantos: int


def gerar(mod: A.Api, importa: str) -> Programa:
    """O programa de um módulo. `importa` é o que vai no `from ... import`:
    `<pkg/mod.psc>` para um pacote, ou o nome do módulo ao lado."""
    nomes: list<str> = []
    exemplos: list<Exemplo> = []
    for e in extrai(mod.doc):
        exemplos.append(e)
    for s in mod.simbolos:
        for e2 in extrai(s.doc):
            exemplos.append(e2)
        # só os nomes SIMPLES entram no `from ... import`: um método
        # (`Struct.metodo`) vem com o tipo dele, e um tipo importado traz os
        # métodos consigo
        if len(s.nome) > 0 and "." not in s.nome and s.nome not in nomes:
            nomes.append(s.nome)
    if len(exemplos) == 0:
        return Programa("", "", 0)
    b = "# GERADO por lib_doctest.psc a partir de " + mod.caminho + " — não editar.\n"
    if len(nomes) > 0:
        b += "from " + importa + " import " + ", ".join(sorted(nomes)) + "\n"
    b += "\n"
    esp = ""
    for e3 in exemplos:
        b += "print(" + e3.expr + ")\n"
        for ln in e3.esperado:
            esp += ln + "\n"
    return Programa(b, esp, len(exemplos))


def gerar_ph(mod: A.Api, importa: str) -> Programa:
    """O mesmo, para um módulo em P: ele entra INTEIRO (`import <pkg/mod.ph>`),
    porque o que dele atravessa a fronteira é decidido pela 45.5 e não por uma
    lista de nomes — e os nomes ficam visíveis sem qualificador."""
    exemplos: list<Exemplo> = []
    for e in extrai(mod.doc):
        exemplos.append(e)
    for s in mod.simbolos:
        for e2 in extrai(s.doc):
            exemplos.append(e2)
    if len(exemplos) == 0:
        return Programa("", "", 0)
    b = "# GERADO por lib_doctest.psc a partir de " + mod.caminho + " — não editar.\n"
    b += "import " + importa + "\n\n"
    esp = ""
    for e3 in exemplos:
        b += "print(" + e3.expr + ")\n"
        for ln in e3.esperado:
            esp += ln + "\n"
    return Programa(b, esp, len(exemplos))
