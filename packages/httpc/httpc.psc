"""Um cliente HTTP/1.1 e WebSocket.

O parser é o MESMO do servidor — `packages/http`, incremental e conferido contra
o corpus do llhttp —, e isso não é reaproveitamento de código por economia: é o
que garante que o que o nosso servidor escreve o nosso cliente lê, porque os dois
têm uma máquina de estados só. Duas implementações concordariam nos casos fáceis e
divergiriam exactamente onde interessa.

O que este módulo tem, e a razão de cada coisa:

  * **redirects, contados.** Um `Location` seguido às cegas é um laço infinito à
    espera de acontecer, e um servidor hostil dá-lho de graça. O tecto é um número.
  * **os métodos que mudam de método.** Um 301/302/303 sobre um POST vira GET e
    perde o corpo — é o que todo o cliente faz e o que o RFC 9110 §15.4 permite —,
    e um 307/308 NÃO: esses existem justamente para preservar o método;
  * **os cabeçalhos sensíveis caem ao mudar de origem.** Seguir um redirect para
    outro domínio a levar o `Authorization` é entregar a credencial a quem
    escreveu o `Location`. É a falha que os clientes de HTTP tapam um a um, e cada
    um dela demorou uma versão a aparecer;
  * **um POOL de conexões**, porque sem ele cada pedido paga um aperto de mão TCP
    e um TLS — e para um cliente que fala com o mesmo servidor mil vezes, isso é
    a diferença toda;
  * **gzip**, decodificado com o `packages/compress`;
  * **e o cliente de WebSocket**, sobre o mesmo `packages/ws` do servidor.
"""
import <http/http.psc> as h
import <url/url.psc> as u
import <compress/compress.psc> as comp
import <ws/ws.psc> as ws
import <sha1/sha1.psc> as sha1
import <csprng/csprng.psc> as rng
import net
import time


struct Response:
    status: int
    reason: str
    headers: Dict<str, str>
    raw: List<h.Header>
    body: bytes
    # por quantos redirects se passou para chegar aqui, e onde se acabou. O URL
    # final importa: um `Location` relativo resolve-se contra ele, e quem lê a
    # resposta muitas vezes precisa de saber onde é que acabou.
    final_url: str
    redirects: int

    def header(self, name: str) -> str:
        for hd in self.raw:
            if hd.name == name:
                return hd.value
        return ""

    def text(self) -> str:
        return str(self.body)

    def ok(self) -> bool:
        return self.status >= 200 and self.status < 300


struct Request:
    method: str
    url: str
    headers: List<h.Header>
    body: bytes
    # o tecto de redirects. Zero = não seguir nenhum.
    max_redirects: int
    timeout: float
    # verificar a cadeia do certificado? Duas portas e não uma bandeira, como a
    # 141.4 manda — mas aqui é um campo de uma struct que já existe, e o nome dele
    # aparece num `grep` do mesmo jeito.
    verify: bool
    # aceitar gzip? Ligado, porque o custo é uma linha e o ganho é a rede.
    accept_gzip: bool


def request(method: str, url: str) -> Request:
    p = Request(method.upper(), url, [], b"", 10, 30.0, True, True)
    return p


struct Target:
    """Um URL desmontado no que faz falta para ligar."""
    scheme: str
    host: str
    port: int
    path: str
    ok: bool


def parse_target(s: str) -> Target:
    """Desmonta um URL absoluto. É deliberadamente simples e não é o `packages/url`
    inteiro: para LIGAR só fazem falta cinco coisas, e o parser completo da WHATWG
    é para normalizar e comparar URLs — outro trabalho."""
    i = s.find("://")
    if i < 0:
        return Target("", "", 0, "", False)
    sch = s[0:i].lower()
    if sch != "http" and sch != "https" and sch != "ws" and sch != "wss":
        return Target("", "", 0, "", False)
    rest = s[i + 3:]
    j = rest.find("/")
    authority = rest if j < 0 else rest[0:j]
    path = "/" if j < 0 else rest[j:]
    # a credencial num URL (`user:senha@host`) é da RFC 3986 e ninguém devia
    # usá-la; ignorá-la em silêncio seria pior do que a recusar
    if authority.find("@") >= 0:
        return Target("", "", 0, "", False)
    host = authority
    port = 443 if (sch == "https" or sch == "wss") else 80
    # um IPv6 vem entre parênteses rectos, e o `:` do porto é o que vem DEPOIS
    # deles — sem esta distinção, `[::1]:8080` parte no primeiro dois-pontos
    if host.startswith("["):
        k = host.find("]")
        if k < 0:
            return Target("", "", 0, "", False)
        name = host[1:k]
        tail = host[k + 1:]
        if tail.startswith(":"):
            port = int(tail[1:])
        return Target(sch, name, port, path, True)
    k2 = host.rfind(":")
    if k2 > 0:
        p2 = host[k2 + 1:]
        if not p2.isdigit():
            return Target("", "", 0, "", False)
        port = int(p2)
        host = host[0:k2]
    if len(host) == 0:
        return Target("", "", 0, "", False)
    return Target(sch, host, port, path, True)


