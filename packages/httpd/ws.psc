"""O WebSocket ligado ao servidor (F6/D9b): o aperto de mão, e a conexão.

O protocolo em si está no `packages/ws` e não tem socket nenhum. Aqui é onde ele
encontra o fio: o `Upgrade` do HTTP, a chave do §4.2.2, e um laço que lê quadros
e chama o que o programa escreveu.

**O aperto de mão não é criptografia.** O `Sec-WebSocket-Accept` é o SHA-1 da
chave do cliente concatenada com um GUID fixo, em base64 — e serve só para provar
que do outro lado está um servidor que ENTENDEU o pedido, e não um servidor HTTP
qualquer a devolver 200 por acidente. Um cache poisoning começa exactamente assim:
um intermediário que responde à toa a um pedido que não compreende.

Por isso o SHA-1 aqui está certo apesar de estar partido desde 2017: ninguém
confia neste valor, ele só tem de ser difícil de acertar por acaso.
"""
import <httpd/httpd.psc> as httpd
import <ws/ws.psc> as ws
import <sha1/sha1.psc> as sha1


# RFC 6455 §1.3: o GUID é literal, está na norma, e não é um segredo
const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def accept_key(chave: str) -> str:
    """O `Sec-WebSocket-Accept` a partir do `Sec-WebSocket-Key`."""
    return sha1.sha1((chave + GUID).encode()).base64()


def is_upgrade(req: httpd.Request) -> bool:
    """Este pedido é um aperto de mão de WebSocket?

    As quatro perguntas do §4.2.1, e nenhuma delas é dispensável: o `Upgrade` e o
    `Connection` dizem o que se quer, a versão diz qual protocolo (só a 13
    existe), e a chave é o que torna a resposta verificável. Um pedido a que falte
    uma destas não é um aperto de mão a que falta um detalhe — é outra coisa.
    """
    if req.method != "GET":
        return False
    if req.header("upgrade").lower() != "websocket":
        return False
    if "upgrade" not in req.header("connection").lower():
        return False
    if req.header("sec-websocket-version") != "13":
        return False
    return len(req.header("sec-websocket-key")) > 0


def upgrade(req: httpd.Request, subprotocol: str = "") -> httpd.Response:
    """A resposta 101 que faz a conexão deixar de ser HTTP.

    Quando o pedido não é um aperto de mão válido, isto responde **426 com
    `Sec-WebSocket-Version: 13`** e não 400: o 426 é literalmente "actualize", e o
    cabeçalho diz para o quê. Um 400 diria que o cliente escreveu mal, e ele pode
    ter escrito perfeitamente bem — só numa versão que já não existe.
    """
    if not is_upgrade(req):
        r = httpd.status_code(426)
        r.headers.append(httpd.Header("sec-websocket-version", "13"))
        return r
    r2 = httpd.Response(101, [], b"", True)
    r2.headers.append(httpd.Header("upgrade", "websocket"))
    r2.headers.append(httpd.Header("connection", "Upgrade"))
    r2.headers.append(httpd.Header("sec-websocket-accept", accept_key(req.header("sec-websocket-key"))))
    if len(subprotocol) > 0:
        r2.headers.append(httpd.Header("sec-websocket-protocol", subprotocol))
    return r2


# ---------- a conexão, depois do 101 ----------

