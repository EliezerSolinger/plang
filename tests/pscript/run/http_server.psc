"""Um servidor e um cliente HTTP, no mesmo processo (77.2/78.1).

O parser está em `lib_http.psc`, escrito em pscript a partir da especificação —
nenhum `.c` de terceiro entrou no runtime. Este programa põe os dois lados para
conversar por um socket de verdade, na mesma thread, o que só é possível
porque cada espera ESTACIONA: se `accept` bloqueasse, o cliente nunca chegaria
a conectar.

O que ele exercita, de propósito:

  * leitura INCREMENTAL: o servidor lê 64 bytes por vez e alimenta o parser
    até ele dizer que o pedido acabou — que é como um servidor de verdade
    trabalha, porque `read(n)` devolve o que houver (79.2);
  * corpo com `content-length` e corpo em PEDAÇOS (chunked);
  * as recusas que o llhttp também faz: espaço antes dos dois-pontos, e
    `content-length` junto com `chunked`.
"""

import net
import lib_http as http


async def servidor(srv: socket, quantos: int) -> int:
    atendidos = 0
    for i in range(quantos):
        with await srv.accept() as c:
            p = http.novo_parser()
            pronto = False
            while not pronto:
                pedaco = await c.read(64)
                if len(pedaco) == 0:
                    break
                pronto = p.feed(pedaco)
            if not pronto:
                await c.write(http.resposta(400, "Bad Request", "text/plain", p.problema))
                continue
            r = p.pedido()
            corpo = "metodo=" + r.method + " alvo=" + r.target
            corpo += " host=" + r.header("host")
            corpo += " corpo=" + str(r.body)
            await c.write(http.resposta(200, "OK", "text/plain", corpo))
            atendidos += 1
    return atendidos


async def cliente(porta: int, texto: str) -> str:
    with await net.connect("127.0.0.1", porta) as c:
        await c.write(texto)
        # a resposta pode vir em pedaços como qualquer outra coisa
        todo: list<u8> = []
        while True:
            parte = await c.read(128)
            if len(parte) == 0:
                break
            for b in parte:
                todo.append(b)
        return str(todo)


def ultima_linha(s: str) -> str:
    partes = s.split("\r\n\r\n")
    return partes[len(partes) - 1] if len(partes) > 1 else s


srv = net.listen(0)
porta = srv.port()
s = servidor(srv, 3)

# 1. um GET simples
r1 = await cliente(porta, http.pedido("GET", "/ola", "exemplo.local", ""))
print("1:", ultima_linha(r1))

# 2. um POST com corpo
r2 = await cliente(porta, http.pedido("POST", "/eco", "exemplo.local", "ola mundo"))
print("2:", ultima_linha(r2))

# 3. um pedido em PEDAÇOS, montado à mão
em_pedacos = "POST /pedacos HTTP/1.1\r\nhost: exemplo.local\r\ntransfer-encoding: chunked\r\n\r\n"
em_pedacos += "5\r\nabcde\r\n3\r\nfgh\r\n0\r\n\r\n"
r3 = await cliente(porta, em_pedacos)
print("3:", ultima_linha(r3))

print("atendidos:", await s)
srv.close()

# ---- as recusas, sem precisar de socket ----
mau = http.novo_parser()
bytes_maus: list<u8> = []
for ch in "GET / HTTP/1.1\r\nhost : x\r\n\r\n":
    bytes_maus.append(u8(ord(ch)))
mau.feed(bytes_maus)
print("recusa 1:", mau.problema)

mau2 = http.novo_parser()
b2: list<u8> = []
for ch in "GET / HTTP/1.1\r\ncontent-length: 3\r\ntransfer-encoding: chunked\r\n\r\n":
    b2.append(u8(ord(ch)))
mau2.feed(b2)
print("recusa 2:", mau2.problema)