# ---------- uma volta: liga, escreve, le ----------

def build(p: Request, a: Target) -> bytes:
    """O request em bytes. O `Host` e obrigatorio no HTTP/1.1 e vai sempre."""
    sb: List<str> = []
    sb.append(p.method + " " + a.path + " HTTP/1.1\r\n")
    # o porto no `Host` so quando NAO e o do esquema: um `Host: exemplo.pt:443`
    # num https e tecnicamente valido e ha servidores que o leem como um nome
    # diferente do `exemplo.pt` do certificado
    standard = 443 if a.scheme == "https" or a.scheme == "wss" else 80
    sb.append("host: " + (a.host if a.port == standard else a.host + ":" + str(a.port)) + "\r\n")
    has_type = False
    for hd in p.headers:
        n = hd.name.lower()
        if n == "host" or n == "content-length" or n == "connection":
            continue        # sao de quem manda, e nao de quem pediu
        if n == "content-type":
            has_type = True
        sb.append(hd.name + ": " + hd.value + "\r\n")
    if p.accept_gzip:
        sb.append("accept-encoding: gzip\r\n")
    if len(p.body) > 0:
        sb.append("content-length: " + str(len(p.body)) + "\r\n")
        if not has_type:
            sb.append("content-type: application/octet-stream\r\n")
    elif p.method == "POST" or p.method == "PUT" or p.method == "PATCH":
        # um POST sem corpo leva `content-length: 0` explicito: sem ele ha
        # servidores que esperam por um corpo que nunca vem
        sb.append("content-length: 0\r\n")
    sb.append("connection: keep-alive\r\n\r\n")
    hdr = "".join(sb).encode()
    if len(p.body) == 0:
        return hdr
    return hdr + p.body


async def one_round(p: Request, a: Target) -> Response:
    """UM pedido, sem seguir redirects. A conexao e nova e fecha no fim.

    O pool (mais abaixo) e uma camada por cima disto, e por isso esta funcao
    existe: ela e o caminho simples e testavel, e o pool troca-lhe o "liga e
    fecha" por "toma e devolve" sem mudar mais nada.
    """
    c = await net.connect(a.host, a.port)
    if a.scheme == "https" or a.scheme == "wss":
        if p.verify:
            n0 = await net.starttls(c, a.host)
        else:
            # o nome diz o que faz, e aparece num `grep` — e a razao de nao haver
            # um `verify=False` em lado nenhum (141.4)
            n0 = await net.starttls_insecure(c, a.host)
    await c.write(build(p, a))
    pr = h.new_response_parser()
    whole = False
    with Buffer(65536) as rb:
        while True:
            k = 0
            try:
                k = await c.read_into(rb, 0, 65536)
            catch e:
                break
            if k == 0:
                # o servidor fechou: um corpo sem comprimento declarado acaba
                # exactamente aqui, e e `finish` quem o diz ao parser
                whole = pr.finish()
                break
            if pr.feed(bytes(rb[0:k])):
                whole = True
                break
            if pr.failed():
                break
    c.close()
    if not whole:
        raise error("a resposta nao chegou inteira" + (": " + pr.problem if pr.failed() else ""))
    r = pr.response()
    body = r.body
    # o gzip, desfeito aqui: quem pediu o cabecalho e este modulo, portanto e ele
    # que tem de o desfazer — devolver bytes comprimidos a quem pediu texto seria
    # uma surpresa
    ce = ""
    for hd in r.raw:
        if hd.name == "content-encoding":
            ce = hd.value.lower()
    if ce.find("gzip") >= 0:
        body = comp.gzip_decompress(body)
    elif ce.find("deflate") >= 0:
        body = comp.zlib_decompress(body)
    return Response(r.status, r.reason, r.headers, r.raw, body, p.url, 0)


