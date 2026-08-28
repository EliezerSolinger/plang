"""O encaminhador (D19/D34).

Uma rota é um PADRÃO sobre os segmentos do caminho, e só sabe três coisas:

    /jogadores            um segmento literal
    /jogadores/:id        um segmento que CAPTURA, e fica em `req.param("id")`
    /ficheiros/*          um resto, que captura tudo o que sobra em `param("*")`

Não há expressões regulares e não vai haver. Um padrão de rota com uma regex
dentro é uma linguagem a mais para quem lê o programa aprender, e é onde nascem
os buracos de autorização — `/admin/(.*)` que também casa `/adminX`. Segmentos
literais, uma captura por segmento, e um resto no fim: o que falta a isso é
trabalho do handler, que tem a linguagem inteira à mão.

**A ordem em que as rotas são registadas NÃO decide.** Decide a especificidade: um
segmento literal ganha a uma captura, e uma captura ganha ao resto. Com a ordem a
decidir, mudar a posição de duas linhas mudaria o que o servidor faz — e a
consequência é sempre a mesma: alguém acrescenta uma rota no fim do ficheiro e
uma outra deixa silenciosamente de ser alcançável.

D34: o `HEAD` e o `OPTIONS` saem de graça. Um `HEAD` procura o handler do `GET`,
e a `httpd` corta o corpo na saída — o handler nem sabe a diferença. Um caminho
que existe com OUTRO método é **405 com `Allow`**, e não 404: a distinção importa,
porque um 404 diz "não há nada aqui" e o que se passa é "há, mas não assim".
"""
import <httpd/httpd.psc> as httpd


struct Route:
    method: str
    # os segmentos do padrão, já partidos. Um que comece por `:` captura; um `*`
    # sozinho no fim leva o resto.
    segs: List<str>
    handler: def(httpd.Request) -> Task<httpd.Response>


def split_path(p: str) -> List<str>:
    """`/a/b/` -> `["a", "b"]`. O vazio do princípio e o do fim caem, portanto
    `/a` e `/a/` são o MESMO caminho — que é o que quem escreve o URL espera, e
    tratá-los como dois é a origem de metade das duplicações de conteúdo."""
    out: List<str> = []
    for s in p.split("/"):
        if len(s) > 0:
            out.append(s)
    return out


def score(segs: List<str>) -> int:
    """Quão ESPECÍFICO é este padrão. É isto que decide, e não a ordem.

    Um literal vale 4, uma captura 2 e o resto 1, somados por posição das
    primeiras para as últimas. Assim `/a/b` ganha a `/a/:x`, que ganha a
    `/:x/:y`, que ganha a `/*`; e duas formas diferentes divergem nalgum
    segmento, portanto não empatam.
    """
    v = 0
    for s in segs:
        v = v * 8
        if s == "*":
            v += 1
        elif s.startswith(":"):
            v += 2
        else:
            v += 4
    # e um padrão mais LONGO é mais específico que um curto com o mesmo princípio
    return v * 64 + len(segs)


def matches(r: Route, parts: List<str>, params: Dict<str, str>) -> bool:
    """Este padrão serve este caminho? Enche `params` quando sim."""
    i = 0
    while i < len(r.segs):
        s = r.segs[i]
        if s == "*":
            # o resto, junto outra vez com barras — vazio quando não sobra nada
            rest = ""
            j = i
            while j < len(parts):
                if len(rest) > 0:
                    rest += "/"
                rest += parts[j]
                j += 1
            params["*"] = rest
            return True
        if i >= len(parts):
            return False
        if s.startswith(":"):
            params[s[1:]] = httpd.pct_decode_seg(parts[i])
        elif s != httpd.pct_decode_seg(parts[i]):
            return False
        i += 1
    return i == len(parts)


async def not_found_response(req: httpd.Request) -> httpd.Response:
    return httpd.status_code(404)


