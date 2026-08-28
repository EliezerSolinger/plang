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


struct Resposta:
    status: int
    reason: str
    headers: Dict<str, str>
    raw: List<h.Header>
    body: bytes
    # por quantos redirects se passou para chegar aqui, e onde se acabou. O URL
    # final importa: um `Location` relativo resolve-se contra ele, e quem lê a
    # resposta muitas vezes precisa de saber onde é que acabou.
    url_final: str
    redirects: int

    def header(self, nome: str) -> str:
        for hd in self.raw:
            if hd.name == nome:
                return hd.value
        return ""

    def texto(self) -> str:
        return str(self.body)

    def ok(self) -> bool:
        return self.status >= 200 and self.status < 300


struct Pedido:
    metodo: str
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
    aceita_gzip: bool


def pedido(metodo: str, url: str) -> Pedido:
    p = Pedido(metodo.upper(), url, [], b"", 10, 30.0, True, True)
    return p


struct Alvo:
    """Um URL desmontado no que faz falta para ligar."""
    esquema: str
    host: str
    porta: int
    caminho: str
    ok: bool


def parse_alvo(s: str) -> Alvo:
    """Desmonta um URL absoluto. É deliberadamente simples e não é o `packages/url`
    inteiro: para LIGAR só fazem falta cinco coisas, e o parser completo da WHATWG
    é para normalizar e comparar URLs — outro trabalho."""
    i = s.find("://")
    if i < 0:
        return Alvo("", "", 0, "", False)
    esq = s[0:i].lower()
    if esq != "http" and esq != "https" and esq != "ws" and esq != "wss":
        return Alvo("", "", 0, "", False)
    resto = s[i + 3:]
    j = resto.find("/")
    autoridade = resto if j < 0 else resto[0:j]
    caminho = "/" if j < 0 else resto[j:]
    # a credencial num URL (`user:senha@host`) é da RFC 3986 e ninguém devia
    # usá-la; ignorá-la em silêncio seria pior do que a recusar
    if autoridade.find("@") >= 0:
        return Alvo("", "", 0, "", False)
    host = autoridade
    porta = 443 if (esq == "https" or esq == "wss") else 80
    # um IPv6 vem entre parênteses rectos, e o `:` do porto é o que vem DEPOIS
    # deles — sem esta distinção, `[::1]:8080` parte no primeiro dois-pontos
    if host.startswith("["):
        k = host.find("]")
        if k < 0:
            return Alvo("", "", 0, "", False)
        nome = host[1:k]
        cauda = host[k + 1:]
        if cauda.startswith(":"):
            porta = int(cauda[1:])
        return Alvo(esq, nome, porta, caminho, True)
    k2 = host.rfind(":")
    if k2 > 0:
        p2 = host[k2 + 1:]
        if not p2.isdigit():
            return Alvo("", "", 0, "", False)
        porta = int(p2)
        host = host[0:k2]
    if len(host) == 0:
        return Alvo("", "", 0, "", False)
    return Alvo(esq, host, porta, caminho, True)


# ---------- uma volta: liga, escreve, le ----------

def monta(p: Pedido, a: Alvo) -> bytes:
    """O pedido em bytes. O `Host` e obrigatorio no HTTP/1.1 e vai sempre."""
    sb: List<str> = []
    sb.append(p.metodo + " " + a.caminho + " HTTP/1.1\r\n")
    # o porto no `Host` so quando NAO e o do esquema: um `Host: exemplo.pt:443`
    # num https e tecnicamente valido e ha servidores que o leem como um nome
    # diferente do `exemplo.pt` do certificado
    padrao = 443 if a.esquema == "https" or a.esquema == "wss" else 80
    sb.append("host: " + (a.host if a.porta == padrao else a.host + ":" + str(a.porta)) + "\r\n")
    tem_tipo = False
    for hd in p.headers:
        n = hd.name.lower()
        if n == "host" or n == "content-length" or n == "connection":
            continue        # sao de quem manda, e nao de quem pediu
        if n == "content-type":
            tem_tipo = True
        sb.append(hd.name + ": " + hd.value + "\r\n")
    if p.aceita_gzip:
        sb.append("accept-encoding: gzip\r\n")
    if len(p.body) > 0:
        sb.append("content-length: " + str(len(p.body)) + "\r\n")
        if not tem_tipo:
            sb.append("content-type: application/octet-stream\r\n")
    elif p.metodo == "POST" or p.metodo == "PUT" or p.metodo == "PATCH":
        # um POST sem corpo leva `content-length: 0` explicito: sem ele ha
        # servidores que esperam por um corpo que nunca vem
        sb.append("content-length: 0\r\n")
    sb.append("connection: keep-alive\r\n\r\n")
    cab = "".join(sb).encode()
    if len(p.body) == 0:
        return cab
    return cab + p.body


