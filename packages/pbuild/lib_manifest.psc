"""`pack.json`: a package's manifest, and the WORKSPACE's.

It is **data, never a program**, and that decision holds up the rest: it is the
file the IDE's configuration panel edits, and a panel does not edit code. For
the same reason it does NOT repeat the package's file list — the import graph IS
the package's graph, and the compiler already answers what it is (answers 1 and
3 of the protocol). A manifest that listed files would hold two truths about the
same thing, and one of them would go stale.

Two shapes in one format:

    PACKAGE     { "name": "pui", "version": "0.1.0", "lang": "pscript",
                  "root": "pui.psc", "deps": {}, "system": {},
                  "toolchain": ">= 0.1.0", "description": "..." }

    WORKSPACE   { "members": ["packages/stl", "packages/pui"],
                  "default": "build/bin/ppack" }

Whatever has `members` is a workspace; whatever does not is a package. There is
no third file and no `kind` field: the shape says what it is.

**AN ERROR HAS A POSITION, and the position is the KEY's.** `pack.json:4:12:
error: ...` is clickable in the IDE by the same route a compile error is, and
that is why it is worth the trouble. The position is found by searching for the
key in the raw text — the language's `json.parse` returns the structure and not
the positions, and writing a second JSON reader just to have them would be
paying dearly for a number. When the key is not found (the error is about the
whole file), the message comes out without numbers, which is the same shape
minus the colons — and not a second format.
"""
import json
import path

struct Dep:
    name: str
    req: str        # the version requirement asked for, as written

struct Manifest:
    file: str           # where it came from (for the error message)
    is_workspace: bool
    # package
    name: str
    version: str
    lang: str           # "p" or "pscript"
    root: str           # the root module, relative to the package directory
    deps: list<Dep>
    system: list<Dep>
    toolchain: str
    description: str
    # 2.13: the C the package brings HAND-WRITTEN, and its flags. The paths are
    # relative to the package directory — it does not know where it was
    # extracted — and whoever makes them absolute is the tooling, never the
    # manifest.
    csources: list<str>
    cflags: list<str>
    # workspace
    members: list<str>
    default_target: str
    # ... and where the dependencies that are NOT in the tree come from. The
    # list belongs to the PROJECT and not to the machine: two projects on the
    # same computer may use different repositories, and a project you clone
    # brings along where its dependencies come from. The order is the search
    # order; with no list, the default one applies.
    repos: list<str>
    repos_unsafe: list<bool>

def empty(file: str) -> Manifest:
    return Manifest(file, False, "", "", "", "", [], [], "", "", [], [], [], "", [], [])

# ---------- a key's position ----------
def where_key(raw: str, key: str) -> str:
    """`file:line:column` of the key, or "" if it is not in the text."""
    target = "\"" + key + "\""
    i = raw.find(target)
    if i < 0:
        return ""
    line = 1
    col = 1
    k = 0
    while k < i:
        if raw[k] == "\n":
            line += 1
            col = 1
        else:
            col += 1
        k += 1
    return str(line) + ":" + str(col)

private def fail(m: Manifest, raw: str, key: str, msg: str):
    p = where_key(raw, key)
    if len(p) > 0:
        raise error(m.file + ":" + p + ": error: " + msg)
    raise error(m.file + ": error: " + msg)

