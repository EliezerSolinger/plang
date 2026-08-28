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
import sys
import topic


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
    r2 = httpd.Response(101, [], b"", True, None)
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
    # o hub deste servidor. A conexão conhece-o para que o programa escreva
    # `c.subscribe("lobby")` e não tenha de carregar o hub por todos os handlers
    # — e a referência é circular de propósito: o hub tem as conexões e cada
    # conexão tem o hub, o que um coletor resolve e um `free` manual não.
    hub: Hub

    def subscribe(self, topico: str):
        self.hub.subscribe(self, topico)

    def unsubscribe(self, topico: str):
        self.hub.unsubscribe(self, topico)

    async def publish(self, topico: str, corpo: bytes) -> int:
        return await self.hub.publish(topico, corpo, True)

    async def publish_text(self, topico: str, s: str) -> int:
        return await self.hub.publish_text(topico, s)

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
    # F7: o hub dos tópicos, um por servidor
    hub: Hub


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
    c = WsConn(sock, ws.proto(True), req, hs.proximo_id, True, [], hs.hub)
    hs.proximo_id += 1
    hs.hub.add(c)
    entregues = 0

    if len(resto) > 0:
        c.pr.feed(resto)

    ab = hs.on_open
    if ab != None:
        try:
            ignora = await ab(c)
        catch e:
            ignora_log = await sys.err.write("ws: on_open: " + e.message + "\n")

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
    # D9c: a inscrição morre com a conexão, e morre ANTES do `on_close` — assim
    # um `on_close` que publique não escreve para o socket que acabou de fechar
    hs.hub.drop(c)
    fc = hs.on_close
    if fc != None:
        try:
            ignora2 = await fc(c, 1006 if not c.pr.close_received else 1000, "")
        catch e:
            ignora_log = await sys.err.write("ws: on_close: " + e.message + "\n")
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
                ignora_log = await sys.err.write("ws: on_message: " + e.message + "\n")
                ignora5 = await c.close(ws.CLOSE_INTERNAL, "")
                return False


def handlers(on_open: (def(WsConn) -> Task<int>)?,
             # só TEXT e BINARY chegam aqui: um ping é respondido pela biblioteca e um
    # pong é a resposta a um ping dela. Um handler que os visse teria de os
    # filtrar, e quem se esquecesse fazia eco de um ping como mensagem.
    on_message: (def(WsConn, Event) -> Task<int>)?,
             on_close: (def(WsConn, int, str) -> Task<int>)?) -> Handlers:
    return Handlers(on_open, on_message, on_close, 1, hub())


def upgrader(hs: Handlers) -> def(Socket, httpd.Request, bytes) -> Task<int>:
    """Embrulha os handlers num `on_upgrade` para a `Config` da httpd.

    Existe porque a `httpd` é CEGA ao WebSocket de propósito (D7): ela sabe que
    alguém pediu para tomar conta da conexão, e não sabe do que se trata. Sem
    isto, ou a httpd conhecia o ws, ou o programa escrevia esta cola.
    """
    return lambda s, r, resto: serve_ws(s, r, resto, hs)


# ---------- F7/D6: os tópicos ----------

