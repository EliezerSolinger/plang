"""O exemplo do servidor de jogo, ponta a ponta.

É o portão que junta tudo: estáticos, API, o upgrade com autorização ANTES dele,
e a difusão a atravessar os workers. Se este passa, a `packages/httpd` faz o que
o desenho prometeu.
"""
import asyncio, sys, urllib.error, urllib.request, websockets


async def main(porta):
    base = f"http://127.0.0.1:{porta}"
    with urllib.request.urlopen(base + "/") as r:
        print("index", r.read().decode().startswith("<!doctype html>"))
    with urllib.request.urlopen(base + "/jogo.js") as r:
        print("mime-js", r.headers["content-type"])
    with urllib.request.urlopen(base + "/api/estado") as r:
        print("api", "ligacoes" in r.read().decode())

    # o upgrade sem token é 401: a autorização é código normal ANTES dele (D9b)
    try:
        urllib.request.urlopen(base + "/ws")
        print("ws-sem-token ERRO: devia recusar")
    except urllib.error.HTTPError as e:
        print("ws-sem-token", e.code)

    # a travessia continua fechada, mesmo servindo estáticos por uma rota `*`
    try:
        urllib.request.urlopen(base + "/../../etc/passwd")
        print("travessia ERRO: devia recusar")
    except urllib.error.HTTPError as e:
        print("travessia", e.code)

    u = f"ws://127.0.0.1:{porta}/ws?jogador=%s"
    a = await websockets.connect(u % "ana")
    b = await websockets.connect(u % "rui")
    c = await websockets.connect(u % "zed")
    for w in (a, b, c):
        await w.recv()

    # A DIFUSÃO ATRAVESSA OS WORKERS: um manda, e todos recebem — estejam eles
    # no worker que estiverem.
    await a.send('{"tipo":"move","x":10}')
    ok = 0
    for w in (a, b, c):
        try:
            if await asyncio.wait_for(w.recv(), 3) == '{"tipo":"move","x":10}':
                ok += 1
        except asyncio.TimeoutError:
            pass
    print("difusao-de-ana", ok)

    # e do outro lado, que é o que prova que não é um worker a falar consigo
    await c.send('{"tipo":"bloco","id":7}')
    ok2 = 0
    for w in (a, b, c):
        try:
            if await asyncio.wait_for(w.recv(), 3) == '{"tipo":"bloco","id":7}':
                ok2 += 1
        except asyncio.TimeoutError:
            pass
    print("difusao-de-zed", ok2)

    for w in (a, b, c):
        await w.close()


asyncio.run(main(int(sys.argv[1])))
