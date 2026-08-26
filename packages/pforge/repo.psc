"""THE REPOSITORY: a format, not a service.

The whole design is in `pforge/REPOSITORIO.md`; what follows is what this file
implements of it.

A repository is four names and a directory:

    repo/
      index.json                            what you can search and resolve
      index.json.sig                        the repository's signature
      pkg/<name>/<name>-<version>.tar       the source
      pkg/<name>/<name>-<version>.tar.sig   the author's signature

Servable by `python3 -m http.server`, by a bucket, by `file://`, by a USB stick.
That is the consequence of being a format: publishing sends nothing, it produces
— and sending is `rsync`, `scp` or `git push`.

**NOTHING IS GLOBAL.** The stored index, the tarballs and the unpacked trees live
in the PROJECT's `build/pkg/`. There is no directory under `~` that this writes
to, and the consequence is that copying the project takes everything with it, two
checkouts do not contaminate each other, and there is no hidden state on a machine
to explain a "works here". The key accepted by TOFU is the exception that
confirms it: it lives in `pack.lock`, which is COMMITTED — trust is versioned and
goes through code review, instead of through a warning on one person's terminal.

The hash is NEVER waived: it is the only thing that stops what arrived from being
something else.
"""
import json
import net
import os
import path
import time
import manifest as M
import <ed25519/ed25519.ph>
import <http/http.psc> as H
import <url/url.psc> as U
import <tar/tar.psc> as tar
import <sha2/sha2.ph>
import <csprng/csprng.psc> as csprng

# everything this project keeps from outside lives here, and `make clean` takes
# it along — safe by construction, because the lock has the hash of everything
const STORE: str = "build/pkg"

# what the `user-agent` says. A server that wants to deny us service has the
# right to know who is knocking.
const UA_VERSION: str = "0.1.0"


def indexes_dir() -> str:
    return path.join(STORE, ".index")


def tarballs_dir() -> str:
    return path.join(STORE, ".pak")


# ---------- the address ----------

struct Repo:
    url: str        # normalized, always ending in "/"
    is_unsafe: bool
    id: str         # the URL's hash: a stable name nobody chooses

def normalize(url: str) -> str:
    return url if url.endswith("/") else url + "/"


def id_of(url: str) -> str:
    """The `<repo-id>`: the first 16 digits of the normalized URL's SHA-256.

    Not a nickname, because a nickname is a choice, and two people choose
    `official` for different repositories. A hash does not have that freedom."""
    return sha256_of(tar.bytes_of(normalize(url)))[0:16]


def repo(url: str, is_unsafe: bool) -> Repo:
    n = normalize(url)
    return Repo(n, is_unsafe, id_of(n))


def is_file_repo(r: Repo) -> bool:
    return r.url.startswith("file://")


def local_path(r: Repo) -> str:
    """The directory behind a `file://`. Raises for any other scheme."""
    if not is_file_repo(r):
        raise error("not a local repository: " + r.url, VALUE)
    return r.url[7:len(r.url)]


async def fetch(r: Repo, rel: str) -> bytes:
    """ONE file from the repository, by its relative path.

    It is the ONLY point where bytes from outside come in, and that is on
    purpose: the rest of the package manager does not know whether the package
    came from a directory, a USB stick or the network. Changing transports
    changes nothing above — that is how HTTP came in, after the whole of phase 1
    had already been proven over `file://`.

    What is NOT here, and it is a decision: TLS. Trust comes from the CONTENT
    (the hash, and the signature), not from the connection, and that is what makes
    a mirror served by `python3 -m http.server` off a USB stick as good as a
    bucket with a certificate."""
    if is_file_repo(r):
        target = path.join(local_path(r), rel)
        if not path.isfile(target):
            raise error("does not exist in the repository: " + target, IO)
        f = await open(target, "r")
        b = await f.read_all()
        await f.close()
        return b
    if r.url.startswith("http://") or r.url.startswith("https://"):
        return await fetch_http(r, rel)
    raise error("I do not know how to fetch from " + r.url + " — the schemes are file://, http:// and https://", VALUE)


