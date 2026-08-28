"""F2/D5: o corpo em pedaços chega EM PEDAÇOS, e não todo no fim.

É a única coisa que interessa provar aqui, e um `curl` normal não a prova — ele
junta tudo e mostra o resultado, que é indistinguível de uma resposta comum. O
que se mede são os TEMPOS de chegada: se o primeiro pedaço chega antes do último,
o servidor não os tamponou.
"""
import socket, sys, time


def main(port):
    s = socket.create_connection(("127.0.0.1", port))
    s.sendall(b"GET /fluxo HTTP/1.1\r\nHost: x\r\n\r\n")
    t0 = time.time()
    tempos = []
    buf = b""
    while b"0\r\n\r\n" not in buf:
        d = s.recv(4096)
        if not d:
            break
        buf += d
        tempos.append(time.time() - t0)
    s.close()
    print("pedacos", len(tempos) >= 3)
    print("incremental", tempos[0] < tempos[-1])
    print("chunked", b"transfer-encoding: chunked" in buf.lower())
    print("terminador", buf.endswith(b"0\r\n\r\n"))
    corpo = b"".join(l for l in buf.split(b"\r\n") if l.startswith(b"pedaco-"))
    print("corpo", corpo.decode())


main(int(sys.argv[1]))
