"""Um servidor WebSocket para os portões das quatro peças que faltavam:
subprotocolo escolhido, envio fragmentado, keepalive e parâmetros do deflate.

Tudo o que muda de conexão para conexão vem da linha de comando, para o portão
poder pedir uma janela de ping de meio segundo sem que o servidor de eco normal
mude de comportamento:

    wsfeatures <ficheiro-do-porto> [fragment_size] [ping_interval] [ping_timeout]

As rotas:

  * `/ws`     — eco, com os subprotocolos `v2` e `v1` oferecidos POR ESTA ORDEM,
                que é a ordem de preferência do servidor;
  * `/proto`  — a primeira mensagem diz qual subprotocolo ficou escolhido;
  * `/big`    — manda uma mensagem grande logo ao abrir, para se ver sair em
                fragmentos;
  * `/quiet`  — não manda nada e não responde a nada: serve para o portão do
                keepalive ver o servidor desistir de um cliente calado;
  * `/huge`   — 400 KB logo ao abrir, para encher o tampão de envio do kernel.
                É a única maneira de forçar uma escrita PARCIAL, e é aí que se vê
                se o trinco por conexão impede um ping de outra tarefa de entrar
                no meio de um fragmento.
"""
import <httpd/httpd.psc> as httpd
import <httpd/ws.psc> as hws
import <ws/ws.psc> as ws
import sys


const PROTOCOLS = ["v2", "v1"]


async def opened(c: hws.WsConn) -> int:
    if c.req.path == "/proto":
        ok = await c.send_text("proto=" + c.protocol)
        return 1
    if c.req.path == "/huge":
        # grande o suficiente para NAO caber no tampao de envio do kernel: e a
        # condicao de que o portao da intercalacao precisa, porque so uma escrita
        # PARCIAL estaciona a tarefa a meio de um quadro
        ok3 = await c.send_text("0123456789" * 40000)
        return 1
    if c.req.path == "/big":
        # 300 bytes de um padrão que se reconhece do outro lado: com
        # `fragment_size=64` isto tem de sair em cinco quadros, e o conteúdo
        # montado tem de ser byte a byte igual a isto
        s = ""
        for i in range(30):
            s += "0123456789"
        ok2 = await c.send_text(s)
        return 1
    return 1


async def message_h(c: hws.WsConn, ev: hws.Event) -> int:
    if c.req.path == "/quiet":
        return 1
    if ev.is_text():
        ok = await c.send_text("eco:" + ev.text())
        return 1
    ok2 = await c.send_bytes(ev.data)
    return 1


async def closed_h(c: hws.WsConn, code: int, reason: str) -> int:
    return 1


async def handle(req: httpd.Request) -> httpd.Response:
    if (req.path == "/ws" or req.path == "/proto" or req.path == "/big"
            or req.path == "/quiet" or req.path == "/huge"):
        return hws.upgrade(req, PROTOCOLS)
    return httpd.text("sou http")


frag = int(sys.argv[2]) if len(sys.argv) > 2 else 0
interval = float(sys.argv[3]) if len(sys.argv) > 3 else 20.0
deadline = float(sys.argv[4]) if len(sys.argv) > 4 else 10.0

cfg = httpd.config()
cfg.debug = True
hs = hws.handlers(opened, message_h, closed_h, frag, interval, deadline)
cfg.on_upgrade = hws.upgrader(hs)
srv = httpd.listen(0, cfg)
if len(sys.argv) > 1:
    f = await open(sys.argv[1], "w")
    await f.write(str(srv.port))
    f.close()
await httpd.run(srv, handle)