async def fetch_http(r: Repo, rel: str) -> bytes:
    """A GET, and nothing clever: no silently followed redirect, no cache, no
    session. What is asked for is an immutable file at a known path.

    The redirect is NOT followed, and that is the opposite of a limitation: an
    index that answers 301 is sending us somewhere else, and the repository's URL
    is what the project declared and the lock recorded. Whoever wants to move
    changes `pack.json`, where the diff can be seen."""
    parsed = U.parse(r.url + rel, U.blank_url(), False)
    if parsed == None:
        raise error("URL I do not understand: " + r.url + rel, VALUE)
    # `!= None` PROVES non-null (43.1): from here down `parsed` IS a `Url`
    u = parsed
    # 158.8: `https` speaks. The refusal that used to stand here was written
    # when there was no TLS; there has been since S7/153, and what was missing
    # was the wiring — not the protocol.
    #
    # It stays OPTIONAL, and that is the honest position rather than a
    # limitation: the index is SIGNED (2.9), so integrity comes from the hash
    # and not from the connection, and a `pforge` built without OpenSSL keeps
    # working against an http:// mirror. What TLS adds here is confidentiality —
    # which package you asked for — and that is worth having when it is there.
    tls = u.scheme == "https"
    if tls and not net.tls_available():
        raise error("this pforge was built without TLS: rebuild the runtime with `-D PSRT_TLS` and link "
                    + "`-lssl -lcrypto`, or point at an http:// mirror — the index is signed, so what "
                    + "you would lose is privacy and not integrity", IO)
    port = u.port if u.port > 0 else (443 if tls else 80)
    target = U.serialize_path(u)
    if len(target) == 0:
        target = "/"
    if u.has_query and len(u.query) > 0:
        target = target + "?" + u.query
    hostval = u.host if port == (443 if tls else 80) else u.host + ":" + str(port)
    c = await net.connect(u.host, port)
    if tls:
        # 153.1: promotes the SAME connection. Everything above — `read_into`,
        # `write_from`, the parser — goes on talking to a `Socket` and does not
        # know the difference, which is why this is four lines and not a second
        # client.
        if not await net.starttls(c, u.host):
            c.close()
            raise error("the TLS handshake with " + u.host + " did not complete", IO)
    req = "GET " + target + " HTTP/1.1\r\n"
    req += "host: " + hostval + "\r\n"
    req += "user-agent: pforge/" + UA_VERSION + "\r\n"
    req += "accept: */*\r\n"
    req += "connection: close\r\n\r\n"
    await c.write(req)
    p = H.new_response_parser()
    done = False
    # 135.2: ONE buffer for the whole download, reused on every turn. The old
    # `read(n)` allocated a fresh `List<u8>` per chunk and copied into it; this
    # allocates once and the syscall writes straight into it, because a Buffer
    # is malloc'd and never moves (52.3).
    with Buffer(65536) as rb:
        while not done:
            got = await c.read_into(rb, 0, 65536)
            if got == 0:
                # the peer closed: it is the only way a response with neither
                # `content-length` nor `chunked` can be complete, and the parser
                # knows how to say so
                done = p.finish()
                break
            done = p.feed(bytes(rb[0:got]))
    c.close()
    if not done:
        raise error("the response from " + r.url + rel + " ended halfway: " + p.problem, IO)
    resp = p.response()
    if resp.status != 200:
        raise error(f"{r.url}{rel}: HTTP {resp.status} {resp.reason}", IO)
    return resp.body


# ---------- the index ----------

struct Release:
    name: str
    version: str
    file: str             # the `.tar`'s path inside the repository
    size: int
    sha256: str
    author: str           # the key that signed the tarball ("" while unsafe)
    lang: str
    root: str
    deps: List<M.Dep>
    toolchain: str
    description: str
    api: Dict<str, List<str>>    # module -> the canonical symbol list
    api_hash: Dict<str, str>     # module -> the interface hash


struct Index:
    format: int
    name: str
    updated: str
    # name -> version -> the entry
    packages: Dict<str, Dict<str, Release>>

    def has(self, name: str, version: str) -> bool:
        if name not in self.packages:
            return False
        return version in self.packages[name]

    def get(self, name: str, version: str) -> Release:
        if not self.has(name, version):
            raise error(f"{name}@{version} is not in the index", KEY)
        return self.packages[name][version]

    def names(self) -> List<str>:
        out: List<str> = []
        for n in self.packages:
            out.append(n)
        return sorted(out)

    def versions(self, name: str) -> List<str>:
        out: List<str> = []
        if name not in self.packages:
            return out
        for v in self.packages[name]:
            out.append(v)
        return sorted(out)


