"""F3/D12: N workers no MESMO porto, e a prova é a contagem.

Cada resposta diz QUEM a serviu. Bate-se 200 vezes com uma conexão nova de cada
vez — porque é o accept que se está a testar, e o keep-alive esconde-o — e conta-se
quantos workers distintos responderam.

O que NÃO se afirma é a proporção: é uma dispersão da quádrupla feita pelo kernel,
e prendê-la seria prender a hash de outra pessoa. Afirma-se que mais de um serve e
que NENHUMA conexão se perde — o zero de falhas é a metade que interessa, e é o
que apanhou o defeito do `const` no worker.
"""
import socket, sys
from collections import Counter


def main(port, quantos):
    ok = 0
    falhas = 0
    quem = Counter()
    for _ in range(200):
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=5)
            s.sendall(b"GET /quem HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            buf = b""
            while True:
                d = s.recv(4096)
                if not d:
                    break
                buf += d
            s.close()
            if buf.startswith(b"HTTP/1.1 200"):
                ok += 1
                quem[buf.rsplit(b"\r\n\r\n", 1)[1].decode()] += 1
            else:
                falhas += 1
        except Exception:
            falhas += 1
    print("servidas", ok)
    print("falhas", falhas)
    print("mais de um worker serviu", len(quem) > 1)
    print("nenhum worker a mais", len(quem) <= quantos)


main(int(sys.argv[1]), int(sys.argv[2]))
