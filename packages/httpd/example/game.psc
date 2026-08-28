"""Um servidor de jogo em cinquenta linhas, que é o que motivou tudo isto.

Não é um brinquedo com as arestas escondidas: é a `packages/httpd` como ela é, e
todas as decisões do desenho estão à vista.

    bash tests/psbuild.sh packages/httpd/exemplo/jogo.psc /tmp/jogo
    /tmp/jogo 3335 4                 # porto, e quantos workers

O que ele faz:

  * serve os ficheiros do cliente de `./publico` (F8) — com ETag, `Range` e a
    travessia fechada;
  * `/api/estado` responde JSON (F1c);
  * `/ws` é o WebSocket (F6): quem entra assina o tópico `mundo`, e cada mensagem
    é difundida a **todos os workers** (F7/L4);
  * e o servidor usa a máquina inteira (F3/D12): N workers no mesmo porto, cada um
    com heap, coletor e escalonador próprios. Uma pausa do coletor pára UM worker.
"""
import <httpd/httpd.psc> as httpd
import <httpd/ws.psc> as hws
import <httpd/files.psc> as fl
import <httpd/router.psc> as rt
import os
import sys
import topic


# o estado do worker: construído à primeira pergunta, porque um worker não corre
# o topo do programa (42.2) e um inicializador de global não corre lá
struct Estado:
    ligacoes: int
    tiques: int


estado: Estado? = None
arvore: fl.Files? = None
mapa: rt.Router? = None


def meu() -> Estado:
    global estado
    e = estado
    if e != None:
        return e
    novo = Estado(0, 0)
    estado = novo
    return novo


# ---------- o HTTP ----------

async def api_estado(req: httpd.Request) -> httpd.Response:
    return httpd.json({"ligacoes": meu().ligacoes, "tiques": meu().tiques})


async def entrar_no_ws(req: httpd.Request) -> httpd.Response:
    # A DECISÃO DE ACEITAR É CÓDIGO NORMAL, ANTES do upgrade (D9b): o token do
    # jogador, a rota, a origem. Não é um privilégio do servidor.
    if len(req.q("jogador")) == 0:
        return httpd.status_code(401)
    return hws.upgrade(req)


async def estaticos(req: httpd.Request) -> httpd.Response:
    a = arvore
    if a == None:
        return httpd.status_code(404)
    return await fl.serve(a, req)


# ---------- o WebSocket ----------

async def entrou(c: hws.WsConn) -> int:
    meu().ligacoes += 1
    # assinar o tópico inscreve TAMBÉM este worker no runtime, uma vez só
    c.subscribe("mundo")
    ok = await c.send_text("{\"tipo\":\"ola\",\"id\":" + str(c.id) + "}")
    return 1


async def mensagem(c: hws.WsConn, ev: hws.Event) -> int:
    meu().tiques += 1
    # O CAMINHO QUENTE (D6): os mesmos bytes para todo o tópico. Dentro do worker
    # o quadro é montado UMA vez e escrito N, sem serializar nada; para os outros
    # workers atravessa como bytes, uma vez por WORKER e não por conexão.
    n = await c.hub.broadcast("mundo", ev.data, not ev.is_text())
    return n


async def saiu(c: hws.WsConn, code: int, reason: str) -> int:
    meu().ligacoes -= 1
    # não é preciso dessubscrever: fechar dessubscreve de tudo (D9c)
    return 1


# ---------- e o que atravessa as publicações dos OUTROS workers ----------

async def escuta_os_outros(hs: hws.Handlers) -> int:
    """`await topic.recv()` dorme no cano do contexto — o mesmo `poll` que já
    espera pelos sockets. Não custa nada enquanto não há nada."""
    return await hws.pump_hub(hs.hub)


async def trabalhador(porta: int, raiz: str) -> int:
    c = httpd.config()
    c.server_name = ""            # não anunciar software a quem procura alvos
    monta(raiz, c)
    srv = httpd.listen(porta, c, True)
    t = escuta_os_outros(handlers_do_worker())
    await httpd.run(srv, despacha)
    return 0


hs_worker: hws.Handlers? = None


def handlers_do_worker() -> hws.Handlers:
    global hs_worker
    h = hs_worker
    if h != None:
        return h
    novo = hws.handlers(entrou, mensagem, saiu)
    hs_worker = novo
    return novo


def monta(raiz: str, cfg: httpd.Config):
    global arvore
    global mapa
    arvore = fl.files(raiz, "index.html", "max-age=60")
    m = rt.router()
    m.get("/api/estado", api_estado)
    m.get("/ws", entrar_no_ws)
    m.get("/*", estaticos)
    mapa = m
    cfg.on_upgrade = hws.upgrader(handlers_do_worker())


async def despacha(req: httpd.Request) -> httpd.Response:
    m = mapa
    if m == None:
        return httpd.status_code(503)
    return await rt.dispatch(m, req)


porta = int(sys.argv[1]) if len(sys.argv) > 1 else 3335
quantos = int(sys.argv[2]) if len(sys.argv) > 2 else os.nproc()
raiz = sys.argv[3] if len(sys.argv) > 3 else "publico"

cfg = httpd.config()
cfg.server_name = ""
monta(raiz, cfg)
srv0 = httpd.listen(porta, cfg, quantos > 1)
print("a servir em http://127.0.0.1:" + str(srv0.port) + " com " + str(quantos) + " workers")
for i in range(quantos - 1):
    w = spawn(trabalhador, (srv0.port, raiz))
t0 = escuta_os_outros(handlers_do_worker())
await httpd.run(srv0, despacha)
