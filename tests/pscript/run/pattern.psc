"""`re.compile` dá um `Pattern` (152.8): um padrão que se GUARDA.

A cache das 24 entradas já fazia metade do trabalho — um padrão dentro de um laço
compila uma vez. O que faltava era a outra metade, e a 152.8 disse-a assim:

> *"quem quiser passar um padrão como valor ainda não tem tipo para isso."*

Um `Pattern` é um valor: mora num campo de `struct`, passa-se a uma função,
devolve-se, entra numa lista. E traz consigo a garantia que a cache não dá — a
compilação está **ali dentro**, e não depende de o padrão não ter sido despejado
por outros vinte e quatro pelo meio.

**Os nomes são os mesmos do módulo, de propósito.** Quem sabe `re.search(p, t)`
sabe `p.search(t)`, e a única coisa que muda é de onde vem o padrão. Os tipos de
retorno são os mesmos até ao fim: `match`/`search` dão os grupos ou None,
`findall`/`split` dão sempre uma lista, `finditer` dá as POSIÇÕES em plano, e
`sub` dá texto.

**E um padrão que não compila levanta em `re.compile`** — onde foi escrito, e não
três funções à frente na primeira vez que alguém o usar.
"""
import re


struct Regra:
    nome: str
    pat: Pattern


def aplica(r: Regra, texto: str) -> str:
    return r.pat.sub("<" + r.nome + ">", texto)


p = re.compile("[0-9]+")
print("guardado:", p.pattern())
def primeiro(m: List<str>?) -> str:
    if m == None:
        return "(nada)"
    for g in m:
        return g
    return "(vazio)"


print("search:", primeiro(p.search("abc 42 def")))
print("match exige o principio:", p.match("abc 42") == None, p.match("42 abc") != None)
print("findall:", p.findall("1 22 333"))
print("split:", p.split("a1b22c"))
print("sub:", p.sub("#", "a1b22c"), "| com limite:", p.sub("#", "a1b22c", 1))
print("finditer (posicoes):", p.finditer("x1y22"))

# ... e agora a parte que só um VALOR permite: guardá-lo
regras: List<Regra> = [Regra("num", re.compile("[0-9]+")),
                       Regra("esp", re.compile("[ ]+"))]
t = "ola 12 mundo 345"
for r in regras:
    t = aplica(r, t)
print("as duas regras:", t)

# um padrão que não compila levanta onde foi ESCRITO
try:
    mau = re.compile("[unclosed")
    print("ISTO NAO DEVIA APARECER")
catch e:
    print("recusa:", e.message)
