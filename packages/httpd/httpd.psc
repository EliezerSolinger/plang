"""Um servidor HTTP/1.1 (e, mais à frente, WebSocket) escrito em pscript.

O parser não está aqui: está no `packages/http`, é incremental e é conferido
contra o corpus do próprio llhttp. O que este módulo acrescenta é tudo o que fica
ENTRE o parser e quem escreve o programa — a conexão, o keep-alive, a resposta,
os erros — e nada dele precisa do runtime.

**O modelo de concorrência é o argumento.** Cada worker tem heap, coletor e
escalonador PRÓPRIOS (18.1), e N workers escutam o mesmo porto com `SO_REUSEPORT`
(D2): o kernel reparte as conexões e ninguém passa descritores a ninguém. Uma
pausa do coletor pára UM worker, não o servidor; e o estado partilhado, quando é
preciso, tem três degraus com custos diferentes e visíveis — o `shared dict` (um
lock por operação), o `shared Buffer` (zero cópia) e a mensagem (serializa).

As decisões que o desenho fixou e que este ficheiro cumpre:

  * **D3c — cabeçalhos são uma LISTA de pares.** O HTTP permite nomes repetidos e
    a ordem importa; `Set-Cookie` é o caso de todos os dias. `req.header(name_s)` dá
    o primeiro, `req.headers_all(name_s)` dá todos. Um `Dict<str,str>` obrigaria a
    um caminho especial só para o `Set-Cookie`, que é a gambiarra que as
    bibliotecas de JavaScript carregam.

  * **D3d — keep-alive desde o v1.** É o padrão do HTTP/1.1 e todo o cliente
    moderno assume-o. Sem ele cada pedido paga um aperto de mão TCP (e um TLS!).

  * **D3e — uma excepção no handler vira 500 e o worker continua.** A excepção
    completa vai para o `stderr` (o `print` atómico da 107.2 garante que a linha
    sai inteira com N workers); com `debug=True` vai também no CORPO, que é o que
    um servidor de desenvolvimento faz.

  * **D3f — o corpo tem dois acessores e um botão.** `req.body` é o corpo inteiro
    até ao tecto; acima dele, 413. A configuração é UM número: `max_body`.

  * **D3g — conveniências mais o construtor.** `text`, `html`, `json`, `blob`,
    `status`, `redirect` para o comum; `Response(...)` para o resto.

  * **D41 — o `Host` é exigido** num pedido HTTP/1.1, como o RFC manda, e validá-lo
    contra uma lista é opção de quem serve.

  * **D42 — `Date` sim, `Server` só a pedido.** O `Date` é obrigatório e as caches
    dependem dele; calcula-se UMA VEZ POR SEGUNDO, porque formatar uma data é caro
    e o valor muda uma vez por segundo. O `Server` anuncia software e versão a
    quem procura alvos, e por isso sai por omissão.
"""
import <http/http.psc> as h
import <datetime/datetime.psc> as dt
import <url/url.psc> as url
import <compress/compress.psc> as comp
import json as jsn
import net
import sys
import time


# ---------- o que entra ----------

struct Header:
    name: str
    value: str


struct Request:
    """O pedido, como o handler o vê.

    `raw` é a lista de pares na ordem em que chegaram (D3c) e é a fonte da
    verdade; `headers` é a mesma coisa dobrada num dicionário, com os repetidos
    juntos por `, ` como o RFC 9110 §5.3 manda — conveniente para o caso comum e
    errado para o `Set-Cookie`, que é justamente por isso que `raw` existe.
    """
    method: str
    target: str            # o alvo cru, tal como veio: `/a/b?x=1`
    path: str              # só o caminho
    query: str             # o que vem depois do `?`, ainda cru
    version: str           # "1.0" ou "1.1"
    headers: Dict<str, str>
    raw: List<Header>
    body: bytes
    peer: str              # o endereço de quem ligou
    params: Dict<str, str> # o que uma rota `:name_s` capturou (F1b)
    # O SÍTIO onde uma camada de cima guarda uma DECISÃO que já tomou.
    #
    # Existe por um defeito concreto: o `upgrade` do WebSocket escolhia o
    # subprotocolo e a extensão a partir dos cabeçalhos, e o laço da conexão
    # repetia a escolha a partir dos MESMOS cabeçalhos, apoiado em ela ser
    # determinística. Era verdade e era frágil — qualquer parâmetro novo tinha de
    # ser reproduzido nos dois sítios, e o dia em que os dois discordassem o
    # servidor diria uma coisa ao cliente e usaria outra.
    #
    # Não é só do WebSocket: é onde um autenticador põe o utilizador que
    # verificou, e a razão de ele não precisar de o verificar duas vezes. A httpd
    # não lê nada daqui — as chaves são de quem as escreve, e é isso que a mantém
    # cega ao que corre por cima dela (D7).
    attrs: Dict<str, str>

    def header(self, name: str) -> str:
        """O PRIMEIRO valor com este nome, ou "" — nomes em minúsculas."""
        for hd in self.raw:
            if hd.name == name:
                return hd.value
        return ""

    def has(self, name: str) -> bool:
        return name in self.headers

    def headers_all(self, name: str) -> List<str>:
        """TODOS os valores com este nome, na ordem em que chegaram (D3c)."""
        out: List<str> = []
        for hd in self.raw:
            if hd.name == name:
                out.append(hd.value)
        return out

    def param(self, name: str) -> str:
        return self.params[name] if name in self.params else ""

    # ---------- F1c/D29: a query ----------

    def query_params(self) -> Dict<str, str>:
        """`?a=1&b=two` lido como um dicionário. É calculado a cada chamada e
        não guardado: a esmagadora maioria dos pedidos não tem query nenhuma, e
        um campo a mais na `Request` custaria a todos eles."""
        return parse_query(self.query)

    def q(self, name_s: str) -> str:
        """UM valor da query, ou "". O atalho para o caso de todos os dias, sem
        construir o dicionário inteiro para ler uma chave."""
        for pair in self.query.split("&"):
            if len(pair) == 0:
                continue
            i = pair.find("=")
            k = form_decode(pair) if i < 0 else form_decode(pair[0:i])
            if k == name_s:
                return "" if i < 0 else form_decode(pair[i + 1:])
        return ""

    def q_all(self, name_s: str) -> List<str>:
        """TODOS os valores desta chave. `?t=a&t=b` é a forma normal de mandar
        uma lista, e um dicionário perde-a — a mesma razão da D3c."""
        return query_all(self.query, name_s)

    # ---------- F1c/D30: o corpo como JSON ----------

    def json(self) -> any:
        """O corpo lido como JSON. Levanta se não for JSON — e é isso que se
        quer: um corpo que devia ser JSON e não é NÃO é um caso a tratar com um
        valor vazio, é um 400. Quem quer o 400 escreve o `try`; quem não escreve
        recebe o 500, que é a verdade sobre o que aconteceu.

        O `content-type` NÃO é conferido aqui. Quem manda `text/plain` com JSON
        lá dentro está a fazer uma coisa estranha e não uma coisa errada, e
        recusar seria a biblioteca a ter opinião sobre o cliente de quem a usa.
        """
        return jsn.parse(str(self.body))

    def cookie(self, name_s: str) -> str:
        """Um cookie do pedido, ou "". Calculado a cada chamada e nao guardado: a
        maioria dos pedidos de uma API nao tem cookies, e um campo a mais na
        `Request` custaria a todos eles."""
        cookie_map = parse_cookies(self.header("cookie"))
        return cookie_map[name_s] if name_s in cookie_map else ""

    def cookies(self) -> Dict<str, str>:
        return parse_cookies(self.header("cookie"))

    def ip(self, trusted_proxies: List<str>) -> str:
        """D32: O IP DO CLIENTE, e a regra que o torna confiavel.

        `peer` e o IP do socket, e e sempre verdade. O `X-Forwarded-For` e um
        cabecalho, portanto qualquer cliente o escreve -- e por isso ele so e
        lido **quando a conexao vem de um proxy da lista**. Confiar nele sem isso
        deixa qualquer um forjar o proprio IP, e ai o rate-limit e o ban por IP
        viram enfeite.

        Da lista do `X-Forwarded-For` toma-se o **ultimo** e nao o primeiro. E ao
        contrario do que a intuicao diz, e e a unica escolha segura: a cadeia e
        `cliente, proxy1, proxy2`, e o cliente controla o principio dela --
        escrever `X-Forwarded-For: 1.2.3.4` faz o primeiro elemento ser o que ele
        quiser. O ultimo foi posto pelo proxy em que confiamos.
        """
        for p in trusted_proxies:
            if p == self.peer:
                xff = self.header("x-forwarded-for")
                if len(xff) > 0:
                    parts = xff.split(",")
                    return parts[len(parts) - 1].strip()
                xreal = self.header("x-real-ip")
                if len(xreal) > 0:
                    return xreal.strip()
        return self.peer

    def is_json(self) -> bool:
        """O `content-type` DIZ que é JSON? A pergunta que decide se vale a pena
        tentar — separada do `json()` porque são duas perguntas."""
        t = self.header("content-type").lower()
        return t.startswith("application/json") or t.find("+json") > 0


