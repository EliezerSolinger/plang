"""Sessão, cookies e rate limit, com DOIS workers — para se ver que a tabela é
mesmo partilhada."""
import <httpd/httpd.psc> as httpd
import <httpd/session.psc> as ss
import sys


const SECRET = "uma-chave-de-teste-que-nao-e-um-segredo"


async def handle(req: httpd.Request) -> httpd.Response:
    ip = req.ip(["127.0.0.1"])

    if req.path == "/entra":
        # o rate limit vem PRIMEIRO: travar antes de trabalhar é o ponto dele
        if not ss.allow(ip, 5, 60):
            return httpd.status_code(429)
        tok = await ss.create(SECRET, "utilizador=" + req.q("quem"), 3600)
        r = httpd.text("entrou")
        return httpd.set_cookie(r, "sid", tok, 3600, "/", "", True, False, "Lax")

    if req.path == "/quem":
        v = ss.read(SECRET, req.cookie("sid"))
        if len(v) == 0:
            return httpd.status_code(401)
        return httpd.text(v)

    if req.path == "/sai":
        ok = ss.revoke(SECRET, req.cookie("sid"))
        r2 = httpd.text("revogou=" + str(ok))
        return httpd.clear_cookie(r2, "sid")

    if req.path == "/quantas":
        return httpd.text(str(ss.count()))

    if req.path == "/ip":
        # COM 127.0.0.1 na lista: o cabeçalho é lido, porque a ligação vem de um
        # proxy declarado
        return httpd.text(ip)

    if req.path == "/ip-estrito":
        # SEM lista nenhuma: o `X-Forwarded-For` é ignorado, e é isto que impede
        # um cliente de forjar o próprio IP. Sem esta regra o rate-limit e o ban
        # por IP viram enfeite.
        return httpd.text(req.ip([]))

    if req.path == "/limitado":
        if not ss.allow(ip + "|limitado", 3, 60):
            return httpd.status_code(429)
        return httpd.text("ok")

    if req.path == "/cookies":
        cs = req.cookies()
        keys_l: List<str> = []
        for k in cs:
            keys_l.append(k + "=" + cs[k])
        keys_l.sort()
        return httpd.text("|".join(keys_l))

    return httpd.status_code(404)


async def worker_fn(h: def(httpd.Request) -> Task<httpd.Response>, port_n: int) -> int:
    c = httpd.config()
    c.debug = True
    srv = httpd.listen(port_n, c, True)
    await httpd.run(srv, h)
    return 0


cfg = httpd.config()
cfg.debug = True
srv0 = httpd.listen(0, cfg, True)
f = await open(sys.argv[1], "w")
await f.write(str(srv0.port))
f.close()
w = spawn(worker_fn, (handle, srv0.port))
await httpd.run(srv0, handle)
