"""WebSocket (RFC 6455), sans-io: bytes entram, EVENTOS saem.

Não há socket nenhum neste ficheiro, e é de propósito. Um protocolo é uma
máquina de estados sobre bytes; quem lê e escreve é outra camada. A biblioteca
`websockets` do Python está organizada assim e tem quatro cópias da mesma lógica
por baixo — uma por modelo de I/O (asyncio, trio, síncrono, o legado). Aqui o
modelo de concorrência é UM, portanto a lógica é uma.

O que isto compra, além do tamanho: o protocolo testa-se sem rede. Uma sequência
de bytes entra, uma sequência de eventos sai, e o portão compara-a — sem portos,
sem esperas, sem intermitência.

**A validação é o produto.** Fazer o quadro é fácil; a suíte Autobahn existe
porque o que separa uma implementação de brincar de uma a sério são as recusas:

  * os bits RSV têm de ser zero enquanto não houver extensão negociada;
  * os opcodes 3–7 e 11–15 são reservados, e um quadro com um deles é 1002;
  * um quadro de CONTROLO não passa de 125 bytes e nunca é fragmentado;
  * uma continuação sem princípio, ou um princípio novo a meio de outro, é 1002;
  * o comprimento tem de vir na forma MÍNIMA — 125 não se escreve em dois bytes;
  * um comprimento de 64 bits com o bit alto ligado é 1002;
  * o cliente MASCARA sempre e o servidor NUNCA, e o contrário é 1002 dos dois
    lados;
  * o texto tem de ser UTF-8 válido, ou é 1007 — e essa aqui sai de graça, porque
    `str(bytes)` já levanta em UTF-8 inválido: a promessa do tipo faz o trabalho
    que noutras bibliotecas é código à mão, e é o sítio onde a Autobahn mais
    reprova;
  * um código de fecho fora da lista, ou um corpo de fecho com um byte só, é 1002.

**A máscara não é segurança** e não vale a pena fingir que é: ela existe porque
proxies antigos podiam ser enganados a tratar o corpo como uma requisição HTTP
(cache poisoning), e a chave viaja no próprio quadro. O que ela exige é que a
chave seja IMPREVISÍVEL, e por isso vem do gerador criptográfico e não do
`random`.
"""
import <csprng/csprng.psc> as rng


# ---------- os opcodes ----------

const OP_CONT = 0x0
const OP_TEXT = 0x1
const OP_BIN = 0x2
const OP_CLOSE = 0x8
const OP_PING = 0x9
const OP_PONG = 0xA

# ---------- os códigos de fecho (RFC 6455 §7.4.1) ----------

const CLOSE_NORMAL = 1000
const CLOSE_GOING_AWAY = 1001
const CLOSE_PROTOCOL_ERROR = 1002
const CLOSE_UNSUPPORTED = 1003
const CLOSE_INVALID_DATA = 1007
const CLOSE_POLICY = 1008
const CLOSE_TOO_BIG = 1009
const CLOSE_NO_EXTENSION = 1010
const CLOSE_INTERNAL = 1011


def is_control(op: int) -> bool:
    return op >= 0x8


def close_code_ok(c: int) -> bool:
    """Um código que pode VIAJAR. Os que não podem não são um capricho da lista:

      * **1004** nunca chegou a significar nada e ficou reservado;
      * **1005** é "não houve código" e **1006** é "a ligação partiu-se" — os dois
        são coisas que a APLICAÇÃO conclui, e escrevê-los no fio seria mentir
        sobre uma conclusão que só o outro lado pode tirar;
      * **1015** é a falha de TLS, e pela mesma razão.

    Os 1012–1014 são registados na IANA (reiniciar, sobrecarga, mau gateway) e
    passam. De 3000 a 3999 é o espaço das bibliotecas, de 4000 a 4999 o das
    aplicações — e esses ninguém valida por dentro, que é o que os torna úteis.
    """
    if c == 1004 or c == 1005 or c == 1006:
        return False
    if c >= 1000 and c <= 1014:
        return True
    return c >= 3000 and c <= 4999


# ---------- um quadro ----------

struct Frame:
    fin: bool
    rsv1: bool
    rsv2: bool
    rsv3: bool
    op: int
    payload: bytes

    def is_control(self) -> bool:
        return is_control(self.op)


def frame(op: int, payload: bytes, fin: bool = True) -> Frame:
    return Frame(fin, False, False, False, op, payload)


