"""O httpd a servir `https` (F4/D8): a mesma `Config`, mais dois caminhos."""
import <httpd/httpd.psc> as httpd
import sys


async def handle(req: httpd.Request) -> httpd.Response:
    if req.path == "/":
        return httpd.text("ola por https")
    if req.path == "/json":
        return httpd.json({"seguro": True})
    return httpd.status_code(404)


cfg = httpd.config()
cfg.debug = True
cfg.tls_cert = sys.argv[2]
cfg.tls_key = sys.argv[3]
srv = httpd.listen(0, cfg)
f = await open(sys.argv[1], "w")
await f.write(str(srv.port))
f.close()
await httpd.run(srv, handle)