def empty_release() -> Release:
    return Release("", "", "", 0, "", "", "", "", [], "", "", {}, {})


def new_index(name: str) -> Index:
    return Index(1, name, "", {})


# ---------- JSON: reading ----------
#
# Read with `as`, which is CHECKED and raises (55.2). There is no leniency of
# "ignore what you do not understand" here: this is OUR format, written by
# `publish`, and an index with the wrong shape is a corrupted index — going on
# with it would give a build that resolves versions out of garbage. What the
# reader does is lend the message the file's name, so the error says WHICH index.

private def txt(d: Dict<str, any>, k: str, dflt: str) -> str:
    if k not in d:
        return dflt
    return d[k] as str


private def num(d: Dict<str, any>, k: str) -> int:
    if k not in d:
        return 0
    return d[k] as int


def read_index(raw: str, whence: str) -> Index:
    try:
        return read_index_x(raw)
    catch e:
        raise error(whence + ": " + e.message, VALUE)


private def read_index_x(raw: str) -> Index:
    d = json.parse(raw) as Dict<str, any>
    ix = new_index(txt(d, "name", ""))
    ix.format = num(d, "format")
    if ix.format != 1:
        raise error(f"index format {ix.format}, and this version reads 1", VALUE)
    ix.updated = txt(d, "updated", "")
    if "packages" not in d:
        return ix
    packages = d["packages"] as Dict<str, any>
    names: List<str> = []
    for n in packages:
        names.append(n)
    for name in sorted(names):
        byver = packages[name] as Dict<str, any>
        out: Dict<str, Release> = {}
        vs: List<str> = []
        for vn in byver:
            vs.append(vn)
        for version in sorted(vs):
            e = byver[version] as Dict<str, any>
            u = empty_release()
            u.name = name
            u.version = version
            u.file = txt(e, "file", "")
            u.size = num(e, "size")
            u.sha256 = txt(e, "sha256", "")
            u.author = txt(e, "author", "")
            u.lang = txt(e, "lang", "")
            u.root = txt(e, "root", "")
            u.toolchain = txt(e, "toolchain", "")
            u.description = txt(e, "description", "")
            if "deps" in e:
                dd = e["deps"] as Dict<str, any>
                dns: List<str> = []
                for dn in dd:
                    dns.append(dn)
                for dn2 in sorted(dns):
                    u.deps.append(M.Dep(dn2, dd[dn2] as str))
            if "api" in e:
                aa = e["api"] as Dict<str, any>
                mods: List<str> = []
                for mn in aa:
                    mods.append(mn)
                for mod in sorted(mods):
                    mm = aa[mod] as Dict<str, any>
                    u.api_hash[mod] = txt(mm, "hash", "")
                    syms: List<str> = []
                    if "symbols" in mm:
                        for sv in mm["symbols"] as List<any>:
                            syms.append(sv as str)
                    u.api[mod] = syms
            out[version] = u
        ix.packages[name] = out
    return ix


# ---------- JSON: writing ----------
#
# By hand, and on purpose: the ORDER is what makes two `publish` runs over the
# same content give the same file, and a `dict` dumped without order would give a
# huge diff on every publication. Everything here comes out sorted by key.

private def esc(s: str) -> str:
    out = "\""
    for ch in s:
        c = ord(ch)
        if ch == "\"" or ch == "\\":
            out += "\\" + ch
        elif c == 10:
            out += "\\n"
        elif c == 13:
            out += "\\r"
        elif c == 9:
            out += "\\t"
        elif c < 32:
            out += f"\\u{c:04x}"
        else:
            out += ch
    return out + "\""


