"""THE GRAPH: nodes, fat edges, and how a graph gets in (memory or JSON).

Decision 1.3 of `pforge/DESIGN.md`: **an edge is fat and self-contained**. It
carries everything — the `argv`, the inputs in their three bands, the outputs,
the environment, the directory, where standard output goes, and the marks
(`restat`, `generator`, `pool`). There is no "rule" with variables to expand,
and that is what keeps the 921 lines samurai spends on variable scoping out of
the engine.

What factors out repetition is the DESCRIPTOR, which is a program — a pscript
function factors better than any variable mechanism, and needs no scoping rules
at all. And there is a gain you only see later: **two graphs compare line by
line**. In the rule model, changing one rule alters a thousand edges invisibly,
which is exactly why ninja needs the command hash in its log to notice.

The three input bands come from ninja, and each exists for a reason:

  * `ins`      — what the tool READS, and what decides whether the output is
                 stale;
  * `implicit` — the same, but discovered (the `depfile` from `cc -MD`), which
                 is why it does not appear in the `argv`;
  * `order`    — "must exist BEFORE", and dirties nothing: it is the output
                 directory, whose mtime changes with every file created inside
                 it and which would rebuild the world if it counted as a real
                 input.
"""
import json
import path

# ---------- the hash ----------
# 64-bit FNV-1a. This is a DIRTINESS hash — it decides whether an edge has to
# run again — not a defense against an adversary: the SHA-256 the packages use
# (F4) is another function for another problem. Written here because the runtime
# has its own (`ps_hash_bytes`) and does not expose it to the language, and
# because ten readable lines are worth more than one more dependency.
const FNV_OFF: u64 = 0xcbf29ce484222325
const FNV_PRIME: u64 = 0x100000001b3

def hash_str(seed: u64, s: str) -> u64:
    h = seed
    for ch in s:
        h = (h ^ u64(ord(ch))) %* FNV_PRIME
    return h

def sh_quote(s: str) -> str:
    """SINGLE quotes around everything, and the only escape is the single quote
    itself — which closes, escapes and reopens. Inside single quotes the shell
    expands nothing: no `$`, no `` ` ``, no `*`, no `~`. It is the one form of
    shell quoting with no exceptions."""
    if len(s) == 0:
        return "''"
    safe = True
    for ch in s:
        c = ord(ch)
        ok = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
        if not ok and ch != "/" and ch != "." and ch != "_" and ch != "-" and ch != "=" and ch != "+" and ch != ",":
            safe = False
            break
    if safe:
        return s
    out = "'"
    for ch2 in s:
        if ch2 == "'":
            out += "'\\''"
        else:
            out += ch2
    return out + "'"

# ---------- the node: a file ----------
const MTIME_UNKNOWN: int = -1
const MTIME_MISSING: int = -2

struct Node:
    """A file in the graph. The `mtime` is in NANOSECONDS, and that is not
    fussiness: in a fast build two files written in the same second are
    indistinguishable at second resolution, and that is how an incremental build
    forgets to redo something.
    """
    id: int
    p: str
    mtime: int          # ns; MTIME_UNKNOWN / MTIME_MISSING
    logmtime: int       # what the log says it had when it was produced
    loghash: u64        # ... and the hash of the command that produced it
    gen: int            # the edge that produces it; -1 = it is a source
    used: list<int>     # the edges that consume it
    dirty: bool

    def stat_now(self):
        """Asks the disk ONCE. After that the value stands: a build that asked
        twice could see two different answers and decide on half the
        information."""
        if self.mtime != MTIME_UNKNOWN:
            return
        if path.exists(self.p):
            self.mtime = path.getmtime_ns(self.p)
        else:
            self.mtime = MTIME_MISSING