# ---------- D29/D30: percent-decoding e a query ----------

def pct_decode_seg(s: str) -> str:
    """O percent-decoding de um SEGMENTO. Um `%2F` aqui dentro NÃO volta a ser
    uma barra que parta o caminho: a partição já aconteceu, e desfazê-la depois
    é exactamente o truque com que se sai de um directório."""
    return str(bytes(url.pct_decode(s)))


def form_decode(s: str) -> str:
    """O mesmo, mas para uma QUERY, onde `+` é um espaço.

    A diferença entre isto e o `pct` acima não é um pormenor: `+` é espaço em
    `application/x-www-form-urlencoded` e é um `+` literal num caminho. Usar a
    regra errada faz `a+b` chegar ao programa como `a b` ou como `a+b` conforme
    o sítio, e é meia hora de depuração de cada vez.
    """
    swapped = ""
    for ch in s:
        swapped += " " if ch == "+" else ch
    return pct_decode_seg(swapped)


def parse_query(q: str) -> Dict<str, str>:
    """`a=1&b=two&c` -> `{"a": "1", "b": "two", "c": ""}`.

    Uma chave sem `=` vale "", que é o que toda a gente faz — e uma chave
    REPETIDA fica com a primeira. Quem precisa de todas usa `query_all`, pela
    mesma razão que os cabeçalhos têm as duas portas (D3c).
    """
    out: Dict<str, str> = {}
    for pair in q.split("&"):
        if len(pair) == 0:
            continue
        i = pair.find("=")
        k = form_decode(pair) if i < 0 else form_decode(pair[0:i])
        v = "" if i < 0 else form_decode(pair[i + 1:])
        if k not in out:
            out[k] = v
    return out


def query_all(q: str, name_s: str) -> List<str>:
    """TODOS os valores desta chave, na ordem em que vieram. `?t=a&t=b` é a forma
    normal de mandar uma lista, e um dicionário perde-a."""
    out: List<str> = []
    for pair in q.split("&"):
        if len(pair) == 0:
            continue
        i = pair.find("=")
        k = form_decode(pair) if i < 0 else form_decode(pair[0:i])
        if k == name_s:
            out.append("" if i < 0 else form_decode(pair[i + 1:]))
    return out


# ---------- o que sai ----------

struct Response:
    """A resposta. `headers` é uma lista pela mesma razão que a do pedido é.

    O `body` é sempre `bytes`: é o que vai para o fio, e ter-lhe dois tipos
    possíveis obrigaria toda a gente a escolher entre eles em cada resposta. As
    conveniências abaixo é que aceitam texto.
    """
    status: int
    headers: List<Header>
    body: bytes
    # 101: a conexão deixou de ser HTTP e passa a ser outra coisa. Quem serve lê
    # isto DEPOIS de escrever a resposta, e entrega o socket a quem vem a seguir.
    upgraded: bool
    # F2/D5: O CORPO POR CURSOR.
    #
    # Uma resposta tem `body` OU isto, e nunca os dois. Não é um tipo-união: é um
    # campo opcional, e quem serve pergunta por ele. A alternativa — um `body`
    # que fosse `bytes | Cursor` — obrigaria toda a gente a desembrulhar em cada
    # resposta, para um caso que é a minoria.
    #
    # O cursor devolve `bytes` a cada chamada e `b""` quando acabou, que é a
    # mesma forma do `Cursor` do MySQL. O `write` de quem serve é um `await`,
    # portanto a CONTRAPRESSÃO vem de graça: um cliente lento faz o cursor
    # esperar, e a memória não cresce.
    stream: (def() -> Task<bytes>)?

    def with_header(self, name: str, value: str) -> Response:
        self.headers.append(Header(name, value))
        return self

    def header(self, name: str) -> str:
        for hd in self.headers:
            if hd.name == name:
                return hd.value
        return ""