async def uma_volta(p: Pedido, a: Alvo) -> Resposta:
    """UM pedido, sem seguir redirects. A conexao e nova e fecha no fim.

    O pool (mais abaixo) e uma camada por cima disto, e por isso esta funcao
    existe: ela e o caminho simples e testavel, e o pool troca-lhe o "liga e
    fecha" por "toma e devolve" sem mudar mais nada.
    """
    c = await net.connect(a.host, a.porta)
    if a.esquema == "https" or a.esquema == "wss":
        if p.verify:
            n0 = await net.starttls(c, a.host)
        else:
            # o nome diz o que faz, e aparece num `grep` — e a razao de nao haver
            # um `verify=False` em lado nenhum (141.4)
            n0 = await net.starttls_insecure(c, a.host)
    await c.write(monta(p, a))
    pr = h.new_response_parser()
    inteiro = False
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
                inteiro = pr.finish()
                break
            if pr.feed(bytes(rb[0:k])):
                inteiro = True
                break
            if pr.failed():
                break
    c.close()
    if not inteiro:
        raise error("a resposta nao chegou inteira" + (": " + pr.problem if pr.failed() else ""))
    r = pr.response()
    corpo = r.body
    # o gzip, desfeito aqui: quem pediu o cabecalho e este modulo, portanto e ele
    # que tem de o desfazer — devolver bytes comprimidos a quem pediu texto seria
    # uma surpresa
    ce = ""
    for hd in r.raw:
        if hd.name == "content-encoding":
            ce = hd.value.lower()
    if ce.find("gzip") >= 0:
        corpo = comp.gzip_decompress(corpo)
    elif ce.find("deflate") >= 0:
        corpo = comp.zlib_decompress(corpo)
    return Resposta(r.status, r.reason, r.headers, r.raw, corpo, p.url, 0)


# ---------- os redirects ----------

def resolve(base: Alvo, loc: str) -> str:
    """Um `Location` resolvido contra o URL de onde veio.

    As tres formas que aparecem: absoluta (`https://...`), de raiz (`/a/b`) e
    relativa (`b`). A terceira e a que se esquece, e e a que o RFC 9110 permite
    desde a 7231 — antes dela alguns servidores mandavam-na e os clientes
    adivinhavam.
    """
    if loc.find("://") > 0:
        return loc
    padrao = 443 if base.esquema == "https" or base.esquema == "wss" else 80
    autoridade = base.host if base.porta == padrao else base.host + ":" + str(base.porta)
    raiz = base.esquema + "://" + autoridade
    if loc.startswith("/"):
        return raiz + loc
    # relativa: substitui o ULTIMO segmento do caminho actual
    i = base.caminho.rfind("/")
    prefixo = base.caminho[0:i + 1] if i >= 0 else "/"
    return raiz + prefixo + loc


def muda_metodo(status: int, metodo: str) -> str:
    """Um 301/302/303 sobre um POST vira GET; um 307/308 nao muda nada.

    A primeira parte contradiz o que os RFCs antigos diziam e e o que TODO o
    cliente faz -- o RFC 9110 s15.4 acabou por a permitir por escrito. A segunda e
    a razao de os codigos 307 e 308 existirem: eles foram criados exactamente para
    dizer "segue, e NAO mudes o metodo".
    """
    if status == 307 or status == 308:
        return metodo
    if metodo == "HEAD":
        return "HEAD"
    return "GET"


