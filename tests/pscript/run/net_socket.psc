"""Sockets (77.1): the other half of I/O, and what it does NOT need the pool for.

A socket has a real non-blocking mode, so `accept`, `read` and `write` are
POLLED: the scheduler puts the descriptor in the same `poll` it has been
running since 74.1, and the system call happens in here, when it can no longer
block. No thread. `connect` and name resolution go to the POOL instead, because
`getaddrinfo` blocks and cannot be talked out of it — that is libuv's split,
and it is not a matter of taste: it is what the operating system offers.

The program below is a server and a client in the SAME process, on the same
thread. That only works because every wait parks: if `accept` blocked, the
client would never get to connect.

Two things it pins on purpose:

  * `read(n)` gives back up to n bytes, and the empty answer means the other
    side closed (79.2) — the semantics of `recv`, which is what an incremental
    parser wants;
  * `str(b)` is how bytes become text, and it CHECKS: a `str` promises
    codepoints, so bytes that are not valid UTF-8 raise instead of producing a
    string that lies about its own length (79.1/83.2).
"""

import net


async def serve(srv: Socket) -> int:
    total = 0
    for i in range(2):
        with await srv.accept() as c:
            asked = await c.read(4096)
            total += len(asked)
            await c.write("ok:" + str(asked) + "\n")
            # the client closes; the next read sees the end
            rest = await c.read(16)
            if len(rest) == 0:
                total += 100
    return total


async def client(port: int, text: str) -> str:
    with await net.connect("127.0.0.1", port) as c:
        await c.write(text)
        answer = await c.read(256)
        return str(answer)


srv = net.listen(0)
port = srv.port()
print("the system chose a port:", port > 0)

s = serve(srv)
a = await client(port, "ping")
b = await client(port, "pong")
print("client 1:", a)
print("client 2:", b)
print("the server counted:", await s)
srv.close()

# the machine's own name always resolves, network or no network
ip = await net.lookup("localhost")
print("localhost resolves to something:", len(ip) > 0)
