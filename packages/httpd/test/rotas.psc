"""Um servidor com ROTAS, para o portão bater nos casos da F1b/F1c."""
import <httpd/httpd.psc> as httpd
import <httpd/router.psc> as rt
import sys


async def raiz(req: httpd.Request) -> httpd.Response:
    return httpd.text("raiz")

async def lista(req: httpd.Request) -> httpd.Response:
    return httpd.text("lista de jogadores")

async def um(req: httpd.Request) -> httpd.Response:
    return httpd.text("jogador " + req.param("id"))

async def inventario(req: httpd.Request) -> httpd.Response:
    return httpd.text("inventario de " + req.param("id"))

async def literal(req: httpd.Request) -> httpd.Response:
    # ESPECIFICIDADE: este casa `/jogadores/eu`, e ganha ao `:id` sem depender de
    # ter sido registado antes ou depois — a linha abaixo prova-o registando-o
    # DEPOIS do `:id`
    return httpd.text("sou eu")

async def cria(req: httpd.Request) -> httpd.Response:
    return httpd.text("criado")

async def ficheiro(req: httpd.Request) -> httpd.Response:
    return httpd.text("resto=" + req.param("*"))

async def eco_query(req: httpd.Request) -> httpd.Response:
    return httpd.text(req.q("nome") + "|" + req.q("vazio") + "|" + str(len(req.q("nao_existe"))))

async def query_lista(req: httpd.Request) -> httpd.Response:
    return httpd.text(",".join(req.q_all("t")))

async def corpo_json(req: httpd.Request) -> httpd.Response:
    v = req.json()
    return httpd.json({"recebi": v, "era_json": req.is_json()})


r = rt.router()
r.get("/", raiz)
r.get("/jogadores", lista)
r.get("/jogadores/:id", um)
r.get("/jogadores/:id/inventario", inventario)
r.get("/jogadores/eu", literal)          # registado DEPOIS do `:id`, e ganha
r.post("/jogadores", cria)
r.get("/ficheiros/*", ficheiro)
r.get("/query", eco_query)
r.get("/lista", query_lista)
r.post("/json", corpo_json)

cfg = httpd.config()
cfg.debug = True
srv = httpd.listen(0, cfg)
if len(sys.argv) > 1:
    f = await open(sys.argv[1], "w")
    await f.write(str(srv.port))
    f.close()


async def despacha(req: httpd.Request) -> httpd.Response:
    return await rt.dispatch(r, req)

await httpd.run(srv, despacha)
