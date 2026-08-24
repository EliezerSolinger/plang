"""O que o par de oráculo não pode medir do açúcar de iteração (104).

O oráculo compara com o Python linha por linha; o que fica aqui é o que o Python
não tem para comparar: o laço dentro de um `async def` (onde a variável é campo
do frame, não local), o escopo da variável de laço (64.1, que DIVERGE do Python
de propósito) e o desempacotar com objetos coletados dentro da tupla.
"""

struct Node:
    label: str

async def soma(ns: List<int>) -> int:
    t = 0
    for i, v in enumerate(ns):
        await sleep(0.0)
        t += i * v
    return t

async def zipado(a: List<int>, b: List<str>) -> str:
    out = ""
    for n, s in zip(a, b):
        await sleep(0.0)
        out += f"{n}{s}"
    return out

ns = [1, 2, 3, 4]
print(await soma(ns))
print(await zipado(ns, ["a", "b"]))

# 64.1: a variável de laço vive no escopo do LAÇO. Quando o nome já existe
# fora, o `for` atribui a ele (como o Python); quando não existe, ele não
# sobrevive ao laço — e é aí que a linguagem diverge do Python de propósito.
v = "antes"
for i, v in enumerate(["p", "q"]):
    pass
print(v)

# tuplas com objeto coletado dentro, desempacotadas
nodes = [(Node("um"), 1), (Node("dois"), 2)]
for nd, k in nodes:
    print(f"{nd.label}={k}")

# o mesmo em comprehension, com o coletor no meio
labels = [f"{nd.label}:{k}" for nd, k in nodes]
print(labels)

# reversed sobre uma lista de objetos
for nd, k in nodes:
    print(nd.label)
back = [nd.label for nd in [Node("a"), Node("b"), Node("c")]]
print(back)
