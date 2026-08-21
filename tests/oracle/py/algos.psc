"""Ordenação estável, `bisect` e `heapq` (106), contra o Python.

O `heapq` é comparado pelo ARRAY INTEIRO a cada passo, e não só pela ordem em
que os itens saem: um heap correto pode ter mil formas, e só uma delas é a que o
`Lib/heapq.py` produz. Se os dois arrays batem em cada `heapify`, `heappush` e
`heappop`, o porte é fiel à ordem de peneira do CPython — que é o que se quis
portar, em vez de escrever um heap qualquer.

A ordenação é comparada com padrões, não só com ruído: já ordenado, ao
contrário, serra, tudo igual, dois valores. É onde a detecção de corridas do
merge sort pode errar, e é onde `qsort` deixava a estabilidade por conta de
qual libc compilou.
"""

import bisect
import heapq
import random

# ---- ordenação: os padrões ----
random.seed(4242)
casos = [
    [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5],
    [1, 2, 3, 4, 5, 6, 7, 8],
    [8, 7, 6, 5, 4, 3, 2, 1],
    [1, 1, 1, 1, 1],
    [2, 1],
    [1],
    [0, -0, 0, -0],
    [-5, 3, -1, 0, 7, -9],
]
for c in casos:
    print(sorted(c))

serra = [i % 7 for i in range(50)]
print(sorted(serra))
grande = [random.randrange(100) for i in range(300)]
print(sorted(grande))

# os floats, onde a estabilidade é VISÍVEL: 0.0 e -0.0 comparam iguais e
# imprimem diferente, então a ordem entre eles mostra se a ordenação é estável
print(sorted([0.0, -0.0, 0.0, -0.0]))
print(sorted([-0.0, 0.0, -0.0, 0.0]))
print(sorted([1.5, -0.0, 0.0, -2.5, 3.5]))
print(sorted(["pera", "uva", "abacate", "uva", "manga"]))
vazia: list<int> = []
print(sorted(vazia))

# um tamanho de cada, até passar do minrun (32) e do primeiro merge
for n in range(0, 40):
    xs = [(n * 7 - i * 3) % 11 for i in range(n)]
    print(n, sorted(xs))

# ---- bisect ----
xs = [1, 3, 3, 3, 5, 7, 9]
for v in [0, 1, 2, 3, 4, 5, 8, 9, 10]:
    print(v, bisect.bisect_left(xs, v), bisect.bisect_right(xs, v), bisect.bisect(xs, v))
ins = [1, 3, 5]
bisect.insort(ins, 4)
print(ins)
bisect.insort(ins, 0)
print(ins)
bisect.insort(ins, 9)
print(ins)
bisect.insort_left(ins, 3)
print(ins)
bisect.insort_right(ins, 3)
print(ins)
ws = ["abacate", "manga", "pera"]
print(bisect.bisect_left(ws, "manga"), bisect.bisect_right(ws, "manga"), bisect.bisect_left(ws, "uva"))
bisect.insort(ws, "banana")
print(ws)
mt: list<int> = []
print(bisect.bisect_left(mt, 5), bisect.bisect_right(mt, 5))
bisect.insort(mt, 5)
print(mt)

# ---- heapq: o ARRAY inteiro, passo a passo ----
h = [5, 3, 8, 1, 9, 2, 7, 0, 4, 6]
heapq.heapify(h)
print(h)
for v in [-1, 5, 100, 3, -20]:
    heapq.heappush(h, v)
    print(v, h)
while len(h) > 0:
    v = heapq.heappop(h)
    print(v, h)

h2: list<int> = []
for v in [4, 2, 9, 1, 7, 7, 3]:
    heapq.heappush(h2, v)
    print(h2)
heapq.heapify(h2)
print(h2)

hf = [2.5, -1.5, 0.0, 9.5]
heapq.heapify(hf)
print(hf)
print(heapq.heappop(hf), hf)

hs = ["pera", "abacate", "uva"]
heapq.heapify(hs)
print(hs)
print(heapq.heappop(hs), hs)

# um heap grande, para exercitar a peneira em vários níveis
random.seed(7)
hb = [random.randrange(1000) for i in range(200)]
heapq.heapify(hb)
print(hb)
saida = ""
while len(hb) > 0:
    saida += str(heapq.heappop(hb)) + ","
print(saida)