# ---------- the edge: a command ----------
struct Edge:
    """A command with what it reads and what it writes. Everything that changes
    the result goes into the `hash` — `argv`, environment, directory, where the
    output goes, and the TARGET — because a dirtiness key has to answer "was
    this produced exactly like that?" and not "by a similar command".
    """
    id: int
    argv: list<str>
    env: dict<str, str>       # empty = inherit the caller's environment
    cwd: str                  # "" = the caller's directory
    stdout_to: str            # "" = the output comes back captured
    ins: list<int>
    implicit: list<int>
    order: list<int>
    outs: list<int>
    out_implicit: list<int>
    restat: bool
    generator: bool
    pool: str                 # "" = none; "console" = talks to the terminal
    depfile: str              # "" = none
    desc: str                 # what gets printed; "" = the command itself
    target: str               # the compilation target (goes into the hash)
    # state during a build
    hash: u64
    nblock: int               # inputs still missing before this one can run
    nprune: int               # ... and before its outputs can be pruned
    want: bool                # is in the requested build
    dirty_in: bool
    dirty_out: bool
    dur_ms: int               # how long it took last time (from the log)
    cpw: int                  # critical path weight

    def label(self) -> str:
        if len(self.desc) > 0:
            return self.desc
        return " ".join(self.argv)

    def compute_hash(self) -> u64:
        """This edge's dirtiness key. It covers the EFFECTIVE environment
        because ninja does not, and that is a real hole in it: swapping
        `CC=clang` for `CC=gcc` can silently reuse an artifact when the compiler
        arrives through a variable. And it covers the TARGET because an artifact
        for `linux-amd64` is not an artifact for `macos-arm64`.
        """
        h = FNV_OFF
        for a in self.argv:
            h = hash_str(h, a)
            h = hash_str(h, "\n")
        # the environment in KEY order: a dict keeps insertion order, and two
        # assemblies of the same environment need not insert in the same order
        ks: list<str> = []
        for k in self.env:
            ks.append(k)
        ks = sorted(ks)
        for k2 in ks:
            h = hash_str(h, k2)
            h = hash_str(h, "=")
            h = hash_str(h, self.env[k2])
            h = hash_str(h, "\n")
        h = hash_str(h, self.cwd)
        h = hash_str(h, self.stdout_to)
        h = hash_str(h, self.target)
        return h

# ---------- the graph ----------
struct Graph:
    nodes: list<Node>
    edges: list<Edge>
    by_path: dict<str, int>
    default_targets: list<str>
    dupes: list<str>          # outputs with TWO producers (see `add_edge`)

    def node(self, p: str) -> Node:
        """The node for a path, created if this is the first time. The path is
        NORMALIZED on the way in: `a/../b/c.o` and `b/c.o` are the same file, and
        a graph that saw them as two nodes would rebuild for nothing."""
        np = path.normpath(p)
        if np in self.by_path:
            return self.nodes[self.by_path[np]]
        n = Node(len(self.nodes), np, MTIME_UNKNOWN, MTIME_MISSING, u64(0), -1, [], False)
        self.nodes.append(n)
        self.by_path[np] = n.id
        return n

    def add_edge(self, e: Edge) -> Edge:
        e.id = len(self.edges)
        self.edges.append(e)
        for o in e.outs:
            # two edges producing the SAME file is a graph with no answer: which
            # of the two defines the content depends on the order they run in,
            # and the incremental build starts depending on luck. It is recorded
            # here, where it is known, and the engine refuses the build.
            if self.nodes[o].gen >= 0:
                self.dupes.append(self.nodes[o].p)
            self.nodes[o].gen = e.id
        for oi in e.out_implicit:
            if self.nodes[oi].gen >= 0:
                self.dupes.append(self.nodes[oi].p)
            self.nodes[oi].gen = e.id
        for i in e.ins:
            self.nodes[i].used.append(e.id)
        for im in e.implicit:
            self.nodes[im].used.append(e.id)
        for od in e.order:
            self.nodes[od].used.append(e.id)
        e.hash = e.compute_hash()
        return e

def new_graph() -> Graph:
    return Graph([], [], {}, [], [])

def new_edge(argv: list<str>) -> Edge:
    """An edge with every default in place. It exists because an edge has
    eighteen fields and building one by position would be unreadable — and
    because each field's default is a decision that deserves one home."""
    return Edge(-1, argv, {}, "", "", [], [], [], [], [], False, False, "", "", "", "",
                u64(0), 0, 0, False, False, False, 0, 0)

# ---------- from JSON to graph ----------
# The truth of a graph is the STRUCTURE (1.8: memory when it is the same
# execution). Reading JSON is merely one of its constructors — the one that
# serves when whoever describes and whoever executes are not the same process,
# and the one that leaves the door open for ninja's language to arrive later
# without the engine knowing the difference.
private def getl(d: dict<str, any>, k: str) -> list<str>:
    out: list<str> = []
    if k in d:
        for x in d[k] as list<any>:
            out.append(x as str)
    return out

private def ss(d: dict<str, any>, k: str, dflt: str) -> str:
    if k in d:
        return d[k] as str
    return dflt