async def mask_key() -> bytes:
    """Quatro bytes IMPREVISÍVEIS. Do gerador criptográfico e não do `random`:
    a máscara existe para que um proxy não possa ser enganado a ler o corpo como
    uma requisição HTTP, e uma chave que se consegue prever não impede nada.
    Custa quatro bytes por quadro; o `random` custaria a razão de ela existir.

    É a ÚNICA função assíncrona do módulo, e não fica no caminho: o `serialize`
    recebe a chave em vez de a ir buscar, portanto a parte que é máquina de
    estados continua pura e testável sem rede. Quem monta quadros do lado do
    cliente pede uma chave por quadro e passa-a.
    """
    return await rng.random_bytes(4)


def apply_mask(data: bytes, key: bytes) -> bytes:
    """O XOR cíclico do §5.3. É a mesma operação nos dois sentidos — mascarar e
    desmascarar são a mesma função, que é a propriedade do XOR e a razão de não
    haver duas."""
    if len(key) != 4:
        return data
    out: List<u8> = []
    i = 0
    for b in data:
        out.append(u8(int(b) ^ int(key[i & 3])))
        i += 1
    return bytes(out)


def serialize(f: Frame, key: bytes) -> bytes:
    """Um quadro em bytes. `key` vazia = sem máscara (o lado do servidor).

    O COMPRIMENTO SAI NA FORMA MÍNIMA, e isso é obrigação e não gosto: o §5.2 diz
    "MUST", e um quadro de 125 bytes escrito em dois bytes de comprimento é
    recusado por qualquer implementação séria — a Autobahn tem casos só para isso.
    Escrever sempre a forma longa seria mais simples de ler aqui e romperia com
    toda a gente.
    """
    out: List<u8> = []
    b0 = f.op & 0x0F
    if f.fin:
        b0 |= 0x80
    if f.rsv1:
        b0 |= 0x40
    if f.rsv2:
        b0 |= 0x20
    if f.rsv3:
        b0 |= 0x10
    out.append(u8(b0))
    n = len(f.payload)
    masked = 0x80 if len(key) == 4 else 0
    if n < 126:
        out.append(u8(masked | n))
    elif n < 65536:
        out.append(u8(masked | 126))
        out.append(u8((n >> 8) & 0xFF))
        out.append(u8(n & 0xFF))
    else:
        out.append(u8(masked | 127))
        i = 56
        while i >= 0:
            out.append(u8((n >> i) & 0xFF))
            i -= 8
    if len(key) == 4:
        for b in key:
            out.append(b)
    corpo = apply_mask(f.payload, key) if len(key) == 4 else f.payload
    return bytes(out) + corpo


def close_payload(code: int, reason: str) -> bytes:
    """O corpo de um CLOSE: dois bytes de código, big-endian, e a razão em UTF-8.

    Um fecho SEM código é legítimo (corpo vazio) e é diferente de um fecho com
    o código 1005 — esse não pode viajar. É a mesma distinção entre "não disse" e
    "disse que não sabe".
    """
    if code == 0:
        return b""
    out: List<u8> = [u8((code >> 8) & 0xFF), u8(code & 0xFF)]
    return bytes(out) + reason.encode()


# ---------- o parser incremental ----------

