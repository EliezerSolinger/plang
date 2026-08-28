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
import <compress/compress.psc> as comp
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




# ---------- a gramática de um cabeçalho de LISTA COM PARÂMETROS ----------
#
# `Sec-WebSocket-Extensions` e `Sec-WebSocket-Protocol` são a mesma forma do
# RFC 7230 §7, e o `permessage-deflate` do RFC 7692 §7 vive dentro dela:
#
#     lista  = 1#item
#     item   = token *( ";" param )
#     param  = token [ "=" ( token | quoted-string ) ]
#
# **Uma busca de subcadeia não serve, e é o que aqui estava.** Um valor entre
# aspas pode conter uma vírgula e um ponto e vírgula, e um `find("server_max_
# window_bits")` acerta dentro de `x="server_max_window_bits"` — que é um valor e
# não um parâmetro. Ler a gramática é a diferença entre honrar
# `client_max_window_bits=10` e não saber que ele foi pedido.


struct Param:
    name: str
    value: str          # "" = o parâmetro veio SEM valor, que é diferente de ausente


struct Offer:
    """Um item da lista, com os seus parâmetros pela ordem em que vieram."""
    name: str
    params: List<Param>

    def has(self, k: str) -> bool:
        for p in self.params:
            if p.name == k:
                return True
        return False

    def get(self, k: str) -> str:
        """O valor, ou "" quando o parâmetro não tem valor OU não está lá. Quem
        precisa de distinguir os dois casos pergunta ao `has` primeiro — é a
        mesma distinção entre "não disse" e "disse que não sabe" do código de
        fecho 1005."""
        for p in self.params:
            if p.name == k:
                return p.value
        return ""


def is_token_char(c: int) -> bool:
    """Um `tchar` do RFC 7230 §3.2.6. A lista é branca e não preta de propósito:
    um byte que não esteja aqui termina o token, e assim um cabeçalho torcido
    para-se em vez de se ler para dentro do seguinte."""
    if c >= 48 and c <= 57:
        return True
    if (c >= 65 and c <= 90) or (c >= 97 and c <= 122):
        return True
    # !#$%&'*+-.^_`|~ — os quinze que o RFC deixa passar num token
    if c == 33 or c == 35 or c == 36 or c == 37 or c == 38:
        return True
    if c == 39 or c == 42 or c == 43 or c == 45 or c == 46:
        return True
    return c == 94 or c == 95 or c == 96 or c == 124 or c == 126


def skip_ows(b: bytes, i: int) -> int:
    """O `OWS` do §3.2.3: espaço e tabulação, e mais nada — um `\r` ou um `\n`
    aqui dentro seria uma injecção de cabeçalho, e quem os deixa passar é que a
    permite."""
    n = len(b)
    while i < n and (int(b[i]) == 32 or int(b[i]) == 9):
        i += 1
    return i


def read_text(b: bytes) -> str:
    """Os bytes como texto, ou "" quando não são UTF-8.

    Um cabeçalho DEVIA ser ASCII, e é justamente por isso que isto não levanta:
    um cliente que manda um byte torto num valor entre aspas conseguiria derrubar
    a negociação inteira se o `str()` subisse daqui. O item fica com o valor
    vazio e a oferta é recusada mais à frente, que é o que se quer.
    """
    try:
        return str(b)
    catch e:
        return ""


