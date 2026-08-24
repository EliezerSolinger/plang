"""THE BUILD LOG, and the `depfile` the `cc` leaves behind.

The log is what makes an INCREMENTAL build possible, and it keeps five things
per output, each answering a question the disk alone does not answer:

  * the **mtime** of when its CONTENT last changed — because the mtime you see
    now may be the one a `touch` left, and because a run that died halfway
    leaves a new file with old content;
  * the **vtime**, the date of the newest input when the edge was checked —
    which is a DIFFERENT question from the previous one, and the note just below
    says why;
  * the **command hash** that produced it — this is what catches "I changed a
    flag", which no date comparison catches;
  * the hash of the output's **CONTENT** — which ninja does NOT keep, and which
    is what makes `restat` work here: ninja's `restat` compares mtime, and a
    tool that rewrites the file every time (our `plangc` does) changes the mtime
    even when it produces identical bytes. Without the content, pruning would
    never happen — and pruning is precisely what turns "I regenerated identical
    C" into "I did not recompile for 18 s";
  * the **duration** — which ninja records and does not use, and which here
    decides the ORDER of the queue: with the critical path weighted by time, the
    most expensive edge starts first. In this repository that is worth ~4 s out
    of 5 (a 4.96 s TU in a 5.0 s build), and without it the expensive edge can
    go last.

The format is text, one line per output, because a build log is the first thing
anyone opens when the incremental build does something unexpected.
"""
import os
import path

# The name changed with the tool's (`ppack` -> `pforge`), and so did the version:
# a log written by the old name is not read, which costs one full rebuild and
# nothing else. Pretending the marker did not change would be worse.
const LOG_HEADER: str = "# pforge log v3"

record LogEnt:
    mtime: int     # when this output's CONTENT last changed
    vtime: int     # ... and the newest input's date when it was CHECKED
    dur_ms: int
    hash: u64      # the hash of the COMMAND that produced this output
    chash: u64     # ... and the hash of its CONTENT, for `restat`

# Why TWO dates, which is the question this file has to answer.
#
# On a `restat` edge the two diverge, and that is exactly where an incremental
# build is won or lost. The generator ran (the input changed), the output came
# out IDENTICAL:
#
#   * whoever READS the output does not need to run — for them it did not
#     change, and the date that counts is when the content last changed. That is
#     the `mtime`.
#   * the EDGE that produced it, on the other hand, is up to date with today's
#     inputs, and must not run again on the next pass. That is the `vtime`.
#
# One date cannot say both things. Keeping the old one made the edge run
# forever; keeping the new one made readers recompile for nothing. Both shapes
# were in the code, each with its own defect, and that is why the explanation
# lives here.

# ---------- hexadecimal, by hand ----------
# The hash is u64 and does not fit a signed `int`, so it cannot go to the log in
# decimal and come back through `int(s)`. Sixteen hex digits solve it, and the
# conversion both ways is short enough not to be worth a dependency.
const HEXD: str = "0123456789abcdef"

def to_hex16(v: u64) -> str:
    out = ""
    i = 0
    while i < 16:
        sh = u64((15 - i) * 4)
        d = int((v >> sh) & u64(15))
        out += HEXD[d]
        i += 1
    return out

def from_hex(s: str) -> u64:
    v = u64(0)
    for ch in s:
        c = ord(ch)
        d = 0
        if c >= 48 and c <= 57:
            d = c - 48
        elif c >= 97 and c <= 102:
            d = c - 87
        elif c >= 65 and c <= 70:
            d = c - 55
        else:
            return v
        v = (v %* u64(16)) %+ u64(d)
    return v

# ---------- the log ----------
struct Log:
    p: str
    ents: dict<str, LogEnt>
    dirty: bool

    def get(self, key: str) -> LogEnt:
        """An output's entry, or an empty one — no `mtime`, zero hash — which is
        what "never built" means to whoever decides dirtiness."""
        if key in self.ents:
            return self.ents[key]
        return LogEnt(-2, -2, 0, u64(0), u64(0))

    def has(self, key: str) -> bool:
        return key in self.ents

    def put(self, key: str, mtime: int, vtime: int, dur_ms: int, h: u64, ch: u64):
        self.ents[key] = LogEnt(mtime, vtime, dur_ms, h, ch)
        self.dirty = True

async def load(p: str) -> Log:
    lg = Log(p, {}, False)
    if not path.exists(p):
        return lg
    f = await open(p, "r")
    txt = await f.text()
    await f.close()
    first = True
    for line in txt.split("\n"):
        if first:
            first = False
            continue          # the header, which states the format version
        if len(line) == 0:
            continue
        parts = line.split("\t")
        if len(parts) != 6:
            # one damaged line does not invalidate the whole log: it becomes
            # "that output was never built", which is the safe worst case
            continue
        lg.ents[parts[5]] = LogEnt(int(parts[0]), int(parts[1]), int(parts[2]),
                                   from_hex(parts[3]), from_hex(parts[4]))
    return lg

async def save(lg: Log):
    """Rewrites the whole log. Ninja appends line by line and compacts when it
    grows; here the file has one line per output of the project (thousands, not
    millions) and rewriting is simpler and leaves no litter behind."""
    if not lg.dirty:
        return
    d = path.dirname(lg.p)
    if len(d) > 0 and not path.isdir(d):
        os.makedirs(d)
    out = LOG_HEADER + "\n"
    ks: list<str> = []
    for k in lg.ents:
        ks.append(k)
    ks = sorted(ks)     # sorted: two identical builds give identical logs
    for k2 in ks:
        e = lg.ents[k2]
        out += (str(e.mtime) + "\t" + str(e.vtime) + "\t" + str(e.dur_ms) + "\t"
                + to_hex16(e.hash) + "\t" + to_hex16(e.chash) + "\t" + k2 + "\n")
    f = await open(lg.p, "w")
    await f.write(out)
    await f.close()
    lg.dirty = False

# ---------- the depfile ----------
# `cc -MD` leaves a file in Makefile format: `target: dep1 dep2 \` with line
# continuations. The C side is still a stranger to us (it is the `cc` that knows
# which headers it read), and this is the price — thirty lines of parser. On OUR
# side the compiler answers question 1 of the protocol and none of this is
# needed.
def parse_depfile(txt: str) -> list<str>:
    out: list<str> = []
    # join the continuations and turn every separator into a space
    flat = ""
    i = 0
    n = len(txt)
    while i < n:
        ch = txt[i]
        if ch == "\\" and i + 1 < n and txt[i + 1] == "\n":
            flat += " "
            i += 2
            continue
        if ch == "\\" and i + 1 < n and txt[i + 1] == " ":
            flat += "\x01"      # an ESCAPED space: part of the name, not a separator
            i += 2
            continue
        if ch == "\n" or ch == "\t":
            flat += " "
            i += 1
            continue
        flat += ch
        i += 1
    # everything before the first `:` is the target, and the target is already
    # in the graph
    ci = flat.find(":")
    if ci < 0:
        return out
    for piece in flat[ci + 1:].split(" "):
        if len(piece) == 0:
            continue
        out.append(piece.replace("\x01", " "))
    return out
