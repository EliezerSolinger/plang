"""`json.stringify` de um `any` DECLARADO, e a chave do descritor por trás dele.

Um `Dict<str, any>` é a forma exacta de um objecto JSON, e é o que sai de um
`json.parse`. Não voltava a atravessar para texto — o círculo
`stringify(parse(x))` não fechava. O caminho por dentro de um `any` já existia
(é o que trata os valores de um dicionário guardado num); o que faltava era o
caso de o TIPO ESTÁTICO dizer `any`.

E há um segundo defeito escondido neste ficheiro, que é a razão de ele mencionar
`bytes` sem precisar. O descritor de um tipo é pedido por uma CHAVE, e o fundo
dessa chave respondia `"v"` a tudo o que não tivesse caso próprio: `any`, `bytes`,
`Task`, `Socket`. Quem chegasse primeiro no módulo registava `__ty_v`, e os
outros recebiam o dele — silenciosamente, e dependendo da ORDEM em que os tipos
aparecem no ficheiro.

Enquanto todos eram opacos não se via, porque o corpo era igual. Passou a ver-se
quando o `any` ganhou espécie própria: num módulo onde um `bytes` fosse visto
primeiro, o `any` ficava com o descritor OPACO dele. A linha do `bytes` aqui em
baixo vem ANTES de propósito — sem ela este ficheiro passava mesmo com o defeito.
"""
import json as jsn

# o `bytes` primeiro: é ele que registava a chave partilhada
marca: bytes = b"\x7fELF"
print(marca.hex())

# ---- 1. um `any` declarado, com as cinco formas que o JSON tem ----
d: Dict<str, any> = {"a": "x", "b": 3, "c": True, "d": 1.5, "e": None}
print(jsn.stringify(d))

# ---- 2. o círculo fecha ----
v = jsn.parse('{"n":1,"s":"dois","l":[1,2,3],"o":{"k":true}}')
print(jsn.stringify(v))

# ---- 3. um `any` que atravessa uma FUNÇÃO, que é o caso do `httpd.json` ----
def envelope(x: any) -> str:
    return jsn.stringify(x)

print(envelope({"quem": "pscript", "quantos": 3}))
print(envelope([1, "dois", True, None]))

# ---- 4. e o `T?`, que é `null` — a palavra que o JSON tem para isso ----
struct Pessoa:
    nome: str
    idade: int?
    email: str?

print(jsn.stringify(Pessoa("Ana", 3, None)))
print(jsn.stringify(Pessoa("Rui", None, "rui@exemplo.pt")))
