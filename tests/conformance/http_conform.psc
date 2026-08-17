"""llhttp's fixtures, fed to our parser.

Reads the case file that `llhttp_digest.py` writes — an id, a kind, the input
as hex, and the digest llhttp's own log reduces to — and prints OUR digest of
the same bytes in the same shape. `tests/conformance/run.sh http` diffs the two.

The bytes arrive as hex on purpose: an HTTP fixture is full of CR, LF, NUL,
invalid UTF-8 and lone `\\r`, and any text encoding of that would be one more
thing to get wrong between the two sides.

The input is fed in ONE piece here. Incremental feeding is what
`tests/pscript/run/http_server.psc` exercises, over a real socket; what this
corpus is measuring is the verdict, not the chunking.
"""

import sys
import http


def hex_nib(c: int) -> int:
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 97 and c <= 102:
        return c - 87
    if c >= 65 and c <= 70:
        return c - 55
    return -1


def unhex(s: str) -> list<u8>:
    out: list<u8> = []
    i = 0
    n = len(s)
    while i + 1 < n:
        hi = hex_nib(ord(s[i]))
        lo = hex_nib(ord(s[i + 1]))
        if hi < 0 or lo < 0:
            return out
        out.append(u8(hi * 16 + lo))
        i += 2
    return out


HEX: str = "0123456789abcdef"


def tohex(bs: list<u8>) -> str:
    out = ""
    for b in bs:
        v = int(b)
        out += HEX[v // 16]
        out += HEX[v % 16]
    return out


# The same reduction llhttp_digest.py performs on the log, performed on a
# parser. Every line here is a field llhttp also states; nothing is added to
# make the two agree.
def digest(p: http.Parser, whole: bool, msg: int, out: list<str>):
    pre = "m" + str(msg) + " "
    if not p.is_response and len(p.method) > 0:
        out.append(pre + "method=" + p.method)
        out.append(pre + "url=" + p.target)
    if len(p.protocol) > 0:
        out.append(pre + "protocol=" + p.protocol)
        out.append(pre + "version=" + p.version)
    # the status CODE keeps llhttp's timing: it only states it once the headers
    # are done, so this only states it there too
    past_headers = p.state != http.H_LINE and p.state != http.H_HEADERS
    if p.is_response and past_headers and p.status > 0:
        out.append(pre + "status=" + str(p.status))
        if len(p.reason) > 0:
            out.append(pre + "reason=" + p.reason)
    for h in p.raw:
        out.append(pre + "header:" + h.name + "=" + h.value)
    if len(p.body) > 0:
        out.append(pre + "body=" + tohex(p.body))
    if whole:
        out.append(pre + "complete")


# One connection can carry several messages (keep-alive, and pipelining), and
# llhttp reports them one after another. Our parser handles ONE, so the driver
# is what restarts it with whatever bytes are left over — which is exactly what
# a server does with the tail of a read.
def run_case(kind: str, data: list<u8>) -> list<str>:
    out: list<str> = []
    rest = data
    msg = 0
    while True:
        p = http.new_response_parser() if kind == "response" else http.new_parser()
        whole = p.feed(rest)
        digest(p, whole, msg, out)
        if p.state == http.H_ERROR:
            out.append("error")
            return out
        if not whole:
            return out
        left: list<u8> = []
        k = p.pos
        while k < len(p.buf):
            left.append(p.buf[k])
            k += 1
        if len(left) == 0:
            return out
        rest = left
        msg += 1
    return out


async def main_task() -> int:
    args = sys.argv
    if len(args) < 2:
        print("usage: http_conform <cases>")
        return 1
    f = await open(args[1], "r")
    text = await f.text()
    await f.close()

    kind: str = "request"
    n = 0
    for line in text.split("\n"):
        if len(line) == 0:
            continue
        if line.startswith("CASE "):
            print(line)
            continue
        if line.startswith("KIND "):
            kind = line[5:len(line)]
            continue
        if line.startswith("INPUT "):
            for d in run_case(kind, unhex(line[6:len(line)])):
                print("WANT " + d)
            print("END")
            n += 1
            continue
    return n


count = await main_task()
