"""Worker e async ao MESMO TEMPO (107), que é onde os dois modelos se encostam.

Cada worker tem heap, coletor e laço próprios (18.1/22.3), e a 74.1 já tinha
tirado o `recv` do condvar para que esperar uma mensagem não parasse as outras
tarefas. O que este arquivo cobre é o resto: a entrada do worker sendo um `async
def`, o `recv` dentro de uma task (e não no topo), dois esperando a MESMA fila,
o pai que acaba sem mandar nada, spawn aninhado, e o erro que atravessa.
"""

async def eco(n: int) -> int:
    """A entrada é `async`, e é isso que dá ao worker o direito de `await`."""
    total = 0
    while True:
        v = await parent.recv()
        if v == 0:
            break
        total += v
    parent.send(total)
    return total


async def soma(n: int) -> int:
    for i in range(n):
        parent.send(i * i)
    return n


async def coletor(w: Worker<int>, quantas: int) -> int:
    """`recv` DENTRO de uma task: enquanto ela espera, as outras andam."""
    t = 0
    for i in range(quantas):
        t += await w.recv()
    return t


async def ruido(marca: str, voltas: int) -> str:
    s = ""
    for i in range(voltas):
        await sleep(0.0)
        s += marca
    return s


async def neto(n: int) -> int:
    parent.send(n * 100)
    return n


async def filho(n: int) -> int:
    """spawn DENTRO de um worker: o filho tem o seu próprio filho."""
    g = spawn(neto, (n,))
    v = await g.recv()
    parent.send(v + 1)
    return v


async def quebra(n: int) -> int:
    await sleep(0.0)
    raise error("estourei no worker")


async def espera_sempre(n: int) -> int:
    """O pai nunca manda nada. Antes isto travava o programa para sempre: o
    `join` do fim esperava o worker, e o worker esperava uma mensagem que já não
    podia chegar. Agora o fim do pai FECHA o canal e o `recv` termina."""
    v = await parent.recv()
    return v


# ---- 1. ida e volta com entrada async ----
w = spawn(eco, (0,))
print(w.send(3), w.send(4), w.send(0))
print(f"eco {await w.recv()}")

# ---- 2. recv dentro de uma task, com outra task andando ao lado ----
s = spawn(soma, (5,))
c = coletor(s, 5)
r = ruido("r", 3)
print(f"coletor {await c} ruido {await r}")

# ---- 3. dois esperando a MESMA fila: quem chegou primeiro recebe primeiro ----
async def falante(n: int) -> int:
    await sleep(0.01)
    parent.send(1)
    await sleep(0.01)
    parent.send(2)
    return n

async def um(w2: Worker<int>, marca: str) -> str:
    v = await w2.recv()
    return f"{marca}{v}"

f = spawn(falante, (0,))
a = um(f, "A")
b = um(f, "B")
print(f"fila {await a} {await b}")

# ---- 4. spawn aninhado ----
nw = spawn(filho, (7,))
print(f"neto {await nw.recv()}")

# ---- 5. o erro do worker chega ao pai como Error ----
q = spawn(quebra, (1,))
await sleep(0.05)
e = q.error()
if e != None:
    print(f"erro {e.message}")
else:
    print("erro nenhum")

# ---- 6. o pai acaba sem mandar nada, e o programa TERMINA ----
z = spawn(espera_sempre, (0,))
print("fim do main")