struct WsConn:
    """Uma conexão WebSocket de pé. O que o programa recebe nos seus handlers.

    O protocolo (`pr`) não sabe do socket e o socket não sabe do protocolo; esta
    struct é o sítio onde os dois se encontram, e é a única coisa aqui que faz
    I/O.
    """
    sock: Socket
    pr: ws.Proto
    req: httpd.Request
    # a identidade desta conexão dentro do worker. Um número e não um objecto,
    # porque é isto que um tópico guarda (F7) e um número é o que atravessa.
    id: int
    aberta: bool
    # os tópicos que esta conexão assina, para a dessubscrição automática do fecho
    # não depender de o programa se lembrar dela (D9c)
    topicos: List<str>

    async def send_text(self, s: str) -> bool:
        return await self.send_frame(ws.OP_TEXT, s.encode())

    async def send_bytes(self, b: bytes) -> bool:
        return await self.send_frame(ws.OP_BIN, b)

    async def ping(self, b: bytes) -> bool:
        return await self.send_frame(ws.OP_PING, b)

    async def pong(self, b: bytes) -> bool:
        return await self.send_frame(ws.OP_PONG, b)

    async def send_frame(self, op: int, corpo: bytes) -> bool:
        """Um quadro para o fio. Do lado do SERVIDOR nunca leva máscara — o §5.1
        diz "MUST NOT", e mascarar aqui faria qualquer cliente correcto fechar a
        conexão com 1002.

        Devolve se conseguiu, em vez de levantar: um cliente que desliga a meio
        não é um erro do servidor, é o caso de todos os dias.
        """
        if not self.aberta:
            return False
        try:
            await self.sock.write(ws.serialize(ws.frame(op, corpo), b""))
            return True
        catch e:
            self.aberta = False
            return False

    async def close(self, code: int, reason: str) -> bool:
        """O fecho LIMPO: manda o quadro de fecho e só depois desliga.

        Fechar o socket sem o quadro deixa o outro lado com um 1006 ("a ligação
        partiu-se"), que é indistinguível de um cabo puxado. Um servidor que faz
        isso não consegue dizer a nenhum cliente porque é que o mandou embora.
        """
        if not self.aberta:
            return False
        ok = await self.send_frame(ws.OP_CLOSE, ws.close_payload(code, reason))
        self.aberta = False
        self.sock.close()
        return ok


struct Handlers:
    """O que o programa escreve. Três funções, e nenhuma é obrigatória — um eco
    só precisa da do meio."""
    on_open: (def(WsConn) -> Task<int>)?
    # só TEXT e BINARY chegam aqui: um ping é respondido pela biblioteca e um
    # pong é a resposta a um ping dela. Um handler que os visse teria de os
    # filtrar, e quem se esquecesse fazia eco de um ping como mensagem.
    on_message: (def(WsConn, Event) -> Task<int>)?
    on_close: (def(WsConn, int, str) -> Task<int>)?
    # O CONTADOR DE CONEXÕES vive aqui, e não numa global, pela mesma razão que a
    # data da httpd vive na `Config`: um módulo importado não pode ter instruções
    # de topo. Ficou melhor — o número é do SERVIDOR, portanto dois servidores no
    # mesmo worker não partilham a numeração, e não há lock porque uma conexão só
    # é falada dentro do worker que a tem (42.2).
    proximo_id: int


# o evento, reexportado para o programa não ter de importar o `ws` só por causa
# das constantes
struct Event:
    kind: int
    data: bytes
    code: int

    def text(self) -> str:
        return str(self.data)

    def is_text(self) -> bool:
        return self.kind == ws.EV_TEXT

    def is_binary(self) -> bool:
        return self.kind == ws.EV_BINARY


# ---------- o laço ----------

async def serve_ws(sock: Socket, req: httpd.Request, resto: bytes, hs: Handlers) -> int:
    """A conexão, do 101 até ao fecho. Devolve quantas MENSAGENS entregou.

    `resto` são os bytes que já tinham chegado a seguir ao aperto de mão. Não é
    um pormenor: um cliente ansioso manda o primeiro quadro colado ao pedido, no
    mesmo `read`, e sem estes bytes a primeira mensagem perdia-se — um defeito
    que só aparece com um cliente rápido, e portanto nunca no teste de quem o
    escreveu.
    """
    c = WsConn(sock, ws.proto(True), req, hs.proximo_id, True, [])
    hs.proximo_id += 1
    entregues = 0

    if len(resto) > 0:
        c.pr.feed(resto)

    ab = hs.on_open
    if ab != None:
        try:
            ignora = await ab(c)
        catch e:
            aprint("ws: on_open: " + e.message)

    with Buffer(65536) as rb:
        while c.aberta:
            # o que já está no parser é servido ANTES de se ler mais: os bytes de
            # `resto`, e o que sobrou de um `read` que trouxe dois quadros
            if not await drena(c, hs):
                break
            if not c.aberta:
                break
            n = 0
            try:
                n = await sock.read_into(rb, 0, 65536)
            catch e:
                break
            if n == 0:
                # o cliente desligou sem quadro de fecho: é um 1006, e o 1006 é
                # justamente o código que NÃO viaja — quem o conclui é este lado
                break
            c.pr.feed(bytes(rb[0:n]))

    c.aberta = False
    sock.close()
    fc = hs.on_close
    if fc != None:
        try:
            ignora2 = await fc(c, 1006 if not c.pr.close_received else 1000, "")
        catch e:
            aprint("ws: on_close: " + e.message)
    return entregues