def reason_for(status: int) -> str:
    """A frase do estado. Só as que se usam — a lista completa da IANA seria uma
    tabela a envelhecer, e um estado desconhecido responde-se com o número, que é
    o que o RFC 9110 §15 diz que um cliente tem de aceitar de qualquer maneira."""
    match status:
        case 100:
            return "Continue"
        case 101:
            return "Switching Protocols"
        case 200:
            return "OK"
        case 201:
            return "Created"
        case 202:
            return "Accepted"
        case 204:
            return "No Content"
        case 206:
            return "Partial Content"
        case 301:
            return "Moved Permanently"
        case 302:
            return "Found"
        case 303:
            return "See Other"
        case 304:
            return "Not Modified"
        case 307:
            return "Temporary Redirect"
        case 308:
            return "Permanent Redirect"
        case 400:
            return "Bad Request"
        case 401:
            return "Unauthorized"
        case 403:
            return "Forbidden"
        case 404:
            return "Not Found"
        case 405:
            return "Method Not Allowed"
        case 408:
            return "Request Timeout"
        case 409:
            return "Conflict"
        case 411:
            return "Length Required"
        case 413:
            return "Content Too Large"
        case 414:
            return "URI Too Long"
        case 415:
            return "Unsupported Media Type"
        case 416:
            return "Range Not Satisfiable"
        case 417:
            return "Expectation Failed"
        case 426:
            return "Upgrade Required"
        case 429:
            return "Too Many Requests"
        case 431:
            return "Request Header Fields Too Large"
        case 500:
            return "Internal Server Error"
        case 501:
            return "Not Implemented"
        case 503:
            return "Service Unavailable"
        case 505:
            return "HTTP Version Not Supported"
        case _:
            return "Status"


# ---------- D3g: as conveniências ----------

def blob(body: bytes, kind: str) -> Response:
    r = Response(200, [], body, False, None)
    r.headers.append(Header("content-type", kind))
    return r


def text(s: str) -> Response:
    return blob(s.encode(), "text/plain; charset=utf-8")


def html(s: str) -> Response:
    return blob(s.encode(), "text/html; charset=utf-8")


def json(v: any) -> Response:
    return blob(jsn.stringify(v).encode(), "application/json")


def status_code(code: int) -> Response:
    """Uma resposta que é só o estado. O corpo é a frase, para que um `curl` sem
    `-i` mostre alguma coisa em vez de nada.

    O desenho chamava-lhe `status`, e o nome não deu: `status(w)` é uma função da
    LINGUAGEM (a de perguntar por um worker, 107.8), e um `def` de topo não a
    tapa. Não é um defeito do módulo — é uma pergunta de desenho da linguagem que
    fica registada nos ACHADOS: se um nome do programa deve ou não ganhar a um
    embutido, como ganha em Python.
    """
    # um estado sem corpo não leva corpo NEM tipo: dizer que o nada é
    # `text/plain` é dizer uma coisa a mais sobre nada
    if code == 204 or code == 304 or (code >= 100 and code < 200):
        return Response(code, [], b"", False, None)
    r = blob((reason_for(code) + "\n").encode(), "text/plain; charset=utf-8")
    r.status = code
    return r


def redirect(location: str, code: int = 302) -> Response:
    r = status_code(code)
    r.headers.append(Header("location", location))
    return r


# ---------- D42: o `Date`, uma vez por segundo ----------

# A data em RFC 7231 §7.1.1.1 — `Sun, 06 Nov 1994 08:49:37 GMT` — é obrigatória
# na resposta e as caches dependem dela. Formatá-la custa uma divisão do calendário
# e umas concatenações, e o valor muda uma vez por segundo: fazê-lo por resposta
# seria pagar o mesmo trabalho milhares de vezes pelo mesmo resultado.
#
# A MEMÓRIA VIVE NA `Config`, e não numa global. Uma global seria do worker
# (42.2) e funcionaria — cada worker teria a sua, sem lock nenhum —, mas um
# módulo importado não pode ter instruções de topo, e é essa a regra que
# decidiu. Ficou melhor: a memória é do SERVIDOR, portanto dois servidores no
# mesmo worker (um de teste, um a sério) não partilham nada.
const DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def two(n: int) -> str:
    return "0" + str(n) if n < 10 else str(n)


def http_date(secs: int) -> str:
    d = dt.to_utc(dt.instant_of(secs, 0))
    # `weekday` devolve 0=segunda, e o RFC começa a lista em `Mon` — batem
    weekday_s = DAYS[dt.weekday(d.date)]
    return (weekday_s + ", " + two(d.date.day) + " " + MONTHS[d.date.month - 1] + " "
            + str(d.date.year) + " " + two(d.time.hour) + ":" + two(d.time.minute)
            + ":" + two(d.time.second) + " GMT")


def date_now(cfg: Config) -> str:
    now_dt = int(time.time())
    if now_dt != cfg.date_secs:
        cfg.date_secs = now_dt
        cfg.date_text = http_date(now_dt)
    return cfg.date_text


# ---------- a configuração ----------

struct Config:
    """Os botões, num sítio só.

    São um `struct` e não uma dúzia de parâmetros com omissão porque atravessam
    QUATRO camadas — o laço, a conexão, o pedido e o handler — e uma lista de
    argumentos que atravessa quatro camadas passa a ser reescrita em quatro
    sítios de cada vez que ganha um botão.
    """
    max_body: int          # o tecto do corpo; acima dele, 413 (D3f)
    max_header: int        # o tecto dos cabeçalhos; acima dele, 431
    debug: bool            # a excepção vai TAMBÉM no corpo (D3e)
    server_name: str       # vazio = não anunciar nada (D42)
    allowed_hosts: List<str>   # vazia = qualquer um (D41)
    keep_alive: bool
    # QUANTO SE ESPERA PELO PEDIDO SEGUINTE, em segundos. 0 desliga.
    #
    # Esteve declarado e MORTO — ninguem o lia —, e isso e um slowloris de graca:
    # uma conexao keep-alive que nao manda nada ficava aberta enquanto o cliente
    # quisesse, e mil conexoes caladas enchem os workers sem nunca fazer um
    # pedido. Custa a um atacante um socket por conexao e mais nada.
    #
    # O prazo vale SO no limiar de um pedido novo, e nao a meio de um corpo: um
    # upload legitimo de um ficheiro grande por uma linha lenta demora, e
    # matá-lo seria trocar uma falha de seguranca por uma falha de servico. Quem
    # limita o corpo e o `max_body`, que e outra pergunta.
    idle_timeout: float
    # D42: a data formatada e o segundo a que ela pertence — ver `date_now`
    date_secs: int
    date_text: str
    # F6/D7: QUEM FICA COM O SOCKET depois de um 101.
    #
    # A `httpd` não sabe o que é um WebSocket, e é essa a fronteira: ela sabe que
    # alguém pediu para tomar conta da conexão e entrega-lha, com o pedido que a
    # pediu e os bytes que já tinham chegado a seguir ao aperto de mão. Quem
    # entende o que vem a seguir é outra camada — hoje o `packages/httpd/ws.psc`,
    # amanhã um túnel de CONNECT ou o h2.
    #
    # Sem os bytes que sobraram isto não funcionaria: um cliente ansioso manda o
    # primeiro quadro colado ao pedido, no MESMO `read`, e esses bytes estão no
    # parser do HTTP quando ele acaba.
    #
    # Os PARÊNTESES não são estilo: `def(...) -> Task<int>?` é a função que
    # devolve um opcional, e `(def(...) -> Task<int>)?` é a função opcional. As
    # duas escrevem-se quase igual e querem dizer coisas diferentes.
    on_upgrade: (def(Socket, Request, bytes) -> Task<int>)?
    # F4/D8: o SERVIDOR NASCE A FALAR `https`. Os dois caminhos (PEM), ou vazios
    # para servir em claro.
    #
    # É um MODO da ligação e não um tipo novo, que é a mesma decisão da S7 do lado
    # cliente: o `read_into`, o `write` e tudo o que está acima não sabem a
    # diferença. Um `TlsSocket` à parte obrigaria cada camada acima a ter duas
    # versões de tudo, e é assim que uma biblioteca de rede duplica.
    tls_cert: str
    tls_key: str