private def sb(d: dict<str, any>, k: str) -> bool:
    if k in d:
        return d[k] as bool
    return False

def from_json(text: str) -> Graph:
    root = json.parse(text) as dict<str, any>
    g = new_graph()
    g.default_targets = getl(root, "default")
    for ev in root["edges"] as list<any>:
        d = ev as dict<str, any>
        e = new_edge(getl(d, "argv"))
        e.cwd = ss(d, "cwd", "")
        e.stdout_to = ss(d, "stdout", "")
        e.pool = ss(d, "pool", "")
        e.depfile = ss(d, "depfile", "")
        e.desc = ss(d, "desc", "")
        e.target = ss(d, "target", "")
        e.restat = sb(d, "restat")
        e.generator = sb(d, "generator")
        if "env" in d:
            ed = d["env"] as dict<str, any>
            for k in ed:
                e.env[k] = ed[k] as str
        for p in getl(d, "in"):
            e.ins.append(g.node(p).id)
        for p2 in getl(d, "implicit"):
            e.implicit.append(g.node(p2).id)
        for p3 in getl(d, "order"):
            e.order.append(g.node(p3).id)
        for p4 in getl(d, "out"):
            e.outs.append(g.node(p4).id)
        for p5 in getl(d, "out_implicit"):
            e.out_implicit.append(g.node(p5).id)
        g.add_edge(e)
    return g

# ---------- from graph to JSON ----------
# The export exists for three things: inspecting (`--emit-graph`), versioning a
# generated graph, and feeding whoever is not this process. Written by hand and
# not by reflection because generic reflection is another phase's decision (F5)
# — and because here we know exactly what every field means.
# public: `pforge --json` speaks the same JSON as the graph export, and a second
# escaper would be a second place to get it wrong
def jstr(s: str) -> str:
    out = '"'
    for ch in s:
        if ch == '"':
            out += '\\"'
        elif ch == '\\':
            out += '\\\\'
        elif ch == '\n':
            out += '\\n'
        elif ch == '\t':
            out += '\\t'
        else:
            out += ch
    return out + '"'

private def jlist(g: Graph, ids: list<int>) -> str:
    parts: list<str> = []
    for i in ids:
        parts.append(jstr(g.nodes[i].p))
    return "[" + ", ".join(parts) + "]"

def to_json(g: Graph) -> str:
    out = '{\n  "version": 1,\n  "edges": [\n'
    first = True
    for e in g.edges:
        if not first:
            out += ',\n'
        first = False
        args: list<str> = []
        for a in e.argv:
            args.append(jstr(a))
        out += '    {"argv": [' + ", ".join(args) + ']'
        out += ', "in": ' + jlist(g, e.ins)
        if len(e.implicit) > 0:
            out += ', "implicit": ' + jlist(g, e.implicit)
        if len(e.order) > 0:
            out += ', "order": ' + jlist(g, e.order)
        out += ', "out": ' + jlist(g, e.outs)
        if len(e.out_implicit) > 0:
            out += ', "out_implicit": ' + jlist(g, e.out_implicit)
        if len(e.env) > 0:
            ks: list<str> = []
            for k in e.env:
                ks.append(k)
            ks = sorted(ks)
            evs: list<str> = []
            for k2 in ks:
                evs.append(jstr(k2) + ': ' + jstr(e.env[k2]))
            out += ', "env": {' + ", ".join(evs) + '}'
        if len(e.cwd) > 0:
            out += ', "cwd": ' + jstr(e.cwd)
        if len(e.stdout_to) > 0:
            out += ', "stdout": ' + jstr(e.stdout_to)
        if len(e.pool) > 0:
            out += ', "pool": ' + jstr(e.pool)
        if len(e.depfile) > 0:
            out += ', "depfile": ' + jstr(e.depfile)
        if len(e.desc) > 0:
            out += ', "desc": ' + jstr(e.desc)
        if len(e.target) > 0:
            out += ', "target": ' + jstr(e.target)
        if e.restat:
            out += ', "restat": true'
        if e.generator:
            out += ', "generator": true'
        out += '}'
    out += '\n  ]'
    if len(g.default_targets) > 0:
        ds: list<str> = []
        for t in g.default_targets:
            ds.append(jstr(t))
        out += ',\n  "default": [' + ", ".join(ds) + ']'
    return out + '\n}\n'
