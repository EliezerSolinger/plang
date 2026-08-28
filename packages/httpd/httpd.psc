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
    a ordem importa; `Set-Cookie` é o caso de todos os dias. `req.header(nome)` dá
    o primeiro, `req.headers_all(nome)` dá todos. Um `Dict<str,str>` obrigaria a
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
import json as jsn
import net
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
    params: Dict<str, str> # o que uma rota `:nome` capturou (F1b)

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
        """`?a=1&b=dois` lido como um dicionário. É calculado a cada chamada e
        não guardado: a esmagadora maioria dos pedidos não tem query nenhuma, e
        um campo a mais na `Request` custaria a todos eles."""
        return parse_query(self.query)

    def q(self, nome: str) -> str:
        """UM valor da query, ou "". O atalho para o caso de todos os dias, sem
        construir o dicionário inteiro para ler uma chave."""
        for par in self.query.split("&"):
            if len(par) == 0:
                continue
            i = par.find("=")
            k = form_decode(par) if i < 0 else form_decode(par[0:i])
            if k == nome:
                return "" if i < 0 else form_decode(par[i + 1:])
        return ""

    def q_all(self, nome: str) -> List<str>:
        """TODOS os valores desta chave. `?t=a&t=b` é a forma normal de mandar
        uma lista, e um dicionário perde-a — a mesma razão da D3c."""
        return query_all(self.query, nome)

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
    trocado = ""
    for ch in s:
        trocado += " " if ch == "+" else ch
    return pct_decode_seg(trocado)


def parse_query(q: str) -> Dict<str, str>:
    """`a=1&b=dois&c` -> `{"a": "1", "b": "dois", "c": ""}`.

    Uma chave sem `=` vale "", que é o que toda a gente faz — e uma chave
    REPETIDA fica com a primeira. Quem precisa de todas usa `query_all`, pela
    mesma razão que os cabeçalhos têm as duas portas (D3c).
    """
    out: Dict<str, str> = {}
    for par in q.split("&"):
        if len(par) == 0:
            continue
        i = par.find("=")
        k = form_decode(par) if i < 0 else form_decode(par[0:i])
        v = "" if i < 0 else form_decode(par[i + 1:])
        if k not in out:
            out[k] = v
    return out


def query_all(q: str, nome: str) -> List<str>:
    """TODOS os valores desta chave, na ordem em que vieram. `?t=a&t=b` é a forma
    normal de mandar uma lista, e um dicionário perde-a."""
    out: List<str> = []
    for par in q.split("&"):
        if len(par) == 0:
            continue
        i = par.find("=")
        k = form_decode(par) if i < 0 else form_decode(par[0:i])
        if k == nome:
            out.append("" if i < 0 else form_decode(par[i + 1:]))
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
    r = Response(200, [], body, False)
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
        return Response(code, [], b"", False)
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
const DIAS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
const MESES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def dois(n: int) -> str:
    return "0" + str(n) if n < 10 else str(n)


def http_date(secs: int) -> str:
    d = dt.to_utc(dt.instant_of(secs, 0))
    # `weekday` devolve 0=segunda, e o RFC começa a lista em `Mon` — batem
    wd = DIAS[dt.weekday(d.date)]
    return (wd + ", " + dois(d.date.day) + " " + MESES[d.date.month - 1] + " "
            + str(d.date.year) + " " + dois(d.time.hour) + ":" + dois(d.time.minute)
            + ":" + dois(d.time.second) + " GMT")


def date_now(cfg: Config) -> str:
    agora = int(time.time())
    if agora != cfg.date_secs:
        cfg.date_secs = agora
        cfg.date_text = http_date(agora)
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
    idle_timeout: float    # quanto se espera pelo pedido seguinte, em segundos
    # D42: a data formatada e o segundo a que ela pertence — ver `date_now`
    date_secs: int
    date_text: str


def config() -> Config:
    return Config(1 << 20, 1 << 16, False, "", [], True, 30.0, -1, "")


# ---------- escrever a resposta ----------

def encode(r: Response, req_version: str, close_after: bool, cfg: Config) -> bytes:
    """A resposta inteira em bytes: linha de estado, cabeçalhos, corpo.

    O `content-length` é POSTO AQUI e não pelo handler, e é uma decisão e não uma
    conveniência: o comprimento é uma função do corpo, e deixar que alguém o
    escrevesse à mão seria deixar que discordasse dele — que é a porta do
    request smuggling. Um handler que já o tenha posto vê-o substituído.
    """
    sb: List<str> = []
    sb.append("HTTP/1.1 " + str(r.status) + " " + reason_for(r.status) + "\r\n")
    tem_tipo = False
    for hd in r.headers:
        n = hd.name.lower()
        # o comprimento e a ligação são de quem serve, não de quem responde
        if n == "content-length" or n == "connection" or n == "date":
            continue
        if n == "content-type":
            tem_tipo = True
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
        if not (r.status == 204 or (r.status >= 100 and r.status < 200)):
            sb.append("content-length: " + str(len(r.body)) + "\r\n")
        sb.append("connection: " + ("close" if close_after else "keep-alive") + "\r\n")
    sb.append("\r\n")
    cab = "".join(sb).encode()
    # HEAD e os estados sem corpo levam os cabeçalhos e mais nada
    if len(r.body) == 0:
        return cab
    return cab + r.body


