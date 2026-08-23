"""`pack.lock`: the PROVENANCE of what this project uses.

It is committed, and that is the decision that makes the rest work. A `build/`
you can delete without fear, a checkout you clone and that builds the same, and —
the part that is not obvious — a **TOFU better than SSH's**: the key you accepted
the first time lives here, versioned. Whoever clones the project inherits the
accepted key; a key that changes shows up in the DIFF and goes through code
review, instead of through a warning on one person's terminal at eleven at night,
in a hurry.

    {
      "format": 1,
      "repos": { "file:///tmp/repo/": { "key": "", "first_seen": "2026-08-22" } },
      "packages": [
        { "name": "sha2", "version": "0.1.0", "sha256": "9f2c…",
          "repo": "file:///tmp/repo/", "file": "pkg/sha2/sha2-0.1.0.tar",
          "unsafe": true, "toolchain": ">= 0.1.0" }
      ]
    }

The `sha256` is NEVER missing, not even in unsafe mode: "unsafe" means nobody
signed it, not that the content goes unchecked. The `unsafe` field is recorded
precisely so that whoever reviews the PR can see it.
"""
import json
import path
import lib_repo as R

struct Locked:
    name: str
    version: str
    sha256: str
    repo: str
    file: str
    is_unsafe: bool
    toolchain: str

struct KnownRepo:
    url: str
    key: str
    first_seen: str

struct Lock:
    format: int
    repos: list<KnownRepo>
    packages: list<Locked>

    def find(self, name: str) -> int:
        i = 0
        while i < len(self.packages):
            if self.packages[i].name == name:
                return i
            i += 1
        return -1

    def known_repo(self, url: str) -> int:
        i = 0
        while i < len(self.repos):
            if self.repos[i].url == url:
                return i
            i += 1
        return -1


def new_lock() -> Lock:
    return Lock(1, [], [])


private def txt(d: dict<str, any>, k: str) -> str:
    if k not in d:
        return ""
    return d[k] as str


private def flag(d: dict<str, any>, k: str) -> bool:
    if k not in d:
        return False
    return d[k] as bool


async def read(file: str) -> Lock:
    lk = new_lock()
    if not path.isfile(file):
        return lk
    f = await open(file, "r")
    raw = await f.text()
    await f.close()
    try:
        d = json.parse(raw) as dict<str, any>
        if "repos" in d:
            rr = d["repos"] as dict<str, any>
            urls: list<str> = []
            for u in rr:
                urls.append(u)
            for url in sorted(urls):
                e = rr[url] as dict<str, any>
                lk.repos.append(KnownRepo(url, txt(e, "key"), txt(e, "first_seen")))
        if "packages" in d:
            for item in d["packages"] as list<any>:
                e2 = item as dict<str, any>
                lk.packages.append(Locked(txt(e2, "name"), txt(e2, "version"), txt(e2, "sha256"),
                                          txt(e2, "repo"), txt(e2, "file"),
                                          flag(e2, "unsafe"), txt(e2, "toolchain")))
    catch err:
        raise error(file + ": " + err.message, VALUE)
    return lk


private def esc(s: str) -> str:
    out = "\""
    for ch in s:
        if ch == "\"" or ch == "\\":
            out += "\\" + ch
        else:
            out += ch
    return out + "\""


def text(lk: Lock) -> str:
    """The lock as text. SORTED, always: a lock whose order depends on a `dict`
    produces a different diff on every run, and a diff that changes without
    anything changing is a diff nobody reads."""
    b = "{\n  \"format\": 1,\n  \"repos\": {"
    p = True
    ordered: list<str> = []
    for r in lk.repos:
        ordered.append(r.url)
    for url in sorted(ordered):
        i = lk.known_repo(url)
        r = lk.repos[i]
        b += "" if p else ","
        p = False
        b += "\n    " + esc(r.url) + ": {\"key\": " + esc(r.key) + ", \"first_seen\": " + esc(r.first_seen) + "}"
    b += "\n  }" if not p else "}"
    b += ",\n  \"packages\": ["
    names: list<str> = []
    for x in lk.packages:
        names.append(x.name)
    p2 = True
    for name in sorted(names):
        t = lk.packages[lk.find(name)]
        b += "" if p2 else ","
        p2 = False
        b += "\n    {\"name\": " + esc(t.name) + ", \"version\": " + esc(t.version)
        b += ", \"sha256\": " + esc(t.sha256) + ", \"repo\": " + esc(t.repo)
        b += ", \"file\": " + esc(t.file)
        b += ", \"unsafe\": " + ("true" if t.is_unsafe else "false")
        b += ", \"toolchain\": " + esc(t.toolchain) + "}"
    b += "\n  ]" if not p2 else "]"
    return b + "\n}\n"


async def write(lk: Lock, file: str):
    await R.write_bytes(file, R.bytes_of_text(text(lk)))
