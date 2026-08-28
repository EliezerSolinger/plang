"""Ordenação estável, `bisect` e `heapq` (106) num programa de verdade.

O par de oráculo compara com o Python; o que fica aqui é o que ele não pode
comparar: as recusas, e os três sobre uma lista de OBJETOS coletados — que é
onde a peneira mexe em ponteiros e o coletor pode entrar no meio.
"""

import bisect
import heapq

struct Job:
    name_s: str
    prio: int

mt: List<int> = []
try:
    print(str(heapq.heappop(mt)))
catch e:
    print(f"heap vazio: {e.message}")

# uma fila de prioridade de verdade: as prioridades num heap, e o nome
# alcançado por um dict — que é como se faz sem tupla comparável
queue: List<int> = []
names: Dict<int, str> = {}
jobs = [Job("backup", 5), Job("email", 2), Job("deploy", 1), Job("log", 9)]
for t in jobs:
    heapq.heappush(queue, t.prio)
    names[t.prio] = t.name_s
order = ""
while len(queue) > 0:
    p = heapq.heappop(queue)
    order += names[p] + " "
print(order)

# a lista ordenada mantida por insort, com objetos alcançados pelo índice
keys_l: List<str> = []
for t in jobs:
    bisect.insort(keys_l, t.name_s)
print(keys_l)
print(bisect.bisect_left(keys_l, "email"), bisect.bisect_right(keys_l, "email"))

# ordenar uma lista de objetos por chave continua sendo `sorted(key=...)`, e é
# estável: as prioridades iguais saem na ordem em que entraram
more = [Job("a", 1), Job("b", 0), Job("c", 1), Job("d", 0), Job("e", 1)]
por_prio = sorted(more, key=lambda t: t.prio)
out_s = ""
for t in por_prio:
    out_s += t.name_s
print(out_s)

# e o coletor no meio: cada volta aloca uma string nova
big: List<int> = []
junk = ""
for i in range(200):
    heapq.heappush(big, (i * 37) % 200)
    junk += "x"
sum_v = 0
ant = -1
grows = True
while len(big) > 0:
    v = heapq.heappop(big)
    if v < ant:
        grows = False
    ant = v
    sum_v += v
print(f"200 saem em ordem: {grows} soma {sum_v} lixo {len(junk)}")