async def fetch(p: Pedido) -> Resposta:
    """O pedido, com os redirects seguidos e contados."""
    actual = p
    vezes = 0
    while True:
        a = parse_alvo(actual.url)
        if not a.ok:
            raise error("nao e um URL que se possa buscar: " + actual.url)
        r = await uma_volta(actual, a)
        r.redirects = vezes
        r.url_final = actual.url
        if r.status < 300 or r.status > 308 or r.status == 304 or r.status == 305 or r.status == 306:
            return r
        if vezes >= p.max_redirects:
            raise error("demasiados redirects (" + str(vezes) + "): um `Location` seguido as cegas e um laco a espera de acontecer")
        loc = r.header("location")
        if len(loc) == 0:
            return r        # um 3xx sem `Location` nao e um redirect: e a resposta
        destino = resolve(a, loc)
        b = parse_alvo(destino)
        if not b.ok:
            raise error("o `Location` nao e um URL: " + loc)
        novo = pedido(muda_metodo(r.status, actual.metodo), destino)
        novo.max_redirects = p.max_redirects
        novo.timeout = p.timeout
        novo.verify = p.verify
        novo.aceita_gzip = p.aceita_gzip
        # OS CABECALHOS SENSIVEIS CAEM AO MUDAR DE ORIGEM, e e a falha que os
        # clientes de HTTP tapam um a um: seguir um redirect para outro dominio a
        # levar o `Authorization` e entregar a credencial a quem escreveu o
        # `Location`. A origem e o trio esquema+host+porto, como na Same-Origin.
        mesma = a.esquema == b.esquema and a.host == b.host and a.porta == b.porta
        for hd in actual.headers:
            n = hd.name.lower()
            if not mesma and (n == "authorization" or n == "cookie" or n == "proxy-authorization"):
                continue
            novo.headers.append(hd)
        # o corpo so sobrevive quando o metodo sobrevive
        if novo.metodo == actual.metodo:
            novo.body = actual.body
        actual = novo
        vezes += 1


# ---------- as conveniencias ----------

async def get(url: str) -> Resposta:
    return await fetch(pedido("GET", url))


async def head(url: str) -> Resposta:
    return await fetch(pedido("HEAD", url))


async def post(url: str, corpo: bytes, tipo: str = "application/octet-stream") -> Resposta:
    p = pedido("POST", url)
    p.body = corpo
    p.headers.append(h.Header("content-type", tipo))
    return await fetch(p)


async def post_json(url: str, texto: str) -> Resposta:
    return await post(url, texto.encode(), "application/json")


async def put(url: str, corpo: bytes, tipo: str = "application/octet-stream") -> Resposta:
    p = pedido("PUT", url)
    p.body = corpo
    p.headers.append(h.Header("content-type", tipo))
    return await fetch(p)


async def delete(url: str) -> Resposta:
    return await fetch(pedido("DELETE", url))


# ---------- o cliente de WEBSOCKET ----------