def parse_list(header: str) -> List<Offer>:
    """A lista, item a item, pela ordem em que veio — que é a ordem de
    PREFERÊNCIA de quem a mandou, e por isso não se ordena."""
    out: List<Offer> = []
    b = header.encode()
    n = len(b)
    i = 0
    while i < n:
        i = skip_ows(b, i)
        start = i
        while i < n and is_token_char(int(b[i])):
            i += 1
        name = read_text(b[start:i])
        params: List<Param> = []
        i = skip_ows(b, i)
        while i < n and int(b[i]) == 59:            # ';'
            i += 1
            i = skip_ows(b, i)
            ps = i
            while i < n and is_token_char(int(b[i])):
                i += 1
            pname = read_text(b[ps:i])
            pval = ""
            i = skip_ows(b, i)
            if i < n and int(b[i]) == 61:           # '='
                i += 1
                i = skip_ows(b, i)
                if i < n and int(b[i]) == 34:       # '"' — uma quoted-string
                    i += 1
                    vb: List<u8> = []
                    while i < n and int(b[i]) != 34:
                        # o `quoted-pair` do §3.2.6: uma barra invertida escapa o
                        # byte seguinte, e sem isto um valor com uma aspa dentro
                        # fecharia a string no sítio errado
                        if int(b[i]) == 92 and i + 1 < n:
                            i += 1
                        vb.append(b[i])
                        i += 1
                    if i < n:
                        i += 1                      # a aspa de fecho
                    pval = read_text(bytes(vb))
                else:
                    vs = i
                    while i < n and is_token_char(int(b[i])):
                        i += 1
                    pval = read_text(b[vs:i])
                i = skip_ows(b, i)
            if len(pname) > 0:
                params.append(Param(pname, pval))
        if len(name) > 0:
            out.append(Offer(name, params))
        if i < n and int(b[i]) == 44:               # ',' — o item seguinte
            i += 1
        elif i < n:
            # um byte que a gramática não prevê. Salta-se UM, e é o que garante
            # que isto termina: sem este passo um cabeçalho com lixo a meio
            # ficava em laço com `i` parado, e um laço infinito num parser de
            # cabeçalhos é uma negação de serviço de um cabeçalho só.
            i += 1
    return out


def pick_token(header: str, offered: List<str>) -> str:
    """O primeiro item da lista que também esteja em `offered`, ou "".

    A ordem que manda é a NOSSA e não a do cliente, e é uma decisão: o cliente
    diz o que sabe falar, o servidor diz o que prefere. `offered` é a preferência
    do programa, e percorrer-se-a por fora significa que a primeira que ele
    escreveu ganha.
    """
    items = parse_list(header)
    for want in offered:
        for it in items:
            if it.name == want:
                return want
    return ""


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
    body = apply_mask(f.payload, key) if len(key) == 4 else f.payload
    return bytes(out) + body


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


def fragment_bounds(n: int, size: int) -> List<int>:
    """Os limites dos fragmentos de uma mensagem de `n` bytes: `[0, a, b, ..., n]`.

    Devolve INTEIROS e nao quadros, e a diferenca e entre fragmentar e duplicar:
    montar a lista de `Frame` de uma mensagem de dez megabytes copia os dez
    megabytes para as fatias e guarda-os todos ao mesmo tempo — o DOBRO da
    memoria, na funcao que existe justamente para nao precisar dela. Com os
    limites, quem escreve corta um pedaco de cada vez e nunca tem mais do que um.

    Uma mensagem VAZIA da `[0, 0]`: um fragmento de zero bytes, porque uma
    mensagem vazia continua a ser uma mensagem.
    """
    out: List<int> = [0]
    if size <= 0 or n <= size:
        out.append(n)
        return out
    at = 0
    while at < n:
        end = at + size
        if end > n:
            end = n
        out.append(end)
        at = end
    return out