def config() -> Config:
    c: Config = Config(1 << 20, 1 << 16, False, "", [], True, 30.0, -1, "", None, "", "")
    return c


# ---------- escrever a resposta ----------

def stream_of(fn: def() -> Task<bytes>, kind: str) -> Response:
    """F2/D5: uma resposta cujo corpo vem por PEDAÇOS.

    `fn()` devolve o pedaço seguinte, e `b""` diz que acabou — a mesma forma que
    o cursor do MySQL tem, para não haver duas maneiras de ler algo aos bocados
    nesta base de código.

    Sai em `chunked` e não com `content-length`, porque o comprimento não se sabe
    — e é essa a diferença entre isto e uma resposta normal. Um servidor que
    juntasse os pedaços para poder anunciar o comprimento teria feito exactamente
    o trabalho que o streaming existe para evitar.
    """
    r = Response(200, [], b"", False, fn)
    r.headers.append(Header("content-type", kind))
    return r


def sse(fn: def() -> Task<bytes>) -> Response:
    """Server-Sent Events: um cursor com os cabeçalhos que o browser espera.

    O `X-Accel-Buffering: no` não é para nós — é para um nginx à frente. Sem ele
    o proxy junta os eventos num tampão e entrega-os todos no fim, o que
    transforma um fluxo em tempo real numa resposta longa. É o problema mais
    reportado de SSE atrás de um proxy, e cabe num cabeçalho.
    """
    r = stream_of(fn, "text/event-stream")
    r.headers.append(Header("cache-control", "no-cache"))
    r.headers.append(Header("x-accel-buffering", "no"))
    return r


def sse_event(name_s: str, data: str) -> bytes:
    """Um evento SSE, com a moldura que a especificação pede.

    Cada linha dos dados leva o seu `data:`, porque uma quebra de linha crua
    dentro do campo TERMINA o evento — é o engano de sempre, e serializar JSON
    numa linha só não chega quando ele tem um `\n` lá dentro.
    """
    out = ""
    if len(name_s) > 0:
        out += "event: " + name_s + "\n"
    for line in data.split("\n"):
        out += "data: " + line + "\n"
    return (out + "\n").encode()


def encode(r: Response, req_version: str, close_after: bool, cfg: Config) -> bytes:
    """A resposta inteira em bytes: linha de estado, cabeçalhos, corpo.

    O `content-length` é POSTO AQUI e não pelo handler, e é uma decisão e não uma
    conveniência: o comprimento é uma função do corpo, e deixar que alguém o
    escrevesse à mão seria deixar que discordasse dele — que é a porta do
    request smuggling. Um handler que já o tenha posto vê-o substituído.
    """
    sb: List<str> = []
    sb.append("HTTP/1.1 " + str(r.status) + " " + reason_for(r.status) + "\r\n")
    has_type = False
    for hd in r.headers:
        n = hd.name.lower()
        # o comprimento e a ligação são de quem SERVE, não de quem responde — um
        # handler que escrevesse o seu comprimento poderia discordar do corpo, e
        # dois comprimentos que discordam é a porta do request smuggling.
        #
        # A EXCEPÇÃO é o 101: aí a conexão deixa de ser HTTP, e quem sabe o que
        # ela passa a ser é justamente quem respondeu — o `connection: Upgrade`
        # é dele. Sem esta linha o aperto de mão sai sem o cabeçalho e qualquer
        # cliente correcto recusa-o.
        if n == "content-length" or n == "date":
            continue
        if n == "connection" and not r.upgraded:
            continue
        if n == "content-type":
            has_type = True
        sb.append(hd.name + ": " + hd.value + "\r\n")
    sb.append("date: " + date_now(cfg) + "\r\n")
    if len(cfg.server_name) > 0:
        sb.append("server: " + cfg.server_name + "\r\n")
    # RFC 9110 §8.6: um 1xx e um 204 NÃO levam `content-length` — nem sequer
    # zero. E o 101 entrega a conexão a outro protocolo: não tem corpo, não tem
    # comprimento, e a ligação não fecha, que é o que a entrega significa.
    #
    # A diferença entre "não levar" e "levar zero" parece de gosto e não é: um
    # intermediário que veja `content-length` num 204 tem duas leituras da
    # mesma resposta, e duas leituras da mesma resposta é a definição de
    # dessincronizar um cano partilhado.
    if not r.upgraded:
        if r.stream != None:
            # F2/D5: o comprimento NÃO SE SABE, e é essa a diferença. Um servidor
            # que juntasse os pedaços para o poder anunciar teria feito
            # exactamente o trabalho que o streaming existe para evitar.
            sb.append("transfer-encoding: chunked\r\n")
        elif not (r.status == 204 or (r.status >= 100 and r.status < 200)):
            sb.append("content-length: " + str(len(r.body)) + "\r\n")
        sb.append("connection: " + ("close" if close_after else "keep-alive") + "\r\n")
    sb.append("\r\n")
    hdr = "".join(sb).encode()
    # HEAD e os estados sem corpo levam os cabeçalhos e mais nada
    if len(r.body) == 0:
        return hdr
    return hdr + r.body


def bodyless(status: int, method: str) -> bool:
    """RFC 9112 §6.3: estas respostas NÃO têm corpo, e escrever um faz o cliente
    lê-lo como o princípio da mensagem seguinte."""
    return method == "HEAD" or status == 204 or status == 304 or (status >= 100 and status < 200)


# ---------- a conexão ----------

def split_target(t: str) -> List<str>:
    """`/a/b?x=1` -> `["/a/b", "x=1"]`. O fragmento (`#`) nunca chega ao servidor
    — o RFC 9112 §3.2 diz que o cliente não o manda —, e se chegar é lixo e vai
    junto com a query, onde não estraga nada."""
    i = t.find("?")
    if i < 0:
        return [t, ""]
    return [t[0:i], t[i + 1:]]


def to_request(r: h.Request, peer: str) -> Request:
    raw: List<Header> = []
    for hd in r.raw:
        raw.append(Header(hd.name, hd.value))
    p = split_target(r.target)
    return Request(r.method, r.target, p[0], p[1], r.version,
                   r.headers, raw, r.body, peer, {}, {})


