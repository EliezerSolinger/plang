"""O portao do `idle_timeout`: uma conexao calada tem de ser fechada.

Existe porque o campo esteve declarado e MORTO, e isso e um slowloris de graca:
mil sockets abertos que nunca fazem um pedido enchem os workers e custam a quem
os abre um descritor cada. O `curl` nao serve para o provar — ele fala sempre —,
portanto isto e um socket cru que se cala de proposito.

E prova as DUAS metades, que e o que separa um portao de uma afirmacao:

  * uma conexao nova que nao diz nada fecha dentro do prazo;
  * uma conexao keep-alive que JA serviu um pedido e depois se cala fecha tambem
    — que e o caso que interessa, porque e o que um cliente normal deixa aberto;
  * e um pedido que chega DEPRESSA e servido, o que mostra que o prazo nao esta a
    matar trafego legitimo.
"""
import socket, sys, time

port = int(sys.argv[1])
prazo = float(sys.argv[2])


def espera_fecho(s, rotulo):
    t0 = time.time()
    s.settimeout(prazo * 4 + 2.0)
    try:
        d = s.recv(4096)
    except socket.timeout:
        print(f"{rotulo}: NAO FECHOU dentro de {prazo * 4 + 2.0:.1f}s")
        return
    dt = time.time() - t0
    if d == b"":
        # dentro do prazo, com folga para uma maquina partilhada
        print(f"{rotulo}: fechou, no prazo={dt <= prazo * 4 + 1.0}")
    else:
        print(f"{rotulo}: bytes inesperados {d[:40]!r}")


# 1. liga e cala-se
s1 = socket.create_connection(("127.0.0.1", port), timeout=10)
espera_fecho(s1, "calado desde o principio")
s1.close()

# 2. serve um pedido e SO DEPOIS se cala
s2 = socket.create_connection(("127.0.0.1", port), timeout=10)
s2.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n")
s2.settimeout(10)
resp = b""
while b"\r\n\r\n" not in resp:
    resp += s2.recv(65536)
print("o pedido foi servido:", resp.split(b"\r\n")[0].decode())
espera_fecho(s2, "calado depois de servir")
s2.close()