struct Hub:
    """As conexões deste worker, e quem assina o quê.

    **DENTRO do worker isto não serializa nada.** Um tópico é um conjunto de
    conexões e uma publicação é uma escrita directa no socket de cada uma — o
    mesmo `bytes` vai para todas, e o quadro é montado UMA vez. É a diferença
    entre este desenho e um em que cada assinante recebe uma mensagem própria.

    O que o Hub NÃO faz é atravessar workers. A camada de cima disso é a L4 do
    desenho: o runtime rastreia quais WORKERS assinam cada tópico e escreve uma
    vez no pipe de cada um; quem distribui às conexões continua a ser isto, aqui
    dentro. A fronteira é a D7 — o runtime nunca conhece framing de WebSocket —,
    e por isso esta struct não muda quando essa camada chegar: ela ganha uma
    entrada, não uma reescrita.
    """
    # tópico -> as conexões que o assinam, por id
    subs: Dict<str, List<int>>
    # id -> a conexão. Um id e não a conexão dentro do tópico porque uma conexão
    # sai por muitos caminhos (fecha, rebenta, o cliente desaparece) e um id
    # morto é fácil de limpar; um ponteiro morto não é.
    conns: Dict<int, WsConn>

    def add(self, c: WsConn):
        self.conns[c.id] = c

    def subscribe(self, c: WsConn, topico: str):
        if topico not in self.subs:
            self.subs[topico] = []
            # o PRIMEIRO assinante local deste tópico inscreve o WORKER no
            # runtime. Os seguintes não repetem: o runtime rastreia contextos.
            topic.subscribe(topico)
        if c.id not in self.subs[topico]:
            self.subs[topico].append(c.id)
        if topico not in c.topicos:
            c.topicos.append(topico)

    def unsubscribe(self, c: WsConn, topico: str):
        if topico in self.subs:
            novos: List<int> = []
            for i in self.subs[topico]:
                if i != c.id:
                    novos.append(i)
            self.subs[topico] = novos
        restantes: List<str> = []
        for t in c.topicos:
            if t != topico:
                restantes.append(t)
        c.topicos = restantes

    def drop(self, c: WsConn):
        """D9c: FECHAR DESSUBSCREVE DE TUDO, sempre.

        Não é conveniência: um servidor de jogo tem gente a entrar e a sair o dia
        inteiro, e uma inscrição que sobrevive à conexão é uma fuga que cresce
        com o tempo de vida do processo. Fazer o programa lembrar-se disto é
        garantir que um dia ele se esquece.
        """
        for t in c.topicos:
            if t in self.subs:
                novos: List<int> = []
                for i in self.subs[t]:
                    if i != c.id:
                        novos.append(i)
                self.subs[t] = novos
        c.topicos = []
        if c.id in self.conns:
            self.conns.remove(c.id)

    def count(self, topico: str) -> int:
        return len(self.subs[topico]) if topico in self.subs else 0

    async def publish(self, topico: str, corpo: bytes, binario: bool) -> int:
        """O CAMINHO QUENTE: os mesmos bytes para toda a gente do tópico.

        O quadro é montado UMA vez e escrito N. Não há serialização por assinante
        e não há cópia por assinante — é o que torna difundir o estado do mundo
        60 vezes por segundo uma coisa que se pode fazer.

        Devolve a quantos foi. As conexões mortas caem no caminho, que é o sítio
        certo para as apanhar: quem publica é quem descobre que já não está lá.
        """
        if topico not in self.subs:
            return 0
        quadro = ws.serialize(ws.frame(ws.OP_BIN if binario else ws.OP_TEXT, corpo), b"")
        vivos: List<int> = []
        n = 0
        for i in self.subs[topico]:
            if i not in self.conns:
                continue
            c = self.conns[i]
            if not c.aberta:
                continue
            ok = False
            try:
                await c.sock.write(quadro)
                ok = True
            catch e:
                c.aberta = False
            if ok:
                vivos.append(i)
                n += 1
        self.subs[topico] = vivos
        return n

    async def publish_text(self, topico: str, s: str) -> int:
        return await self.publish(topico, s.encode(), False)

    # ---------- L4: e os OUTROS WORKERS ----------

    def join(self, topico: str):
        """Diz ao runtime que ESTE worker passa a receber publicações do tópico.

        Chama-se uma vez por tópico e não uma vez por conexão: o runtime rastreia
        CONTEXTOS (D7), e mandar-lhe a mesma inscrição N vezes seria N vezes o
        mesmo. A `subscribe` de uma conexão chama isto por baixo.
        """
        topic.subscribe(topico)

    async def broadcast(self, topico: str, corpo: bytes, binario: bool) -> int:
        """A publicação COMPLETA: as conexões deste worker, e os outros workers.

        Os dois degraus da D6 numa chamada, com os custos separados e visíveis:

          * **aqui dentro** não serializa nada — o quadro é montado uma vez e
            escrito N, e os mesmos bytes vão para todas as conexões;
          * **para fora** atravessa como bytes, uma vez por WORKER e não uma vez
            por conexão. Quem distribui do outro lado é esta mesma função, no
            worker de lá, chamada pelo laço do `pump`.

        Devolve quantas conexões LOCAIS receberam. O número dos outros workers
        não se sabe daqui, e inventá-lo seria pior do que não o dar.
        """
        n = await self.publish(topico, corpo, binario)
        # o cabeçalho é `nome\n` e é da BIBLIOTECA, não do runtime: ele routeia
        # pelo nome que lhe foi dado e entrega os bytes tal e qual (D6), portanto
        # quem recebe precisa de saber a que tópico pertencem. Um `\n` porque um
        # nome de tópico não o tem — e se tiver, a culpa é de quem o escolheu.
        marca = (topico + "\n").encode()
        ignora = topic.publish(topico, marca + (b"\x01" if binario else b"\x00") + corpo)
        return n

    async def pump(self) -> int:
        """Uma publicação vinda de OUTRO worker, entregue às conexões daqui.

        Corre numa tarefa própria, em laço: `await topic.recv()` dorme no cano do
        contexto — o mesmo `poll` que já espera pelos sockets — e por isso não
        custa nada enquanto não há nada.
        """
        recebidas = 0
        while True:
            d = await topic.recv()
            i = 0
            while i < len(d) and int(d[i]) != 10:
                i += 1
            if i >= len(d):
                continue
            nome = str(d[0:i])
            binario = len(d) > i + 1 and int(d[i + 1]) == 1
            corpo = d[i + 2:]
            ignora = await self.publish(nome, corpo, binario)
            recebidas += 1


def hub() -> Hub:
    return Hub({}, {})