def sem_corpo(status: int, method: str) -> bool:
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
                   r.headers, raw, r.body, peer, {})


def host_ok(req: Request, cfg: Config) -> bool:
    """D41: o `Host` é exigido no HTTP/1.1, e validá-lo é opção.

    Quem constrói URLs a partir do Host — o link de um reset de senha é o exemplo
    de sempre — está a deixar o cliente escolher o domínio para onde o utilizador
    vai. O Django tem `ALLOWED_HOSTS` por causa dessa história.
    """
    hst = req.header("host")
    if req.version == "1.1" and len(hst) == 0:
        return False
    if len(cfg.allowed_hosts) == 0:
        return True
    # o porto não faz parte da comparação: `exemplo.pt` e `exemplo.pt:8080` são
    # o mesmo nome
    nome = hst
    i = nome.rfind(":")
    if i > 0 and nome.find("]") < i:
        nome = nome[0:i]
    for a in cfg.allowed_hosts:
        if a == nome:
            return True
    return False


async def escreve(c: Socket, b: bytes) -> bool:
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
    servidos = 0
    p = h.new_parser()
    with Buffer(65536) as rb:
        while True:
            # ---- lê o que houver ----
            n = 0
            try:
                n = await c.read_into(rb, 0, 65536)
            catch e:
                break
            if n == 0:
                # o cliente fechou. Um corpo sem comprimento declarado acaba
                # exactamente aqui, e é `finish` quem o diz ao parser.
                p.finish()
                break
            if not p.feed(bytes(rb[0:n])):
                if p.failed():
                    # 400, e fecha. O que sobra no cano pertence a uma mensagem
                    # que não se sabe onde acaba, e continuar a ler dela é
                    # exactamente o que o request smuggling explora.
                    await escreve(c, encode(status_code(400), "1.1", True, cfg))
                    break
                if p.handoff():
                    # a conexão deixou de ser HTTP/1 sem passar pelo handler:
                    # um CONNECT ou o preâmbulo do HTTP/2. Nada aqui sabe o que
                    # fazer com ela (F6/F11), e fingir que sabe seria pior.
                    await escreve(c, encode(status_code(501), "1.1", True, cfg))
                    break
                # a mensagem ainda não chegou inteira: lê mais
                continue

            # ---- há um pedido inteiro ----
            req = to_request(p.request(), peer)
            manter = cfg.keep_alive and p.keep_alive()
            resp = await responde(req, handle, cfg)
            if sem_corpo(resp.status, req.method):
                resp.body = b""
            if resp.status == 413 or resp.status == 400 or resp.status == 431:
                # depois de recusar por forma, o que sobra no cano é de uma
                # mensagem que não se sabe onde acaba — a única saída sã é fechar
                manter = False
            if not await escreve(c, encode(resp, req.version, not manter, cfg)):
                break
            servidos += 1
            if resp.upgraded:
                # a conexão deixou de ser HTTP/1: quem trata do que vem a seguir
                # é outra camada (F6), e este laço acabou
                return servidos
            if not manter:
                break
            p.reset()
    c.close()
    return servidos


async def responde(req: Request, handle: def(Request) -> Task<Response>,
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
        aprint("httpd: " + req.method + " " + req.target + ": " + e.message)
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
            conta(srv, c, handle)
        catch e:
            if not srv.running:
                break
            # um `accept` que falha não é o fim do servidor: o descritor
            # esgotou-se, o cliente desistiu entre o SYN e o accept. Cede a vez e
            # tenta outra vez, em vez de girar a queimar o núcleo.
            await sleep(0.01)


def conta(srv: Server, c: Socket, handle: def(Request) -> Task<Response>):
    """Arranca a tarefa da conexão e deita fora o valor. Existe como função para
    dizer isso por escrito: o resultado é deliberadamente ignorado, e uma linha
    que ignora um valor sem o dizer lê-se como um esquecimento."""
    t = serve_conn(c, "", handle, srv.cfg)


async def serve(port: int, handle: def(Request) -> Task<Response>,
                cfg: Config? = None) -> Server:
    """O atalho: abre, corre, e só volta quando alguém parar o servidor."""
    c2: Config = config()
    if cfg != None:
        c2 = cfg
    srv = listen(port, c2)
    await run(srv, handle)
    return srv