# ---------- what a name and a version may be ----------
def name_ok(s: str) -> bool:
    """Lowercase, digits, `_` and `-`, starting with a letter. Narrow on
    purpose: a package name becomes a directory name, part of an import path
    and (later) part of a URL — and each of those places has its own list of
    characters that hurt. This is the intersection."""
    if len(s) == 0:
        return False
    c0 = ord(s[0])
    if not (c0 >= 97 and c0 <= 122):
        return False
    for ch in s:
        c = ord(ch)
        if (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or ch == "_" or ch == "-":
            continue
        return False
    return True

def version_ok(s: str) -> bool:
    """`x.y.z`, three numbers and nothing else. No pre-release suffix for now:
    adding one later is compatible, taking one away is not."""
    parts = s.split(".")
    if len(parts) != 3:
        return False
    for p in parts:
        if len(p) == 0:
            return False
        for ch in p:
            c = ord(ch)
            if c < 48 or c > 57:
                return False
        if len(p) > 1 and p[0] == "0":
            return False        # `01` is not a version number
    return True

# ---------- reading ----------
private def text_of(d: dict<str, any>, k: str, dflt: str) -> str:
    if k in d:
        return d[k] as str
    return dflt

private def pairs(d: dict<str, any>, k: str) -> list<Dep>:
    out: list<Dep> = []
    if k not in d:
        return out
    sub = d[k] as dict<str, any>
    ks: list<str> = []
    for n in sub:
        ks.append(n)
    ks = sorted(ks)     # sorted: two identical manifests give the same list
    for n2 in ks:
        out.append(Dep(n2, sub[n2] as str))
    return out

private def strings(d: dict<str, any>, key: str) -> list<str>:
    out: list<str> = []
    if key not in d:
        return out
    for x in d[key] as list<any>:
        out.append(x as str)
    return out


async def read(file: str) -> Manifest:
    f = await open(file, "r")
    raw = await f.text()
    await f.close()
    m = empty(file)
    nonlocal root
    try:
        root = json.parse(raw) as dict<str, any>
    catch e:
        raise error(file + ": error: not a JSON object (" + e.message + ")")

    if "members" in root:
        m.is_workspace = True
        for x in root["members"] as list<any>:
            m.members.append(x as str)
        m.default_target = text_of(root, "default", "")
        # the workspace also declares the project's EXTERNAL dependencies, which
        # are not members: a member is code from this repository, a dependency
        # is code from outside with a name, a version and a hash
        m.deps = pairs(root, "deps")
        if "repos" in root:
            for rv in root["repos"] as list<any>:
                # two shapes, and the short one is the common one: a URL. The
                # long one exists for the unsigned development mirror, which is
                # `unsafe` throughout. `as` raises when the type does not match,
                # so trying the short one and falling into the long one is the
                # reading — and whatever is neither lands on the error with the
                # key's position.
                try:
                    m.repos.append(rv as str)
                    m.repos_unsafe.append(False)
                catch e2:
                    try:
                        rd = rv as dict<str, any>
                        m.repos.append(text_of(rd, "url", ""))
                        m.repos_unsafe.append(("unsafe" in rd) and (rd["unsafe"] as bool))
                    catch e3:
                        fail(m, raw, "repos", "a repository is a URL, or {\"url\": ..., \"unsafe\": true}")
        if len(m.members) == 0:
            fail(m, raw, "members", "a workspace with no members is not a workspace")
        return m

    m.name = text_of(root, "name", "")
    m.version = text_of(root, "version", "")
    m.lang = text_of(root, "lang", "")
    m.root = text_of(root, "root", "")
    m.toolchain = text_of(root, "toolchain", "")
    m.description = text_of(root, "description", "")
    m.deps = pairs(root, "deps")
    m.system = pairs(root, "system")
    m.csources = strings(root, "csources")
    m.cflags = strings(root, "cflags")

    if not name_ok(m.name):
        fail(m, raw, "name", "package name: lowercase, digits, `_` and `-`, starting with a letter (got '" + m.name + "')")
    if not version_ok(m.version):
        fail(m, raw, "version", "version: three numbers, `x.y.z` (got '" + m.version + "')")
    if m.lang != "p" and m.lang != "pscript":
        fail(m, raw, "lang", "lang: `p` or `pscript` (got '" + m.lang + "')")
    # `root` is OPTIONAL, and `stl` is the reason: it is ten independent `.ph`
    # files (vec, str, dict, map, set, list, queue, slice, hash, traits) and none
    # of them is "the interface". Electing one would be arbitrary and would
    # confuse the reader. A package may be a SET of modules — and it is whoever
    # wants `import <pkg>` (the short form) that needs a root named after the
    # package.
    dirp = path.dirname(file)
    if len(m.root) > 0:
        if m.lang == "p" and m.root.endswith(".psc"):
            # the rule that makes a P package usable by whoever has no runtime
            fail(m, raw, "root", "a `p` package has no pscript module: the root is a `.ph`")
        if not path.isfile(path.join(dirp, m.root)):
            fail(m, raw, "root", "the root '" + m.root + "' does not exist in " + dirp)
    for dp in m.deps:
        if not name_ok(dp.name):
            fail(m, raw, "deps", "dependency with an invalid name: '" + dp.name + "'")
    # 2.13: the package's C. Checking here is checking once — the build, the
    # publication and `ppack check` all read this same manifest.
    for cs in m.csources:
        if not cs.endswith(".c"):
            fail(m, raw, "csources", "csources is C: '" + cs + "' does not end in `.c`")
        elif cs.startswith("/") or ".." in cs:
            # the same rule as the tar reader, and for the same reason: a path
            # that leaves the package is a package reading the tree of whoever
            # installed it
            fail(m, raw, "csources", "'" + cs + "': the path is relative to the package, and does not leave it")
        elif not path.isfile(path.join(dirp, cs)):
            fail(m, raw, "csources", "'" + cs + "' does not exist in " + dirp)
    return m


# ---------- writing to the manifest without ruining it ----------
async def write_dep(file: str, name: str, version: str):
    """The dependency goes into the workspace's `pack.json`, by hand and
    preserving the rest of the file. Rewriting the whole JSON from the structure
    would lose the formatting whoever wrote it chose and reorder everything — a
    package manager that ruins its user's file is a package manager you distrust.

    A name that is already there is REPLACED and not repeated: `{"tar": "0.1.0",
    "tar": "0.2.0"}` is an object with the same key twice, which every JSON
    reader resolves its own way."""
    f = await open(file, "r")
    raw = await f.text()
    await f.close()
    line = "    " + jstr(name) + ": " + jstr(version)
    target = jstr(name) + ":"
    if "\"deps\"" in raw:
        i = raw.find("\"deps\"")
        j = raw.find("{", i)
        if j < 0:
            raise error(file + ": `deps` has to be an object", VALUE)
        k = raw.find("}", j)
        inside = raw[j + 1:k]
        # is the name already there? then only its line is swapped
        p0 = inside.find(target)
        if p0 >= 0:
            start = 0
            for z in range(p0):
                if inside[z] == "\n":
                    start = z + 1
            end = inside.find("\n", p0)
            if end < 0:
                end = len(inside)
            comma = "," if inside[start:end].rstrip().endswith(",") else ""
            raw = raw[0:j + 1] + inside[0:start] + line + comma + inside[end:] + raw[k:]
        elif len(inside.strip()) == 0:
            raw = raw[0:j] + "{\n" + line + "\n  }" + raw[k + 1:len(raw)]
        else:
            raw = raw[0:j] + "{" + inside.rstrip() + ",\n" + line + "\n  }" + raw[k + 1:len(raw)]
    else:
        i2 = raw.rfind("}")
        before = raw[0:i2].rstrip()
        if before.endswith(","):
            before = before[0:len(before) - 1]
        raw = before + ",\n  \"deps\": {\n" + line + "\n  }\n}\n"
    await write_text(file, raw)


async def write_field(file: str, key: str, value: str):
    """A TOP-level field of the manifest, written by hand and preserving the
    rest.

    The same surgery as `write_dep`, and for the same reason: rewriting the JSON
    from the structure would lose the formatting whoever wrote it chose and
    reorder everything. A tool that ruins its user's file is a tool you distrust
    — and a manifest is a file people commit.

    A key that already exists is REPLACED where it stands; one that does not
    goes in before the closing brace."""
    f = await open(file, "r")
    raw = await f.text()
    await f.close()
    target = jstr(key) + ":"
    k = raw.find(target)
    if k >= 0:
        start = 0
        for z in range(k):
            if raw[z] == "\n":
                start = z + 1
        end = raw.find("\n", k)
        if end < 0:
            end = len(raw)
        comma = "," if raw[start:end].rstrip().endswith(",") else ""
        raw = raw[0:start] + "  " + target + " " + jstr(value) + comma + raw[end:len(raw)]
    else:
        i2 = raw.rfind("}")
        before = raw[0:i2].rstrip()
        if before.endswith(","):
            before = before[0:len(before) - 1]
        raw = before + ",\n  " + target + " " + jstr(value) + "\n}\n"
    await write_text(file, raw)


private async def write_text(file: str, txt: str):
    f = await open(file, "w")
    await f.write(txt)
    await f.close()


def jstr(s: str) -> str:
    """A JSON string, escaped. It is the same arithmetic as `lib_graph`'s, and
    it lives here because a manifest cannot depend on the graph — whoever reads
    `pack.json` is the package manager, and the package manager comes before the
    build."""
    out = "\""
    for c in s:
        if c == "\"":
            out += "\\\""
        elif c == "\\":
            out += "\\\\"
        elif c == "\n":
            out += "\\n"
        elif c == "\t":
            out += "\\t"
        elif c == "\r":
            out += "\\r"
        else:
            out += c
    return out + "\""


def version_greater(a: str, b: str) -> bool:
    """`a > b`, comparing NUMBER by number and not text by text.

    "0.10.0" and "0.9.0": as text the second wins, and as a version it loses. It
    is the classic mistake, and it costs three lines not to make it."""
    pa = a.split(".")
    pb = b.split(".")
    i = 0
    while i < 3:
        na = int(pa[i]) if i < len(pa) else 0
        nb = int(pb[i]) if i < len(pb) else 0
        if na != nb:
            return na > nb
        i += 1
    return False


def toolchain_ok(req: str, version: str) -> str:
    """The toolchain requirement against the version you have. Returns "" when
    it fits, and the REASON when it does not.

    The requirement is `>= X.Y.Z` and nothing else — v1 has no resolver and no
    interval algebra either. An empty requirement means "any will do", which is
    what a package with no demands means.

    Checking this BEFORE compiling gives the best possible message ("package foo
    requires plangc >= X, yours is Y") instead of a syntax error halfway through
    a module that uses something which does not exist yet."""
    f = req.strip()
    if len(f) == 0 or len(version) == 0:
        return ""
    if not f.startswith(">="):
        return "toolchain requirement I do not understand: `" + req + "` (v1 reads `>= x.y.z`)"
    wants = f[2:].strip()
    if not version_ok(wants) or not version_ok(version):
        return ""
    if version_greater(wants, version):
        return "requires plangc " + f + ", and yours is " + version
    return ""
