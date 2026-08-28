"""Um cliente WebSocket de socket CRU, para ver o que a biblioteca esconde.

Existe porque as coisas que estes portoes provam sao invisiveis a uma biblioteca
correcta:

  * a `websockets` do Python REMONTA uma mensagem fragmentada antes de a entregar,
    portanto com ela nao se distingue uma mensagem de 300 bytes num quadro de uma
    em cinco quadros -- e a diferenca e justamente o que se quer provar;
  * ela tambem RESPONDE aos pings automaticamente, o que torna impossivel testar o
    que o servidor faz com um cliente que NAO responde.

Por isso o aperto de mao e os quadros estao aqui escritos a mao, do RFC 6455. Nao
substitui o oraculo -- a `websockets` continua a ser quem confere os bytes nos dois
sentidos; isto responde as perguntas que ela nao pode responder.
"""
import base64, os, socket, struct, sys, time

OPS = {0x0: "CONT", 0x1: "TEXT", 0x2: "BIN", 0x8: "CLOSE", 0x9: "PING", 0xA: "PONG"}


def handshake(sock, host, port, path, subprotocols=None, extensions=None):
    key = base64.b64encode(os.urandom(16)).decode()
    req = f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
    req += "Upgrade: websocket\r\nConnection: Upgrade\r\n"
    req += f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
    if subprotocols:
        req += "Sec-WebSocket-Protocol: " + ", ".join(subprotocols) + "\r\n"
    if extensions:
        req += "Sec-WebSocket-Extensions: " + extensions + "\r\n"
    req += "\r\n"
    sock.sendall(req.encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = sock.recv(4096)
        if not d:
            raise RuntimeError("o servidor fechou durante o aperto de mao")
        buf += d
    head, rest = buf.split(b"\r\n\r\n", 1)
    lines = head.decode("latin1").split("\r\n")
    status = lines[0]
    hdrs = {}
    for ln in lines[1:]:
        if ":" in ln:
            k, v = ln.split(":", 1)
            hdrs[k.strip().lower()] = v.strip()
    return status, hdrs, rest


class Reader:
    """Le quadros, sem remontar nada e sem responder a nada."""

    def __init__(self, sock, rest=b"", chunk=65536, delay=0.0):
        self.sock, self.buf = sock, rest
        # a leitura ESTRANGULADA e o que cria a condicao do portao do trinco: com
        # o cliente a drenar devagar e sem parar, o `write` do servidor fica
        # cronicamente PARCIAL -- ele escreve o que cabe, estaciona no POLLOUT, e
        # abre espaco outra vez pouco depois. E nessa fresta que os bytes de outra
        # tarefa entram no meio de um quadro. Uma pausa TOTAL nao serve: durante
        # ela nada drena, portanto nada se intercala.
        self.chunk, self.delay = chunk, delay

    def need(self, n):
        while len(self.buf) < n:
            d = self.sock.recv(self.chunk)
            if not d:
                raise EOFError("o servidor fechou")
            self.buf += d
            if self.delay:
                time.sleep(self.delay)

    def frame(self):
        self.need(2)
        b0, b1 = self.buf[0], self.buf[1]
        fin = bool(b0 & 0x80)
        rsv1 = bool(b0 & 0x40)
        op = b0 & 0x0F
        masked = bool(b1 & 0x80)
        ln = b1 & 0x7F
        at = 2
        if ln == 126:
            self.need(4)
            ln = struct.unpack(">H", self.buf[2:4])[0]
            at = 4
        elif ln == 127:
            self.need(10)
            ln = struct.unpack(">Q", self.buf[2:10])[0]
            at = 10
        if masked:
            raise RuntimeError("um quadro de SERVIDOR nao pode vir mascarado (RFC 6455 s5.1)")
        self.need(at + ln)
        payload = self.buf[at:at + ln]
        self.buf = self.buf[at + ln:]
        return op, fin, rsv1, payload


def mask_frame(op, payload):
    """Um quadro de CLIENTE: mascarado, como o s5.1 obriga."""
    key = os.urandom(4)
    body = bytes(b ^ key[i & 3] for i, b in enumerate(payload))
    n = len(payload)
    out = bytes([0x80 | op])
    if n < 126:
        out += bytes([0x80 | n])
    elif n < 65536:
        out += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        out += bytes([0x80 | 127]) + struct.pack(">Q", n)
    return out + key + body


def main():
    mode, host, port, path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    args = sys.argv[5:]
    subs = None
    exts = None
    for a in args:
        if a.startswith("--subprotocols="):
            subs = a.split("=", 1)[1].split(",")
        if a.startswith("--extensions="):
            exts = a.split("=", 1)[1]
    sock = socket.create_connection((host, port), timeout=20)

    if mode == "handshake":
        status, hdrs, _ = handshake(sock, host, port, path, subs, exts)
        print("status", status.split()[1])
        for k in ("sec-websocket-protocol", "sec-websocket-extensions"):
            print(k, "=", hdrs.get(k, "<ausente>"))
        return

    if mode == "frames":
        # quantos quadros ler
        n = 1
        for a in args:
            if a.startswith("--n="):
                n = int(a.split("=", 1)[1])
        status, hdrs, rest = handshake(sock, host, port, path, subs, exts)
        r = Reader(sock, rest)
        total = b""
        for _ in range(n):
            op, fin, rsv1, payload = r.frame()
            print(f"{OPS.get(op, op)} fin={int(fin)} rsv1={int(rsv1)} len={len(payload)}")
            total += payload
        print("montado", len(total), "bytes")
        print("conteudo-ok", total.decode("utf-8", "replace") == "0123456789" * 30)
        return

    if mode == "keepalive":
        # Le e NAO responde ao ping. O servidor tem de desistir, e o codigo tem de
        # ser 1001 ("going away"): nao houve erro de protocolo nenhum, o outro
        # lado simplesmente nao esta la.
        limite = float(args[0]) if args and not args[0].startswith("--") else 10.0
        status, hdrs, rest = handshake(sock, host, port, path, subs, exts)
        sock.settimeout(limite)
        r = Reader(sock, rest)
        vistos = []
        try:
            while True:
                op, fin, rsv1, payload = r.frame()
                vistos.append(OPS.get(op, op))
                if op == 0x8:
                    code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else 0
                    print("sequencia", " ".join(vistos))
                    print("fechou com", code)
                    return
        except (EOFError, socket.timeout) as e:
            print("sequencia", " ".join(vistos))
            print("fechou com", "<nada: " + type(e).__name__ + ">")
        return

    if mode == "pong":
        # o contrario: RESPONDE ao ping, e a conexao tem de sobreviver ao prazo
        limite = float(args[0]) if args and not args[0].startswith("--") else 10.0
        status, hdrs, rest = handshake(sock, host, port, path, subs, exts)
        sock.settimeout(limite)
        r = Reader(sock, rest)
        pings = 0
        try:
            while True:
                op, fin, rsv1, payload = r.frame()
                if op == 0x9:
                    pings += 1
                    sock.sendall(mask_frame(0xA, payload))
                    if pings >= 2:
                        # dois pings respondidos: a conexao aguentou mais do que
                        # um ciclo de keepalive, que e o que se quer provar
                        print("pings respondidos", pings)
                        print("ainda aberta True")
                        return
                if op == 0x8:
                    code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else 0
                    print("pings respondidos", pings)
                    print("ainda aberta False (fechou com " + str(code) + ")")
                    return
        except (EOFError, socket.timeout):
            print("pings respondidos", pings)
            print("ainda aberta False (calou-se)")
        return

    if mode == "flood":
        # O TESTE DA INTERCALACAO. O cliente drena DEVAGAR E SEM PARAR: um
        # `SO_RCVBUF` pequeno mais uma pausa por leitura. Assim o `write` do
        # servidor e cronicamente PARCIAL -- ele escreve o que cabe e estaciona no
        # POLLOUT --, e e nessa fresta que um ping de outra tarefa pode entrar no
        # MEIO da carga de um fragmento. Sem um trinco por conexao, o que se le a
        # seguir nao e um quadro: e lixo alinhado ao contrario.
        esperado = int(args[0])
        atraso = float(args[1]) if len(args) > 1 else 0.004
        sock.close()
        sock = socket.socket()
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2048)
        sock.settimeout(60)
        sock.connect((host, port))
        status, hdrs, rest = handshake(sock, host, port, path, subs, exts)
        r = Reader(sock, rest, chunk=1024, delay=atraso)
        dados, pings, montado = 0, 0, b""
        try:
            while True:
                op, fin, rsv1, payload = r.frame()
                if op == 0x9:
                    pings += 1
                    continue
                if op == 0x8:
                    break
                if op in (0x0, 0x1, 0x2):
                    dados += 1
                    montado += payload
                    if fin:
                        break
        except Exception as e:
            print("CORROMPIDO:", type(e).__name__, str(e)[:60])
            print("montado", len(montado), "de", esperado, "| pings", pings)
            return
        alvo = (b"0123456789" * ((esperado // 10) + 1))[:esperado]
        print("pings entremeados", "sim" if pings > 0 else "nao")
        print("montado", len(montado), "esperado", esperado)
        print("intacto", montado == alvo)
        return

    raise SystemExit("modo desconhecido: " + mode)


if __name__ == "__main__":
    main()
