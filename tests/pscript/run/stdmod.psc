"""`random`, `math` e `time` (103) — os três primeiros módulos da biblioteca.

Não são bibliotecas em pscript escritas por cima do que já havia: `math` é a
libm direta (nada a inventar) e `random` é o MT19937 do CPython PORTADO, para
que a mesma semente dê a mesma sequência que o Python — o par de oráculo em
tests/oracle/py/rng.psc compara número por número. Aqui ficam a superfície do
módulo, o que é int e o que é float, e as recusas.
"""

import random
import math
import time

# ---- com semente, tudo é determinístico e pode ir no .expected ----
random.seed(2026)
print(f"random {random.random()}")
print(f"bits {random.getrandbits(12)}")
print(f"dado {random.randint(1, 6)}")
print(f"range {random.randrange(50)} {random.randrange(10, 20)} {random.randrange(0, 30, 5)}")
print(f"uniform {random.uniform(1.0, 2.0)}")

cards = ["as", "rei", "dama", "valete", "dez"]
random.shuffle(cards)
print(f"shuffle {cards}")
# de novo: com esta semente a primeira passada devolve a ordem original (o
# Python devolve a mesma, é o par de oráculo que garante), então a segunda é
# que mostra que o embaralhamento realmente mexe
random.shuffle(cards)
print(f"shuffle {cards}")
print(f"choice {random.choice(cards)}")

# uma lista de objetos embaralha do mesmo jeito: o `shuffle` troca os `esize`
# bytes do elemento, e um elemento pode ser um ponteiro
struct Card:
    name_s: str

objs = [Card("a"), Card("b"), Card("c"), Card("d")]
random.shuffle(objs)
names = ""
for c in objs:
    names += c.name_s
print(f"objetos {names}")

print(f"gauss {random.gauss(0.0, 1.0)} {random.gauss(0.0, 1.0)}")
print(f"expo {random.expovariate(2.0)}")

# ---- math: floor/ceil/trunc devolvem INT, e é por isso que indexam ----
xs = [10, 20, 30, 40]
print(f"indexa {xs[math.floor(2.7)]} {xs[math.ceil(0.2)]}")
print(f"sqrt {math.sqrt(144.0)} hypot {math.hypot(3.0, 4.0)}")
print(f"pow {math.pow(2.0, 16.0)} log2 {math.log2(256.0)}")
print(f"pi {math.pi} e {math.e}")
print(f"inf {math.inf > 1e300} nan {math.nan != math.nan}")

# ---- time: `time()` é o relógio de parede, `monotonic()` é o que mede ----
t0 = time.monotonic()
sum_v = 0
for i in range(100000):
    sum_v += i
dt = time.monotonic() - t0
print(f"soma {sum_v} durou {dt >= 0.0}")
print(f"epoca {time.time() > 1600000000.0}")

# ---- as recusas em tempo de execução ----
try:
    print(random.getrandbits(64))
catch e:
    print("bits demais")

try:
    print(random.randrange(3, 3))
catch e:
    print(f"vazio: {e.message}")

try:
    print(random.randrange(0, 10, 0))
catch e:
    print(f"passo: {e.message}")
