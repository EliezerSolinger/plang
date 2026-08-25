"""`ustar`: the envelope, reading and writing.

A package travels as a `.tar` and nothing else — no compression, no format of our
own. There is one reason and it is worth the size difference: `tar tf package.tar`
works without this tool, and "what is inside this package?" is a question nobody
needs to ask our permission to answer.

What is here is POSIX's `ustar` and nothing more: a 512-byte header with the
fields in octal, the content in 512-byte blocks, two blocks of zeros at the end.
No links, no sparse files, no PAX, no GNU longname.

And READING REFUSES what it does not understand, instead of guessing. This is not
decorative rigour — it is the boundary where outside code comes in, and every
refusal here is a known attack that does not happen:

  * an ABSOLUTE path (`/etc/cron.d/x`) would write outside the tree;
  * a `..` in any component does the same by another route — that is *zip slip*,
    and the defence is to refuse the member, not to normalize the name;
  * a type that is neither a regular file nor a directory: a symbolic link inside
    a tarball is the same attack with more steps (you extract `a -> /etc`, and the
    next member writes into `a/passwd`);
  * a checksum that does not match, a `magic` that is not `ustar`, a size that is
    not octal, a block that ends halfway.

Each of them stops with an `error(...)` naming the member. An extractor that
"does the best it can" with a strange tarball is an extractor that does exactly
what the strange tarball wants.
"""

# ---------- what goes in and comes out ----------

struct Member:
    name: str          # relative, no `..`, with `/` as the separator
    kind: str          # "file" or "dir"
    mode: int          # the permissions, in binary (0o644, 0o755)
    mtime: int         # seconds since the epoch
    # 135.6: `bytes` is what CROSSES — it came from a read and it goes to a
    # hash, to a write or to P — and neither of those wants a list it could
    # change. What BUILDS the tarball below is still a `List<u8>`, because
    # building is what a list is for.
    data: bytes        # empty in a directory


def file(name: str, data: bytes, mode: int, mtime: int) -> Member:
    return Member(name, "file", mode, mtime, data)


def directory(name: str, mode: int, mtime: int) -> Member:
    return Member(name if name.endswith("/") else name + "/", "dir", mode, mtime, b"")


# ---------- bytes and text ----------

def bytes_of(s: str) -> List<u8>:
    """The text as UTF-8. A file name may carry an accent, and what goes into the
    header is BYTES — counting codepoints would give a length that is not the
    disk's.

    >>> len(bytes_of("abc"))
    3
    >>> len(bytes_of("naïve"))
    6
    """
    out: List<u8> = []
    for ch in s:
        cp = ord(ch)
        if cp < 0x80:
            out.append(u8(cp))
        elif cp < 0x800:
            out.append(u8(0xC0 | (cp >> 6)))
            out.append(u8(0x80 | (cp & 0x3F)))
        elif cp < 0x10000:
            out.append(u8(0xE0 | (cp >> 12)))
            out.append(u8(0x80 | ((cp >> 6) & 0x3F)))
            out.append(u8(0x80 | (cp & 0x3F)))
        else:
            out.append(u8(0xF0 | (cp >> 18)))
            out.append(u8(0x80 | ((cp >> 12) & 0x3F)))
            out.append(u8(0x80 | ((cp >> 6) & 0x3F)))
            out.append(u8(0x80 | (cp & 0x3F)))
    return out


# ---------- writing ----------

def octal(v: int, width: int) -> str:
    """A numeric ustar field: octal, right-aligned with zeros, and the last byte
    reserved for the NUL. `width` is the whole field.

    >>> octal(0o644, 8)
    0000644
    >>> octal(0, 12)
    00000000000
    """
    d = ""
    n = v
    if n < 0:
        raise error("a tar field is not negative: " + str(v), VALUE)
    while n > 0:
        d = str(n % 8) + d
        n = n // 8
    if d == "":
        d = "0"
    if len(d) > width - 1:
        raise error(f"does not fit in {width - 1} octal digits: {v}", VALUE)
    while len(d) < width - 1:
        d = "0" + d
    return d


private def put_bytes(block: List<u8>, pos: int, bs: List<u8>, width: int):
    if len(bs) > width:
        raise error("a header field does not fit", VALUE)
    i = 0
    for b in bs:
        block[pos + i] = b
        i += 1


private def put_text(block: List<u8>, pos: int, s: str, width: int):
    put_bytes(block, pos, bytes_of(s), width)


def header(m: Member) -> List<u8>:
    """A member's 512 bytes. The ustar `prefix` exists and is used: a name up to
    100 bytes goes whole into `name`, and more than that is split at a separator —
    which gives 255 and is enough for anything a package holds."""
    name_b = bytes_of(m.name)
    prefix = ""
    name = m.name
    if len(name_b) > 100:
        # split at the LAST `/` that leaves both halves within the limits
        cut = -1
        i = len(name) - 1
        while i > 0:
            if name[i] == "/" and len(bytes_of(name[i + 1:len(name)])) <= 100 and len(bytes_of(name[0:i])) <= 155:
                cut = i
                break
            i -= 1
        if cut < 0:
            raise error("the name does not fit in ustar (100 + 155 bytes): " + m.name, VALUE)
        prefix = name[0:cut]
        name = name[cut + 1:len(name)]

    b: List<u8> = []
    for _ in range(512):
        b.append(u8(0))
    put_text(b, 0, name, 100)
    put_text(b, 100, octal(m.mode, 8), 7)
    put_text(b, 108, octal(0, 8), 7)          # uid: always 0, see the note below
    put_text(b, 116, octal(0, 8), 7)          # gid
    put_text(b, 124, octal(len(m.data), 12), 11)
    put_text(b, 136, octal(m.mtime, 12), 11)
    # the checksum goes in afterwards; while it is summed, the field is EIGHT
    # SPACES
    for i in range(8):
        b[148 + i] = u8(32)
    b[156] = u8(53) if m.kind == "dir" else u8(48)   # '5' or '0'
    put_text(b, 257, "ustar", 6)
    b[262] = u8(0)
    put_text(b, 263, "00", 2)
    # owner and group: empty NAMES and ids 0. A source-code tarball carrying the
    # user of whoever made it is a tarball that changes when it changes machine —
    # and its hash is what guarantees distribution. Reproducible or verifiable:
    # you choose once, and it was chosen here.
    put_text(b, 329, octal(0, 8), 7)
    put_text(b, 337, octal(0, 8), 7)
    if prefix != "":
        put_text(b, 345, prefix, 155)
    sum = 0
    for x in b:
        sum += int(x)
    # six octal digits, NUL, space — the shape everyone reads
    put_text(b, 148, octal(sum, 7), 6)
    b[154] = u8(0)
    b[155] = u8(32)
    return b


