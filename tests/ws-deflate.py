"""F9b/RFC 7692: permessage-deflate, com a `websockets` do Python por oráculo.

O que se prova é a negociação nos dois sentidos e o que ela poupa NO FIO — e a
última metade não se vê com a biblioteca, que entrega a mensagem já
descomprimida. Por isso a segunda parte fala o protocolo em cru.
"""
import asyncio, base64, os, socket, struct, sys, websockets


async def com_a_biblioteca(port):
    uri = f"ws://127.0.0.1:{port}/ws"
    async with websockets.connect(uri) as w:
        ext = [str(e) for e in w.protocol.extensions]
        print("negociou", len(ext) == 1 and "PerMessageDeflate" in ext[0])
        print("sem takeover dos dois lados",
              "remote_no_context_takeover=True" in ext[0] and "local_no_context_takeover=True" in ext[0])
        await w.recv()
        g = '{"tipo":"move","x":10,"y":4,"jogador":"ana"}' * 20
        await w.send(g)
        print("eco-comprimido", (await w.recv()) == "eco:" + g)
        # e o inverso: a biblioteca comprime, nós descomprimimos
        await w.send("z" * 5000)
        print("do-cliente", len((await w.recv())) - 4 == 5000)
    # sem a extensão, o servidor não a impõe
    async with websockets.connect(uri, compression=None) as w2:
        print("sem-extensao", [str(e) for e in w2.protocol.extensions] == [])
        await w2.recv()
        await w2.send("simples")
        print("eco-simples", (await w2.recv()) == "eco:simples")


def aperto(port, com_deflate):
    s = socket.create_connection(("127.0.0.1", port))
    k = base64.b64encode(os.urandom(16)).decode()
    ext = "\r\nSec-WebSocket-Extensions: permessage-deflate; client_no_context_takeover" if com_deflate else ""
    s.sendall((f"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {k}\r\nSec-WebSocket-Version: 13{ext}\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(4096)
    cab, resto = buf.split(b"\r\n\r\n", 1)
    return s, resto


def le_quadro(s, resto):
    d = resto
    while len(d) < 2:
        d += s.recv(4096)
    n = d[1] & 0x7f
    off = 2
    if n == 126:
        while len(d) < 4:
            d += s.recv(4096)
        n = struct.unpack(">H", d[2:4])[0]
        off = 4
    elif n == 127:
        while len(d) < 10:
            d += s.recv(4096)
        n = struct.unpack(">Q", d[2:10])[0]
        off = 10
    while len(d) < off + n:
        d += s.recv(4096)
    return off + n, d[off + n:], (d[0] & 0x40) != 0


def envia(s, texto):
    m = os.urandom(4)
    p = texto.encode()
    c = bytes(b ^ m[i & 3] for i, b in enumerate(p))
    h = bytes([0x81])
    if len(p) < 126:
        h += bytes([0x80 | len(p)])
    elif len(p) < 65536:
        h += bytes([0x80 | 126]) + struct.pack(">H", len(p))
    else:
        h += bytes([0x80 | 127]) + struct.pack(">Q", len(p))
    s.sendall(h + m + c)


def no_fio(port):
    g = '{"tipo":"move","x":10,"y":4,"jogador":"ana"}' * 20
    tamanhos = {}
    for com in (False, True):
        s, resto = aperto(port, com)
        _, resto, _ = le_quadro(s, resto)
        envia(s, g)
        n, _, rsv1 = le_quadro(s, resto)
        tamanhos[com] = (n, rsv1)
        s.close()
    print("sem-deflate-rsv1", tamanhos[False][1])
    print("com-deflate-rsv1", tamanhos[True][1])
    # o que interessa: comprime MESMO. Um décimo é folgado — a medição dá 60
    # contra 888 — e o portão não prende o número exacto, que depende do
    # compressor.
    print("comprime-de-verdade", tamanhos[True][0] * 10 < tamanhos[False][0])


asyncio.run(com_a_biblioteca(int(sys.argv[1])))
no_fio(int(sys.argv[1]))
