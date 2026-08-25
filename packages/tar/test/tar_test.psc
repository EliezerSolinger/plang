"""Write, read back, and refuse what has to be refused.

The gate that matters most is not here: it is the system's `tar` opening ours
(`bash packages/tar/test/sistema.sh`). This one checks the whole round trip
without leaving home, and above all checks the REFUSALS — which are the reason the
reader exists.
"""

import <tar/tar.psc> as tar

e: List<int> = [0, 0]


def check(name: str, cond: bool):
    if cond:
        e[0] += 1
    else:
        e[1] += 1
        print("  FAILED: " + name)


def bs(s: str) -> bytes:
    # 135.7: `s.encode()` IS this — the UTF-8 the string already holds, with
    # the promise taken off. The package keeps `bytes_of` because its header
    # builder wants a LIST it can index; a caller wants the value.
    return s.encode()


def txt(b: bytes) -> str:
    return str(b)


# ---------- the round trip ----------
ms: List<tar.Member> = [
    tar.directory("pkg", 0o755, 1700000000),
    tar.file("pkg/pack.json", bs("{\"name\": \"x\"}"), 0o644, 1700000001),
    tar.file("pkg/empty.txt", bs(""), 0o644, 1700000002),
    # exactly 512 bytes: the size where the padding is zero and an inattentive
    # reader adds one block too many
    tar.file("pkg/exact.bin", bs("z" * 512), 0o600, 1700000003),
    tar.file("pkg/accented-café.txt", bs("naïve"), 0o644, 1700000004),
]
b = tar.write(ms)
check("the tarball is a multiple of 512", len(b) % 512 == 0)
back = tar.read(b)
check("the same number of members", len(back) == len(ms))
check("the directory came back as a directory", back[0].kind == "dir" and back[0].name == "pkg/")
check("the content came back", txt(back[1].data) == "{\"name\": \"x\"}")
check("the mode came back", back[1].mode == 0o644)
check("the mtime came back", back[1].mtime == 1700000001)
check("an empty file is a file", back[2].name == "pkg/empty.txt" and len(back[2].data) == 0)
check("exactly 512 bytes", len(back[3].data) == 512 and back[3].mode == 0o600)
check("the accented name came back", back[4].name == "pkg/accented-café.txt")
check("the accented content came back", txt(back[4].data) == "naïve")

# ---------- the long name, through the prefix ----------
long_name = "package-with-a-long-name/" + ("dir/" * 20) + "file.txt"
b2 = tar.write([tar.file(long_name, bs("k"), 0o644, 1700000000)])
v2 = tar.read(b2)
check("a name over 100 bytes, through the prefix", v2[0].name == long_name)

# ---------- the refusals ----------
def refuses(name: str, f: def() -> int) -> bool:
    try:
        f()
        return False
    catch err:
        return True


def absolute_path() -> int:
    return len(tar.read(tar.write([tar.file("/etc/passwd", bs("x"), 0o644, 1)])))


def climbs_out() -> int:
    return len(tar.read(tar.write([tar.file("a/../../etc/passwd", bs("x"), 0o644, 1)])))


def wrong_checksum() -> int:
    bad = list(tar.write([tar.file("a.txt", bs("x"), 0o644, 1)]))
    bad[0] = u8(ord("b"))          # change the name without touching the checksum
    return len(tar.read(bytes(bad)))


def wrong_magic() -> int:
    bad = list(tar.write([tar.file("a.txt", bs("x"), 0o644, 1)]))
    bad[257] = u8(ord("g"))
    return len(tar.read(bytes(bad)))


def refused_kind() -> int:
    bad = list(tar.write([tar.file("a.txt", bs("x"), 0o644, 1)]))
    bad[156] = u8(ord("2"))        # symbolic link
    sum = 0
    for i in range(512):
        sum += 32 if i >= 148 and i < 156 else int(bad[i])
    d = tar.octal(sum, 7)
    j = 0
    for ch in d:
        bad[148 + j] = u8(ord(ch))
        j += 1
    return len(tar.read(bytes(bad)))


def ends_halfway() -> int:
    whole = tar.write([tar.file("a.txt", bs("x" * 600), 0o644, 1)])
    # a WINDOW over the first 700 bytes: no copy, and it says exactly what the
    # test means — the same tarball, ending early (135.1)
    return len(tar.read(whole[0:700]))


check("refuses an absolute path", refuses("abs", absolute_path))
check("refuses `..`", refuses("..", climbs_out))
check("refuses a wrong checksum", refuses("cks", wrong_checksum))
check("refuses a wrong magic", refuses("magic", wrong_magic))
check("refuses a symbolic link", refuses("link", refused_kind))
check("refuses a truncated tarball", refuses("short", ends_halfway))

print(f"tar: {e[0]} ok, {e[1]} failed")