def write(members: List<Member>) -> bytes:
    """The whole tarball in memory. A source-code package fits, and having all the
    bytes in hand is what allows hashing and writing in a single pass."""
    out: List<u8> = []
    for m in members:
        if m.name == "":
            raise error("a member with no name", VALUE)
        for b in header(m):
            out.append(b)
        for d in m.data:
            out.append(d)
        rest = len(m.data) % 512
        if rest != 0:
            for _ in range(512 - rest):
                out.append(u8(0))
    # the end marker: TWO blocks of zeros
    for _ in range(1024):
        out.append(u8(0))
    # ... and here is the one conversion (135.6): built in a list, handed over
    # as the value that crosses
    return bytes(out)


# ---------- reading ----------

private def text_until_nul(b: bytes, pos: int, width: int) -> str:
    i = 0
    while i < width and b[pos + i] != u8(0):
        i += 1
    # a WINDOW and then a decode: no list is built, and `str(bytes)` checks the
    # UTF-8 exactly as `str(List<u8>)` did (79.1)
    return str(b[pos:pos + i])


private def read_octal(b: bytes, pos: int, width: int, field: str) -> int:
    v = 0
    i = 0
    seen = False
    while i < width:
        c = int(b[pos + i])
        if c == 0 or c == 32:
            # spaces and NUL delimit; after them no more digits may come
            i += 1
            while i < width:
                c2 = int(b[pos + i])
                if c2 != 0 and c2 != 32:
                    raise error(f"the {field} field is not octal", VALUE)
                i += 1
            break
        if c < 48 or c > 55:
            raise error(f"the {field} field is not octal", VALUE)
        v = v * 8 + (c - 48)
        seen = True
        i += 1
    if not seen:
        return 0
    return v


def safe_name(name: str) -> str:
    """The refusal that matters most. Returns "" when the name is good, and the
    reason when it is not — so the caller can say WHICH member and WHY.

    >>> safe_name("pkg/README.md") == ""
    True
    >>> len(safe_name("/etc/passwd")) > 0
    True
    >>> len(safe_name("a/../../etc/passwd")) > 0
    True
    """
    if name == "":
        return "a member with no name"
    if name.startswith("/"):
        return "absolute path: " + name
    if len(name) > 1 and name[1] == ":":
        return "path with a drive letter: " + name
    for part in name.split("/"):
        if part == "..":
            return "the path climbs out of the destination: " + name
    if "\\" in name:
        return "a backslash in a member name: " + name
    return ""


def read(data: bytes) -> List<Member>:
    """The members, in order. Raises at the first thing it does not
    understand."""
    out: List<Member> = []
    pos = 0
    n = len(data)
    while pos + 512 <= n:
        # a block of all zeros is the end
        empty = True
        for i in range(512):
            if data[pos + i] != u8(0):
                empty = False
                break
        if empty:
            break
        # the checksum, with the field read as eight spaces
        declared = read_octal(data, pos + 148, 8, "checksum")
        sum = 0
        for i in range(512):
            sum += 32 if i >= 148 and i < 156 else int(data[pos + i])
        if sum != declared:
            raise error(f"wrong checksum in block {pos // 512}: {sum} != {declared}", VALUE)
        magic = text_until_nul(data, pos + 257, 6)
        if magic != "ustar":
            raise error("not ustar: " + magic, VALUE)
        name = text_until_nul(data, pos, 100)
        prefix = text_until_nul(data, pos + 345, 155)
        if prefix != "":
            name = prefix + "/" + name
        kind_b = int(data[pos + 156])
        # '\0' is the old spelling of "regular file" and counts; nothing else does
        if kind_b != 48 and kind_b != 0 and kind_b != 53:
            raise error(f"the member '{name}' is of type '{chr(kind_b) if kind_b > 32 else str(kind_b)}', and only files and directories come in here", VALUE)
        bad = safe_name(name)
        if bad != "":
            raise error(bad, VALUE)
        mode = read_octal(data, pos + 100, 8, "mode")
        size = read_octal(data, pos + 124, 12, "size")
        mtime = read_octal(data, pos + 136, 12, "mtime")
        pos += 512
        body = b""
        if kind_b == 53:
            if size != 0:
                raise error("a directory with content: " + name, VALUE)
        else:
            if pos + size > n:
                raise error("the tarball ends halfway through '" + name + "'", VALUE)
            # 135.1: a WINDOW over the tarball, not a copy of it. The member's
            # bytes are the tarball's bytes, and the tarball stays alive for as
            # long as any member does — which is what `owner` is for.
            body = data[pos:pos + size]
            pos += size
            rest = size % 512
            if rest != 0:
                pos += 512 - rest
        out.append(Member(name, "dir" if kind_b == 53 else "file", mode, mtime, body))
    return out