def host_ok(req: Request, cfg: Config) -> bool:
    """D41: o `Host` é exigido no HTTP/1.1, e validá-lo é opção.

    Quem constrói URLs a partir do Host — o link de um reset de senha é o exemplo
    de sempre — está a deixar o cliente escolher o domínio para onde o utilizador
    vai. O Django tem `ALLOWED_HOSTS` por causa dessa história.
    """
    host_hdr = req.header("host")
    if req.version == "1.1" and len(host_hdr) == 0:
        return False
    if len(cfg.allowed_hosts) == 0:
        return True
    # o porto não faz parte da comparação: `exemplo.pt` e `exemplo.pt:8080` são
    # o mesmo nome
    name_s = host_hdr
    i = name_s.rfind(":")
    if i > 0 and name_s.find("]") < i:
        name_s = name_s[0:i]
    for a in cfg.allowed_hosts:
        if a == name_s:
            return True
    return False


def chunk(b: bytes) -> bytes:
    """Um pedaço em `chunked`: o tamanho em HEXADECIMAL, CRLF, os bytes, CRLF.

    Em hexadecimal e sem zeros à frente — o RFC 9112 §7.1 diz que é um
    `chunk-size` hex, e um servidor que escrevesse decimal seria lido como um
    tamanho dezasseis vezes maior no melhor dos casos.
    """
    return (hex_len(len(b)) + "\r\n").encode() + b + b"\r\n"


def hex_len(n: int) -> str:
    if n == 0:
        return "0"
    digits = "0123456789abcdef"
    out = ""
    v = n
    while v > 0:
        out = digits[v % 16] + out
        v = v // 16
    return out


async def write_stream(c: Socket, r: Response, cfg: Config) -> bool:
    """Os pedaços, até o cursor dizer que acabou.

    A CONTRAPRESSÃO vem de graça e não foi preciso escrevê-la: o `write` é um
    `await`, portanto um cliente lento faz esta tarefa esperar no socket, e o
    cursor só é chamado outra vez quando o pedaço anterior saiu. A memória não
    cresce, e o worker corre as outras conexões enquanto isto espera.
    """
    fn = r.stream
    if fn == None:
        return True
    while True:
        piece = b""
        try:
            piece = await fn()
        catch e:
            # o cursor rebentou a meio. Os cabeçalhos já foram, portanto não há
            # 500 possível — o que há é acabar o corpo e fechar, que é o que um
            # cliente lê como "a resposta foi interrompida".
            ignored_log = await sys.err.write("httpd: stream: " + e.message + "\n")
            return False
        if len(piece) == 0:
            break
        if not await write_all(c, chunk(piece)):
            return False
    # o pedaço de tamanho zero é o FIM, e o CRLF a seguir fecha os trailers que
    # não existem. Sem ele o cliente fica à espera de mais.
    return await write_all(c, b"0\r\n\r\n")


async def write_all(c: Socket, b: bytes) -> bool:
    """Escreve tudo, e diz se conseguiu. Um cliente que desliga a meio não é um
    erro do servidor — é o caso comum de quem carrega em `stop` no browser — e
    por isso isto responde em vez de levantar."""
    try:
        await c.write(b)
        return True
    catch e:
        return False


async def serve_conn(c: Socket, peer: str, handle: def(Request) -> Task<Response>,
                     cfg: Config) -> int:
    """UMA conexão, do princípio ao fim: o laço do keep-alive (D3d).

    A forma é: lê -> alimenta o parser -> quando há mensagem inteira, chama o
    handler -> escreve -> ou recomeça, ou fecha.

    Nada aqui levanta para fora. Uma conexão é uma coisa que corre mal por
    profissão — o cliente desliga, manda lixo, desaparece a meio do corpo — e um
    servidor que morresse com isso não seria um servidor. Devolve QUANTOS pedidos
    serviu, que é o número que um teste consegue afirmar.
    """
    served_n = 0
    answered_expect = False
    # estamos no LIMIAR de um pedido, ou a meio de um? O prazo do `idle_timeout`
    # vale so no limiar (ver a nota do campo)
    idle = True
    # F4/D8: o TLS vai POR CIMA da ligação aceita, antes de se ler o primeiro
    # byte. Falhar aqui é o cliente a apresentar-se mal — fecha-se em silêncio,
    # porque não há canal por onde dizer nada: o que ele espera é TLS, e um 400 em
    # claro seria lixo.
    if len(cfg.tls_cert) > 0:
        try:
            ignored_tls = await net.serve_tls(c, cfg.tls_cert, cfg.tls_key)
        catch e:
            c.close()
            return 0
    p = h.new_parser()
    with Buffer(65536) as rb:
        while True:
            # ---- lê o que houver ----
            n = 0
            try:
                rd = c.read_into(rb, 0, 65536)
                if idle and cfg.idle_timeout > 0.0:
                    # o `timeout` CANCELA o perdedor (48.2), portanto uma conexao
                    # calada custa o prazo e nem um descritor a mais. O `sleep`
                    # dele estaciona no mesmo multiplexador que espera pelos
                    # sockets, e por isso esperar aqui nao custa nada a ninguem.
                    if not await timeout(rd, cfg.idle_timeout):
                        break
                # o valor le-se da tarefa depois de ela ter ganho (37.2)
                n = await rd
            catch e:
                break
            idle = False
            if n == 0:
                # o cliente fechou. Um corpo sem comprimento declarado acaba
                # exactamente aqui, e é `finish` quem o diz ao parser.
                p.finish()
                break
            if not p.feed(bytes(rb[0:n])):
                # D40: A JANELA DO `Expect: 100-continue`.
                #
                # Os cabeçalhos chegaram e o corpo ainda não. É o único momento
                # em que se pode recusar por tamanho ANTES de o upload subir, e é
                # toda a razão de o cabeçalho existir — o `curl` manda-o sozinho
                # acima de um KiB.
                #
                # E não é opcional: um cliente que o mande ESPERA pela resposta
                # antes de enviar. Sem esta linha ele espera o tempo dele (um
                # segundo, no `curl`) e só depois manda — um segundo por pedido,
                # que num teste passa por lentidão da rede.
                if p.headers_done() and not answered_expect:
                    answered_expect = True
                    decl = p.declared_length()
                    if decl > cfg.max_body:
                        # 413 ANTES de o corpo subir, que é o que se ganha
                        await write_all(c, encode(status_code(413), "1.1", True, cfg))
                        break
                    if len(p.request().header("expect")) > 0 and expect_continue(to_request(p.request(), peer)):
                        if not await write_all(c, b"HTTP/1.1 100 Continue\r\n\r\n"):
                            break
                if p.failed():
                    # 400, e fecha. O que sobra no cano pertence a uma mensagem
                    # que não se sabe onde acaba, e continuar a ler dela é
                    # exactamente o que o request smuggling explora.
                    await write_all(c, encode(status_code(400), "1.1", True, cfg))
                    break
                if p.handoff():
                    # a conexão deixou de ser HTTP/1 sem passar pelo handler:
                    # um CONNECT ou o preâmbulo do HTTP/2. Nada aqui sabe o que
                    # fazer com ela (F6/F11), e fingir que sabe seria pior.
                    await write_all(c, encode(status_code(501), "1.1", True, cfg))
                    break
                # a mensagem ainda não chegou inteira: lê mais
                continue

            # ---- há um pedido inteiro ----
            req = to_request(p.request(), peer)
            keep = cfg.keep_alive and p.keep_alive()
            resp = await respond(req, handle, cfg)
            if bodyless(resp.status, req.method):
                resp.body = b""
            if resp.status == 413 or resp.status == 400 or resp.status == 431:
                # depois de recusar por forma, o que sobra no cano é de uma
                # mensagem que não se sabe onde acaba — a única saída sã é fechar
                keep = False
            if not await write_all(c, encode(resp, req.version, not keep, cfg)):
                break
            if resp.stream != None and req.method != "HEAD":
                # um HEAD leva os cabeçalhos e mais nada, e isso inclui não
                # chamar o cursor: gerar o corpo para o deitar fora seria pagar
                # o trabalho inteiro pela resposta que existe para o evitar
                if not await write_stream(c, resp, cfg):
                    break
            served_n += 1
            answered_expect = False
            if resp.upgraded:
                # a conexão deixou de ser HTTP/1. Entrega-se a quem a pediu, COM
                # o que sobrou por ler: um cliente ansioso manda o primeiro
                # quadro colado ao pedido, no mesmo `read`, e esses bytes estão
                # aqui dentro. Sem os passar, a primeira mensagem perdia-se —
                # e é o género de defeito que só aparece com um cliente rápido.
                # o estreitamento prova-se num LOCAL e não num campo (43.1): o
                # campo pode ser reatribuído entre a prova e o uso, e um local
                # não pode
                up = cfg.on_upgrade
                if up != None:
                    ignored = await up(c, req, p.rest())
                    return served_n
                # ninguém a pediu: fecha, em vez de deixar um socket vivo a
                # falar um protocolo que ninguém está a ler
                c.close()
                return served_n
            if not keep:
                break
            p.reset()
            idle = True
    c.close()
    return served_n