struct Parser:
    """Bytes entram por `feed`, quadros saem por `next`. Guarda o que ficou a
    meio, porque um `read` de socket dá o que houver e quase nunca um quadro.

    `is_server` decide a regra da MÁSCARA, e ela é assimétrica de propósito: o
    cliente mascara sempre e o servidor nunca. Um servidor que aceitasse um
    quadro sem máscara estaria a aceitar exactamente o que a máscara existe para
    impedir, e um cliente que aceitasse um mascarado estaria a esconder um
    servidor mal escrito.
    """
    is_server: bool
    buf: List<u8>
    pos: int
    problem: str        # vazio = tudo bem
    code: int           # o código de fecho com que se recusa

    def fail(self, code: int, msg: str) -> bool:
        # a PRIMEIRA falha é a que conta: as seguintes são consequência dela, e
        # sobrescrever a razão faria o relatório apontar para o sítio errado
        if len(self.problem) == 0:
            self.problem = msg
            self.code = code
        return False

    def failed(self) -> bool:
        return len(self.problem) > 0

    def feed(self, chunk: bytes):
        for b in chunk:
            self.buf.append(b)

    def compact(self):
        """Deita fora o que já foi lido. Sem isto o `buf` de uma conexão longa
        cresce para sempre — um jogo com 60 quadros por segundo enche um
        gigabyte numa tarde."""
        if self.pos == 0:
            return
        novo: List<u8> = []
        i = self.pos
        while i < len(self.buf):
            novo.append(self.buf[i])
            i += 1
        self.buf = novo
        self.pos = 0

    def next(self) -> Frame?:
        """O quadro seguinte, ou `None` quando ainda não chegou inteiro.

        Um `None` NÃO quer dizer "acabou": quer dizer "falta". Quem tiver de
        distinguir pergunta ao `failed()`, que é a outra saída.
        """
        if self.failed():
            return None
        n = len(self.buf)
        p = self.pos
        if n - p < 2:
            return None
        b0 = int(self.buf[p])
        b1 = int(self.buf[p + 1])
        fin = (b0 & 0x80) != 0
        rsv1 = (b0 & 0x40) != 0
        rsv2 = (b0 & 0x20) != 0
        rsv3 = (b0 & 0x10) != 0
        op = b0 & 0x0F
        masked = (b1 & 0x80) != 0
        tam = b1 & 0x7F
        cab = p + 2

        # ---- as recusas que não dependem do corpo ----
        if rsv1 or rsv2 or rsv3:
            # sem extensão negociada, um bit reservado ligado é um emissor a
            # falar de uma coisa que não combinámos (§5.2)
            self.fail(CLOSE_PROTOCOL_ERROR, "reserved bit set with no extension negotiated")
            return None
        if op != OP_CONT and op != OP_TEXT and op != OP_BIN and not is_control(op):
            self.fail(CLOSE_PROTOCOL_ERROR, "reserved opcode")
            return None
        if is_control(op) and op != OP_CLOSE and op != OP_PING and op != OP_PONG:
            self.fail(CLOSE_PROTOCOL_ERROR, "reserved control opcode")
            return None
        if is_control(op):
            if not fin:
                # um controlo fragmentado nunca poderia ser entregue a meio de
                # uma mensagem, que é justamente para o que ele serve (§5.5)
                self.fail(CLOSE_PROTOCOL_ERROR, "a control frame may not be fragmented")
                return None
            if tam > 125:
                self.fail(CLOSE_PROTOCOL_ERROR, "a control frame may not carry more than 125 bytes")
                return None
        if masked != self.is_server:
            self.fail(CLOSE_PROTOCOL_ERROR,
                      "a client frame must be masked" if self.is_server else "a server frame must not be masked")
            return None

        # ---- o comprimento, e a forma MÍNIMA ----
        if tam == 126:
            if n - cab < 2:
                return None
            tam = (int(self.buf[cab]) << 8) | int(self.buf[cab + 1])
            cab += 2
            if tam < 126:
                # o §5.2 diz "MUST": 125 escreve-se num byte, e escrevê-lo em dois
                # é uma segunda maneira de dizer a mesma coisa — que é como se
                # dessincronizam dois leitores do mesmo cano
                self.fail(CLOSE_PROTOCOL_ERROR, "length not in its minimal form")
                return None
        elif tam == 127:
            if n - cab < 8:
                return None
            if (int(self.buf[cab]) & 0x80) != 0:
                self.fail(CLOSE_PROTOCOL_ERROR, "the high bit of a 64-bit length must be zero")
                return None
            tam = 0
            i = 0
            while i < 8:
                tam = (tam << 8) | int(self.buf[cab + i])
                i += 1
            cab += 8
            if tam < 65536:
                self.fail(CLOSE_PROTOCOL_ERROR, "length not in its minimal form")
                return None

        chave: List<u8> = []
        if masked:
            if n - cab < 4:
                return None
            chave = [self.buf[cab], self.buf[cab + 1], self.buf[cab + 2], self.buf[cab + 3]]
            cab += 4
        if n - cab < tam:
            return None

        corpo: List<u8> = []
        i = 0
        while i < tam:
            b = int(self.buf[cab + i])
            if masked:
                b = b ^ int(chave[i & 3])
            corpo.append(u8(b))
            i += 1
        self.pos = cab + tam
        self.compact()
        return Frame(fin, rsv1, rsv2, rsv3, op, bytes(corpo))


def parser(is_server: bool) -> Parser:
    return Parser(is_server, [], 0, "", 0)


# ---------- a máquina de estados da CONEXÃO ----------

const EV_TEXT = 1        # uma mensagem de texto, inteira
const EV_BINARY = 2      # ... e uma binária
const EV_PING = 3
const EV_PONG = 4
const EV_CLOSE = 5       # o outro lado pediu para fechar


struct Event:
    kind: int
    data: bytes          # o corpo; num CLOSE é a razão, já sem o código
    code: int            # só num CLOSE

    def text(self) -> str:
        """O corpo como texto. Num EV_TEXT é sempre válido — a máquina já o
        conferiu antes de o entregar."""
        return str(self.data)


