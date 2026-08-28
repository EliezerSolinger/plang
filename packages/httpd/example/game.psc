"""Um servidor de jogo em cinquenta linhas, que é o que motivou tudo isto.

Não é um brinquedo com as arestas escondidas: é a `packages/httpd` como ela é, e
todas as decisões do desenho estão à vista.

    bash tests/psbuild.sh packages/httpd/example/game.psc /tmp/jogo
    /tmp/jogo 3335 4                 # porto, e quantos workers

O que ele faz:

  * serve os ficheiros do cliente de `./publico` (F8) — com ETag, `Range` e a
    travessia fechada;
  * `/api/state` responde JSON (F1c);
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
struct State:
    connections: int
    ticks: int


state: State? = None
tree: fl.Files? = None
routes_r: rt.Router? = None


def mine() -> State:
    global state
    e = state
    if e != None:
        return e
    fresh = State(0, 0)
    state = fresh
    return fresh


# ---------- o HTTP ----------

async def api_state(req: httpd.Request) -> httpd.Response:
    return httpd.json({"ligacoes": mine().connections, "tiques": mine().ticks})


async def enter_ws(req: httpd.Request) -> httpd.Response:
    # A DECISÃO DE ACEITAR É CÓDIGO NORMAL, ANTES do upgrade (D9b): o token do
    # jogador, a rota, a origem. Não é um privilégio do servidor.
    if len(req.q("jogador")) == 0:
        return httpd.status_code(401)
    return hws.upgrade(req)


async def static_files(req: httpd.Request) -> httpd.Response:
    a = tree
    if a == None:
        return httpd.status_code(404)
    return await fl.serve(a, req)


# ---------- o WebSocket ----------

async def joined(c: hws.WsConn) -> int:
    mine().connections += 1
    # assinar o tópico inscreve TAMBÉM este worker no runtime, uma vez só
    c.subscribe("mundo")
    ok = await c.send_text("{\"tipo\":\"ola\",\"id\":" + str(c.id) + "}")
    return 1


async def message_h(c: hws.WsConn, ev: hws.Event) -> int:
    mine().ticks += 1
    # O CAMINHO QUENTE (D6): os mesmos bytes para todo o tópico. Dentro do worker
    # o quadro é montado UMA vez e escrito N, sem serializar nada; para os outros
    # workers atravessa como bytes, uma vez por WORKER e não por conexão.
    n = await c.hub.broadcast("mundo", ev.data, not ev.is_text())
    return n


async def left(c: hws.WsConn, code: int, reason: str) -> int:
    mine().connections -= 1
    # não é preciso dessubscrever: fechar dessubscreve de tudo (D9c)
    return 1


# ---------- e o que atravessa as publicações dos OUTROS workers ----------

async def listen_others(hs: hws.Handlers) -> int:
    """`await topic.recv()` dorme no cano do contexto — o mesmo `poll` que já
    espera pelos sockets. Não custa nada enquanto não há nada."""
    return await hws.pump_hub(hs.hub)


async def worker_fn(port_n: int, root: str) -> int:
    c = httpd.config()
    c.server_name = ""            # não anunciar software a quem procura alvos
    build(root, c)
    srv = httpd.listen(port_n, c, True)
    t = listen_others(worker_handlers())
    await httpd.run(srv, dispatch_fn)
    return 0


hs_worker: hws.Handlers? = None


def worker_handlers() -> hws.Handlers:
    global hs_worker
    h = hs_worker
    if h != None:
        return h
    fresh = hws.handlers(joined, message_h, left)
    hs_worker = fresh
    return fresh


def build(root: str, cfg: httpd.Config):
    global tree
    global routes_r
    tree = fl.files(root, "index.html", "max-age=60")
    m = rt.router()
    m.get("/api/estado", api_state)
    m.get("/ws", enter_ws)
    m.get("/*", static_files)
    routes_r = m
    cfg.on_upgrade = hws.upgrader(worker_handlers())


async def dispatch_fn(req: httpd.Request) -> httpd.Response:
    m = routes_r
    if m == None:
        return httpd.status_code(503)
    return await rt.dispatch(m, req)


port_n = int(sys.argv[1]) if len(sys.argv) > 1 else 3335
how_many = int(sys.argv[2]) if len(sys.argv) > 2 else os.nproc()
root = sys.argv[3] if len(sys.argv) > 3 else "publico"

cfg = httpd.config()
cfg.server_name = ""
build(root, cfg)
srv0 = httpd.listen(port_n, cfg, how_many > 1)
print("a servir em http://127.0.0.1:" + str(srv0.port) + " com " + str(how_many) + " workers")
for i in range(how_many - 1):
    w = spawn(worker_fn, (srv0.port, root))
t0 = listen_others(worker_handlers())
await httpd.run(srv0, dispatch_fn)
