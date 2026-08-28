"""Um servidor com ROTAS, para o portão bater nos casos da F1b/F1c."""
import <httpd/httpd.psc> as httpd
import <httpd/router.psc> as rt
import sys


async def root(req: httpd.Request) -> httpd.Response:
    return httpd.text("raiz")

async def list_h(req: httpd.Request) -> httpd.Response:
    return httpd.text("lista de jogadores")

async def one(req: httpd.Request) -> httpd.Response:
    return httpd.text("jogador " + req.param("id"))

async def inventory(req: httpd.Request) -> httpd.Response:
    return httpd.text("inventario de " + req.param("id"))

async def literal(req: httpd.Request) -> httpd.Response:
    # ESPECIFICIDADE: este casa `/jogadores/eu`, e ganha ao `:id` sem depender de
    # ter sido registado antes ou depois — a linha abaixo prova-o registando-o
    # DEPOIS do `:id`
    return httpd.text("sou eu")

async def create(req: httpd.Request) -> httpd.Response:
    return httpd.text("criado")

async def file_name(req: httpd.Request) -> httpd.Response:
    return httpd.text("resto=" + req.param("*"))

async def echo_query(req: httpd.Request) -> httpd.Response:
    return httpd.text(req.q("nome") + "|" + req.q("vazio") + "|" + str(len(req.q("nao_existe"))))

async def query_list(req: httpd.Request) -> httpd.Response:
    return httpd.text(",".join(req.q_all("t")))

async def json_body(req: httpd.Request) -> httpd.Response:
    v = req.json()
    return httpd.json({"recebi": v, "era_json": req.is_json()})


r = rt.router()
r.get("/", root)
r.get("/jogadores", list_h)
r.get("/jogadores/:id", one)
r.get("/jogadores/:id/inventario", inventory)
r.get("/jogadores/eu", literal)          # registado DEPOIS do `:id`, e ganha
r.post("/jogadores", create)
r.get("/ficheiros/*", file_name)
r.get("/query", echo_query)
r.get("/lista", query_list)
r.post("/json", json_body)

cfg = httpd.config()
cfg.debug = True
srv = httpd.listen(0, cfg)
if len(sys.argv) > 1:
    f = await open(sys.argv[1], "w")
    await f.write(str(srv.port))
    f.close()


async def dispatch_fn(req: httpd.Request) -> httpd.Response:
    return await rt.dispatch(r, req)

await httpd.run(srv, dispatch_fn)