async def respond(req: Request, handle: def(Request) -> Task<Response>,
                   cfg: Config) -> Response:
    """O handler, com as recusas por forma à frente e a rede de segurança atrás.

    D3e: uma excepção vira 500 e o worker continua. A excepção completa vai para
    o `stderr` sempre — com N workers a escrever ao mesmo tempo, é o `print`
    atómico da 107.2 que garante que a linha sai inteira — e vai TAMBÉM no corpo
    quando `debug` está ligado, que é o que um servidor de desenvolvimento faz e
    o que poupa uma ida ao terminal enquanto se porta o jogo.
    """
    if not host_ok(req, cfg):
        return status_code(400)
    if len(req.body) > cfg.max_body:
        return status_code(413)
    try:
        return await handle(req)
    catch e:
        ignored_log = await sys.err.write("httpd: " + req.method + " " + req.target + ": " + e.message + "\n")
        if cfg.debug:
            r = status_code(500)
            r.body = ("500 Internal Server Error\n\n" + e.message + "\n").encode()
            return r
        return status_code(500)


# ---------- o servidor ----------

struct Server:
    """O que `serve` devolve, e o que `with` fecha (D38).

    Guardar o socket num tipo com nome, em vez de o devolver nu, é o que deixa
    parar um servidor: um teste que arranca um servidor tem de o poder desligar,
    e um servidor que só se desliga matando o processo não é testável.
    """
    sock: Socket
    cfg: Config
    port: int
    running: bool
    served: int            # quantos pedidos, ao todo — o que um teste afirma

    def stop(self):
        self.running = False


implement Closeable for Server:
    def close(self):
        self.running = False
        self.sock.close()


def listen(port: int, cfg: Config, reuseport: bool = False) -> Server:
    """Abre o porto. É SÍNCRONO de propósito: ligar e escutar são instantâneos
    (77.1), e o que espera é o `accept`. Assim quem arranca um servidor num teste
    sabe o porto ANTES de haver qualquer tarefa a correr."""
    s = net.listen(port, reuseport)
    return Server(s, cfg, s.port(), True, 0)


async def run(srv: Server, handle: def(Request) -> Task<Response>):
    """O laço: aceita e entrega, para sempre.

    Cada conexão é uma TAREFA QUENTE que ninguém espera — chamar já a arranca
    (35.3), e o escalonador deste worker leva-a até ao fim. É por isso que o
    `serve_conn` não deixa escapar nada: uma tarefa que ninguém espera e que
    levanta escreve "an error nobody awaited" e mais nada, o que seria um erro
    perdido em vez de um 500.
    """
    while srv.running:
        try:
            c = await srv.sock.accept()
            srv.served += 1
            count(srv, c, handle)
        catch e:
            if not srv.running:
                break
            # um `accept` que falha não é o fim do servidor: o descritor
            # esgotou-se, o cliente desistiu entre o SYN e o accept. Cede a vez e
            # tenta outra vez, em vez de girar a queimar o núcleo.
            await sleep(0.01)


def count(srv: Server, c: Socket, handle: def(Request) -> Task<Response>):
    """Arranca a tarefa da conexão e deita fora o valor. Existe como função para
    dizer isso por escrito: o resultado é deliberadamente ignorado, e uma linha
    que ignora um valor sem o dizer lê-se como um esquecimento."""
    # D32: o endereço de quem ligou, lido do socket. É a única fonte que o
    # cliente não pode escrever, e é por isso que o `X-Forwarded-For` só é lido
    # quando ELE diz que a ligação vem de um proxy declarado.
    t = serve_conn(c, c.peer(), handle, srv.cfg)


# ---------- F3/D12: N WORKERS NO MESMO PORTO ----------
#
# É aqui que as três peças da linguagem se juntam, e nenhuma delas era acessória:
#
#   * **L1** — o handler ATRAVESSA para o worker. Um `def` de topo é um símbolo,
#     o mesmo endereço em toda a thread do mesmo binário. Sem isto não havia como
#     dar o handler a um worker, e o `serve(porta, handle, workers=N)` do desenho
#     não podia existir;
#   * **L2** — `SO_REUSEPORT`: os N escutam o MESMO porto e o kernel reparte as
#     conexões. Sem aceitador único (que seria o gargalo) e sem thundering herd;
#   * **L4** — os tópicos alcançam os N, para que uma difusão chegue a um jogador
#     esteja ele no worker que estiver.
#
# **`workers=os.nproc()` por omissão** (D12): o servidor nasce a usar a máquina
# inteira, que é o argumento. O Bun usa um e o `cluster` é opt-in; nascer
# multi-core é exactamente o diferencial. `workers=1` é o opt-in de quem depura.
async def worker_entry(handle: def(Request) -> Task<Response>, port: int, debug: bool) -> int:
    """O que cada worker corre. Recebe o HANDLER pela travessia da L1.
    
    A `Config` não atravessa — ela é um `struct` e um struct é coletado, portanto
    cada worker faz a sua. O que atravessa são os números e os bools, que é o que
    a mensagem sabe carregar (34.3), e é também o desenho certo: a memória da
    data (D42) e o hub dos tópicos passam a ser de cada worker, sem lock nenhum a
    partilhar.
    """
    c = config()
    c.debug = debug
    # `reuseport=True`: é o que faz os N poderem ligar-se ao mesmo porto
    srv = listen(port, c, True)
    await run(srv, handle)
    return 0


