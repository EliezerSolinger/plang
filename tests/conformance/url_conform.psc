"""The WPT URL corpus, fed to our parser.

Reads the case file `wpt_url_digest.py` writes and prints the same shape back,
so `tests/conformance/run.sh url` can diff the two. Failure is a verdict like
any other: 267 of the 891 cases exist to be REFUSED, and refusing them for the
right reason is most of what a URL parser is for.
"""

import sys
import url


def hex_nib(c: int) -> int:
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 97 and c <= 102:
        return c - 87
    if c >= 65 and c <= 70:
        return c - 55
    return -1


def unhex_text(s: str) -> str:
    bs: List<u8> = []
    i = 0
    n = len(s)
    while i + 1 < n:
        hi = hex_nib(ord(s[i]))
        lo = hex_nib(ord(s[i + 1]))
        if hi < 0 or lo < 0:
            return url.decode_utf8(bs)
        bs.append(u8(hi * 16 + lo))
        i += 2
    return url.decode_utf8(bs)


def components(u: url.Url) -> List<str>:
    out: List<str> = []
    out.append("href=" + url.href(u))
    out.append("protocol=" + u.scheme + ":")
    out.append("username=" + u.username)
    out.append("password=" + u.password)
    hostport = u.host
    if u.port >= 0:
        hostport += ":" + str(u.port)
    out.append("host=" + hostport)
    out.append("hostname=" + u.host)
    out.append("port=" + (str(u.port) if u.port >= 0 else ""))
    out.append("pathname=" + url.serialize_path(u))
    out.append("search=" + ("?" + u.query if u.has_query and len(u.query) > 0 else ""))
    out.append("hash=" + ("#" + u.fragment if u.has_fragment and len(u.fragment) > 0 else ""))
    return out


# The base is parsed first, and its own failure makes the case fail — which is
# what a browser does with a base it cannot read.
def run_case(input_s: str, base_s: str) -> List<str>:
    failed: List<str> = ["failure"]
    base = url.blank_url()
    has_base = False
    if base_s != "-":
        b = url.parse(unhex_text(base_s), url.blank_url(), False)
        # the positive form on purpose: a guard clause (`if b == None: return`)
        # does NOT narrow what comes after it today — see bateria 88 in PLAN.md
        if b != None:
            base = b
            has_base = True
        else:
            return failed
    u = url.parse(input_s, base, has_base)
    if u != None:
        return components(u)
    return failed


async def main_task() -> int:
    args = sys.argv
    if len(args) < 2:
        print("usage: url_conform <cases>")
        return 1
    f = await open(args[1], "r")
    text = await f.text()
    await f.close()

    input_s: str = ""
    base_s: str = ""
    n = 0
    for line in text.split("\n"):
        if len(line) == 0:
            continue
        if line.startswith("CASE "):
            print(line)
            continue
        if line.startswith("INPUT "):
            input_s = unhex_text(line[6:len(line)])
            continue
        if line.startswith("BASE "):
            base_s = line[5:len(line)]
            continue
        if line == "END":
            for w in run_case(input_s, base_s):
                print("WANT " + w)
            print("END")
            n += 1
            continue
    return n


count = await main_task()
