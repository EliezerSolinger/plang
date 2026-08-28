"""Um servidor de ficheiros, para o portão da F8 lhe bater à porta — e para lhe
tentar sair do directório por todas as grafias que um atacante tenta."""
import <httpd/httpd.psc> as httpd
import <httpd/files.psc> as fl
import os
import path
import sys


raiz = sys.argv[2]
arv = fl.files(raiz, "index.html", "max-age=60")


async def handle(req: httpd.Request) -> httpd.Response:
    return await fl.serve(arv, req)


cfg = httpd.config()
cfg.debug = True
srv = httpd.listen(0, cfg)
f = await open(sys.argv[1], "w")
await f.write(str(srv.port))
f.close()
await httpd.run(srv, handle)