def fragments(op: int, payload: bytes, size: int, rsv1: bool = False) -> List<Frame>:
    """Uma mensagem partida em quadros. `size` <= 0 = um quadro só.

    **Porque e que isto faz falta.** Ate aqui tudo o que se enviava saia num
    quadro unico, e um quadro unico de dez megabytes obriga o outro lado a ter os
    dez megabytes inteiros em memoria antes de poder olhar para o primeiro byte
    — e obriga-nos a escrever dez megabytes num `write` que nao cede. Um snapshot
    de mundo de um jogo e exactamente esse caso.

    **O RSV1 vai SO no primeiro quadro** (§6.1 do RFC 7692): ele descreve a
    MENSAGEM e nao o quadro, e repeti-lo nas continuacoes e um erro de protocolo
    que qualquer implementacao correcta recusa com 1002. Pela mesma razao a
    compressao acontece ANTES desta funcao: o fluxo do DEFLATE atravessa a
    fragmentacao, e comprimir cada fragmento por si daria N fluxos que o outro
    lado nao consegue juntar.

    O opcode do primeiro quadro e o da mensagem; os seguintes sao OP_CONT, e o
    ultimo e o que leva o FIN.
    """
    out: List<Frame> = []
    n = len(payload)
    b = fragment_bounds(n, size)
    i = 1
    while i < len(b):
        first = i == 1
        out.append(Frame(b[i] >= n, rsv1 and first, False, False,
                         op if first else OP_CONT, payload[b[i - 1]:b[i]]))
        i += 1
    return out


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
    # 148/F9b: uma extensão foi negociada? É o que decide se o bit RSV1 é uma
    # carga comprimida ou um emissor a falar de uma coisa que não combinámos.
    # Sem extensão, os três bits reservados TÊM de ser zero (§5.2).
    rsv1_ok: bool

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
        fresh: List<u8> = []
        i = self.pos
        while i < len(self.buf):
            fresh.append(self.buf[i])
            i += 1
        self.buf = fresh
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
        size = b1 & 0x7F
        head = p + 2

        # ---- as recusas que não dependem do corpo ----
        if rsv2 or rsv3 or (rsv1 and not self.rsv1_ok):
            # sem extensão negociada, um bit reservado ligado é um emissor a
            # falar de uma coisa que não combinámos (§5.2). Com o
            # permessage-deflate combinado, o RSV1 passa a ter significado — e
            # SÓ ele: o RSV2 e o RSV3 continuam a ser um erro.
            self.fail(CLOSE_PROTOCOL_ERROR, "reserved bit set with no extension negotiated")
            return None
        if op != OP_CONT and op != OP_TEXT and op != OP_BIN and not is_control(op):
            self.fail(CLOSE_PROTOCOL_ERROR, "reserved opcode")
            return None
        if is_control(op) and op != OP_CLOSE and op != OP_PING and op != OP_PONG:
            self.fail(CLOSE_PROTOCOL_ERROR, "reserved control opcode")
            return None
        if is_control(op):
            if rsv1:
                # §6.1 do RFC 7692: um quadro de CONTROLO nunca é comprimido, e
                # o RSV1 nele é um erro de protocolo mesmo com a extensão
                # combinada
                self.fail(CLOSE_PROTOCOL_ERROR, "a control frame is never compressed")
                return None
            if not fin:
                # um controlo fragmentado nunca poderia ser entregue a meio de
                # uma mensagem, que é justamente para o que ele serve (§5.5)
                self.fail(CLOSE_PROTOCOL_ERROR, "a control frame may not be fragmented")
                return None
            if size > 125:
                self.fail(CLOSE_PROTOCOL_ERROR, "a control frame may not carry more than 125 bytes")
                return None
        if masked != self.is_server:
            self.fail(CLOSE_PROTOCOL_ERROR,
                      "a client frame must be masked" if self.is_server else "a server frame must not be masked")
            return None

        # ---- o comprimento, e a forma MÍNIMA ----
        if size == 126:
            if n - head < 2:
                return None
            size = (int(self.buf[head]) << 8) | int(self.buf[head + 1])
            head += 2
            if size < 126:
                # o §5.2 diz "MUST": 125 escreve-se num byte, e escrevê-lo em dois
                # é uma segunda maneira de dizer a mesma coisa — que é como se
                # dessincronizam dois leitores do mesmo cano
                self.fail(CLOSE_PROTOCOL_ERROR, "length not in its minimal form")
                return None
        elif size == 127:
            if n - head < 8:
                return None
            if (int(self.buf[head]) & 0x80) != 0:
                self.fail(CLOSE_PROTOCOL_ERROR, "the high bit of a 64-bit length must be zero")
                return None
            size = 0
            i = 0
            while i < 8:
                size = (size << 8) | int(self.buf[head + i])
                i += 1
            head += 8
            if size < 65536:
                self.fail(CLOSE_PROTOCOL_ERROR, "length not in its minimal form")
                return None

        key: List<u8> = []
        if masked:
            if n - head < 4:
                return None
            key = [self.buf[head], self.buf[head + 1], self.buf[head + 2], self.buf[head + 3]]
            head += 4
        if n - head < size:
            return None

        body: List<u8> = []
        i = 0
        while i < size:
            b = int(self.buf[head + i])
            if masked:
                b = b ^ int(key[i & 3])
            body.append(u8(b))
            i += 1
        self.pos = head + size
        self.compact()
        return Frame(fin, rsv1, rsv2, rsv3, op, bytes(body))


