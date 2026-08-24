"""Contêiner de OPCIONAL de referência, sob o coletor (113).

`T?` de referência é o ponteiro nu — é a representação que a 9.4 escolheu, e ela
custa zero. Mas o predicado que diz "isto é referência" não conhecia o `?`:
`Dict<str, def(int,int)?>` nascia com `vref = False`, o coletor não seguia os
valores, e depois de uma coleta o dict devolvia ponteiro para o cemitério.

O teste é sobre PRESSÃO: alocar o suficiente para o coletor rodar no meio, e
depois LER tudo. Sem a correção, isto morre com SIGSEGV sob
`PSCRIPT_GC_STRESS=1` — e passava sem ele, que é o que o torna um teste do
coletor e não da linguagem.
"""

# List<str?>: metade None, e as cadeias criadas antes das coletas
names: List<str?> = []
for i in range(200):
    names.append(None if i % 2 == 0 else "nome-" + str(i))

# Dict<str, str?> e Dict<str, List<int>?>
by_key: Dict<str, str?> = {}
lists: Dict<str, List<int>?> = {}
for i in range(200):
    by_key["k" + str(i)] = None if i % 3 == 0 else "valor-" + str(i)
    lists["l" + str(i)] = None if i % 4 == 0 else [i, i + 1, i + 2]

# um struct com campo opcional de referência (o mesmo predicado decide o trace)
struct Node:
    name: str
    next: Node?
    tag: List<int>?

head: Node? = None
for i in range(200):
    head = Node("n" + str(i), head, None if i % 5 == 0 else [i])

# pressão: alocar bastante para o coletor rodar entre a escrita e a leitura
junk = 0
for i in range(3000):
    s = "lixo " + str(i) + " " * (i % 17)
    junk += len(s)

# e agora ler TUDO de volta
nn = 0
for v in names:
    if v != None:
        nn += len(v)
print("List<str?> " + str(nn))

sk = 0
for i in range(200):
    v = by_key["k" + str(i)]
    if v != None:
        sk += len(v)
    l = lists["l" + str(i)]
    if l != None:
        sk += l[0] + l[1] + l[2]
print("dict " + str(sk))

depth = 0
tags = 0
h = head
while h != None:
    depth += len(h.name)
    t = h.tag
    if t != None:
        tags += t[0]
    h = h.next
print("struct " + str(depth) + " " + str(tags))
print("junk " + str(junk))
