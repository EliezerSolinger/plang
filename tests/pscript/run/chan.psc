"""`Channel<T>` (S3/147): o canal entre TAREFAS.

**O canal é entre TAREFAS; o worker é entre THREADS.** É essa a regra, e o que
ela compra é concreto: um canal fica dentro de um heap só, portanto **não
serializa nada** — o valor que sai é o mesmo ponteiro que entrou, e o coletor
percorre a fila porque ela é um objecto como outro qualquer. O worker nunca
poderá ser barato assim, porque atravessar uma thread é copiar.

Antes disto, três tarefas na mesma thread não tinham como passar valores umas às
outras a não ser por `shared dict` — uma tabela fora dos heaps, com cadeado, para
um caso onde não há thread nenhuma.

**147.1 — `recv()` devolve `T?`, e a razão é a 4.2.** Chegar ao fim de um canal
faz parte do algoritmo, e o que faz parte do algoritmo devolve-se. O laço que
funciona com qualquer número de receptores não precisa de predicado nenhum; o
`open()` fica para o caso de um receptor só, que é o comum.

**147.2 — não é sondado.** Quem alimenta um canal é outra tarefa daqui, então um
`send` que encontra um receptor parado escreve no quadro dele e põe-no nos
prontos ali mesmo: sem `poll`, sem descritor, sem uma volta ao escalonador.
"""


record Point:
    x: int
    y: int


async def produce(ch: Channel<int>, n: int) -> int:
    for i in range(n):
        await ch.send(i * 10)
    ch.close()
    return n


async def consume(ch: Channel<int>) -> int:
    total = 0
    while True:
        v = await ch.recv()
        if v == None:
            break
        total += v
    return total


async def fill(ch: Channel<str>, n: int) -> int:
    for i in range(n):
        ok = await ch.send("valor-" + str(i))
        if not ok:
            return i
    return n


async def drain(ch: Channel<str>) -> int:
    c = 0
    while True:
        v = await ch.recv()
        if v == None:
            break
        c += 1
    return c


async def go() -> int:
    # ---- 1. o produtor é mais rápido do que o canal: o emissor ESTACIONA ----
    #
    # capacidade 2 para cinco valores. O anel cresce para lá da capacidade para
    # guardar o valor de quem está parado, e `len > cap` quer dizer exactamente
    # "há emissores à espera".
    ch: Channel<int> = Channel(2)
    p = produce(ch, 5)
    c = consume(ch)
    print("produziu", await p, "e a soma chegou inteira:", await c)

    # ---- 2. referências, e DOIS receptores ----
    #
    # é aqui que o predicado sozinho não chegaria: os dois podiam passar um
    # `open()` com um único valor na fila, e o segundo ficaria preso para sempre.
    # Fechar acorda os dois, e o `None` da 147.1 é o que os deixa sair.
    cs: Channel<str> = Channel(3)
    pe = fill(cs, 20)
    a = drain(cs)
    b = drain(cs)
    n = await pe
    cs.close()
    print("mandou", n, "e os dois leram", await a + await b)

    # ---- 3. um canal fechado RESPONDE, não levanta (4.2/45.3) ----
    z: Channel<int> = Channel(1)
    z.close()
    print("fechado aceita?", await z.send(1))
    print("e recv da None:", await z.recv() == None)

    # ---- 4. `open()` e `len()`: o predicado do worker, e a fila ----
    q: Channel<int> = Channel(4)
    await q.send(1)
    await q.send(2)
    print("open", q.open(), "len", q.len())
    q.close()
    # fechado com coisa lá dentro ainda está "aberto" para quem lê (36.1)
    print("fechado mas com fila:", q.open(), q.len())
    v1 = await q.recv()
    v2 = await q.recv()
    if v1 != None:
        if v2 != None:
            print("drenou", v1, v2)
    print("e agora nao:", q.open())

    # ---- 5. um registo atravessa por VALOR ----
    r: Channel<Point> = Channel(2)
    await r.send(Point(3, 4))
    pt = await r.recv()
    if pt != None:
        print("ponto", pt.x, pt.y)

    # ---- 6. a capacidade é pelo menos 1: não há encontro à Go (147) ----
    try:
        bad: Channel<int> = Channel(0)
        print("ISTO NAO DEVIA APARECER", bad.len())
    catch e:
        print("zero:", e.message)

    return 0


await go()
print("chan-ok")