def parser(is_server: bool, rsv1_ok: bool = False) -> Parser:
    return Parser(is_server, [], 0, "", 0, rsv1_ok)


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
    # 148/F9b: a mensagem em curso veio comprimida? O RSV1 vem no PRIMEIRO
    # quadro de uma mensagem fragmentada e vale para ela inteira (§6.1), portanto
    # tem de ser guardado quando ela começa.
    frag_compressed: bool
    pmd: Deflate

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
            reason: bytes = b""
            if n >= 2:
                code = (int(f.payload[0]) << 8) | int(f.payload[1])
                if not close_code_ok(code):
                    self.fail(CLOSE_PROTOCOL_ERROR, "close code " + str(code) + " may not travel")
                    return None
                reason = f.payload[2:]
                # a razão é TEXTO, e portanto tem de ser UTF-8 — o mesmo 1007 de
                # uma mensagem de texto, e pela mesma razão
                try:
                    ignored = str(reason)
                catch e:
                    self.fail(CLOSE_INVALID_DATA, "the close reason is not valid UTF-8")
                    return None
            self.close_received = True
            return Event(EV_CLOSE, reason, code)

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
            # o RSV1 do PRIMEIRO quadro vale para a mensagem inteira (§6.1)
            self.frag_compressed = f.rsv1

        for b in f.payload:
            self.frag.append(b)
        if len(self.frag) > self.max_message:
            self.fail(CLOSE_TOO_BIG, "the message is over the ceiling")
            return None
        if not f.fin:
            return None

        body = bytes(self.frag)
        op = self.frag_op
        self.fragmenting = False
        self.frag = []
        if self.frag_compressed:
            # a carga descomprime-se DEPOIS de a mensagem estar montada, e não
            # quadro a quadro: o fluxo do DEFLATE atravessa a fragmentação, e um
            # fragmento sozinho não é um fluxo que se possa ler.
            try:
                body = decompress_payload(body, self.max_message)
            catch e:
                self.fail(CLOSE_INVALID_DATA, "the compressed payload could not be read: " + e.message)
                return None
            self.frag_compressed = False
        if op == OP_TEXT:
            # 1007, E SAI DE GRAÇA: `str(bytes)` levanta em UTF-8 inválido,
            # porque uma `str` PROMETE codepoints (79.1). O que noutras
            # bibliotecas é um validador escrito à mão — e é onde a Autobahn mais
            # reprova — aqui é a promessa do tipo a fazer o trabalho.
            try:
                ignored2 = str(body)
            catch e:
                self.fail(CLOSE_INVALID_DATA, "the text message is not valid UTF-8")
                return None
            return Event(EV_TEXT, body, 0)
        return Event(EV_BINARY, body, 0)


def proto(is_server: bool, max_message: int = 1 << 24, pmd: Deflate? = None) -> Proto:
    d: Deflate = no_deflate()
    if pmd != None:
        d = pmd
    return Proto(parser(is_server, d.enabled), is_server, 0, [], False, False, False, False,
                 max_message, False, d)


# ---------- 148/F9b: permessage-deflate (RFC 7692) ----------
#
# A extensao que comprime a CARGA de um quadro. Para um servidor de jogo que
# difunde estado em JSON sessenta vezes por segundo, ela e a diferenca entre
# mandar oitocentos bytes e mandar cinquenta.
#
# **O que se negoceia, e o que se recusa.** O RFC tem quatro parametros, e o que
# manda neles e a JANELA partilhada entre mensagens (`context takeover`): com ela,
# a mensagem N comprime contra o que a N-1 disse, e o ganho e grande num fluxo de
# mensagens parecidas. Sem ela, cada mensagem comprime sozinha.
#
# **Aqui exige-se `no_context_takeover` dos dois lados**, e a razao esta dita em
# vez de escondida: o nosso compressor e de uma passagem, sem estado entre
# chamadas, e uma janela partilhada precisa de um LZ77 que guarde os ultimos 32
# KiB de cada conexao — em memoria, por conexao, dos dois lados. E o que o desenho
# chamou de "onde ele morde".
#
# A consequencia, medida: uma mensagem de 880 bytes de JSON repetido vai em 54.
# Com takeover iria em menos, e a segunda iria em muito menos. O que se perde esta
# quantificado; o que nao se faz e fingir que se suporta e mandar quadros que o
# outro lado nao consegue ler.