struct Router:
    routes: List<Route>
    # o que responder quando nenhuma rota casa. Fica aqui e não no `serve` porque
    # é uma decisão do MAPA de rotas: um servidor de API responde JSON, um de
    # ficheiros responde a página de erro.
    not_found: def(httpd.Request) -> Task<httpd.Response>

    def add(self, method: str, pattern: str, fn: def(httpd.Request) -> Task<httpd.Response>):
        self.routes.append(Route(method.upper(), split_path(pattern), fn))

    def get(self, pattern: str, fn: def(httpd.Request) -> Task<httpd.Response>):
        self.add("GET", pattern, fn)

    def post(self, pattern: str, fn: def(httpd.Request) -> Task<httpd.Response>):
        self.add("POST", pattern, fn)

    def put(self, pattern: str, fn: def(httpd.Request) -> Task<httpd.Response>):
        self.add("PUT", pattern, fn)

    def delete(self, pattern: str, fn: def(httpd.Request) -> Task<httpd.Response>):
        self.add("DELETE", pattern, fn)

    def patch(self, pattern: str, fn: def(httpd.Request) -> Task<httpd.Response>):
        self.add("PATCH", pattern, fn)

    def allowed(self, parts: List<str>) -> List<str>:
        """Que métodos existem para ESTE caminho. É o `Allow` de um 405 e o de um
        OPTIONS — a mesma pergunta nos dois sítios, portanto uma função só."""
        out: List<str> = []
        for r in self.routes:
            p: Dict<str, str> = {}
            if matches(r, parts, p) and r.method not in out:
                out.append(r.method)
        # D34: quem serve um GET serve um HEAD, e não é opção — a `httpd` corta o
        # corpo na saída, portanto o handler nem sabe a diferença
        if "GET" in out and "HEAD" not in out:
            out.append("HEAD")
        if len(out) > 0 and "OPTIONS" not in out:
            out.append("OPTIONS")
        return out


def router() -> Router:
    return Router([], not_found_response)


# O DESPACHO É UMA FUNÇÃO LIVRE, e não um método, por uma razão da linguagem: um
# método LIGADO não é um valor. `routes_map.handle` não se escreve — o campo não existe
# —, e o `run` do servidor quer justamente um `def(Request) -> Task<...>` para
# chamar a cada pedido. Portanto o programa escreve o adaptador de duas linhas:
#
#     async def despacha(req: httpd.Request) -> httpd.Response:
#         return await rt.dispatch(mapa, req)
#     await httpd.run(srv, despacha)
#
# Fica registado nos ACHADOS que um método ligado como valor é uma coisa que a
# linguagem ainda não tem.
async def dispatch(routes_map: Router, req: httpd.Request) -> httpd.Response:
    parts = split_path(req.path)
    # o método com que se PROCURA: um HEAD procura o GET, porque é o mesmo
    # handler e a diferença é só o corpo (D34)
    wanted = "GET" if req.method == "HEAD" else req.method
    best: Route? = None
    best_score = -1
    best_params: Dict<str, str> = {}
    for r in routes_map.routes:
        if r.method != wanted:
            continue
        p: Dict<str, str> = {}
        if not matches(r, parts, p):
            continue
        score_n = score(r.segs)
        if score_n > best_score:
            best_score = score_n
            best = r
            best_params = p
    if best != None:
        req.params = best_params
        return await best.handler(req)

    # nenhuma rota com este método. Existe com OUTRO?
    allowed_s = routes_map.allowed(parts)
    if len(allowed_s) > 0:
        if req.method == "OPTIONS":
            r2 = httpd.status_code(204)
            r2.headers.append(httpd.Header("allow", ", ".join(allowed_s)))
            return r2
        # 405 e NÃO 404, e o `Allow` é obrigatório (RFC 9110 §15.5.6) e não é
        # cortesia: sem ele o cliente sabe que errou e não sabe em quê.
        r3 = httpd.status_code(405)
        r3.headers.append(httpd.Header("allow", ", ".join(allowed_s)))
        return r3
    return await routes_map.not_found(req)