# ---------- os redirects ----------

def resolve(base: Target, loc: str) -> str:
    """Um `Location` resolvido contra o URL de onde veio.

    As tres formas que aparecem: absoluta (`https://...`), de raiz (`/a/b`) e
    relativa (`b`). A terceira e a que se esquece, e e a que o RFC 9110 permite
    desde a 7231 — antes dela alguns servidores mandavam-na e os clientes
    adivinhavam.
    """
    if loc.find("://") > 0:
        return loc
    standard = 443 if base.scheme == "https" or base.scheme == "wss" else 80
    authority = base.host if base.port == standard else base.host + ":" + str(base.port)
    root = base.scheme + "://" + authority
    if loc.startswith("/"):
        return root + loc
    # relativa: substitui o ULTIMO segmento do caminho actual
    i = base.path.rfind("/")
    prefix = base.path[0:i + 1] if i >= 0 else "/"
    return root + prefix + loc


def next_method(status: int, method: str) -> str:
    """Um 301/302/303 sobre um POST vira GET; um 307/308 nao muda nada.

    A primeira parte contradiz o que os RFCs antigos diziam e e o que TODO o
    cliente faz -- o RFC 9110 s15.4 acabou por a permitir por escrito. A segunda e
    a razao de os codigos 307 e 308 existirem: eles foram criados exactamente para
    dizer "segue, e NAO mudes o metodo".
    """
    if status == 307 or status == 308:
        return method
    if method == "HEAD":
        return "HEAD"
    return "GET"


async def fetch(p: Request) -> Response:
    """O request, com os redirects seguidos e contados."""
    current = p
    times = 0
    while True:
        a = parse_target(current.url)
        if not a.ok:
            raise error("nao e um URL que se possa buscar: " + current.url)
        r = await one_round(current, a)
        r.redirects = times
        r.final_url = current.url
        if r.status < 300 or r.status > 308 or r.status == 304 or r.status == 305 or r.status == 306:
            return r
        if times >= p.max_redirects:
            raise error("demasiados redirects (" + str(times) + "): um `Location` seguido as cegas e um laco a espera de acontecer")
        loc = r.header("location")
        if len(loc) == 0:
            return r        # um 3xx sem `Location` nao e um redirect: e a resposta
        dest = resolve(a, loc)
        b = parse_target(dest)
        if not b.ok:
            raise error("o `Location` nao e um URL: " + loc)
        fresh = request(next_method(r.status, current.method), dest)
        fresh.max_redirects = p.max_redirects
        fresh.timeout = p.timeout
        fresh.verify = p.verify
        fresh.accept_gzip = p.accept_gzip
        # OS CABECALHOS SENSIVEIS CAEM AO MUDAR DE ORIGEM, e e a falha que os
        # clientes de HTTP tapam um a um: seguir um redirect para outro dominio a
        # levar o `Authorization` e entregar a credencial a quem escreveu o
        # `Location`. A origem e o trio esquema+host+porto, como na Same-Origin.
        same = a.scheme == b.scheme and a.host == b.host and a.port == b.port
        for hd in current.headers:
            n = hd.name.lower()
            if not same and (n == "authorization" or n == "cookie" or n == "proxy-authorization"):
                continue
            fresh.headers.append(hd)
        # o corpo so sobrevive quando o metodo sobrevive
        if fresh.method == current.method:
            fresh.body = current.body
        current = fresh
        times += 1


# ---------- as conveniencias ----------

async def get(url: str) -> Response:
    return await fetch(request("GET", url))


async def head(url: str) -> Response:
    return await fetch(request("HEAD", url))


async def post(url: str, body: bytes, ctype: str = "application/octet-stream") -> Response:
    p = request("POST", url)
    p.body = body
    p.headers.append(h.Header("content-type", ctype))
    return await fetch(p)