const RSV1 = 0x40      # o bit que diz "esta carga vem comprimida"


struct Deflate:
    """O estado da extensao numa conexao. Sem janela partilhada entre mensagens,
    portanto o que ele guarda e a NEGOCIACAO e nao um dicionario."""
    enabled: bool
    # O TECTO da mensagem descomprimida NAO esta aqui, e chegou a estar: era um
    # `max_output` que ninguem lia. O tecto que vale e o `max_message` do `Proto`
    # — e o mesmo numero para uma mensagem comprimida e para uma fragmentada, que
    # e a defesa contra as duas maneiras de encher a memoria de um servidor. Ter
    # dois campos para um numero e ter um deles errado a certa altura.
    #
    # OS CAMPOS SAO POR DIRECCAO E NAO POR PAPEL, e a razao e concreta: o RFC
    # chama-lhes `server_max_window_bits` e `client_max_window_bits`, e num
    # servidor o primeiro descreve o NOSSO compressor enquanto num cliente
    # descreve o do outro lado. Guardar os nomes do RFC obrigava cada lado a
    # lembrar-se de qual e o seu, e um dia um deles trocava-os — o que produz
    # bytes errados sem erro nenhum.
    #
    # `out_bits`: a janela que o NOSSO compressor respeita, porque foi o que o
    # descompressor do outro lado anunciou. Honrar isto e o que permite aceitar
    # uma oferta com limite de janela em vez de a saltar.
    out_bits: int
    # `in_bits`: o que o outro lado prometeu nao passar. O nosso `inflate` usa a
    # janela inteira, portanto qualquer valor daqui e seguro de aceitar; o campo e
    # o resultado da negociacao para quem o quiser LER — um programa que registe
    # com que janela cada cliente ficou le-o daqui.
    in_bits: int


struct Negotiated:
    """O resultado de ler o `Sec-WebSocket-Extensions`: o que se responde, e o
    estado que fica ligado na conexao.

    Os dois vem juntos porque sao a MESMA decisao, e separa-los foi um defeito:
    o `upgrade` respondia o cabecalho e o laco da conexao voltava a chamar a
    negociacao para descobrir o estado, apoiado em ela ser deterministica. Era
    verdade e era fragil — qualquer parametro que passasse a influenciar o
    estado tinha de ser reproduzido nos dois sitios.
    """
    accepted: str       # o cabecalho de resposta, ou "" quando nao se aceita
    pmd: Deflate


def no_deflate() -> Deflate:
    return Deflate(False, 15, 15)


def window_bits(v: str) -> int:
    """Os bits de janela de um parametro, ou 0 quando o valor nao serve.

    O RFC 7692 §7.1.2 fixa 8..15, e recusar fora disso nao e rigor por gosto: um
    `server_max_window_bits=7` nao e uma janela pequena, e uma oferta que o pede
    esta a pedir uma coisa que o DEFLATE nao tem.
    """
    if len(v) == 0:
        return 0
    n = 0
    for c in v.encode():
        d = int(c)
        if d < 48 or d > 57:
            return 0
        n = n * 10 + (d - 48)
        if n > 15:
            return 0
    return n if n >= 8 else 0


