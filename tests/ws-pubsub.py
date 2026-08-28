"""F7/D6/D9c: os tópicos, com três clientes de verdade.

O que se prova aqui não é que a difusão chega — é que ela chega A QUEM ASSINA e
só a quem assina, que sair funciona, e que **fechar dessubscreve sozinho**. A
última é a que interessa num servidor de jogo: gente a entrar e a sair o dia
inteiro, e uma inscrição que sobrevivesse à conexão seria uma fuga que cresce com
o tempo de vida do processo.
"""
import asyncio, sys, websockets


async def main(port):
    uri = f"ws://127.0.0.1:{port}/ws"
    a = await websockets.connect(uri); await a.recv()
    b = await websockets.connect(uri); await b.recv()
    c = await websockets.connect(uri); await c.recv()

    await a.send("quantos"); print("no-lobby", await a.recv())

    # a difusão chega a TODOS os três, incluindo a quem publicou
    await a.send("difunde:mundo-tick-1")
    print("b-recebeu", await b.recv())
    print("c-recebeu", await c.recv())
    print("a-recebeu", await a.recv())
    print("quantos-alcancou", await a.recv())

    # sair do tópico deixa de receber
    await b.send("saio"); print("saiu", await b.recv())
    await a.send("difunde:tick-2")
    print("c-ainda-recebe", await c.recv())
    print("a-ainda-recebe", await a.recv())
    print("alcancou-menos", await a.recv())
    await b.send("quantos"); print("b-ve", await b.recv())

    # D9c: FECHAR dessubscreve, sem o programa se lembrar
    await c.close()
    await asyncio.sleep(0.3)
    await a.send("quantos"); print("depois-de-fechar", await a.recv())
    await a.close(); await b.close()


asyncio.run(main(int(sys.argv[1])))
