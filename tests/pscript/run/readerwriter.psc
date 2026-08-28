"""`Reader` e `Writer`: uma função de cópia que serve ficheiro e socket.

É a razão de os dois serem TRAITS. Antes disto, uma função que movesse bytes de
um sítio para outro tinha de saber se a origem era um ficheiro ou um socket,
porque as duas não tinham nome comum nenhum — e escrevê-la duas vezes era o que
acontecia.

Os dois são `async`, e não por gosto: um ficheiro estaciona na piscina e um
socket estaciona no `poll`, portanto um `Reader` que não pudesse dizer `async`
não cobriria um socket — e um socket é metade da razão de haver um.

E a assinatura é a da 135.2 dos dois lados: um `Buffer` que quem chama já tem,
onde nele começar, e quantos bytes. **Nada é alocado e nada é copiado** — um
`Buffer` é malloc'd e não se move (52.3), então a chamada de sistema lê e
escreve nele directamente.
"""
import net
import os
import path


D: str = "rwdemo"


# A função que existe UMA vez e serve os três. O `R` e o `W` são lidos dos
# argumentos — ninguém escreve `copy<File, File>(...)` — e o limite é conferido
# onde o tipo concreto existe.
async def copy_all<R: Reader>(src: R, dst: File, buf: Buffer, chunk: int) -> int:
    """Tudo o que houver em `src`, para `dst`, sem alocar por pedaço."""
    total = 0
    while True:
        got = await src.read_into(buf, 0, chunk)
        if got == 0:
            return total
        await dst.write_from(buf, 0, got)
        total += got


async def drain<R: Reader>(src: R, buf: Buffer, chunk: int) -> int:
    """O mesmo genérico sobre outro tipo concreto: é a instanciação que prova
    que o limite não está preso a um deles."""
    total = 0
    while True:
        got = await src.read_into(buf, 0, chunk)
        if got == 0:
            return total
        total += got


async def server(srv: Socket) -> int:
    with await srv.accept() as c:
        await c.write("do outro lado\n")
        return 1


async def go() -> int:
    if not path.isdir(D):
        os.makedirs(D)
    source = path.join(D, "origem.bin")
    dest = path.join(D, "destino.bin")

    # ---- 1. um ficheiro com algo lá dentro ----
    f = await open(source, "w")
    await f.write(("linha de texto\n" * 40).encode())
    await f.close()

    # ---- 2. o genérico sobre um FICHEIRO ----
    nonlocal n
    with Buffer(64) as buf:
        src = await open(source, "r")
        dst = await open(dest, "w")
        n = await copy_all(src, dst, buf, 64)
        await src.close()
        await dst.close()
        print("copiou", n, "bytes em pedaços de 64")

    # o destino tem exactamente o mesmo conteúdo
    a = await open(source, "r")
    b = await open(dest, "r")
    ca = await a.read_all()
    cb = await b.read_all()
    await a.close()
    await b.close()
    print("igual:", ca == cb, len(ca))

    # ---- 3. o MESMO genérico sobre um SOCKET ----
    srv = net.listen(0)
    port_n = srv.port()

    t = server(srv)
    c = await net.connect("127.0.0.1", port_n)
    nonlocal read_n
    with Buffer(32) as buf2:
        read_n = await drain(c, buf2, 32)
    c.close()
    await t
    srv.close()
    print("do socket:", read_n, "bytes pelo mesmo genérico")

    # ---- 4. `freeze`: o bloco muda de dono sem cópia, e o Buffer morre ----
    bf = Buffer(8)
    v = bf.view_u8()
    for i in range(8):
        v[i] = u8(65 + i)
    frozen = bf.freeze()
    print("congelado:", str(frozen), len(frozen))
    try:
        # congelar duas vezes é o engano que a 135.4 previne: o bloco já tem
        # dono. (`size()` não é a que fala — ela responde 0 e não levanta,
        # porque não precisa de contexto e não pode falhar.)
        bf.freeze()
        print("ISTO NÃO DEVIA APARECER")
    catch e:
        print("e o Buffer foi-se:", e.message)

    return n


await go()
print("readerwriter-ok")
