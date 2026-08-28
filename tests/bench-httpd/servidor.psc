"""O nosso servidor para o banco de ensaio: as mesmas três rotas dos outros.

Nada de especial e nada de afinado — é a `packages/httpd` como ela é, com o
`debug` desligado (que é o que um servidor em produção tem) e `workers` a vir do
argumento, para se poder medir um e N na mesma execução.
"""
import <httpd/httpd.psc> as httpd
import sys


async def handle(req: httpd.Request) -> httpd.Response:
    if req.path == "/":
        return httpd.text("ola do pscript")
    if req.path == "/json":
        return httpd.json({"quem": "pscript", "quantos": 3})
    return httpd.status_code(404)


async def trabalhador(h: def(httpd.Request) -> Task<httpd.Response>, porta: int) -> int:
    c = httpd.config()
    srv = httpd.listen(porta, c, True)
    await httpd.run(srv, h)
    return 0


quantos = int(sys.argv[2])
cfg = httpd.config()
srv0 = httpd.listen(0, cfg, quantos > 1)
f = await open(sys.argv[1], "w")
await f.write(str(srv0.port))
f.close()
for i in range(quantos - 1):
    w = spawn(trabalhador, (handle, srv0.port))
await httpd.run(srv0, handle)