def negotiate(offer: str) -> Negotiated:
    """Le o `Sec-WebSocket-Extensions` do cliente e decide.

    O cabecalho e uma lista de ofertas e o servidor escolhe UMA, pela ordem em
    que vieram — que e a ordem de preferencia do cliente.

    **O que se honra, e o que se recusa.** O RFC tem quatro parametros, e o que
    manda neles e a janela partilhada entre mensagens (`context takeover`): com
    ela, a mensagem N comprime contra o que a N-1 disse. Sem ela, cada mensagem
    comprime sozinha.

    Aqui exige-se `no_context_takeover` dos dois lados, e a razao esta dita em vez
    de escondida: o nosso compressor e de uma passagem, sem estado entre chamadas,
    e uma janela partilhada precisa de guardar os ultimos 32 KiB de cada conexao,
    dos dois lados, em memoria.

    Os `max_window_bits` **passaram a ser honrados** em vez de saltados, e a
    diferenca esta no compressor: o `deflate_sync` leva uma janela e o LZ77 nao
    emite um casamento mais distante do que ela. Antes, uma oferta com
    `server_max_window_bits` era passada a frente — o cliente pedia uma coisa
    legitima e ficava sem compressao nenhuma.

    Um parametro DESCONHECIDO invalida a oferta (§7): responder a uma oferta que
    nao se entendeu inteira e prometer um comportamento que ninguem definiu.
    """
    for o in parse_list(offer):
        if o.name != "permessage-deflate":
            continue
        server_b = 15
        client_b = 0        # 0 = o cliente nao falou do parametro
        ok = True
        for pm in o.params:
            if pm.name == "server_no_context_takeover" or pm.name == "client_no_context_takeover":
                # §7.1.1: estes NAO levam valor, e um valor aqui e uma oferta
                # torcida e nao um detalhe a ignorar
                if len(pm.value) > 0:
                    ok = False
                continue
            if pm.name == "server_max_window_bits":
                # numa oferta de CLIENTE este parametro tem de ter valor (§7.1.2.2)
                v = window_bits(pm.value)
                if v == 0:
                    ok = False
                    continue
                server_b = v
                continue
            if pm.name == "client_max_window_bits":
                if len(pm.value) == 0:
                    # sem valor e "eu suporto o parametro, escolhe tu". Nao ha
                    # razao para apertar o cliente, portanto nao se aperta.
                    client_b = 15
                    continue
                v2 = window_bits(pm.value)
                if v2 == 0:
                    ok = False
                    continue
                client_b = v2
                continue
            ok = False
        if not ok:
            continue
        resp = "permessage-deflate; server_no_context_takeover; client_no_context_takeover"
        if server_b != 15:
            resp += "; server_max_window_bits=" + str(server_b)
        # §7.1.2.1: se o cliente NAO ofereceu `client_max_window_bits`, o servidor
        # NAO o pode incluir na resposta — seria exigir uma coisa que o cliente
        # nao disse que sabia fazer
        if client_b > 0 and client_b != 15:
            resp += "; client_max_window_bits=" + str(client_b)
        # do lado do SERVIDOR: `server_max_window_bits` e a nossa saida
        return Negotiated(resp, Deflate(True, server_b, client_b if client_b > 0 else 15))
    return Negotiated("", no_deflate())


# ---------- e o mesmo, do lado do CLIENTE ----------


def client_offer() -> str:
    """O `Sec-WebSocket-Extensions` que um cliente nosso manda.

    Pede `no_context_takeover` nos dois sentidos porque e o que o nosso
    compressor sabe fazer, e pedi-lo na OFERTA e mais honesto do que descobrir na
    resposta que o servidor quer janela partilhada: assim um servidor que so
    saiba com takeover recusa a extensao inteira em vez de combinar uma coisa que
    nao vamos cumprir.

    Nao se pede limite de janela: a nossa saida sabe respeitar o que o servidor
    exigir, e a nossa entrada aguenta a janela inteira. Pedir um limite seria
    apertar-nos a nos por nada.
    """
    return "permessage-deflate; client_no_context_takeover; server_no_context_takeover"