def write_index(ix: Index) -> str:
    b = "{\n"
    b += "  \"format\": 1,\n"
    b += "  \"name\": " + esc(ix.name) + ",\n"
    b += "  \"updated\": " + esc(ix.updated) + ",\n"
    b += "  \"packages\": {"
    first = True
    for name in ix.names():
        b += "" if first else ","
        first = False
        b += "\n    " + esc(name) + ": {"
        pv = True
        for version in ix.versions(name):
            u = ix.get(name, version)
            b += "" if pv else ","
            pv = False
            b += "\n      " + esc(version) + ": {\n"
            b += "        \"file\": " + esc(u.file) + ",\n"
            b += "        \"size\": " + str(u.size) + ",\n"
            b += "        \"sha256\": " + esc(u.sha256) + ",\n"
            b += "        \"author\": " + esc(u.author) + ",\n"
            b += "        \"lang\": " + esc(u.lang) + ",\n"
            b += "        \"root\": " + esc(u.root) + ",\n"
            b += "        \"toolchain\": " + esc(u.toolchain) + ",\n"
            b += "        \"description\": " + esc(u.description) + ",\n"
            b += "        \"deps\": {"
            pd = True
            for d in u.deps:
                b += "" if pd else ", "
                pd = False
                b += esc(d.name) + ": " + esc(d.req)
            b += "},\n"
            b += "        \"api\": {"
            pa = True
            mods: List<str> = []
            for mk in u.api:
                mods.append(mk)
            for mod in sorted(mods):
                b += "" if pa else ","
                pa = False
                b += "\n          " + esc(mod) + ": {\n"
                b += "            \"hash\": " + esc(u.api_hash[mod] if mod in u.api_hash else "") + ",\n"
                b += "            \"symbols\": ["
                ps = True
                for s in u.api[mod]:
                    b += "" if ps else ","
                    ps = False
                    b += "\n              " + esc(s)
                b += "\n            ]" if not ps else "]"
                b += "\n          }"
            b += "\n        }" if not pa else "}"
            b += "\n      }"
        b += "\n    }"
    b += "\n  }" if not first else "}"
    b += "\n}\n"
    return b


# ---------- packing ----------
#
# What goes into the `.tar` is THE WHOLE TREE minus a FIXED list — decided by
# `pforge` and not by the package. A manifest with packaging rules would be a
# second truth about what the package is, and the first one (the import graph)
# already exists. What the list takes out is what is never source: what the build
# produced, what version control keeps, and editor litter.

const SKIP_DIRS: List<str> = ["build", ".git", ".hg", ".svn", ".verify",
                              "__pycache__", "node_modules", ".idea", ".vscode"]
const SKIP_SUFFIXES: List<str> = [".o", ".a", ".so", ".dylib", ".dll", ".exe",
                                  ".tar", ".sig", ".orig", ".rej", ".swp", "~"]
const SKIP_NAMES: List<str> = [".DS_Store", "pack.lock", "core"]


def skipped(name: str, is_dir: bool) -> bool:
    if is_dir:
        return name in SKIP_DIRS
    if name in SKIP_NAMES:
        return True
    for s in SKIP_SUFFIXES:
        if name.endswith(s):
            return True
    return False


private async def walk(root: str, rel: str, out: List<str>):
    """The tree's files, in order. The order is what makes two `publish` runs
    over the same content give the SAME tarball — and the tarball is the
    identity."""
    here = root if rel == "" else path.join(root, rel)
    for name in sorted(os.listdir(here)):
        full = path.join(here, name)
        is_dir = path.isdir(full)
        if skipped(name, is_dir):
            continue
        r2 = name if rel == "" else rel + "/" + name
        if is_dir:
            await walk(root, r2, out)
        else:
            out.append(r2)


async def pack(dir: str, prefix: str) -> bytes:
    """A package's tree as a `.tar`, inside a `prefix/` directory.

    REPRODUCIBLE, and that is not elegance: the tarball's hash IS the package's
    identity in the index and in the lock, so two packings of the same source have
    to give the same hash. That is why the date is ZERO and the mode is fixed —
    the modification date of a file on the publisher's disk is not content, and
    letting it in would make the same version have two hashes depending on the
    machine.

    The price is known and accepted: the execute bit does not survive. A package
    of SOURCE CODE does not need it, and whoever needs a script calls `sh x.sh`.
    """
    files: List<str> = []
    await walk(dir, "", files)
    if len(files) == 0:
        raise error("there is nothing to pack in " + dir, VALUE)
    members: List<tar.Member> = [tar.directory(prefix, 0o755, 0)]
    seen: Dict<str, int> = {}
    for rel in files:
        # the intermediate directories go in before the first file that lives in
        # them: a `tar` that extracts without them depends on the extractor's
        # behaviour, and this format does not depend on other people's kindness
        parts = rel.split("/")
        acc = prefix
        i = 0
        while i < len(parts) - 1:
            acc = acc + "/" + parts[i]
            if acc not in seen:
                seen[acc] = 1
                members.append(tar.directory(acc, 0o755, 0))
            i += 1
        f = await open(path.join(dir, rel), "r")
        data = await f.read_all()
        await f.close()
        members.append(tar.file(prefix + "/" + rel, data, 0o644, 0))
    return tar.write(members)


