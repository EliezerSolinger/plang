"""As RECUSAS, que é onde uma implementação de WebSocket se separa das outras.

Fazer o quadro é fácil. A suíte Autobahn existe porque o que distingue uma
implementação a sério são as coisas que ela se recusa a aceitar — e cada recusa
tem um código de fecho certo, que também faz parte da resposta.

O ficheiro de vectores tem `nome código-esperado hex`, e o hex é um ou mais
quadros colados, tal como chegariam num só `read`.
"""
import <ws/ws.psc> as ws
import sys


def from_hex(h: str) -> bytes:
    v = h.from_hex()
    if v == None:
        raise error("hex invalido: " + h)
    return v


f0 = await open(sys.argv[1], "r")
linhas = await f0.readlines()
f0.close()

for linha0 in linhas:
    linha = linha0.rstrip()
    if len(linha) == 0 or linha.startswith("#"):
        continue
    campos = linha.split(" ")
    nome = campos[0]
    esperado = int(campos[1])
    bytes_ = from_hex(campos[2])

    # do lado do SERVIDOR: é ele que recebe os quadros de um cliente, e é onde a
    # Autobahn bate
    pr = ws.proto(True)
    pr.feed(bytes_)
    eventos = 0
    while True:
        ev = pr.next()
        if ev == None:
            break
        eventos += 1

    if pr.failed():
        print(nome + " " + str(pr.close_code_out()) + " " + pr.problem())
    else:
        print(nome + " 0 aceitou (" + str(eventos) + " eventos)")