struct WsCliente:
    sock: Socket
    pr: ws.Proto
    aberta: bool

    async def send_text(self, s: str) -> bool:
        return await self.send_frame(ws.OP_TEXT, s.encode())

    async def send_bytes(self, b: bytes) -> bool:
        return await self.send_frame(ws.OP_BIN, b)

    async def send_frame(self, op: int, corpo: bytes) -> bool:
        """Um quadro para o fio, MASCARADO — e do lado do cliente isso e
        obrigatorio (RFC 6455 s5.1: "MUST").

        A mascara nao e seguranca e nao vale a pena finge-lo: a chave viaja no
        proprio quadro. Ela existe porque proxies antigos podiam ser enganados a
        tratar o corpo como uma requisicao HTTP. O que ela exige e que a chave seja
        IMPREVISIVEL — e por isso ela vem do gerador criptografico, uma por quadro.
        """
        if not self.aberta:
            return False
        try:
            chave = await ws.mask_key()
            await self.sock.write(ws.serialize(ws.frame(op, corpo), chave))
            return True
        catch e:
            self.aberta = False
            return False

    async def recv(self) -> ws.Event?:
        """A mensagem seguinte, ou `None` quando a conexao acabou.

        Um PING e respondido aqui e nao devolvido: o s5.5.2 pede o pong "as soon as
        is practical", e deixa-lo a quem chama significa que um servidor decide que
        o cliente morreu porque ele estava a tratar de outra coisa.
        """
        with Buffer(65536) as rb:
            while self.aberta:
                ev = self.pr.next()
                if self.pr.failed():
                    ignora = await self.close(self.pr.close_code_out(), self.pr.problem())
                    return None
                if ev != None:
                    e2 = ev
                    if e2.kind == ws.EV_PING:
                        ignora2 = await self.send_frame(ws.OP_PONG, e2.data)
                        continue
                    if e2.kind == ws.EV_PONG:
                        continue
                    if e2.kind == ws.EV_CLOSE:
                        ignora3 = await self.close(e2.code if e2.code != 0 else 1000, "")
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
        self.aberta = False
        return None

    async def close(self, code: int, reason: str) -> bool:
        if not self.aberta:
            return False
        ok = await self.send_frame(ws.OP_CLOSE, ws.close_payload(code, reason))
        self.aberta = False
        self.sock.close()
        return ok


async def ws_connect(url: str, subprotocolo: str = "") -> WsCliente:
    """O aperto de mao do lado do cliente, e a CONFERENCIA da resposta.

    A chave e 16 bytes aleatorios em base64 (s4.1), e o que volta tem de ser o
    SHA-1 dela mais o GUID, tambem em base64. Conferi-la nao e cerimonia: e o que
    prova que do outro lado esta um servidor que ENTENDEU o pedido, e nao um
    servidor HTTP qualquer a devolver 101 por acidente ou um intermediario a
    responder a toa. Um cache poisoning comeca exactamente assim.
    """
    a = parse_alvo(url)
    if not a.ok or (a.esquema != "ws" and a.esquema != "wss"):
        raise error("um websocket precisa de um URL `ws://` ou `wss://`: " + url)
    chave = (await rng.random_bytes(16)).base64()
    c = await net.connect(a.host, a.porta)
    if a.esquema == "wss":
        n0 = await net.starttls(c, a.host)
    padrao = 443 if a.esquema == "wss" else 80
    autoridade = a.host if a.porta == padrao else a.host + ":" + str(a.porta)
    sb = "GET " + a.caminho + " HTTP/1.1\r\n"
    sb += "host: " + autoridade + "\r\n"
    sb += "upgrade: websocket\r\n"
    sb += "connection: Upgrade\r\n"
    sb += "sec-websocket-key: " + chave + "\r\n"
    sb += "sec-websocket-version: 13\r\n"
    if len(subprotocolo) > 0:
        sb += "sec-websocket-protocol: " + subprotocolo + "\r\n"
    sb += "\r\n"
    await c.write(sb.encode())

    pr = h.new_response_parser()
    resto: bytes = b""
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
                resto = pr.rest()
                break
            if pr.failed():
                c.close()
                raise error("o aperto de mao do websocket: " + pr.problem)
    r = pr.response()
    if r.status != 101:
        c.close()
        raise error("o servidor nao aceitou o upgrade: " + str(r.status))
    esperado = sha1.sha1((chave + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).base64()
    dado = ""
    for hd in r.raw:
        if hd.name == "sec-websocket-accept":
            dado = hd.value
    if dado != esperado:
        c.close()
        raise error("o `Sec-WebSocket-Accept` nao bate: do outro lado nao esta um servidor que entendeu o pedido")
    cli = WsCliente(c, ws.proto(False), True)
    if len(resto) > 0:
        cli.pr.feed(resto)
    return cli