async def drena(c: WsConn, hs: Handlers) -> bool:
    """Serve todos os eventos que já dá para ler. False quando a conexão acabou.

    O PING é respondido AQUI e não pelo programa. O §5.5.2 diz que um pong tem
    de vir "as soon as is practical", e deixar isso ao programa significa que uma
    biblioteca cliente qualquer decide que o servidor morreu porque o handler
    estava ocupado. O programa recebe o ping na mesma, se quiser saber.
    """
    while True:
        ev = c.pr.next()
        if c.pr.failed():
            # a recusa já escolheu o código, e o §7.1.7 manda mandá-lo antes de
            # desligar — um cliente que só vê o socket a fechar não sabe porquê
            ignora = await c.close(c.pr.close_code_out(), c.pr.problem())
            return False
        if ev == None:
            return True
        if ev.kind == ws.EV_PING:
            # respondido AQUI, e o programa não o vê. O §5.5.2 pede o pong "as
            # soon as is practical", e deixá-lo ao handler significa que uma
            # biblioteca cliente qualquer decide que o servidor morreu porque o
            # handler estava ocupado.
            #
            # O `continue` é o que faltava e custou uma investigação: sem ele o
            # ping seguia TAMBÉM para o `on_message`, e um servidor de eco
            # devolvia-o como mensagem binária. O cliente ficava com uma
            # mensagem a mais na fila, e a resposta seguinte que ele lesse era a
            # anterior — um desencontro de uma posição, que só aparece depois de
            # alguém mandar um ping.
            ignora2 = await c.pong(ev.data)
            continue
        if ev.kind == ws.EV_PONG:
            # a resposta a um ping NOSSO. Não é uma mensagem, e o programa que
            # quiser medir latência tem o `on_message` para outra coisa.
            continue
        if ev.kind == ws.EV_CLOSE:
            # o eco do fecho: o §5.5.1 manda responder com um de volta, e é o que
            # transforma um fecho em aperto de mão em vez de um desligar
            ignora3 = await c.close(ev.code if ev.code != 0 else 1000, "")
            return False
        me = hs.on_message
        if me != None:
            try:
                ignora4 = await me(c, Event(ev.kind, ev.data, ev.code))
            catch e:
                # D3e outra vez: o handler rebenta, a conexão fecha com 1011, e o
                # worker continua a servir toda a gente
                aprint("ws: on_message: " + e.message)
                ignora5 = await c.close(ws.CLOSE_INTERNAL, "")
                return False


def handlers(on_open: (def(WsConn) -> Task<int>)?,
             # só TEXT e BINARY chegam aqui: um ping é respondido pela biblioteca e um
    # pong é a resposta a um ping dela. Um handler que os visse teria de os
    # filtrar, e quem se esquecesse fazia eco de um ping como mensagem.
    on_message: (def(WsConn, Event) -> Task<int>)?,
             on_close: (def(WsConn, int, str) -> Task<int>)?) -> Handlers:
    return Handlers(on_open, on_message, on_close, 1)


def upgrader(hs: Handlers) -> def(Socket, httpd.Request, bytes) -> Task<int>:
    """Embrulha os handlers num `on_upgrade` para a `Config` da httpd.

    Existe porque a `httpd` é CEGA ao WebSocket de propósito (D7): ela sabe que
    alguém pediu para tomar conta da conexão, e não sabe do que se trata. Sem
    isto, ou a httpd conhecia o ws, ou o programa escrevia esta cola.
    """
    return lambda s, r, resto: serve_ws(s, r, resto, hs)