def read_accepted(header: str) -> Deflate:
    """Le a resposta do servidor a nossa oferta e devolve o que fica ligado.

    **O que se exige, e o que nao se exige.** Os dois `no_context_takeover` nao
    sao simetricos, e tratá-los como se fossem era um defeito meu:

      * **`server_no_context_takeover` e OBRIGATORIO na resposta.** Nao e rigor:
        e uma incapacidade nossa. O `inflate_stream` le cada mensagem como um
        fluxo independente, e com janela partilhada a mensagem N refere-se ao que
        a N-1 disse — o que sairia seriam bytes errados sem erro nenhum. O RFC
        diz que aceitar uma oferta que pede este parametro ja obriga o servidor
        (§7.1.1.1) e que o eco e opcional; exigi-lo mesmo assim e escolher
        depender de uma promessa escrita em vez de uma implicita, e num sitio onde
        o custo de estar errado e silencioso.
      * **`client_no_context_takeover` nao e exigido**, e exigi-lo estava errado:
        ele fala de NOS. Um servidor que o omite esta a PERMITIR-nos janela
        partilhada, e nao usar uma coisa que e permitida e sempre seguro. Recusar
        a extensao ai era recusar uma negociacao perfeitamente utilizavel.

    E recusa-se **um parametro que nao pedimos** ou um valor de janela fora de
    8..15: uma resposta que nao e subconjunto da oferta e o §7.1 a ser quebrado, e
    a conexao fica sem extensao em vez de ficar com uma que ninguem definiu. A
    excepcao e o `client_max_window_bits`, que se HONRA mesmo sem o termos pedido:
    ele aperta a nossa propria saida, e um limite sobre nos mesmos nao pode
    quebrar nada.

    Devolve `no_deflate()` quando nao se aceita — e nao levanta: um servidor que
    responde mal a uma extensao OPCIONAL nao e razao para nao falar com ele.
    """
    for o in parse_list(header):
        if o.name != "permessage-deflate":
            continue
        if not o.has("server_no_context_takeover"):
            return no_deflate()
        out_b = 15      # o que O NOSSO compressor tem de respeitar
        in_b = 15       # e o que o servidor prometeu
        ok = True
        for pm in o.params:
            if pm.name == "server_no_context_takeover" or pm.name == "client_no_context_takeover":
                if len(pm.value) > 0:
                    ok = False
                continue
            if pm.name == "client_max_window_bits":
                # NUMA RESPOSTA este parametro fala do CLIENTE, que somos nos: e
                # a janela que a nossa saida tem de respeitar. E aqui que os
                # nomes do RFC se invertem em relacao ao servidor.
                v = window_bits(pm.value)
                if v == 0:
                    ok = False
                    continue
                out_b = v
                continue
            if pm.name == "server_max_window_bits":
                v2 = window_bits(pm.value)
                if v2 == 0:
                    ok = False
                    continue
                in_b = v2
                continue
            ok = False
        if not ok:
            return no_deflate()
        return Deflate(True, out_b, in_b)
    return no_deflate()


def compress_payload(body: bytes, bits: int = 15) -> bytes:
    """A carga de um quadro, comprimida. Os quatro bytes do sync flush saem, como
    o §7.2.1 manda — eles sao sempre os mesmos, e mandá-los seria mandar quatro
    bytes constantes por mensagem.

    Os `bits` sao os que se negociou: o LZ77 nao emite um casamento mais distante
    do que a janela do descompressor do outro lado. Comprimir com uma janela maior
    do que a anunciada produz um fluxo que o outro lado le mal — e mal, aqui, quer
    dizer bytes errados sem erro nenhum.
    """
    w = 1 << (bits if bits >= 8 and bits <= 15 else 15)
    z = comp.deflate_sync(body, w)
    return z[0:len(z) - 4] if len(z) >= 4 else z


def decompress_payload(body: bytes, ceiling: int) -> bytes:
    """E o inverso: repoe os quatro bytes e descomprime.

    O `ceiling` nao e uma afinacao. Uns poucos quilobytes de zeros comprimidos
    expandem para gigabytes, e uma extensao de compressao sem tecto e uma bomba de
    descompressao a espera de um atacante que sabe disto — que e toda a gente.
    """
    out_bytes = comp.inflate_stream(body + b"\x00\x00\xff\xff")
    if len(out_bytes) > ceiling:
        raise error("permessage-deflate: a mensagem descomprimida passa o tecto — e o que uma bomba de descompressao faz")
    return out_bytes
