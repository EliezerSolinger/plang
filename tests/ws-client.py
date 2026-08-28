"""O cliente do portão da F6: a biblioteca `websockets` do Python a bater no
NOSSO servidor. Ela é o oráculo — se ela aceita o aperto de mão, o aperto de mão
está certo, e se ela lê a mensagem, a mensagem foi bem escrita."""
import asyncio, sys, websockets


async def main(port):
    uri = f"ws://127.0.0.1:{port}/ws"
    async with websockets.connect(uri) as w:
        print("boas-vindas", (await w.recv()).startswith("bem-vindo"))
        await w.send("ola")
        print("eco-texto", await w.recv())
        await w.send(b"\x00\x01\xfe\xff")
        r = await w.recv()
        print("eco-binario", r.hex(), isinstance(r, bytes))
        await w.send("olá 日本語 \U0001f3ae")
        print("utf8", (await w.recv()) == "eco:olá 日本語 \U0001f3ae")

        # um PING é respondido pela biblioteca e NÃO chega ao handler: se
        # chegasse, o servidor de eco devolvia-o como mensagem e a fila do
        # cliente ficava com uma a mais
        pong = await w.ping(b"bate"); await pong
        print("pong-sem-eco", True)

        # e a mensagem a seguir ao ping é a certa, e não a anterior
        g = "x" * 200000
        await w.send(g)
        v = await w.recv()
        print("grande-depois-do-ping", len(v) - 4 == len(g))

        # fragmentada do lado do cliente, montada do nosso
        await w.send(["par", "te", "s"])
        print("fragmentada", await w.recv())

    # o fecho pedido pelo SERVIDOR chega com código e razão
    async with websockets.connect(uri) as w2:
        await w2.recv()
        await w2.send("fecha")
        try:
            await w2.recv()
            print("fecho ERRO: devia ter fechado")
        except websockets.ConnectionClosed as e:
            print("fecho", e.rcvd.code, e.rcvd.reason)

    # um handler que rebenta fecha com 1011 e NÃO leva o servidor
    async with websockets.connect(uri) as w3:
        await w3.recv()
        await w3.send("rebenta")
        try:
            await w3.recv()
            print("rebenta ERRO: devia ter fechado")
        except websockets.ConnectionClosed as e:
            print("rebenta", e.rcvd.code)
    async with websockets.connect(uri) as w4:
        print("continua-vivo", (await w4.recv()).startswith("bem-vindo"))

    # e o mesmo servidor continua a falar HTTP no resto dos caminhos
    import urllib.request
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/") as r:
        print("http-ao-lado", r.read().decode())


asyncio.run(main(int(sys.argv[1])))
