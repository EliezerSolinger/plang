"""Os sockets que faltavam (F7): UDP e Unix.

**UDP: um datagrama não é um fluxo, e a assinatura muda por isso.** Num fluxo há
um par de pontas e ninguém pergunta de onde veio o que chegou; num socket de
datagramas cada pacote vem de onde vier. Por isso `recv_from` devolve os bytes E
DE QUEM VIERAM, e `send_to` leva o destino — e é essa a diferença que o
`read_into` da F1 não cobre sozinho.

**Unix: o mesmo `Socket` sobre um CAMINHO em vez de uma porta.** Herda tudo o
resto de graça — já é um fluxo, já é sondado no mesmo `poll`, e já fala `bytes`
desde a F1 — portanto o que ele acrescenta é uma linha de código e um mundo de
uso: é como dois processos na mesma máquina falam sem passar pela rede.
"""
import net
import os
import path


D: str = "udpdemo"


async def eco_unix(srv: Socket) -> int:
    with await srv.accept() as c:
        with Buffer(64) as rb:
            n = await c.read_into(rb, 0, 64)
            await c.write_from(rb, 0, n)
            return n


async def go() -> int:
    # ---- 1. UDP: um pacote, e quem o mandou ----
    a = net.udp(0)
    b = net.udp(0)
    port_a = a.port()
    print("as duas ligaram-se:", port_a > 0, b.port() > 0)

    with Buffer(64) as tx:
        v = tx.view_u8()
        msg = "ping"
        for i in range(len(msg)):
            v[i] = u8(ord(msg[i]))
        print("mandou", b.send_to(tx, 0, len(msg), "127.0.0.1", port_a), "bytes")

    with Buffer(64) as rx:
        # o `poll` do escalonador é quem diz quando há alguma coisa; aqui basta
        # dar uma volta ao laço de tarefas
        await sleep(0.05)
        de, n = a.recv_from(rx, 0, 64)
        print("chegou", n, "de alguem em 127.0.0.1:", de.startswith("127.0.0.1:"))
        print("conteudo:", str(bytes(rx[0:n])))

    # ---- 2. os dois métodos são de DATAGRAMAS, e um fluxo recusa-os ----
    srv = net.listen(0)
    try:
        with Buffer(4) as z:
            srv.send_to(z, 0, 1, "127.0.0.1", 1)
        print("ISTO NAO DEVIA APARECER")
    catch e:
        print("num fluxo:", e.message)
    srv.close()

    a.close()
    b.close()

    # ---- 3. Unix: o mesmo Socket sobre um caminho ----
    if not path.isdir(D):
        os.makedirs(D)
    sock = path.join(D, "s.sock")
    u = net.unix_listen(sock)
    t = eco_unix(u)
    c = net.unix(sock)
    with Buffer(32) as wb:
        w = wb.view_u8()
        text_s = "pelo caminho"
        for i in range(len(text_s)):
            w[i] = u8(ord(text_s[i]))
        await c.write_from(wb, 0, len(text_s))
        n2 = await c.read_into(wb, 0, 32)
        print("voltou:", str(bytes(wb[0:n2])))
    c.close()
    print("o servidor viu", await t, "bytes")
    u.close()
    os.remove(sock)

    return 0


await go()
print("udpunix-ok")