struct Proto:
    """O protocolo inteiro, sem I/O: bytes para dentro, eventos para fora.

    A montagem dos FRAGMENTOS vive aqui e não no parser porque é uma propriedade
    da conversa e não do quadro: um quadro de continuação, sozinho, é legítimo —
    o que o torna errado é não haver princípio nenhum antes dele.
    """
    p: Parser
    is_server: bool
    # a mensagem a ser montada: o opcode do PRIMEIRO quadro, e o que já veio
    frag_op: int
    frag: List<u8>
    fragmenting: bool
    # o aperto de mão de fecho: quem o começou, e se já acabou
    close_sent: bool
    close_received: bool
    closed: bool
    # o teto de uma mensagem montada. Sem ele, um emissor manda fragmentos para
    # sempre e a memória do servidor é dele — é uma negação de serviço de duas
    # linhas a escrever.
    max_message: int

    def failed(self) -> bool:
        return self.p.failed()

    def problem(self) -> str:
        return self.p.problem

    def close_code_out(self) -> int:
        return self.p.code

    def fail(self, code: int, msg: str):
        self.p.fail(code, msg)

    def feed(self, chunk: bytes):
        self.p.feed(chunk)

    def next(self) -> Event?:
        """O evento seguinte, ou `None` quando ainda não há um.

        Um quadro nem sempre é um evento: o princípio de uma mensagem
        fragmentada não é nada ainda, e é por isso que isto é um laço.
        """
        while True:
            f = self.p.next()
            if f == None:
                return None
            ev = self.on_frame(f)
            if self.p.failed():
                return None
            if ev != None:
                return ev

    def on_frame(self, f: Frame) -> Event?:
        # ---- um CONTROLO passa à frente e não toca na montagem ----
        if f.is_control():
            if f.op == OP_PING:
                return Event(EV_PING, f.payload, 0)
            if f.op == OP_PONG:
                return Event(EV_PONG, f.payload, 0)
            # CLOSE
            n = len(f.payload)
            if n == 1:
                # dois bytes ou nenhum: um byte é meio código, e meio código não
                # é um valor (§5.5.1)
                self.fail(CLOSE_PROTOCOL_ERROR, "a close body of one byte is half a code")
                return None
            code = 0
            razao: bytes = b""
            if n >= 2:
                code = (int(f.payload[0]) << 8) | int(f.payload[1])
                if not close_code_ok(code):
                    self.fail(CLOSE_PROTOCOL_ERROR, "close code " + str(code) + " may not travel")
                    return None
                razao = f.payload[2:]
                # a razão é TEXTO, e portanto tem de ser UTF-8 — o mesmo 1007 de
                # uma mensagem de texto, e pela mesma razão
                try:
                    ignora = str(razao)
                catch e:
                    self.fail(CLOSE_INVALID_DATA, "the close reason is not valid UTF-8")
                    return None
            self.close_received = True
            return Event(EV_CLOSE, razao, code)

        # ---- e um quadro de DADOS entra na montagem ----
        if f.op == OP_CONT:
            if not self.fragmenting:
                self.fail(CLOSE_PROTOCOL_ERROR, "a continuation with nothing to continue")
                return None
        else:
            if self.fragmenting:
                self.fail(CLOSE_PROTOCOL_ERROR, "a new message started while another was still open")
                return None
            self.frag_op = f.op
            self.frag = []
            self.fragmenting = True

        for b in f.payload:
            self.frag.append(b)
        if len(self.frag) > self.max_message:
            self.fail(CLOSE_TOO_BIG, "the message is over the ceiling")
            return None
        if not f.fin:
            return None

        corpo = bytes(self.frag)
        op = self.frag_op
        self.fragmenting = False
        self.frag = []
        if op == OP_TEXT:
            # 1007, E SAI DE GRAÇA: `str(bytes)` levanta em UTF-8 inválido,
            # porque uma `str` PROMETE codepoints (79.1). O que noutras
            # bibliotecas é um validador escrito à mão — e é onde a Autobahn mais
            # reprova — aqui é a promessa do tipo a fazer o trabalho.
            try:
                ignora2 = str(corpo)
            catch e:
                self.fail(CLOSE_INVALID_DATA, "the text message is not valid UTF-8")
                return None
            return Event(EV_TEXT, corpo, 0)
        return Event(EV_BINARY, corpo, 0)


def proto(is_server: bool, max_message: int = 1 << 24) -> Proto:
    return Proto(parser(is_server), is_server, 0, [], False, False, False, False, max_message)