async def serve(port: int, handle: def(Request) -> Task<Response>,
                cfg: Config? = None) -> Server:
    """O atalho: abre, corre, e só volta quando alguém parar o servidor."""
    c2: Config = config()
    if cfg != None:
        c2 = cfg
    srv = listen(port, c2)
    await run(srv, handle)
    return srv


# ---------- F9/D16: a COMPRESSAO ----------

def accepts_gzip(req: Request) -> bool:
    """O cliente disse que aceita gzip?

    A leitura e deliberadamente simples: procura-se o nome na lista. O que ela
    NAO faz e ler os pesos `q=` -- um `gzip;q=0` significa "nao me mandes gzip",
    e honra-lo pede uma gramatica de lista-com-parametros que ainda nao existe
    aqui. Portanto o caso e tratado a mao: um `q=0` explicito e respeitado, e o
    resto e ordem de preferencia que ignoramos com uma resposta correcta.
    """
    accept_enc = req.header("accept-encoding").lower()
    if len(accept_enc) == 0:
        return False
    for part in accept_enc.split(","):
        p = part.strip()
        if p.startswith("gzip"):
            # `gzip;q=0` e uma recusa, e e a unica forma de peso que muda a
            # resposta em vez de a ordenar
            return p.find("q=0") < 0 or p.find("q=0.") >= 0
        if p.startswith("*"):
            return p.find("q=0") < 0 or p.find("q=0.") >= 0
    return False


def compressible(ctype: str) -> bool:
    """Vale a pena comprimir este tipo?

    Comprimir um JPEG, um PNG, um MP4 ou um `.gz` **gasta CPU e aumenta o
    tamanho** -- eles ja estao comprimidos, e o DEFLATE por cima acrescenta a
    moldura dele. E o erro mais comum de quem liga a compressao por omissao, e
    custa em CPU nos dois lados do fio.
    """
    t = ctype.lower()
    if t.startswith("text/"):
        return True
    for m in ["application/json", "application/javascript", "application/xml",
              "application/wasm", "image/svg+xml", "+json", "+xml"]:
        if t.find(m) >= 0:
            return True
    return False


def compress(r: Response, req: Request, minimum: int = 1024) -> Response:
    """Comprime a resposta se valer a pena, e devolve-a de qualquer maneira.

    Tres condicoes, e nenhuma e opcional:

      * o cliente **pediu** (`Accept-Encoding`);
      * o tipo **ganha** com isso -- comprimir um JPEG gasta CPU e cresce;
      * o corpo passa do **minimo**. Abaixo de um kilobyte a moldura do gzip
        (dezoito bytes) e o CPU dos dois lados nao se pagam, e um pacote TCP leva
        mil e quinhentos: comprimir de 400 para 380 bytes nao poupa uma viagem.

    E o `Vary: Accept-Encoding` sai SEMPRE que se comprime, e nao e cortesia: sem
    ele uma cache intermediaria entrega a versao comprimida a um cliente que nao
    a pediu, e esse ve lixo binario. E o defeito classico de por compressao atras
    de um proxy.
    """
    if r.stream != None:
        # um fluxo nao se comprime aqui: o corpo ainda nao existe, e comprimi-lo
        # pedaco a pedaco precisa de um DEFLATE com estado entre chamadas (o
        # mesmo que o permessage-deflate do ws precisa). Fica dito em vez de
        # feito pela metade.
        return r
    if len(r.body) < minimum:
        return r
    if not accepts_gzip(req):
        return r
    if not compressible(r.header("content-type")):
        return r
    if len(r.header("content-encoding")) > 0:
        return r        # ja vem codificada: nao se codifica duas vezes
    z = comp.gzip_compress(r.body)
    if len(z) >= len(r.body):
        # aconteceu: comprimir cresceu. Devolve-se o original, porque o objectivo
        # era poupar bytes e nao usar gzip.
        return r
    r.body = z
    r.headers.append(Header("content-encoding", "gzip"))
    r.headers.append(Header("vary", "Accept-Encoding"))
    return r


# ---------- F8b/D33: os COOKIES ----------

def parse_cookies(hdr: str) -> Dict<str, str>:
    """`Cookie: a=1; b=2` lido como um dicionario.

    O cabecalho `Cookie` e o UNICO que junta pares com `;` em vez de virem em
    linhas separadas -- e por isso e o unico que precisa de um parser proprio. Uma
    chave repetida fica com a PRIMEIRA, que e o que os browsers fazem quando ha um
    cookie de dominio e um de subdominio com o mesmo nome.
    """
    out: Dict<str, str> = {}
    for pair in hdr.split(";"):
        p = pair.strip()
        if len(p) == 0:
            continue
        i = p.find("=")
        if i < 0:
            continue
        k = p[0:i].strip()
        v = p[i + 1:].strip()
        # um valor entre aspas: a RFC 6265 permite, e ha bibliotecas que as poem
        if len(v) >= 2 and v.startswith("\"") and v.endswith("\""):
            v = v[1:len(v) - 1]
        if len(k) > 0 and k not in out:
            out[k] = v
    return out


def cookie_ok(s: str) -> bool:
    """Um nome ou valor de cookie NAO pode ter os caracteres que o quebrariam.

    Nao e uma limpeza estetica: um `\r\n` num valor de cookie que va para um
    `Set-Cookie` e uma INJECCAO DE CABECALHO -- quem controla o valor passa a
    escrever cabecalhos, e dai sai um `Location` ou um segundo `Set-Cookie`. E por
    isso que isto RECUSA em vez de limpar: limpar esconde o ataque, e recusar
    mostra-o a quem escreveu o programa.
    """
    for ch in s:
        c = ord(ch)
        if c < 0x21 or c > 0x7E or ch == ";" or ch == "," or ch == "\\" or ch == "\"":
            return False
    return True


