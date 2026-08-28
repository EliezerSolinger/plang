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

**O que uma conexão de pé tem de fazer além de ler quadros.** Três coisas que
faltavam e que só se notam em produção:

  * **o keepalive.** Um cliente que desaparece sem FIN — um portátil que fecha, um
    NAT que esquece a tradução — deixa uma conexão que este lado julga viva para
    sempre. Um ping periódico com prazo para o pong é a única maneira de o saber,
    e sem ele um servidor de jogo acumula jogadores fantasmas até ao fim do
    processo.
  * **fragmentar o que sai.** Uma mensagem grande num quadro só obriga o outro
    lado a ter tudo em memória antes de olhar para o primeiro byte. O §5.4 existe
    para isso, e até aqui só se sabia RECEBER fragmentos.
  * **escolher o subprotocolo.** O cliente manda a lista do que sabe falar; o
    servidor escolhe UM e diz qual. Ecoar o que o programa deu sem olhar para a
    lista do cliente é responder a uma pergunta que não se leu.
"""
import <httpd/httpd.psc> as httpd
import <ws/ws.psc> as ws
import <sha1/sha1.psc> as sha1
import sys
import topic


# RFC 6455 §1.3: o GUID é literal, está na norma, e não é um segredo
const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def accept_key(key: str) -> str:
    """O `Sec-WebSocket-Accept` a partir do `Sec-WebSocket-Key`."""
    return sha1.sha1((key + GUID).encode()).base64()


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


def upgrade(req: httpd.Request, protocols: List<str> = [], compress: bool = True) -> httpd.Response:
    """A resposta 101 que faz a conexão deixar de ser HTTP.

    Quando o pedido não é um aperto de mão válido, isto responde **426 com
    `Sec-WebSocket-Version: 13`** e não 400: o 426 é literalmente "actualize", e o
    cabeçalho diz para o quê. Um 400 diria que o cliente escreveu mal, e ele pode
    ter escrito perfeitamente bem — só numa versão que já não existe.

    **`protocols` é a preferência do PROGRAMA**, pela ordem em que ele a escreveu,
    e é essa ordem que ganha: o cliente diz o que sabe falar, o servidor escolhe.
    Quando não há nada em comum, o cabeçalho é omitido — e isso é uma resposta
    válida, não um erro: o §4.1 diz que o cliente é que decide se consegue
    continuar sem subprotocolo.

    **A decisão fica guardada na `Request`** (`attrs`) em vez de ser refeita pelo
    laço da conexão. Antes era refeita, apoiada em a negociação ser determinística
    sobre os mesmos cabeçalhos — verdade, e frágil: o dia em que os dois sítios
    discordassem, o servidor dizia uma coisa ao cliente e usava outra.
    """
    if not is_upgrade(req):
        r = httpd.status_code(426)
        r.headers.append(httpd.Header("sec-websocket-version", "13"))
        return r
    r2 = httpd.Response(101, [], b"", True, None)
    r2.headers.append(httpd.Header("upgrade", "websocket"))
    r2.headers.append(httpd.Header("connection", "Upgrade"))
    r2.headers.append(httpd.Header("sec-websocket-accept", accept_key(req.header("sec-websocket-key"))))

    chosen = ws.pick_token(req.header("sec-websocket-protocol"), protocols)
    if len(chosen) > 0:
        r2.headers.append(httpd.Header("sec-websocket-protocol", chosen))
    req.attrs["ws.protocol"] = chosen

    # F9b/RFC 7692: a compressão da CARGA, se o cliente a ofereceu. A resposta tem
    # de nomear exactamente o que se aceita — um servidor que ecoasse a oferta
    # inteira estaria a prometer parâmetros que não implementa.
    bits = ""
    if compress:
        neg = ws.negotiate(req.header("sec-websocket-extensions"))
        if len(neg.accepted) > 0:
            r2.headers.append(httpd.Header("sec-websocket-extensions", neg.accepted))
            # os bits da janela que se prometeu respeitar, guardados como texto
            # porque é o que um `attrs` transporta. É o único número da
            # negociação que o laço precisa de saber.
            bits = str(neg.pmd.out_bits)
    req.attrs["ws.deflate"] = bits
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
    open: bool
    # os tópicos que esta conexão assina, para a dessubscrição automática do fecho
    # não depender de o programa se lembrar dela (D9c)
    topics: List<str>
    # o hub deste servidor. A conexão conhece-o para que o programa escreva
    # `c.subscribe("lobby")` e não tenha de carregar o hub por todos os handlers
    # — e a referência é circular de propósito: o hub tem as conexões e cada
    # conexão tem o hub, o que um coletor resolve e um `free` manual não.
    hub: Hub
    # F9b: a compressão negociada nesta conexão, ou desligada
    pmd: ws.Deflate
    # o subprotocolo escolhido no aperto de mão, ou "". O programa lê-o para
    # saber que dialecto falar — é a razão de se ter negociado.
    protocol: str
    # o tamanho de um fragmento de ENVIO; 0 = uma mensagem por quadro
    fragment_size: int
    # quantas MENSAGENS esta conexão entregou ao programa
    delivered: int
    # keepalive: um ping nosso está à espera de resposta?
    awaiting_pong: bool
    # uma mensagem está a sair EM FRAGMENTOS? Enquanto estiver, outro quadro de
    # dados não pode entrar no fio.
    sending: bool
    # O TRINCO DE ESCRITA, e não é precaução: **uma escrita parcial ESTACIONA a
    # tarefa.** O runtime escreve o que o tampão do kernel aceitar, guarda o
    # deslocamento e volta a dormir no `POLLOUT` (`psrt_rt.p`, "partial: wait for
    # room and send the rest"). Duas tarefas a escrever na mesma conexão
    # intercalam bytes DENTRO de um quadro, e o outro lado fecha com 1002.
    #
    # Não era hipotético e o keepalive tornou-o sistemático: uma mensagem grande a
    # sair por um socket cheio, mais um ping a cada vinte segundos de outra tarefa.
    # Já valia para o `Hub.publish` contra um `send_text` do handler.
    #
    # Um `Channel(1)` é o semáforo binário, e a inversão é de propósito: o canal
    # começa VAZIO e o que ele guarda é "alguém está a escrever". Assim não há
    # nada a inicializar — o `send` entra e bloqueia quando está cheio, o `recv`
    # devolve. Entre dois FRAGMENTOS o trinco é solto, que é o que deixa um ping
    # entremear-se onde o §5.4 o permite.
    wlock: Channel<int>

    def subscribe(self, name: str):
        self.hub.subscribe(self, name)

    def unsubscribe(self, name: str):
        self.hub.unsubscribe(self, name)

    async def publish(self, name: str, body: bytes) -> int:
        return await self.hub.publish(name, body, True)

    async def publish_text(self, name: str, s: str) -> int:
        return await self.hub.publish_text(name, s)

    async def send_text(self, s: str) -> bool:
        return await self.send_message(ws.OP_TEXT, s.encode())

    async def send_bytes(self, b: bytes) -> bool:
        return await self.send_message(ws.OP_BIN, b)

    async def ping(self, b: bytes) -> bool:
        return await self.write_frame(ws.frame(ws.OP_PING, b))

    async def pong(self, b: bytes) -> bool:
        return await self.write_frame(ws.frame(ws.OP_PONG, b))

    async def write_frame(self, f: ws.Frame) -> bool:
        """UM quadro para o fio, tal como está. Do lado do SERVIDOR nunca leva
        máscara — o §5.1 diz "MUST NOT", e mascarar aqui faria qualquer cliente
        correcto fechar a conexão com 1002.

        Devolve se conseguiu, em vez de levantar: um cliente que desliga a meio
        não é um erro do servidor, é o caso de todos os dias.

        É por aqui que passam os quadros de CONTROLO, e de propósito: o §5.4 diz
        que um ping ou um fecho PODEM entremear-se numa mensagem fragmentada, e
        são a única coisa que pode. Por isso não passam pela guarda do
        `send_message`.
        """
        return await self.write_raw(ws.serialize(f, b""))

    async def write_raw(self, wire: bytes) -> bool:
        """Bytes JÁ MOLDADOS para o fio, sob o trinco.

        É por aqui que passa toda a escrita desta conexão — os quadros do
        `write_frame` e a difusão do `Hub`, que monta o quadro uma vez e o escreve
        em N sockets. Ter um só sítio é o que torna o trinco uma garantia em vez de
        uma convenção que um caminho novo esquece.
        """
        if not self.open:
            return False
        await self.wlock.send(1)
        ok = True
        try:
            await self.sock.write(wire)
        catch e:
            self.open = False
            ok = False
        # solta-se nos DOIS caminhos, e é por isso que o `catch` não volta daqui:
        # um trinco que ficasse tomado numa falha travava a conexão para sempre
        ignored = await self.wlock.recv()
        return ok

    async def send_message(self, op: int, body: bytes) -> bool:
        """Uma MENSAGEM para o fio, comprimida e fragmentada como se negociou.

        A ordem das duas é obrigatória e não é gosto: **comprime-se a mensagem
        inteira e só depois se parte**. O fluxo do DEFLATE atravessa a
        fragmentação (§7.2.1 do RFC 7692), e comprimir cada fragmento por si daria
        N fluxos independentes que o outro lado não consegue juntar. Pela mesma
        razão o RSV1 vai só no primeiro quadro: ele descreve a mensagem.
        """
        if not self.open:
            return False
        if self.sending:
            # Uma mensagem fragmentada está a meio do fio. Entremear outra
            # produziria um fluxo que qualquer implementação correcta recusa com
            # 1002 — e um `return False` calado perderia a mensagem sem dizer
            # porquê. Este erro é do PROGRAMA (duas tarefas a escrever na mesma
            # conexão) e tem de ser dele, alto.
            raise error("ws: já está a sair uma mensagem em fragmentos nesta conexão; dois quadros de dados não se entremeiam (RFC 6455 §5.4)")
        payload = body
        rsv1 = False
        # F9b: só os quadros de DADOS se comprimem. Um `ping` de dois bytes
        # comprimido fica maior, e o §6 proíbe-o de qualquer maneira: o RSV1 num
        # quadro de controlo é um erro de protocolo.
        if self.pmd.enabled and (op == ws.OP_TEXT or op == ws.OP_BIN) and len(body) > 0:
            payload = ws.compress_payload(body, self.pmd.out_bits)
            rsv1 = True
        n = len(payload)
        b = ws.fragment_bounds(n, self.fragment_size)
        if len(b) == 2:
            return await self.write_frame(ws.Frame(True, rsv1, False, False, op, payload))
        # os LIMITES e não os quadros: uma mensagem de dez megabytes fragmentada
        # em pedaços de dezasseis quilobytes tem UM pedaço em memória de cada vez,
        # e não os dez megabytes outra vez em fatias
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

    async def close(self, code: int, reason: str) -> bool:
        """O fecho LIMPO: manda o quadro de fecho e só depois desliga.

        Fechar o socket sem o quadro deixa o outro lado com um 1006 ("a ligação
        partiu-se"), que é indistinguível de um cabo puxado. Um servidor que faz
        isso não consegue dizer a nenhum cliente porque é que o mandou embora.

        Não se espera pelo eco, e é o §7.1.1 que o diz: quem fecha primeiro o TCP
        é o SERVIDOR. Esperar aqui seria dar a um cliente que ignora o fecho a
        maneira de nos segurar uma conexão.
        """
        if not self.open:
            return False
        ok = await self.write_frame(ws.frame(ws.OP_CLOSE, ws.close_payload(code, reason)))
        self.open = False
        self.sock.close()
        return ok


struct Handlers:
    """O que o programa escreve, e como esta conexão se porta.

    Três funções, e nenhuma é obrigatória — um eco só precisa da do meio.
    """
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
    next_id: int
    # F7: o hub dos tópicos, um por servidor
    hub: Hub
    # em quantos bytes se parte uma mensagem que sai. 0 = um quadro só, que é o
    # que serve mensagens pequenas — e um jogo manda mensagens pequenas sessenta
    # vezes por segundo, portanto o valor por omissão não fragmenta nada.
    fragment_size: int
    # KEEPALIVE. `ping_interval` = 0 desliga-o.
    #
    # Vinte segundos por omissão, e ligado: uma conexão sem ping nunca descobre
    # um cliente que desapareceu sem FIN, e o custo é dois bytes a cada vinte
    # segundos por conexão. Deixá-lo desligado por omissão seria escolher a fuga
    # silenciosa em vez do custo medido.
    ping_interval: float
    # quanto se espera pelo pong antes de dar a conexão por morta
    ping_timeout: float
    # o tecto de uma mensagem montada (defesa, não afinação — ver o `Proto`)
    max_message: int


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

async def serve_ws(sock: Socket, req: httpd.Request, rest: bytes, hs: Handlers) -> int:
    """A conexão, do 101 até ao fecho. Devolve quantas MENSAGENS entregou.

    `rest` são os bytes que já tinham chegado a seguir ao aperto de mão. Não é um
    pormenor: um cliente ansioso manda o primeiro quadro colado ao pedido, no
    mesmo `read`, e sem estes bytes a primeira mensagem perdia-se — um defeito
    que só aparece com um cliente rápido, e portanto nunca no teste de quem o
    escreveu.

    **Duas tarefas, e nenhuma delas conduz o escalonador.** O laço de leitura é
    esperado com um `await` normal — que ESTACIONA a tarefa —, e o keepalive é uma
    tarefa quente que dorme no relógio. Chegou a ser um `race` das duas, e depois
    um prazo na própria leitura; as duas formas encalhavam pela mesma razão, e
    está no achado 66: um `race` ou um `timeout` conduz o escalonador de dentro
    da tarefa que o chama, e um que fique lá vinte segundos impede as OUTRAS
    conexões de serem servidas.
    """
    # o que o `upgrade` decidiu é o que vale, e vem da `Request` em vez de ser
    # refeito a partir dos cabeçalhos (ver o `upgrade`)
    pmd = ws.no_deflate()
    bits = req.attrs["ws.deflate"] if "ws.deflate" in req.attrs else ""
    if len(bits) > 0:
        sb = ws.window_bits(bits)
        pmd = ws.Deflate(True, sb if sb > 0 else 15, 15)
    protocol = req.attrs["ws.protocol"] if "ws.protocol" in req.attrs else ""

    c = WsConn(sock, ws.proto(True, hs.max_message, pmd), req, hs.next_id, True, [],
               hs.hub, pmd, protocol, hs.fragment_size, 0, False, False, Channel(1))
    hs.next_id += 1
    hs.hub.add(c)

    if len(rest) > 0:
        c.pr.feed(rest)

    h_open = hs.on_open
    if h_open != None:
        try:
            ignored = await h_open(c)
        catch e:
            ignored_log = await sys.err.write("ws: on_open: " + e.message + "\n")

    if hs.ping_interval > 0.0:
        # UMA TAREFA QUENTE, e ninguém a espera — a mesma forma que a `httpd` usa
        # para as conexões. O `await sleep(...)` dela ESTACIONA no relógio do
        # contexto (18.4) em vez de conduzir o escalonador, e é essa a diferença
        # que importa: um `race` ou um `timeout` de vida longa aqui seguraria o
        # laço de aceitação e as outras conexões (achado 66).
        #
        # Ela morre sozinha: acorda, vê `c.open` em falso, e volta.
        watchdog = keepalive(c, hs)
    ignored2 = await read_loop(c, hs)

    c.open = False
    sock.close()
    # D9c: a inscrição morre com a conexão, e morre ANTES do `on_close` — assim
    # um `on_close` que publique não escreve para o socket que acabou de fechar
    hs.hub.drop(c)
    h_close = hs.on_close
    if h_close != None:
        try:
            ignored4 = await h_close(c, 1006 if not c.pr.close_received else 1000, "")
        catch e:
            ignored_log2 = await sys.err.write("ws: on_close: " + e.message + "\n")
    return c.delivered




async def read_loop(c: WsConn, hs: Handlers) -> int:
    """Lê do socket e serve o que chega, até a conexão acabar.

    Sem prazo, de propósito: o prazo é do `keepalive`, que corre à parte e fecha o
    socket quando decide que o cliente já não está lá — e um socket fechado faz
    esta leitura devolver zero. Pôr o prazo AQUI foi tentado e não pode ser: um
    `timeout` conduz o escalonador de dentro da tarefa que o chama, e uma conexão
    que fique lá vinte segundos impede as outras de serem servidas (achado 66).
    """
    with Buffer(65536) as rb:
        while c.open:
            # o que já está no parser é servido ANTES de se ler mais: os bytes de
            # `rest`, e o que sobrou de um `read` que trouxe dois quadros
            if not await drain(c, hs):
                break
            if not c.open:
                break
            n = 0
            try:
                n = await c.sock.read_into(rb, 0, 65536)
            catch e:
                break
            if n == 0:
                # o cliente desligou sem quadro de fecho: é um 1006, e o 1006 é
                # justamente o código que NÃO viaja — quem o conclui é este lado
                break
            c.pr.feed(bytes(rb[0:n]))
    return c.delivered


async def keepalive(c: WsConn, hs: Handlers) -> int:
    """O ping periódico, e o prazo para o pong.

    **Sem isto não há como saber que um cliente desapareceu.** Um portátil que
    fecha a tampa, um NAT que esquece a tradução, um cabo que sai: em nenhum
    destes casos chega um FIN, e o `read` do outro lado espera para sempre por
    bytes que nunca vêm. A conexão fica na lista, o tópico continua a escrever
    para ela, e um servidor de jogo acumula fantasmas até reiniciar.

    Corre como TAREFA QUENTE que ninguém espera, e é essa a peça que importa: o
    `await sleep(...)` estaciona no mesmo multiplexador que espera pelos sockets
    (18.4), portanto isto não custa nada enquanto dorme e não segura ninguém. O
    `race` que aqui estava custava o contrário — ver o `serve_ws`.

    Quando decide que o cliente morreu, FECHA o socket; e é isso que faz o laço de
    leitura devolver zero e acabar. Os dois não precisam de falar.
    """
    while c.open:
        await sleep(hs.ping_interval)
        if not c.open:
            break
        c.awaiting_pong = True
        # um ping com corpo VAZIO: o §5.5.2 não exige corpo, e o pong tem de
        # devolver o mesmo — mandar bytes para os receber de volta seria pagar
        # duas vezes por nada
        if not await c.ping(b""):
            break
        await sleep(hs.ping_timeout)
        if not c.open:
            break
        if c.awaiting_pong:
            # o pong não chegou no prazo. O 1001 ("going away") é o código certo:
            # não houve erro de protocolo nenhum, o outro lado simplesmente já
            # não está lá.
            ignored = await c.close(ws.CLOSE_GOING_AWAY, "sem resposta ao ping")
            break
    return 0


async def drain(c: WsConn, hs: Handlers) -> bool:
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
            ignored = await c.close(c.pr.close_code_out(), c.pr.problem())
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
            ignored2 = await c.pong(ev.data)
            continue
        if ev.kind == ws.EV_PONG:
            # a resposta a um ping NOSSO, e é isto que o keepalive espera. Não é
            # uma mensagem, e o programa que quiser medir latência tem o
            # `on_message` para outra coisa.
            c.awaiting_pong = False
            continue
        if ev.kind == ws.EV_CLOSE:
            # o eco do fecho: o §5.5.1 manda responder com um de volta, e é o que
            # transforma um fecho em aperto de mão em vez de um desligar
            ignored3 = await c.close(ev.code if ev.code != 0 else 1000, "")
            return False
        h_msg = hs.on_message
        if h_msg != None:
            try:
                ignored4 = await h_msg(c, Event(ev.kind, ev.data, ev.code))
                c.delivered += 1
            catch e:
                # D3e outra vez: o handler rebenta, a conexão fecha com 1011, e o
                # worker continua a servir toda a gente
                ignored_log = await sys.err.write("ws: on_message: " + e.message + "\n")
                ignored5 = await c.close(ws.CLOSE_INTERNAL, "")
                return False


def handlers(on_open: (def(WsConn) -> Task<int>)?,
             # só TEXT e BINARY chegam aqui: um ping é respondido pela biblioteca
             # e um pong é a resposta a um ping dela. Um handler que os visse
             # teria de os filtrar, e quem se esquecesse fazia eco de um ping
             # como mensagem.
             on_message: (def(WsConn, Event) -> Task<int>)?,
             on_close: (def(WsConn, int, str) -> Task<int>)?,
             fragment_size: int = 0,
             ping_interval: float = 20.0,
             ping_timeout: float = 10.0,
             max_message: int = 1 << 24) -> Handlers:
    return Handlers(on_open, on_message, on_close, 1, hub(),
                    fragment_size, ping_interval, ping_timeout, max_message)


def upgrader(hs: Handlers) -> def(Socket, httpd.Request, bytes) -> Task<int>:
    """Embrulha os handlers num `on_upgrade` para a `Config` da httpd.

    Existe porque a `httpd` é CEGA ao WebSocket de propósito (D7): ela sabe que
    alguém pediu para tomar conta da conexão, e não sabe do que se trata. Sem
    isto, ou a httpd conhecia o ws, ou o programa escrevia esta cola.
    """
    return lambda s, r, rest: serve_ws(s, r, rest, hs)


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

    def subscribe(self, c: WsConn, name: str):
        if name not in self.subs:
            self.subs[name] = []
            # o PRIMEIRO assinante local deste tópico inscreve o WORKER no
            # runtime. Os seguintes não repetem: o runtime rastreia contextos.
            topic.subscribe(name)
        if c.id not in self.subs[name]:
            self.subs[name].append(c.id)
        if name not in c.topics:
            c.topics.append(name)

    def unsubscribe(self, c: WsConn, name: str):
        if name in self.subs:
            fresh: List<int> = []
            for i in self.subs[name]:
                if i != c.id:
                    fresh.append(i)
            self.subs[name] = fresh
        others: List<str> = []
        for t in c.topics:
            if t != name:
                others.append(t)
        c.topics = others

    def drop(self, c: WsConn):
        """D9c: FECHAR DESSUBSCREVE DE TUDO, sempre.

        Não é conveniência: um servidor de jogo tem gente a entrar e a sair o dia
        inteiro, e uma inscrição que sobrevive à conexão é uma fuga que cresce
        com o tempo de vida do processo. Fazer o programa lembrar-se disto é
        garantir que um dia ele se esquece.
        """
        for t in c.topics:
            if t in self.subs:
                fresh: List<int> = []
                for i in self.subs[t]:
                    if i != c.id:
                        fresh.append(i)
                self.subs[t] = fresh
        c.topics = []
        if c.id in self.conns:
            self.conns.remove(c.id)

    def count(self, name: str) -> int:
        return len(self.subs[name]) if name in self.subs else 0

    async def publish(self, name: str, body: bytes, binary: bool) -> int:
        """O CAMINHO QUENTE: os mesmos bytes para toda a gente do tópico.

        O quadro é montado UMA vez e escrito N. Não há serialização por assinante
        e não há cópia por assinante — é o que torna difundir o estado do mundo
        60 vezes por segundo uma coisa que se pode fazer.

        Devolve a quantos foi. As conexões mortas caem no caminho, que é o sítio
        certo para as apanhar: quem publica é quem descobre que já não está lá.

        **Não comprime e não fragmenta**, e é essa a razão de ser desta função:
        um quadro montado uma vez serve N conexões, e comprimir por conexão —
        cada uma com a sua janela negociada — daria N quadros diferentes e
        acabava com a única propriedade que aqui interessa. Quem quer compressão
        numa difusão manda por `send_bytes` a cada um, e paga-a.
        """
        if name not in self.subs:
            return 0
        wire = ws.serialize(ws.frame(ws.OP_BIN if binary else ws.OP_TEXT, body), b"")
        alive: List<int> = []
        n = 0
        for i in self.subs[name]:
            if i not in self.conns:
                continue
            c = self.conns[i]
            if not c.open:
                continue
            # pelo `write_raw` e não pelo socket: a difusão e um `send_text` do
            # handler são duas tarefas, e sem o trinco os bytes de uma entram no
            # meio do quadro da outra
            ok = await c.write_raw(wire)
            if ok:
                alive.append(i)
                n += 1
        self.subs[name] = alive
        return n

    async def publish_text(self, name: str, s: str) -> int:
        return await self.publish(name, s.encode(), False)

    # ---------- L4: e os OUTROS WORKERS ----------

    def join(self, name: str):
        """Diz ao runtime que ESTE worker passa a receber publicações do tópico.

        Chama-se uma vez por tópico e não uma vez por conexão: o runtime rastreia
        CONTEXTOS (D7), e mandar-lhe a mesma inscrição N vezes seria N vezes o
        mesmo. A `subscribe` de uma conexão chama isto por baixo.
        """
        topic.subscribe(name)

    async def broadcast(self, name: str, body: bytes, binary: bool) -> int:
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
        n = await self.publish(name, body, binary)
        # o cabeçalho é `nome\n` e é da BIBLIOTECA, não do runtime: ele routeia
        # pelo nome que lhe foi dado e entrega os bytes tal e qual (D6), portanto
        # quem recebe precisa de saber a que tópico pertencem. Um `\n` porque um
        # nome de tópico não o tem — e se tiver, a culpa é de quem o escolheu.
        tag = (name + "\n").encode()
        ignored = topic.publish(name, tag + (b"\x01" if binary else b"\x00") + body)
        return n

    async def pump(self) -> int:
        """Uma publicação vinda de OUTRO worker, entregue às conexões daqui.

        Corre numa tarefa própria, em laço: `await topic.recv()` dorme no cano do
        contexto — o mesmo `poll` que já espera pelos sockets — e por isso não
        custa nada enquanto não há nada.
        """
        received = 0
        while True:
            d = await topic.recv()
            i = 0
            while i < len(d) and int(d[i]) != 10:
                i += 1
            if i >= len(d):
                continue
            name = str(d[0:i])
            binary = len(d) > i + 1 and int(d[i + 1]) == 1
            body = d[i + 2:]
            ignored = await self.publish(name, body, binary)
            received += 1


def hub() -> Hub:
    return Hub({}, {})


# O LAÇO das publicações vindas de outros workers, como função livre — pela mesma
# razão do `dispatch` do encaminhador: um método ligado não é um valor, e isto é
# uma tarefa que o programa arranca.
async def pump_hub(h: Hub) -> int:
    return await h.pump()
