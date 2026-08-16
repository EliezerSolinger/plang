"""Socket (77.1): o outro lado do I/O, e o que ele NÃO precisa do pool.

Um socket tem modo não-bloqueante de verdade, então `accept`, `read` e `write`
são POLLED: o escalonador põe o descritor no mesmo `poll` que já roda desde a
74.1, e a chamada de sistema acontece aqui dentro, quando ela não pode mais
bloquear. Nada de thread. Já `connect` e a resolução de nome vão ao POOL,
porque `getaddrinfo` bloqueia e não há como convencê-lo do contrário — é a
divisão da libuv, e ela não é gosto: é o que o sistema operacional oferece.

O programa abaixo é um servidor e um cliente no MESMO processo e na mesma
thread. Isso só funciona porque cada espera estaciona: se `accept` bloqueasse,
o cliente nunca chegaria a conectar.

Duas coisas que o teste prende de propósito:

  * `read(n)` devolve até n bytes, e o vazio significa que o outro lado fechou
    (79.2) — a semântica do `recv`, que é o que um parser incremental quer;
  * `str(b)` é como bytes viram texto, e ele CONFERE: um `str` promete
    codepoints, então bytes que não são UTF-8 válido lançam em vez de produzir
    uma string que mente sobre o próprio tamanho (79.1/83.2).
"""

import net


async def servidor(srv: socket) -> int:
    total = 0
    for i in range(2):
        with await srv.accept() as c:
            pedido = await c.read(4096)
            total += len(pedido)
            await c.write("ok:" + str(pedido) + "\n")
            # o cliente fecha; a próxima leitura vê o fim
            resto = await c.read(16)
            if len(resto) == 0:
                total += 100
    return total


async def cliente(porta: int, texto: str) -> str:
    with await net.connect("127.0.0.1", porta) as c:
        await c.write(texto)
        resposta = await c.read(256)
        return str(resposta)


srv = net.listen(0)
porta = srv.port()
print("porta escolhida pelo sistema:", porta > 0)

s = servidor(srv)
a = await cliente(porta, "ping")
b = await cliente(porta, "pong")
print("cliente 1:", a)
print("cliente 2:", b)
print("servidor contou:", await s)
srv.close()

# o nome do próprio computador sempre resolve, com ou sem rede
ip = await net.lookup("localhost")
print("localhost resolve para algo:", len(ip) > 0)
