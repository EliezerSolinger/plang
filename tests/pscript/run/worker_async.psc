"""Worker e async ao MESMO TEMPO (107), que é onde os dois modelos se encostam.

Cada worker tem heap, coletor e laço próprios (18.1/22.3), e a 74.1 já tinha
tirado o `recv` do condvar para que esperar uma mensagem não parasse as outras
tarefas. O que este arquivo cobre é o resto: a entrada do worker sendo um `async
def`, o `recv` dentro de uma task (e não no topo), dois esperando a MESMA fila,
o pai que acaba sem mandar nada, spawn aninhado, e o erro que atravessa.
"""

async def eco(n: int) -> int:
    """A entrada é `async`, e é isso que dá ao worker o direito de `await`.

    O laço pergunta ao CANAL se ainda pode chegar mensagem (107.8) em vez de
    combinar uma sentinela: `parent.open()` é falso quando o pai fechou — por
    `w.close()` ou por ter terminado — e a fila já está vazia.

    O `sleep` no começo não é enfeite: `open()` é um RETRATO do instante, então
    se a checagem correr com o `close` o laço dá uma volta a mais e recebe uma
    mensagem vazia (que soma zero, mas conta). Dormindo primeiro, as três
    mensagens e o `close` já chegaram quando o laço começa, e a contagem é 3 sob
    qualquer velocidade — inclusive com o coletor em estresse, que foi onde a
    corrida apareceu.
    """
    await sleep(0.05)
    total = 0
    how_many = 0
    while parent.open():
        v = await parent.recv()
        total += v
        how_many += 1
    parent.send(total * 100 + how_many)
    return total


async def sum_v(n: int) -> int:
    for i in range(n):
        parent.send(i * i)
    return n


async def collector(w: Worker<int>, how_many: int) -> int:
    """`recv` DENTRO de uma task: enquanto ela espera, as outras andam."""
    t = 0
    for i in range(how_many):
        t += await w.recv()
    return t


async def noise(tag: str, rounds: int) -> str:
    s = ""
    for i in range(rounds):
        await sleep(0.0)
        s += tag
    return s


async def neto(n: int) -> int:
    parent.send(n * 100)
    return n


async def child(n: int) -> int:
    """spawn DENTRO de um worker: o filho tem o seu próprio filho."""
    g = spawn(neto, (n,))
    v = await g.recv()
    parent.send(v + 1)
    return v


async def breaks(n: int) -> int:
    await sleep(0.0)
    raise error("estourei no worker")


async def waits_forever(n: int) -> int:
    """O pai nunca manda nada. Antes isto travava o programa para sempre: o
    `join` do fim esperava o worker, e o worker esperava uma mensagem que já não
    podia chegar. Agora o fim do pai FECHA o canal e o `recv` termina."""
    v = await parent.recv()
    return v


# ---- 1. ida e volta com entrada async ----
w = spawn(eco, (0,))
print(w.send(3), w.send(4), w.send(5))
w.close()
print(f"eco {await w.recv()}")

# ---- 2. recv dentro de uma task, com outra task andando ao lado ----
s = spawn(sum_v, (5,))
c = collector(s, 5)
r = noise("r", 3)
print(f"coletor {await c} ruido {await r}")

# ---- 3. dois esperando a MESMA fila: quem chegou primeiro recebe primeiro ----
async def talker(n: int) -> int:
    await sleep(0.01)
    parent.send(1)
    await sleep(0.01)
    parent.send(2)
    return n

async def um(w2: Worker<int>, tag: str) -> str:
    v = await w2.recv()
    return f"{tag}{v}"

f = spawn(talker, (0,))
a = um(f, "A")
b = um(f, "B")
print(f"fila {await a} {await b}")

# ---- 3b. do lado do pai: `alive()` drena o que um worker que já foi deixou ----
async def talk(n: int) -> int:
    for i in range(4):
        parent.send(i + 1)
    return n

fw = spawn(talk, (0,))
await sleep(0.1)
tot = 0
n_read = 0
while fw.alive():
    tot += await fw.recv()
    n_read += 1
print(f"drenou {tot} em {n_read}")

# ---- 4. spawn aninhado ----
nw = spawn(child, (7,))
print(f"neto {await nw.recv()}")

# ---- 5. o erro do worker chega ao pai como Error ----
q = spawn(breaks, (1,))
await sleep(0.05)
e = q.error()
if e != None:
    print(f"erro {e.message}")
else:
    print("erro nenhum")

# ---- 6. o pai acaba sem mandar nada, e o programa TERMINA ----
z = spawn(waits_forever, (0,))
print("fim do main")
