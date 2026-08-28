"""Um servidor WebSocket de eco, para o portão da F6 lhe bater à porta."""
import <httpd/httpd.psc> as httpd
import <httpd/ws.psc> as hws
import <ws/ws.psc> as ws
import sys


async def aberto(c: hws.WsConn) -> int:
    ok = await c.send_text("bem-vindo " + str(c.id))
    return 1


async def mensagem(c: hws.WsConn, ev: hws.Event) -> int:
    if ev.is_text():
        t = ev.text()
        if t == "fecha":
            ignora = await c.close(1000, "a pedido")
            return 1
        if t == "rebenta":
            raise error("rebentei de propósito")
        ok = await c.send_text("eco:" + t)
        return 1
    ok2 = await c.send_bytes(ev.data)
    return 1


async def fechado(c: hws.WsConn, code: int, reason: str) -> int:
    return 1


async def handle(req: httpd.Request) -> httpd.Response:
    if req.path == "/ws":
        return hws.upgrade(req)
    return httpd.text("sou http")


cfg = httpd.config()
cfg.debug = True
cfg.on_upgrade = hws.upgrader(hws.handlers(aberto, mensagem, fechado))
srv = httpd.listen(0, cfg)
if len(sys.argv) > 1:
    f = await open(sys.argv[1], "w")
    await f.write(str(srv.port))
    f.close()
await httpd.run(srv, handle)