def hash_of(b: bytes) -> str:
    return sha256_of(b)


# ---------- storing and reading what arrived ----------

async def write_bytes(target: str, b: bytes):
    d = path.dirname(target)
    if len(d) > 0 and not path.isdir(d):
        os.makedirs(d)
    f = await open(target, "w")
    await f.write(b)
    await f.close()


async def read_bytes(target: str) -> bytes:
    f = await open(target, "r")
    b = await f.read_all()
    await f.close()
    return b


async def extract(b: bytes, dest: str) -> int:
    """Unpacks a tarball into `dest`. Returns how many files came out.

    The reader has already refused absolute paths, `..`, and anything that is
    neither a file nor a directory — here it is only writing. The refusal happens
    BEFORE any byte touches the disk, which is the order that matters: an
    extractor that validates while it writes has already written."""
    members = tar.read(b)
    n = 0
    for m in members:
        target = path.join(dest, m.name)
        if m.kind == "dir":
            if not path.isdir(target):
                os.makedirs(target)
            continue
        await write_bytes(target, m.data)
        n += 1
    return n


def bytes_of_text(s: str) -> bytes:
    return s.encode()


# ---------- the date ----------
#
# The language's `time` gives seconds since the epoch and nothing else, and the
# index wants a date a person can read. The conversion is Hinnant's
# civil-from-days algorithm, which is pure arithmetic: no timezone, no table, no
# library — and always in UTC, because a date with a local timezone in a file
# that travels is a date that lies to whoever reads it on the other side.

private def two(n: int) -> str:
    return ("0" + str(n)) if n < 10 else str(n)


def iso_utc(epoch: int) -> str:
    days = epoch // 86400
    secs = epoch - days * 86400
    z = days + 719468
    era = (z if z >= 0 else z - 146096) // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    month = mp + 3 if mp < 10 else mp - 9
    year = y + 1 if month <= 2 else y
    return f"{year}-{two(month)}-{two(d)}T{two(secs // 3600)}:{two((secs // 60) % 60)}:{two(secs % 60)}Z"


def now_iso() -> str:
    return iso_utc(int(time.time()))


def package_dir(name: str, version: str, sha: str) -> str:
    """`build/pkg/<name>-<version>-<hash>/` — and it is THIS that `--pkg-path`
    points at.

    The hash in the name is what makes "the same version with different content"
    impossible to confuse, which is the hole every analysis of `requirements.txt`
    points out. Inside it goes `<name>/`, because a package root is a directory
    whose children are package names."""
    return path.join(STORE, name + "-" + version + "-" + sha[0:12])


async def extract_package(b: bytes, dest: str, name: str) -> int:
    """Unpacks the tarball into `<dest>/<name>/`, stripping the prefix it was
    packed with (`<name>-<version>/`).

    Swapping the prefix is what lets the directory serve as a package root
    without anybody having to know the version: `import <sha2/sha2.ph>` looks for
    `sha2/` and that is what is there."""
    members = tar.read(b)
    n = 0
    for m in members:
        parts = m.name.split("/")
        if len(parts) < 2:
            continue        # the top-level directory: `name` replaces it
        rest = "/".join(parts[1:len(parts)])
        target = path.join(dest, name, rest)
        if m.kind == "dir":
            if not path.isdir(target):
                os.makedirs(target)
            continue
        await write_bytes(target, m.data)
        n += 1
    return n


