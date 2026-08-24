"""An HTTP server and its clients, in one process (77.2/78.1).

The parser lives in `packages/http`, written in pscript from the specification —
no `.c` of anyone else's went into the runtime. This program puts both sides
talking over a real socket, on one thread, which is only possible because every
wait PARKS: if `accept` blocked, the client would never get to connect.

What it exercises on purpose:

  * INCREMENTAL reading: the server reads 64 bytes at a time and feeds the
    parser until it says the request is whole — which is how a real server
    works, because `read(n)` gives back whatever is there (79.2);
  * a body with `content-length`, and a body in CHUNKS;
  * the refusals llhttp also makes: a space before the colon, and
    `content-length` together with `chunked`.
"""

import net
import <http/http.psc> as http


async def serve(srv: Socket, how_many: int) -> int:
    served = 0
    for i in range(how_many):
        with await srv.accept() as c:
            p = http.new_parser()
            whole = False
            while not whole:
                chunk = await c.read(64)
                if len(chunk) == 0:
                    break
                whole = p.feed(chunk)
            if not whole:
                await c.write(http.response(400, "Bad Request", "text/plain", p.problem))
                continue
            r = p.request()
            body = "method=" + r.method + " target=" + r.target
            body += " host=" + r.header("host")
            body += " body=" + str(r.body)
            await c.write(http.response(200, "OK", "text/plain", body))
            served += 1
    return served


async def client(port: int, text: str) -> str:
    with await net.connect("127.0.0.1", port) as c:
        await c.write(text)
        # the answer may arrive in pieces, like anything else
        all: List<u8> = []
        while True:
            part = await c.read(128)
            if len(part) == 0:
                break
            for b in part:
                all.append(b)
        return str(all)


def last_part(s: str) -> str:
    parts = s.split("\r\n\r\n")
    return parts[len(parts) - 1] if len(parts) > 1 else s


srv = net.listen(0)
port = srv.port()
s = serve(srv, 3)

# 1. a plain GET
r1 = await client(port, http.request("GET", "/hello", "example.local", ""))
print("1:", last_part(r1))

# 2. a POST with a body
r2 = await client(port, http.request("POST", "/echo", "example.local", "hello world"))
print("2:", last_part(r2))

# 3. a request in CHUNKS, written by hand
chunked = "POST /chunks HTTP/1.1\r\nhost: example.local\r\ntransfer-encoding: chunked\r\n\r\n"
chunked += "5\r\nabcde\r\n3\r\nfgh\r\n0\r\n\r\n"
r3 = await client(port, chunked)
print("3:", last_part(r3))

print("served:", await s)
srv.close()

# ---- the refusals, which need no socket ----
bad = http.new_parser()
bad_bytes: List<u8> = []
for ch in "GET / HTTP/1.1\r\nhost : x\r\n\r\n":
    bad_bytes.append(u8(ord(ch)))
bad.feed(bad_bytes)
print("refused 1:", bad.problem)

bad2 = http.new_parser()
b2: List<u8> = []
for ch in "GET / HTTP/1.1\r\ncontent-length: 3\r\ntransfer-encoding: chunked\r\n\r\n":
    b2.append(u8(ord(ch)))
bad2.feed(b2)
print("refused 2:", bad2.problem)
