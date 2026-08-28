"""`json.stringify` — o mesmo percurso do `repr`, pela mesma tabela (F5).

Não custa uma linha de código por tipo: o compilador já sabe a forma de cada um
e deixa-a como DADO ao lado do descritor; o runtime percorre-a. Foi assim que
esta função apareceu sem um gerador atrás.

O `repr` e o JSON não são a mesma coisa, e as diferenças são decisões:

  * um `to_str()` escrito pelo tipo GANHA no repr — é a forma de ele se mostrar
    — e NÃO ganha aqui, porque quem lê o JSON do outro lado espera os campos;
  * um enum viaja pelo NOME da variante e não pelo número: o número é uma
    escolha de compilação e o nome é o que significa alguma coisa lá fora;
  * um conjunto viaja como ARRAY, porque JSON não tem conjunto e inventar um
    formato obrigaria o outro lado a conhecê-lo;
  * o que não atravessa LEVANTA, com o caminho onde parou. JSON que sai errado
    em silêncio é pior do que JSON que não sai.
"""

import json

enum Color:
    RED
    GREEN
    BLUE

record Pt:
    x: int
    y: float

struct Box:
    name: str
    p: Pt
    tags: List<str>
    n: int
    color: Color
    ok: bool

struct Money:
    cents: int
    def to_str(self) -> str:
        return "$" + str(self.cents // 100)

# ---- o caso inteiro ----
print(json.stringify(Box("a\"b", Pt(1, 2.5), ["x", "y"], 7, BLUE, True)))

# ---- os pedaços ----
print(json.stringify([1, 2, 3]))
print(json.stringify({"a": [1], "b": []}))
print(json.stringify(Pt(3, 4.0)))
print(json.stringify("olá\n\t"))
print(json.stringify(42))
print(json.stringify(True))
print(json.stringify(RED))
xs: List<int> = []
print(json.stringify(xs))

# o `to_str` NÃO manda aqui: o repr mostra `$2`, o JSON leva o campo
d = Money(250)
print(d, json.stringify(d))

# um conjunto vira array
s: Set<int> = {3, 1}
print(json.stringify(s))

# aninhado
print(json.stringify([Pt(1, 1.0), Pt(2, 2.0)]))
print(json.stringify({"pontos": [1, 2], "vazio": []}))

# ---- e o que ele RECUSA ----
def infinite() -> float:
    return 1.0e400

try:
    print(json.stringify([infinite()]))
catch e:
    print("recusou:", e.message)

# uma chave que não é texto: um objeto JSON não a tem
di: Dict<int, int> = {1: 2}
try:
    print(json.stringify(di))
catch e2:
    print("recusou:", e2.message)


# ---- a volta: o que sai daqui entra no nosso próprio `parse` ----
text = json.stringify(Box("z", Pt(9, 0.5), ["t"], 1, GREEN, False))
back = json.parse(text) as Dict<str, any>
print(back["name"] as str, (back["p"] as Dict<str, any>)["x"] as int, back["color"] as str)

# ... e o `json.dumps` do python concorda caractere a caractere com isto:
#   {"nome":"z","p":{"x":9,"y":0.5},"tags":["t"],"n":1,"cor":"VERDE","ok":false}
print(text)
