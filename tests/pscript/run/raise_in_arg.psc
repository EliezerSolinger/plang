"""Uma chamada que LEVANTA no meio de uma instrução não pode deixar rasto.

O teste de exceção sai no fim da instrução (49.2), e isso bastava enquanto a
instrução era só a chamada. `xs.append(item as str)` são duas coisas na mesma:
o `as` que pode levantar e o `ps_list_push` que RESERVA um lugar na lista. Com o
teste no fim, a reserva acontecia à mesma e a lista ficava com um elemento a
mais, apontando para o que a chamada devolveu depois de falhar — e o segfault
aparecia na leitura seguinte, longe do `catch`.

A regra é a mesma que já valia para o coletor: o lugar de destino só se pede
depois de o valor existir.
"""

import json

v = json.parse("[\"a\", {\"x\": 1}, \"b\", 7]")

xs: list<str> = []
for item in v as list<any>:
    try:
        xs.append(item as str)
    catch e:
        xs.append("<" + e.message + ">")
print(len(xs))
for s in xs:
    print("[" + s + "]")

# o mesmo com um dict, que também reserva antes de escrever
d: dict<str, str> = {}
i = 0
for item2 in v as list<any>:
    try:
        d["k" + str(i)] = item2 as str
    catch e2:
        d["k" + str(i)] = "?"
    i += 1
print(len(d))
for k in sorted(d.keys()):
    print(k, "=", d[k])

# e num campo de struct: o alvo é um endereço, e o mesmo raciocínio vale
struct Caixa:
    dentro: str

c = Caixa("inicial")
lista = v as list<any>
try:
    c.dentro = lista[3] as str
catch e3:
    print("campo intacto:", c.dentro)