def installed_roots() -> List<str>:
    """The package roots `install` materialized. They go into `--pkg-path`
    alongside the workspace's — and after them, because what is in the tree wins
    over what came from outside."""
    out: List<str> = []
    if not path.isdir(STORE):
        return out
    for name in sorted(os.listdir(STORE)):
        if name.startswith("."):
            continue
        d = path.join(STORE, name)
        if path.isdir(d):
            out.append(d)
    return out


# ---------- the keys and the two signatures ----------
#
# There are TWO, with different owners and for different reasons (DESIGN 2.12):
#
#   * the INDEX is signed by the REPOSITORY, and it is what stops somebody in the
#     middle from answering with an old list — the one where the version with the
#     flaw is still the most recent. Without this, each package's hash still holds
#     and you still install the wrong version, in good faith;
#   * each VERSION is signed by the AUTHOR, and it is what stops the repository
#     itself from serving a tarball the author did not make.
#
# The PRIVATE key is a 32-byte seed in hexadecimal, in a file and nothing else. It
# does not go to `build/` — it is not derivable from anything and `make clean`
# would take it — and it does not go to the repository: it is the one thing here
# that is not committed.

async def read_seed(file: str) -> bytes:
    """The private key from a file. It accepts the hexadecimal with spaces and
    newlines around it, because a key file tends to be copied by hand."""
    if not path.isfile(file):
        raise error("I did not find the key in " + file, IO)
    f = await open(file, "r")
    t = (await f.text()).strip()
    await f.close()
    if len(t) != 64:
        raise error(file + f": a private key is 64 hexadecimal digits (32 bytes), and this one has {len(t)}", VALUE)
    b: List<u8> = []
    i = 0
    while i < 64:
        v = dehex(t[i]) * 16 + dehex(t[i + 1])
        if v < 0:
            raise error(file + ": this is not hexadecimal", VALUE)
        b.append(u8(v))
        i += 2
    return bytes(b)


private def dehex(c: str) -> int:
    n = ord(c)
    if n >= 48 and n <= 57:
        return n - 48
    if n >= 97 and n <= 102:
        return n - 87
    if n >= 65 and n <= 70:
        return n - 55
    return -1000


async def new_seed() -> bytes:
    """Thirty-two bytes from `/dev/urandom`, and from nowhere else.

    The language's `random` is a generator for simulation: fast, reproducible and
    completely predictable to anyone who sees two outputs. A private key drawn
    from it is a key you can guess. If there is no `/dev/urandom`, this FAILS —
    inventing an alternative would be the worst thing this file could do.

    This used to open the file here. `csprng` is the same source with the two
    failures handled once instead of once per caller: it raises when the source
    is missing, and it KEEPS READING on a short read rather than treating it as
    one — a key with less entropy than the caller believes it has is the bug this
    file cannot afford."""
    return await csprng.random_bytes(32)


def public_key(seed: bytes) -> str:
    return ed25519_pub_hex(seed)


def sign(seed: bytes, data: bytes) -> str:
    return ed25519_sign_hex(seed, data)


def verify_sig(pub_hex: str, data: bytes, sig_hex: str) -> bool:
    """From the verifier's point of view, a damaged file, a signature that is not
    hexadecimal and a wrong signature are the SAME answer."""
    if len(pub_hex) != 64 or len(sig_hex) != 128:
        return False
    return ed25519_verify_hex(pub_hex, data, sig_hex)


async def signature_of(r: Repo, rel: str) -> str:
    """The signature that accompanies a file from the repository, or "" when
    there is none.

    Its absence is NOT an error here: whoever called decides what to do with it,
    because the answer depends on the mode — in safe mode it is a refusal, in
    unsafe mode a warning."""
    try:
        b = await fetch(r, rel + ".sig")
        return str(b).strip()
    catch e:
        return ""


def index_keys(ix: Index) -> List<str>:
    """The author keys the index declares, without repetition.

    TOFU needs them for a small and important reason: accepting a key the first
    time is not accepting ANYTHING. The index's signature has to match some key
    the index itself names — otherwise what arrived is not even internally
    coherent, and that is not "an unknown key", it is a wrong signature."""
    out: List<str> = []
    for name in ix.names():
        for v in ix.versions(name):
            a = ix.get(name, v).author
            if len(a) == 64 and a not in out:
                out.append(a)
    return out