def set_cookie(r: Response, name_s: str, value_s: str, max_age: int = -1,
               path_s: str = "/", domain: str = "", http_only: bool = True,
               secure: bool = True, same_site: str = "Lax") -> Response:
    """Escreve um `Set-Cookie` com os atributos de seguranca POR OMISSAO.

    `http_only`, `secure` e `same_site=Lax` sao o **padrao** e nao a opcao, e a
    diferenca importa: um cookie de sessao sem `HttpOnly` e legivel por qualquer
    XSS, um sem `Secure` viaja em claro na primeira ligacao HTTP que o browser
    fizer, e um sem `SameSite` vai em pedidos de outros sitios -- que e o CSRF.

    Quem precisa do contrario escreve-o, e a linha fica a dizer o que fez.
    """
    if not cookie_ok(name_s) or not cookie_ok(value_s):
        raise error("um nome ou valor de cookie com caracteres de controlo seria uma injeccao de cabecalho: " + name_s)
    sb = name_s + "=" + value_s
    if max_age >= 0:
        sb += "; Max-Age=" + str(max_age)
    if len(path_s) > 0:
        sb += "; Path=" + path_s
    if len(domain) > 0:
        sb += "; Domain=" + domain
    if http_only:
        sb += "; HttpOnly"
    if secure:
        sb += "; Secure"
    if len(same_site) > 0:
        sb += "; SameSite=" + same_site
    # a LISTA de cabecalhos e o que faz isto funcionar (D3c): um `Set-Cookie` por
    # cookie, e um dicionario juntaria-os com `, ` -- que os browsers leem como
    # UM cookie com uma virgula no valor
    r.headers.append(Header("set-cookie", sb))
    return r


def clear_cookie(r: Response, name_s: str, path_s: str = "/") -> Response:
    """Apaga um cookie: e um `Set-Cookie` com o valor vazio e `Max-Age=0`.

    Nao ha outra maneira -- o HTTP nao tem "apaga este cookie". E o `Path` tem de
    ser o MESMO com que ele foi posto, senao apaga-se um cookie diferente e o
    original fica.
    """
    return set_cookie(r, name_s, "", 0, path_s, "", True, True, "Lax")


# ---------- F8c/D30: MULTIPART/FORM-DATA ----------

struct Part:
    """Um campo de um formulario. `name_s` e o do campo; `file_name` e o nome do
    ficheiro quando havia um, ou "" quando era um campo de texto."""
    name_s: str
    file_name: str
    ctype: str
    data: bytes

    def text(self) -> str:
        return str(self.data)


def boundary_of(content_type: str) -> str:
    """A fronteira do `Content-Type: multipart/form-data; boundary=...`.

    Ela pode vir entre aspas, e vem quando tem caracteres que um token nao
    permite -- o que acontece com a que o `curl` gera. Ler so a forma sem aspas e
    o engano que faz metade dos uploads falharem contra metade dos clientes.
    """
    t = content_type
    i = t.lower().find("boundary=")
    if i < 0:
        return ""
    b = t[i + 9:].strip()
    j = b.find(";")
    if j >= 0:
        b = b[0:j].strip()
    if len(b) >= 2 and b.startswith("\"") and b.endswith("\""):
        b = b[1:len(b) - 1]
    return b


def index_of(body_b: bytes, needle: bytes, from_at: int) -> int:
    """Onde `needle` comeca em `body_b` a partir de `from_at`, ou -1.

    Byte a byte e sem tabela: uma fronteira de multipart tem umas dezenas de
    bytes e aparece umas poucas vezes por pedido, portanto um Boyer-Moore aqui
    seria codigo a mais para um ganho que ninguem mede. O que importa e nao
    procurar no TEXTO -- um corpo de upload nao e UTF-8, e converte-lo para o
    procurar seria transformar um ficheiro binario em erro.
    """
    n = len(body_b)
    m = len(needle)
    if m == 0 or m > n:
        return -1
    i = from_at
    while i + m <= n:
        k = 0
        while k < m and body_b[i + k] == needle[k]:
            k += 1
        if k == m:
            return i
        i += 1
    return -1


def part_headers(raw_s: str) -> Dict<str, str>:
    out: Dict<str, str> = {}
    for line in raw_s.split("\r\n"):
        i = line.find(":")
        if i > 0:
            out[line[0:i].strip().lower()] = line[i + 1:].strip()
    return out


def value_of(disposition: str, key: str) -> str:
    """`form-data; name="a"; filename="b.txt"` -> o valor de uma das chaves."""
    i = disposition.lower().find(key.lower() + "=")
    if i < 0:
        return ""
    v = disposition[i + len(key) + 1:]
    if v.startswith("\""):
        j = v.find("\"", 1)
        return v[1:j] if j > 0 else ""
    j2 = v.find(";")
    return v[0:j2].strip() if j2 >= 0 else v.strip()


def multipart(req: Request) -> List<Part>:
    """As partes de um `multipart/form-data`. Lista vazia quando nao e um.

    O formato e da RFC 7578, e o que ele tem de traicoeiro esta em duas linhas: a
    fronteira no corpo leva DOIS hifens a frente, e a ultima leva dois atras
    tambem. Quem so procura a fronteira nua encontra-a dentro dela mesma.
    """
    boundary = boundary_of(req.header("content-type"))
    if len(boundary) == 0:
        return []
    tag = ("--" + boundary).encode()
    body_b = req.body
    parts: List<Part> = []
    at = index_of(body_b, tag, 0)
    if at < 0:
        return []
    at += len(tag)
    while True:
        # depois da fronteira vem `\r\n` (ha mais uma parte) ou `--` (acabou)
        if at + 2 > len(body_b):
            break
        if int(body_b[at]) == 45 and int(body_b[at + 1]) == 45:
            break        # `--`: era a ultima
        # salta o CRLF
        if int(body_b[at]) == 13:
            at += 2
        head_end = index_of(body_b, b"\r\n\r\n", at)
        if head_end < 0:
            break
        hdr = part_headers(str(body_b[at:head_end]))
        start_at = head_end + 4
        next_at = index_of(body_b, tag, start_at)
        if next_at < 0:
            break
        # o corpo da parte acaba DOIS bytes antes da fronteira: o `\r\n` que a
        # separa pertence a moldura e nao aos dados. Levar-lhos e o defeito que
        # faz cada ficheiro carregado chegar com dois bytes a mais.
        end_at = next_at - 2
        disposition = hdr["content-disposition"] if "content-disposition" in hdr else ""
        ctype = hdr["content-type"] if "content-type" in hdr else ""
        parts.append(Part(value_of(disposition, "name"), value_of(disposition, "filename"),
                            ctype, body_b[start_at:end_at] if end_at > start_at else b""))
        at = next_at + len(tag)
    return parts


# ---------- F8c/D40: `Expect: 100-continue` ----------

def expect_continue(req: Request) -> bool:
    """O cliente perguntou se pode mandar o corpo?

    O `curl` manda isto sozinho acima de um KiB, e e exactamente para isto que o
    cabecalho existe: um upload de um gigabyte que ia ser recusado por tamanho
    nao tem de subir primeiro. Ignora-lo custa a subida inteira de um ficheiro que
    ia ser deitado fora.
    """
    return req.header("expect").lower().find("100-continue") >= 0