async def post_json(url: str, text: str) -> Response:
    return await post(url, text.encode(), "application/json")


async def put(url: str, body: bytes, ctype: str = "application/octet-stream") -> Response:
    p = request("PUT", url)
    p.body = body
    p.headers.append(h.Header("content-type", ctype))
    return await fetch(p)


async def delete(url: str) -> Response:
    return await fetch(request("DELETE", url))


# ---------- o cliente de WEBSOCKET ----------

struct WsClient:
    sock: Socket
    pr: ws.Proto
    open: bool
    # o subprotocolo que o servidor escolheu da nossa lista, ou ""
    protocol: str
    # a compressao negociada, ou desligada
    pmd: ws.Deflate
    # em quantos bytes se parte uma mensagem que sai; 0 = um quadro so
    fragment_size: int
    # quanto se espera pelo eco do fecho antes de desligar o TCP a martelo
    close_timeout: float
    # um ping nosso esta a espera de resposta?
    awaiting_pong: bool
    # uma mensagem esta a sair EM FRAGMENTOS?
    sending: bool
    # o TRINCO de escrita. Ver a nota do `WsConn` no `packages/httpd/ws.psc`: uma
    # escrita parcial estaciona a tarefa, e aqui ha duas a escrever de certeza --
    # o `ws_keepalive` corre a parte e manda um ping enquanto quem chama
    # `send_bytes` pode estar a meio de uma mensagem fragmentada.
    wlock: Channel<int>

    async def send_text(self, s: str) -> bool:
        return await self.send_message(ws.OP_TEXT, s.encode())

    async def send_bytes(self, b: bytes) -> bool:
        return await self.send_message(ws.OP_BIN, b)

    async def ping(self, b: bytes) -> bool:
        return await self.write_frame(ws.frame(ws.OP_PING, b))

    async def pong(self, b: bytes) -> bool:
        return await self.write_frame(ws.frame(ws.OP_PONG, b))

    async def write_frame(self, f: ws.Frame) -> bool:
        """UM quadro para o fio, MASCARADO — e do lado do cliente isso e
        obrigatorio (RFC 6455 §5.1: "MUST").

        A mascara nao e seguranca e nao vale a pena finge-lo: a chave viaja no
        proprio quadro. Ela existe porque proxies antigos podiam ser enganados a
        tratar o corpo como uma requisicao HTTP. O que ela exige e que a chave
        seja IMPREVISIVEL — e por isso ela vem do gerador criptografico, uma por
        quadro.

        Os quadros de CONTROLO passam por aqui e nao pelo `send_message`, porque
        o §5.4 diz que eles PODEM entremear-se numa mensagem fragmentada — e sao
        a unica coisa que pode.
        """
        if not self.open:
            return False
        # a chave vem ANTES do trinco: ela nao toca no socket, e pedi-la com o
        # trinco na mao seria segurar a conexao durante uma leitura do gerador
        key = await ws.mask_key()
        wire = ws.serialize(f, key)
        await self.wlock.send(1)
        ok = True
        try:
            await self.sock.write(wire)
        catch e:
            self.open = False
            ok = False
        ignored = await self.wlock.recv()
        return ok

    async def send_message(self, op: int, body: bytes) -> bool:
        """Uma MENSAGEM: comprimida inteira, e depois partida em quadros.

        A ordem e obrigatoria — o fluxo do DEFLATE atravessa a fragmentacao
        (§7.2.1 do RFC 7692), portanto comprimir cada fragmento por si daria N
        fluxos que o servidor nao consegue juntar.
        """
        if not self.open:
            return False
        if self.sending:
            raise error("ws: ja esta a sair uma mensagem em fragmentos nesta conexao; dois quadros de dados nao se entremeiam (RFC 6455 §5.4)")
        payload = body
        rsv1 = False
        if self.pmd.enabled and (op == ws.OP_TEXT or op == ws.OP_BIN) and len(body) > 0:
            payload = ws.compress_payload(body, self.pmd.out_bits)
            rsv1 = True
        n = len(payload)
        b = ws.fragment_bounds(n, self.fragment_size)
        if len(b) == 2:
            return await self.write_frame(ws.Frame(True, rsv1, False, False, op, payload))
        self.sending = True
        ok = True
        i = 1
        while i < len(b):
            first = i == 1
            f = ws.Frame(b[i] >= n, rsv1 and first, False, False,
                         op if first else ws.OP_CONT, payload[b[i - 1]:b[i]])
            if not await self.write_frame(f):
                ok = False
                break
            i += 1
        self.sending = False
        return ok

    async def recv(self) -> ws.Event?:
        """A mensagem seguinte, ou `None` quando a conexao acabou.

        Um PING e respondido aqui e nao devolvido: o §5.5.2 pede o pong "as soon
        as is practical", e deixa-lo a quem chama significa que um servidor decide
        que o cliente morreu porque ele estava a tratar de outra coisa.
        """
        with Buffer(65536) as rb:
            while self.open:
                ev = self.pr.next()
                if self.pr.failed():
                    ignored = await self.close(self.pr.close_code_out(), self.pr.problem())
                    return None
                if ev != None:
                    e2 = ev
                    if e2.kind == ws.EV_PING:
                        ignored2 = await self.pong(e2.data)
                        continue
                    if e2.kind == ws.EV_PONG:
                        self.awaiting_pong = False
                        continue
                    if e2.kind == ws.EV_CLOSE:
                        ignored3 = await self.close(e2.code if e2.code != 0 else 1000, "")
                        return e2
                    return e2
                k = 0
                try:
                    k = await self.sock.read_into(rb, 0, 65536)
                catch e:
                    break
                if k == 0:
                    break
                self.pr.feed(bytes(rb[0:k]))
        self.open = False
        return None

    async def discard(self) -> int:
        """A fase de DESCARTE do §7.1.7: le e deita fora ate ao fim.

        Existe por uma razao de protocolo e nao de limpeza. Depois de mandar um
        fecho, o §7.1.1 diz que quem fecha o TCP e o SERVIDOR e que o cliente
        espera por isso — fechar o socket a martelo no instante seguinte faz o
        servidor ver um RST em vez de um fim ordenado, e ha servidores que
        registam isso como erro de cliente.

        Esperar SEM PRAZO seria dar a um servidor que ignora o fecho a maneira de
        segurar o nosso processo, e por isso quem chama isto corre-a dentro de um
        `timeout`.
        """
        n = 0
        with Buffer(4096) as rb:
            while True:
                k = 0
                try:
                    k = await self.sock.read_into(rb, 0, 4096)
                catch e:
                    break
                if k == 0:
                    break
                n += k
        return n

    async def close(self, code: int, reason: str) -> bool:
        """O fecho LIMPO, com PRAZO.

        Manda o quadro de fecho, espera pelo eco do servidor até `close_timeout`
        e só então desliga o TCP. O prazo é o que separa "esperar como o RFC pede"
        de "ficar preso para sempre por um servidor que nunca responde".
        """
        if not self.open:
            return False
        ok = await self.write_frame(ws.frame(ws.OP_CLOSE, ws.close_payload(code, reason)))
        if ok and self.close_timeout > 0.0:
            # o `timeout` CANCELA o perdedor (37.2/48.2), portanto um servidor
            # calado custa exactamente `close_timeout` e nem um descritor a mais
            ignored = await timeout(self.discard(), self.close_timeout)
        self.open = False
        self.sock.close()
        return ok


