"""`enumerate`, `zip`, `reversed` e o desempacotar (104), contra o Python.

Os quatro são AÇÚCAR: a sema os reescreve para o laço de índice que já existia,
porque um iterador de verdade precisaria de um objeto com cursor e o par que o
`enumerate` rende precisaria da tupla como valor dentro de contêiner. O que este
arquivo mede é justamente que a reescrita dá o MESMO que o Python dá — incluindo
o `zip` que para no mais curto e o `enumerate(xs, start)`.
"""

xs = ["ana", "bruno", "carla"]
ns = [10, 20, 30, 40]

for i, v in enumerate(xs):
    print(i, v)
for i, v in enumerate(xs, 1):
    print(i, v)
for i, v in enumerate(xs, -2):
    print(i, v)

# o zip para no MAIS CURTO, e a ordem dos operandos não muda isso
for a, b in zip(xs, ns):
    print(a, b)
for b, a in zip(ns, xs):
    print(b, a)
for a, b, c in zip(xs, ns, [1.5, 2.5, 3.5]):
    print(a, b, c)

for v in reversed(xs):
    print(v)
for n in reversed(ns):
    print(n)
for c in reversed("abc"):
    print(c)

# uma lista vazia não dá volta nenhuma nos quatro
empty = []
for i, v in enumerate(empty):
    print("nunca")
for a, b in zip(empty, ns):
    print("nunca")
for v in reversed(empty):
    print("nunca")

# sobre string, e sobre o que vem de uma chamada (a reescrita guarda num
# temporário, então a chamada acontece UMA vez)
for i, ch in enumerate("olá"):
    print(i, ch)
for i, w in enumerate("um dois tres".split(" ")):
    print(i, w)

# desempacotar uma lista de tuplas — e `d.items()` é isso
pairs = [("a", 1), ("b", 2), ("c", 3)]
for k, v in pairs:
    print(k, v)
trips = [(1, 2.5, "z"), (2, 3.5, "w")]
for a, b, c in trips:
    print(a, b, c)

d = {"x": 10, "y": 20}
for k, v in d.items():
    print(k, v)

# em comprehension: os quatro
print([f"{i}{v}" for i, v in enumerate(xs)])
print([f"{i}{v}" for i, v in enumerate(xs, 1)])
print([f"{a}{b}" for a, b in zip(xs, ns)])
print([v for v in reversed(xs)])
print([k for k, v in pairs])
print({k: v for k, v in pairs})
print({v: k for k, v in d.items()})
print({i for i, v in enumerate(xs) if v != "bruno"})
print([f"{i}{c}" for i, c in enumerate("hi")])

# uma comprehension sobre outra comprehension
print([x for x in [y * 2 for y in ns]])
print([len(s) for s in [f"n{i}" for i in range(3)]])

# aninhados, e com break/continue no meio
total = 0
for i, a in enumerate(xs):
    for j, b in enumerate(ns):
        if j == 2:
            break
        total += i * j
print(total)
for i, v in enumerate(xs):
    if i == 1:
        continue
    print("visto", v)
