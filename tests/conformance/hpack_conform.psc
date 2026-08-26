"""The HPACK corpus, fed to our decoder.

`hpack_digest.py` writes a line per case — `<story>#<seqno> <hex>` — and this
prints the `CASE`/`WANT` shape back, so `compare.py` diffs the two the way it
already does for the URL and JSON corpora.

**The dynamic table belongs to the STORY, not to the case.** Each `story_NN.json`
is one connection: its cases share a table in `seqno` order, so an eviction bug
shows up as case 40 decoding to nonsense after 39 perfect ones. A fresh table per
case passes and measures nothing — which is why the reset here keys on the part
of the identifier BEFORE the `#`.
"""

import sys
import <http/hpack.psc> as HP


def hex_nib(c: int) -> int:
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 97 and c <= 102:
        return c - 87
    if c >= 65 and c <= 70:
        return c - 55
    return -1


def unhex(s: str) -> bytes:
    out: List<u8> = []
    i = 0
    while i + 1 < len(s):
        hi = hex_nib(ord(s[i]))
        lo = hex_nib(ord(s[i + 1]))
        if hi < 0 or lo < 0:
            raise error("the wire column is not hexadecimal", VALUE)
        out.append(u8(hi * 16 + lo))
        i += 2
    return bytes(out)


def esc(s: str) -> str:
    out = ""
    for ch in s:
        if ch == "\\":
            out += "\\\\"
        elif ch == "\t":
            out += "\\t"
        elif ch == "\n":
            out += "\\n"
        elif ch == "\r":
            out += "\\r"
        else:
            out += ch
    return out


async def go() -> int:
    if len(sys.argv) < 2:
        print("usage: hpack_conform <wire-file>")
        return 2
    f = await open(sys.argv[1], "r")
    text = str(await f.read_all())
    await f.close()
    story = ""
    t = HP.new_table(4096)
    for line in text.split("\n"):
        sp = line.find(" ")
        if sp <= 0:
            continue
        cid = line[0:sp]
        hx = line[sp + 1:]
        hash_at = cid.find("#")
        this_story = cid[0:hash_at] if hash_at > 0 else cid
        if this_story != story:
            story = this_story
            t = HP.new_table(4096)
        print("CASE " + cid)
        # a case that does not decode is a disagreement like any other: it says
        # nothing and `compare.py` reports it against what the corpus wanted
        try:
            for h in HP.decode(t, unhex(hx)):
                print("WANT " + esc(h.name) + "\t" + esc(h.value))
        catch e:
            print("WANT refused: " + e.message)
    return 0


sys.exit(await go())