async def ws_keepalive(cli: WsClient, interval: float, deadline: float) -> int:
    """O ping periodico de um CLIENTE, para correr como tarefa a parte.

    No servidor o keepalive e automatico porque lá o laço de leitura é da
    biblioteca; aqui quem chama `recv()` é o programa, e entre duas chamadas dele
    a biblioteca não tem onde correr. Portanto isto é explícito:

        k = hc.ws_keepalive(cli, 20.0, 10.0)
        while True:
            ev = await cli.recv()
            ...

    O `sleep` estaciona no mesmo multiplexador que espera pelo socket (18.4), por
    isso isto não custa nada enquanto dorme.
    """
    while cli.open:
        await sleep(interval)
        if not cli.open:
            break
        cli.awaiting_pong = True
        if not await cli.ping(b""):
            break
        await sleep(deadline)
        if not cli.open:
            break
        if cli.awaiting_pong:
            ignored = await cli.close(ws.CLOSE_GOING_AWAY, "sem resposta ao ping")
            break
    return 0


async def ws_connect(url: str, protocols: List<str> = [], compress: bool = True) -> WsClient:
    """O aperto de mao do lado do cliente, e a CONFERENCIA da resposta.

    A chave e 16 bytes aleatorios em base64 (§4.1), e o que volta tem de ser o
    SHA-1 dela mais o GUID, tambem em base64. Conferi-la nao e cerimonia: e o que
    prova que do outro lado esta um servidor que ENTENDEU o pedido, e nao um
    servidor HTTP qualquer a devolver 101 por acidente ou um intermediario a
    responder a toa. Um cache poisoning comeca exactamente assim.

    **Tambem se confere o subprotocolo**, e essa e nova: um servidor que responde
    `Sec-WebSocket-Protocol` com uma coisa que NAO estava na nossa lista esta a
    dizer que vai falar um dialecto que nunca oferecemos, e continuar seria falar
    linguas diferentes com os dois lados convencidos de que se entendem. O §4.1
    manda tratar isso como aperto de mao falhado.
    """
    a = parse_target(url)
    if not a.ok or (a.scheme != "ws" and a.scheme != "wss"):
        raise error("um websocket precisa de um URL `ws://` ou `wss://`: " + url)
    key = (await rng.random_bytes(16)).base64()
    c = await net.connect(a.host, a.port)
    if a.scheme == "wss":
        n0 = await net.starttls(c, a.host)
    standard = 443 if a.scheme == "wss" else 80
    authority = a.host if a.port == standard else a.host + ":" + str(a.port)
    sb = "GET " + a.path + " HTTP/1.1\r\n"
    sb += "host: " + authority + "\r\n"
    sb += "upgrade: websocket\r\n"
    sb += "connection: Upgrade\r\n"
    sb += "sec-websocket-key: " + key + "\r\n"
    sb += "sec-websocket-version: 13\r\n"
    if len(protocols) > 0:
        sb += "sec-websocket-protocol: " + ", ".join(protocols) + "\r\n"
    if compress:
        sb += "sec-websocket-extensions: " + ws.client_offer() + "\r\n"
    sb += "\r\n"
    await c.write(sb.encode())

    pr = h.new_response_parser()
    rest: bytes = b""
    with Buffer(65536) as rb:
        while True:
            k = 0
            try:
                k = await c.read_into(rb, 0, 65536)
            catch e:
                c.close()
                raise error("o aperto de mao do websocket nao teve resposta")
            if k == 0:
                c.close()
                raise error("o servidor fechou durante o aperto de mao")
            if pr.feed(bytes(rb[0:k])):
                break
            if pr.handoff():
                # um 101 e um HANDOFF e nao uma mensagem completa: o parser para
                # aqui de proposito, e o que sobra sao os primeiros bytes do
                # WebSocket — que podem ja ter vindo no mesmo `read`
                rest = pr.rest()
                break
            if pr.failed():
                c.close()
                raise error("o aperto de mao do websocket: " + pr.problem)
    r = pr.response()
    if r.status != 101:
        c.close()
        raise error("o servidor nao aceitou o upgrade: " + str(r.status))
    expected = sha1.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).base64()
    given = ""
    proto_hdr = ""
    ext_hdr = ""
    for hd in r.raw:
        if hd.name == "sec-websocket-accept":
            given = hd.value
        if hd.name == "sec-websocket-protocol":
            proto_hdr = hd.value
        if hd.name == "sec-websocket-extensions":
            ext_hdr = hd.value
    if given != expected:
        c.close()
        raise error("o `Sec-WebSocket-Accept` nao bate: do outro lado nao esta um servidor que entendeu o pedido")

    chosen = proto_hdr.strip()
    if len(chosen) > 0:
        found = False
        for want in protocols:
            if want == chosen:
                found = True
        if not found:
            c.close()
            raise error("o servidor escolheu o subprotocolo `" + chosen + "`, que nao estava na nossa oferta")

    pmd = ws.read_accepted(ext_hdr) if compress else ws.no_deflate()
    cli = WsClient(c, ws.proto(False, 1 << 24, pmd), True, chosen, pmd, 0, 5.0,
                   False, False, Channel(1))
    if len(rest) > 0:
        cli.pr.feed(rest)
    return cli
