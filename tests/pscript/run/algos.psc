"""Ordenação estável, `bisect` e `heapq` (106) num programa de verdade.

O par de oráculo compara com o Python; o que fica aqui é o que ele não pode
comparar: as recusas, e os três sobre uma lista de OBJETOS coletados — que é
onde a peneira mexe em ponteiros e o coletor pode entrar no meio.
"""

import bisect
import heapq

struct Tarefa:
    nome: str
    prio: int

mt: List<int> = []
try:
    print(str(heapq.heappop(mt)))
catch e:
    print(f"heap vazio: {e.message}")

# uma fila de prioridade de verdade: as prioridades num heap, e o nome
# alcançado por um dict — que é como se faz sem tupla comparável
fila: List<int> = []
nomes: Dict<int, str> = {}
tarefas = [Tarefa("backup", 5), Tarefa("email", 2), Tarefa("deploy", 1), Tarefa("log", 9)]
for t in tarefas:
    heapq.heappush(fila, t.prio)
    nomes[t.prio] = t.nome
ordem = ""
while len(fila) > 0:
    p = heapq.heappop(fila)
    ordem += nomes[p] + " "
print(ordem)

# a lista ordenada mantida por insort, com objetos alcançados pelo índice
chaves: List<str> = []
for t in tarefas:
    bisect.insort(chaves, t.nome)
print(chaves)
print(bisect.bisect_left(chaves, "email"), bisect.bisect_right(chaves, "email"))

# ordenar uma lista de objetos por chave continua sendo `sorted(key=...)`, e é
# estável: as prioridades iguais saem na ordem em que entraram
mais = [Tarefa("a", 1), Tarefa("b", 0), Tarefa("c", 1), Tarefa("d", 0), Tarefa("e", 1)]
por_prio = sorted(mais, key=lambda t: t.prio)
saida = ""
for t in por_prio:
    saida += t.nome
print(saida)

# e o coletor no meio: cada volta aloca uma string nova
grande: List<int> = []
lixo = ""
for i in range(200):
    heapq.heappush(grande, (i * 37) % 200)
    lixo += "x"
soma = 0
ant = -1
cresce = True
while len(grande) > 0:
    v = heapq.heappop(grande)
    if v < ant:
        cresce = False
    ant = v
    soma += v
print(f"200 saem em ordem: {cresce} soma {soma} lixo {len(lixo)}")
