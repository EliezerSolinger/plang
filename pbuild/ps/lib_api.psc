"""A resposta 5 do compilador, lida de volta.

`plangc --api <módulo>` responde a interface canónica de um módulo — imports,
enums, structs, funções, constantes — seguida do HASH dela e das DOCSTRINGS. É
uma resposta feita para ser lida por máquina, e este arquivo é a máquina.

O formato, de propósito trivial:

    == <caminho>
    <uma declaração por linha>
    #hash <16 hexa>
    #doc <símbolo> <texto, com \\n escapado>

O que se ganha lendo isto em vez de reparsear o fonte: a lista já está
CANÓNICA (o compilador a normalizou), a docstring já está separada do código, e
o hash já responde "isto mudou?" sem comparar texto. Nada disto seria de graça
num segundo leitor da linguagem — e um segundo leitor divergiria, que é o pior
resultado possível.
"""

struct Simbolo:
    linha: str      # a declaração como o compilador a escreve
    nome: str       # o nome, extraído para poder ser procurado
    doc: str

struct Api:
    caminho: str
    hash: str
    doc: str            # a do módulo
    simbolos: list<Simbolo>

    def acha(self, nome: str) -> int:
        i = 0
        while i < len(self.simbolos):
            if self.simbolos[i].nome == nome:
                return i
            i += 1
        return -1

# ---------- o nome de uma declaração ----------
# `def area(i32, i32) -> i64` -> `area`; `struct Ponto {...}` -> `Ponto`;
# `enum Forma {...}` -> `Forma`; `const MAX: i32 = 64` -> `MAX`.
def nome_da(linha: str) -> str:
    palavras = linha.split(" ")
    if len(palavras) < 2:
        return ""
    cabeca = palavras[0]
    if cabeca == "import" or cabeca == "include":
        return ""
    bruto = palavras[1]
    for corte in ["(", "{", ":", "<"]:
        k = bruto.find(corte)
        if k >= 0:
            bruto = bruto[0:k]
    return bruto

private def desescapa(s: str) -> str:
    out = ""
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            if s[i + 1] == "n":
                out += "\n"
                i += 2
                continue
            if s[i + 1] == "\\":
                out += "\\"
                i += 2
                continue
        out += s[i]
        i += 1
    return out

def limpa(t: str) -> str:
    """A docstring sem a indentação do CÓDIGO.

    Uma docstring é escrita dentro de um corpo, então da segunda linha em diante
    ela carrega a indentação da função. Mostrá-la como está põe quatro espaços a
    mais em tudo e a segunda linha parece um bloco de citação. É o `cleandoc` do
    Python, e a regra dele: a primeira linha perde o espaço da frente, e das
    outras se tira o recuo COMUM — o menor de todas as não vazias."""
    linhas = t.split("\n")
    if len(linhas) == 0:
        return t
    comum = -1
    i = 1
    while i < len(linhas):
        l = linhas[i]
        if len(l.strip()) > 0:
            k = 0
            while k < len(l) and l[k] == " ":
                k += 1
            if comum < 0 or k < comum:
                comum = k
        i += 1
    if comum < 0:
        comum = 0
    out = linhas[0].strip()
    j = 1
    while j < len(linhas):
        l2 = linhas[j]
        out += "\n" + (l2[comum:] if len(l2) >= comum else l2.strip())
        j += 1
    return out.rstrip()

def parse(texto: str) -> list<Api>:
    """A resposta inteira: um `Api` por módulo, na ordem em que o compilador os
    escreveu. Uma linha que não se reconhece é IGNORADA em vez de ser erro —
    o formato pode ganhar linhas novas, e um leitor que estoura com uma linha
    que não conhece envelhece mal."""
    out: list<Api> = []
    atual = Api("", "", "", [])
    tem = False
    for linha in texto.split("\n"):
        if len(linha) == 0:
            continue
        if linha.startswith("== "):
            if tem:
                out.append(atual)
            atual = Api(linha[3:], "", "", [])
            tem = True
            continue
        if not tem:
            continue
        if linha.startswith("#hash "):
            atual.hash = linha[6:]
            continue
        if linha.startswith("#doc "):
            resto = linha[5:]
            k = resto.find(" ")
            if k < 0:
                continue
            sym = resto[0:k]
            txt = limpa(desescapa(resto[k + 1:]))
            if sym == ".":
                atual.doc = txt
                continue
            i = atual.acha(sym)
            if i >= 0:
                atual.simbolos[i].doc = txt
            else:
                # um símbolo com doc e sem declaração visível: um MÉTODO
                # (`Struct.metodo`), que não tem linha própria na lista
                atual.simbolos.append(Simbolo("", sym, txt))
            continue
        atual.simbolos.append(Simbolo(linha, nome_da(linha), ""))
    if tem:
        out.append(atual)
    return out
