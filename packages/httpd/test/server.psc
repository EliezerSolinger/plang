"""Um servidor de verdade, para o portão ponta a ponta bater-lhe à porta.

Pede o porto 0 — o sistema escolhe um livre — e ESCREVE-O NUM FICHEIRO cujo
caminho vem no `argv`. O arreio espera que o ficheiro apareça e lê-o de lá.

Podia parecer mais simples imprimi-lo; não é. O `stdout` de quem escreve para um
cano é tamponado por blocos, portanto a linha ficaria retida até o tampão encher
— e quem lê ficaria à espera de um servidor que já está de pé. O ficheiro só
aparece depois de fechado, o que faz dele um sinal e não uma adivinha.
"""
import <httpd/httpd.psc> as httpd
import os
import sys


# F2/D5: um cursor. Cada chamada dá o pedaço seguinte, e `b""` diz que acabou —
# a mesma forma do cursor do MySQL.
contador: List<int> = [0]

async def pedacos() -> bytes:
    contador[0] += 1
    if contador[0] > 5:
        contador[0] = 0
        return b""
    await sleep(0.01)
    return ("pedaco-" + str(contador[0]) + "\n").encode()


ticks: List<int> = [0]

async def eventos() -> bytes:
    ticks[0] += 1
    if ticks[0] > 3:
        ticks[0] = 0
        return b""
    await sleep(0.01)
    return httpd.evento("tick", "n=" + str(ticks[0]) + "\nlinha2")


async def handle(req: httpd.Request) -> httpd.Response:
    if req.path == "/upload":
        # F8c: as partes de um formulario, com os ficheiros
        ps = httpd.multipart(req)
        linhas: List<str> = []
        for pt in ps:
            if len(pt.ficheiro) > 0:
                linhas.append("ficheiro:" + pt.nome + ":" + pt.ficheiro + ":"
                              + pt.tipo + ":" + str(len(pt.dados)))
            else:
                linhas.append("campo:" + pt.nome + ":" + pt.texto())
        return httpd.text("\n".join(linhas))
    if req.path == "/grande":
        # F9: texto compressivel e acima do minimo
        return httpd.comprime(httpd.text("linha repetida\n" * 400), req)
    if req.path == "/pequeno":
        # abaixo do minimo: NAO se comprime, porque a moldura nao se paga
        return httpd.comprime(httpd.text("curto"), req)
    if req.path == "/jpeg":
        # ja comprimido: comprimir gasta CPU e cresce
        return httpd.comprime(httpd.blob(b"\xff\xd8\xff" + ("A" * 4000).encode(), "image/jpeg"), req)
    if req.path == "/fluxo":
        return httpd.stream_of(pedacos, "text/plain; charset=utf-8")
    if req.path == "/sse":
        return httpd.sse(eventos)
    if req.path == "/":
        return httpd.text("ola do pscript")
    if req.path == "/eco":
        # o corpo de volta, tal e qual, para se ver que ele chegou inteiro
        return httpd.blob(req.body, "application/octet-stream")
    if req.path == "/cabecalhos":
        # D3c: os repetidos continuam separados, que é o que um `Dict` perderia
        todos = req.headers_all("x-nota")
        return httpd.text("|".join(todos))
    if req.path == "/json":
        return httpd.json({"quem": "pscript", "quantos": 3})
    if req.path == "/html":
        return httpd.html("<h1>ola</h1>")
    if req.path == "/vazio":
        return httpd.status_code(204)
    if req.path == "/parati":
        return httpd.redirect("/", 302)
    if req.path == "/rebenta":
        # D3e: isto vira 500, e o servidor continua a servir
        raise error("rebentei de propósito")
    if req.path == "/metodo":
        return httpd.text(req.method)
    if req.path == "/query":
        return httpd.text(req.query)
    return httpd.status_code(404)


cfg = httpd.config()
cfg.debug = True
cfg.server_name = "pscript-httpd"
srv = httpd.listen(0, cfg)
if len(sys.argv) > 1:
    f = await open(sys.argv[1], "w")
    await f.write(str(srv.port))
    f.close()
await httpd.run(srv, handle)
