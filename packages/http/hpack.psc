"""HPACK (RFC 7541) — the header compression HTTP/2 speaks.

HTTP/2 does not send header names as text. It sends indices into two tables, and
for anything not in a table, a length-prefixed string that is usually Huffman
coded. That is the whole of it, and it exists because a browser opening one page
sends `user-agent` fifty times.

**The two tables are one address space, and that is the design.** Index 1..61 is
the STATIC table (Appendix A), fixed forever; from 62 up is the DYNAMIC table,
which both ends build as they go and which must stay identical on the two sides
or every later header decodes to garbage. That shared-state-by-construction is
what makes HPACK fast and what makes a decoder bug silent rather than loud — the
first wrong entry poisons everything after it, on a connection that is still
open.

Three things follow from that, and each one is a refusal here:

  * **the dynamic table is a FIFO of a declared size**, and inserting evicts from
    the back until it fits. An entry costs `len(name) + len(value) + 32`, and the
    32 is in the RFC precisely so that a flood of empty headers cannot be free;
  * **an index of 0 is not a header**, and an index past the end is not either.
    Both are a connection error, because the tables have already diverged;
  * **the EOS symbol must not appear in a Huffman string**, and the padding at
    the end has to be the most significant bits of EOS and no longer than seven
    bits. Anything else is a way of smuggling a second meaning into the same
    bytes, and RFC 7541 §5.2 says to treat it as an error.

**The Huffman code is CANONICAL**, so decoding does not need a 64K lookup table:
symbols sorted by (length, code) are contiguous, and at each length the first
code and the first symbol index are all that is needed to turn a run of bits into
a symbol. It costs 31 entries of bookkeeping instead of 65 536, and the loop is
the textbook one.

Both tables in this file were EXTRACTED from the text of RFC 7541 and checked —
61 static entries, 257 symbols, lengths 5..30, canonical and prefix-free, and the
worked example in the RFC itself (`/` is 0x18 in six bits) reproduced. Typing
them by hand is how a decoder acquires one wrong row that only some peer trips.
"""
from <http/http.psc> import Header


# The static table (Appendix A): index 1..61, name and value side by side.
const STATIC_NAME: List<str> = [
    ":authority", ":method", ":method", ":path",
    ":path", ":scheme", ":scheme", ":status",
    ":status", ":status", ":status", ":status",
    ":status", ":status", "accept-charset", "accept-encoding",
    "accept-language", "accept-ranges", "accept", "access-control-allow-origin",
    "age", "allow", "authorization", "cache-control",
    "content-disposition", "content-encoding", "content-language", "content-length",
    "content-location", "content-range", "content-type", "cookie",
    "date", "etag", "expect", "expires",
    "from", "host", "if-match", "if-modified-since",
    "if-none-match", "if-range", "if-unmodified-since", "last-modified",
    "link", "location", "max-forwards", "proxy-authenticate",
    "proxy-authorization", "range", "referer", "refresh",
    "retry-after", "server", "set-cookie", "strict-transport-security",
    "transfer-encoding", "user-agent", "vary", "via",
    "www-authenticate"
]

const STATIC_VALUE: List<str> = [
    "", "GET", "POST", "/",
    "/index.html", "http", "https", "200",
    "204", "206", "304", "400",
    "404", "500", "", "gzip, deflate",
    "", "", "", "",
    "", "", "", "",
    "", "", "", "",
    "", "", "", "",
    "", "", "", "",
    "", "", "", "",
    "", "", "", "",
    "", "", "", "",
    "", "", "", "",
    "", "", "", "",
    "", "", "", "",
    ""
]

# The Huffman code (Appendix B), and the four arrays that decode it.
#
# `HUFF_CODE`/`HUFF_LEN` are the RFC's own table, indexed by symbol, and they are
# what the ENCODER reads. The other four are the canonical decoder's bookkeeping:
# symbols sorted by (length, code) in `HUFF_SYM`, and for each length the first
# code, where that length's run starts, and how many there are. A code of length
# L is then a subtraction and one array read — 31 entries of bookkeeping instead
# of a 65 536-entry lookup.
#
# They are CONSTANTS and not built at startup, and that is not only about the
# import rule: derived at run time they would be a mutable module global, which
# 42.2 makes worker-local — so every worker would rebuild the same table. The
# generator that emits this checked that reconstructing the 257 codes canonically
# reproduces the RFC exactly, which is the property that makes the short decoder
# legitimate.
const HUFF_CODE: List<int> = [
    0x1ff8, 0x7fffd8, 0xfffffe2, 0xfffffe3, 0xfffffe4, 0xfffffe5, 0xfffffe6, 0xfffffe7, 0xfffffe8, 0xffffea,
    0x3ffffffc, 0xfffffe9, 0xfffffea, 0x3ffffffd, 0xfffffeb, 0xfffffec, 0xfffffed, 0xfffffee, 0xfffffef, 0xffffff0,
    0xffffff1, 0xffffff2, 0x3ffffffe, 0xffffff3, 0xffffff4, 0xffffff5, 0xffffff6, 0xffffff7, 0xffffff8, 0xffffff9,
    0xffffffa, 0xffffffb, 0x14, 0x3f8, 0x3f9, 0xffa, 0x1ff9, 0x15, 0xf8, 0x7fa,
    0x3fa, 0x3fb, 0xf9, 0x7fb, 0xfa, 0x16, 0x17, 0x18, 0x0, 0x1,
    0x2, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x5c, 0xfb,
    0x7ffc, 0x20, 0xffb, 0x3fc, 0x1ffa, 0x21, 0x5d, 0x5e, 0x5f, 0x60,
    0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a,
    0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72, 0xfc, 0x73,
    0xfd, 0x1ffb, 0x7fff0, 0x1ffc, 0x3ffc, 0x22, 0x7ffd, 0x3, 0x23, 0x4,
    0x24, 0x5, 0x25, 0x26, 0x27, 0x6, 0x74, 0x75, 0x28, 0x29,
    0x2a, 0x7, 0x2b, 0x76, 0x2c, 0x8, 0x9, 0x2d, 0x77, 0x78,
    0x79, 0x7a, 0x7b, 0x7ffe, 0x7fc, 0x3ffd, 0x1ffd, 0xffffffc, 0xfffe6, 0x3fffd2,
    0xfffe7, 0xfffe8, 0x3fffd3, 0x3fffd4, 0x3fffd5, 0x7fffd9, 0x3fffd6, 0x7fffda, 0x7fffdb, 0x7fffdc,
    0x7fffdd, 0x7fffde, 0xffffeb, 0x7fffdf, 0xffffec, 0xffffed, 0x3fffd7, 0x7fffe0, 0xffffee, 0x7fffe1,
    0x7fffe2, 0x7fffe3, 0x7fffe4, 0x1fffdc, 0x3fffd8, 0x7fffe5, 0x3fffd9, 0x7fffe6, 0x7fffe7, 0xffffef,
    0x3fffda, 0x1fffdd, 0xfffe9, 0x3fffdb, 0x3fffdc, 0x7fffe8, 0x7fffe9, 0x1fffde, 0x7fffea, 0x3fffdd,
    0x3fffde, 0xfffff0, 0x1fffdf, 0x3fffdf, 0x7fffeb, 0x7fffec, 0x1fffe0, 0x1fffe1, 0x3fffe0, 0x1fffe2,
    0x7fffed, 0x3fffe1, 0x7fffee, 0x7fffef, 0xfffea, 0x3fffe2, 0x3fffe3, 0x3fffe4, 0x7ffff0, 0x3fffe5,
    0x3fffe6, 0x7ffff1, 0x3ffffe0, 0x3ffffe1, 0xfffeb, 0x7fff1, 0x3fffe7, 0x7ffff2, 0x3fffe8, 0x1ffffec,
    0x3ffffe2, 0x3ffffe3, 0x3ffffe4, 0x7ffffde, 0x7ffffdf, 0x3ffffe5, 0xfffff1, 0x1ffffed, 0x7fff2, 0x1fffe3,
    0x3ffffe6, 0x7ffffe0, 0x7ffffe1, 0x3ffffe7, 0x7ffffe2, 0xfffff2, 0x1fffe4, 0x1fffe5, 0x3ffffe8, 0x3ffffe9,
    0xffffffd, 0x7ffffe3, 0x7ffffe4, 0x7ffffe5, 0xfffec, 0xfffff3, 0xfffed, 0x1fffe6, 0x3fffe9, 0x1fffe7,
    0x1fffe8, 0x7ffff3, 0x3fffea, 0x3fffeb, 0x1ffffee, 0x1ffffef, 0xfffff4, 0xfffff5, 0x3ffffea, 0x7ffff4,
    0x3ffffeb, 0x7ffffe6, 0x3ffffec, 0x3ffffed, 0x7ffffe7, 0x7ffffe8, 0x7ffffe9, 0x7ffffea, 0x7ffffeb, 0xffffffe,
    0x7ffffec, 0x7ffffed, 0x7ffffee, 0x7ffffef, 0x7fffff0, 0x3ffffee, 0x3fffffff
]

const HUFF_LEN: List<int> = [
    13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28, 28, 28, 28, 28,
    28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 28, 6, 10, 10, 12, 13, 6, 8, 11,
    10, 10, 8, 11, 8, 6, 6, 6, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 7, 8,
    15, 6, 12, 10, 13, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 8, 7, 8, 13, 19, 13, 14, 6, 15, 5, 6, 5,
    6, 5, 6, 6, 6, 5, 7, 7, 6, 6, 6, 5, 6, 7, 6, 5, 5, 6, 7, 7,
    7, 7, 7, 15, 11, 14, 13, 28, 20, 22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23,
    23, 23, 24, 23, 24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24,
    22, 21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23, 21, 21, 22, 21,
    23, 22, 23, 23, 20, 22, 22, 22, 23, 22, 22, 23, 26, 26, 20, 19, 22, 23, 22, 25,
    26, 26, 26, 27, 27, 26, 24, 25, 19, 21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26,
    28, 27, 27, 27, 20, 24, 20, 21, 22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23,
    26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27, 27, 27, 27, 26, 30
]

const HUFF_SYM: List<int> = [
    48, 49, 50, 97, 99, 101, 105, 111, 115, 116, 32, 37, 45, 46, 47, 51, 52, 53, 54, 55,
    56, 57, 61, 65, 95, 98, 100, 102, 103, 104, 108, 109, 110, 112, 114, 117, 58, 66, 67, 68,
    69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 89,
    106, 107, 113, 118, 119, 120, 121, 122, 38, 42, 44, 59, 88, 90, 33, 34, 40, 41, 63, 39,
    43, 124, 35, 62, 0, 36, 64, 91, 93, 126, 94, 125, 60, 96, 123, 92, 195, 208, 128, 130,
    131, 162, 184, 194, 224, 226, 153, 161, 167, 172, 176, 177, 179, 209, 216, 217, 227, 229, 230, 129,
    132, 133, 134, 136, 146, 154, 156, 160, 163, 164, 169, 170, 173, 178, 181, 185, 186, 187, 189, 190,
    196, 198, 228, 232, 233, 1, 135, 137, 138, 139, 140, 141, 143, 147, 149, 150, 151, 152, 155, 157,
    158, 165, 166, 168, 174, 175, 180, 182, 183, 188, 191, 197, 231, 239, 9, 142, 144, 145, 148, 159,
    171, 206, 215, 225, 236, 237, 199, 207, 234, 235, 192, 193, 200, 201, 202, 205, 210, 213, 218, 219,
    238, 240, 242, 243, 255, 203, 204, 211, 212, 214, 221, 222, 223, 241, 244, 245, 246, 247, 248, 250,
    251, 252, 253, 254, 2, 3, 4, 5, 6, 7, 8, 11, 12, 14, 15, 16, 17, 18, 19, 20,
    21, 23, 24, 25, 26, 27, 28, 29, 30, 31, 127, 220, 249, 10, 13, 22, 256
]

const HUFF_FIRST: List<int> = [
    0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x14, 0x5c, 0xf8, 0x1fc,
    0x3f8, 0x7fa, 0xffa, 0x1ff8, 0x3ffc, 0x7ffc, 0xfffe, 0x1fffc, 0x3fff8, 0x7fff0,
    0xfffe6, 0x1fffdc, 0x3fffd2, 0x7fffd8, 0xffffea, 0x1ffffec, 0x3ffffe0, 0x7ffffde, 0xfffffe2, 0x1ffffffe,
    0x3ffffffc
]

const HUFF_BASE: List<int> = [
    0, 0, 0, 0, 0, 0, 10, 36, 68, 74, 74, 79, 82, 84, 90, 92,
    95, 95, 95, 95, 98, 106, 119, 145, 174, 186, 190, 205, 224, 253, 253
]

const HUFF_COUNT: List<int> = [
    0, 0, 0, 0, 0, 10, 26, 32, 6, 0, 5, 3, 2, 6, 2, 3,
    0, 0, 0, 3, 8, 13, 26, 29, 12, 4, 15, 19, 29, 0, 4
]

const MAX_CODE_LEN: int = 30


def huff_decode(src: bytes, start: int, n: int) -> str:
    """The bits of `src[start:start+n]` as text.

    Refuses three things, and each is RFC 7541 §5.2 rather than taste: a code
    that never completes, the EOS symbol appearing in the data, and padding that
    is not the leading bits of EOS or is eight bits or longer — because eight
    bits of padding is a byte that could have been left out.
    """
    out: List<u8> = []
    acc = 0          # the bits read and not yet consumed, most significant first
    nbits = 0
    i = start
    stop = start + n
    while i < stop:
        acc = (acc << 8) | int(src[i])
        nbits += 8
        i += 1
        # as many symbols as these bits complete
        keep = True
        while keep:
            keep = False
            L = 5
            while L <= MAX_CODE_LEN and L <= nbits:
                cand = (acc >> (nbits - L)) & ((1 << L) - 1)
                if HUFF_COUNT[L] > 0 and cand - HUFF_FIRST[L] < HUFF_COUNT[L] and cand >= HUFF_FIRST[L]:
                    sym = HUFF_SYM[HUFF_BASE[L] + cand - HUFF_FIRST[L]]
                    if sym == 256:
                        raise error("hpack: the EOS symbol is not allowed inside a Huffman string (RFC 7541 5.2)", VALUE)
                    out.append(u8(sym))
                    nbits -= L
                    acc = acc & ((1 << nbits) - 1) if nbits > 0 else 0
                    keep = True
                    break
                L += 1
    # what is left has to be padding: fewer than eight bits, and all ones —
    # which is what the most significant bits of EOS are
    if nbits >= 8:
        raise error("hpack: a Huffman string ends with a whole byte of padding", VALUE)
    if nbits > 0:
        pad = acc & ((1 << nbits) - 1)
        if pad != (1 << nbits) - 1:
            raise error("hpack: the padding of a Huffman string has to be the leading bits of EOS (RFC 7541 5.2)", VALUE)
    return str(bytes(out))


def huff_len(s: str) -> int:
    """How many BYTES `s` takes Huffman coded, padding included."""
    nb = 0
    for b in s.encode():
        nb += HUFF_LEN[int(b)]
    return (nb + 7) // 8


def huff_encode(out: List<u8>, s: str):
    acc = 0
    nbits = 0
    for b in s.encode():
        sym = int(b)
        acc = (acc << HUFF_LEN[sym]) | HUFF_CODE[sym]
        nbits += HUFF_LEN[sym]
        while nbits >= 8:
            out.append(u8((acc >> (nbits - 8)) & 0xFF))
            nbits -= 8
            acc = acc & ((1 << nbits) - 1) if nbits > 0 else 0
    if nbits > 0:
        # pad with the leading bits of EOS, which are all ones
        out.append(u8(((acc << (8 - nbits)) | ((1 << (8 - nbits)) - 1)) & 0xFF))


# ---------- the dynamic table ----------
#
# A FIFO with a size budget. `add` puts at the FRONT — index 62 is the most
# recent — and evicts from the back until the new entry fits. An entry costs its
# two strings plus 32 (RFC 7541 §4.1), and the 32 is there so that a thousand
# empty headers cannot be free.
struct Table:
    names: List<str>
    values: List<str>
    size: int          # what the entries currently cost
    cap: int           # what the peer said the budget is
    hard: int          # ... and what OUR settings allow it to raise it to


def new_table(cap: int) -> Table:
    return Table([], [], 0, cap, cap)


def entry_cost(name: str, value: str) -> int:
    return len(name.encode()) + len(value.encode()) + 32


def evict_to(t: Table, limit: int):
    while t.size > limit and len(t.names) > 0:
        last = len(t.names) - 1
        t.size -= entry_cost(t.names[last], t.values[last])
        # `pop` gives back what it removed and nothing wants it here: the two
        # halves were already read into the cost above
        _ = t.names.pop()
        _ = t.values.pop()


def table_resize(t: Table, cap: int):
    """A dynamic table size update (§6.3). It may not exceed what our SETTINGS
    allowed, and a peer that asks for more is not making a mistake we can absorb:
    it is describing a table we did not agree to keep."""
    if cap > t.hard:
        raise error("hpack: the peer asked for a dynamic table bigger than SETTINGS_HEADER_TABLE_SIZE", VALUE)
    t.cap = cap
    evict_to(t, cap)


def table_add(t: Table, name: str, value: str):
    cost = entry_cost(name, value)
    # §4.4: an entry larger than the whole table is not an error — it empties
    # the table and is then not stored. Refusing it here would break a peer
    # that is following the RFC.
    if cost > t.cap:
        evict_to(t, 0)
        return
    evict_to(t, t.cap - cost)
    t.names.insert(0, name)
    t.values.insert(0, value)
    t.size += cost


def table_get(t: Table, idx: int) -> Header:
    """Index 1..61 is static, 62.. is dynamic — ONE address space (§2.3.3)."""
    if idx <= 0:
        raise error("hpack: index 0 does not name a header field (RFC 7541 6.1)", VALUE)
    if idx <= 61:
        return Header(STATIC_NAME[idx - 1], STATIC_VALUE[idx - 1])
    d = idx - 62
    if d >= len(t.names):
        raise error("hpack: index " + str(idx) + " is past the end of the dynamic table", VALUE)
    return Header(t.names[d], t.values[d])


# ---------- integers and strings (§5) ----------
#
# An integer is written into the low N bits of a byte whose top bits belong to
# whatever instruction it is part of. If it fits, that is the whole of it; if it
# does not, those bits are all ones and the rest follows seven bits at a time.

struct Reader:
    src: bytes
    pos: int


def read_int(r: Reader, prefix: int) -> int:
    if r.pos >= len(r.src):
        raise error("hpack: the block ends where an integer should start", VALUE)
    mask = (1 << prefix) - 1
    v = int(r.src[r.pos]) & mask
    r.pos += 1
    if v < mask:
        return v
    shift = 0
    while True:
        if r.pos >= len(r.src):
            raise error("hpack: the block ends in the middle of an integer", VALUE)
        b = int(r.src[r.pos])
        r.pos += 1
        v += (b & 0x7F) << shift
        # a bound, and it is not arbitrary: an integer that needs more than this
        # is describing a length no message has, and unbounded shifting is how a
        # decoder is turned into an allocator
        if v > 0x7FFFFFFF:
            raise error("hpack: an integer this large cannot be a length", VALUE)
        if (b & 0x80) == 0:
            return v
        shift += 7


def read_str(r: Reader) -> str:
    if r.pos >= len(r.src):
        raise error("hpack: the block ends where a string should start", VALUE)
    huffed = (int(r.src[r.pos]) & 0x80) != 0
    n = read_int(r, 7)
    if r.pos + n > len(r.src):
        raise error("hpack: a string says it is longer than what is left of the block", VALUE)
    if huffed:
        s = huff_decode(r.src, r.pos, n)
        r.pos += n
        return s
    out: List<u8> = []
    for k in range(n):
        out.append(r.src[r.pos + k])
    r.pos += n
    return str(bytes(out))


def write_int(out: List<u8>, v: int, prefix: int, top: int):
    """`top` is what the instruction wants in the bits above the prefix."""
    mask = (1 << prefix) - 1
    if v < mask:
        out.append(u8(top | v))
        return
    out.append(u8(top | mask))
    v -= mask
    while v >= 0x80:
        out.append(u8((v & 0x7F) | 0x80))
        v = v >> 7
    out.append(u8(v))


def write_str(out: List<u8>, s: str):
    """Huffman when it is SHORTER, plain when it is not — which is what every
    encoder does, and what keeps a string of random bytes from growing."""
    raw = s.encode()
    hl = huff_len(s)
    if hl < len(raw):
        write_int(out, hl, 7, 0x80)
        huff_encode(out, s)
        return
    write_int(out, len(raw), 7, 0)
    for b in raw:
        out.append(b)


# ---------- a header block (§6) ----------
#
# Five instructions, told apart by their leading bits, and the order of the
# tests below is the order of the prefixes — a 4-bit form would be read as a
# 5-bit one if the wider test came first.
#
#   1xxxxxxx  indexed                       (§6.1)
#   01xxxxxx  literal, and INDEX it         (§6.2.1)
#   001xxxxx  dynamic table size update     (§6.3)
#   0001xxxx  literal, NEVER index it       (§6.2.3)
#   0000xxxx  literal, do not index it      (§6.2.2)

def decode(t: Table, block: bytes) -> List<Header>:
    r = Reader(block, 0)
    out: List<Header> = []
    # §4.2: a size update is only legal at the START of a block. Allowing it
    # anywhere would let a peer resize the table between two headers of the same
    # message, which is a state the two sides cannot agree on.
    started = False
    while r.pos < len(block):
        b = int(block[r.pos])
        if (b & 0x80) != 0:
            idx = read_int(r, 7)
            out.append(table_get(t, idx))
            started = True
        elif (b & 0xC0) == 0x40:
            ni = read_int(r, 6)
            nm = table_get(t, ni).name if ni > 0 else read_str(r)
            vl = read_str(r)
            table_add(t, nm, vl)
            out.append(Header(nm, vl))
            started = True
        elif (b & 0xE0) == 0x20:
            if started:
                raise error("hpack: a dynamic table size update may only come first in a block (RFC 7541 4.2)", VALUE)
            table_resize(t, read_int(r, 5))
        else:
            # the two literal forms that do NOT touch the table differ only in
            # what a PROXY may do with them: `never indexed` must be forwarded
            # as never-indexed, which is how a header holding a credential stays
            # out of every table on the path
            ni2 = read_int(r, 4)
            nm2 = table_get(t, ni2).name if ni2 > 0 else read_str(r)
            out.append(Header(nm2, read_str(r)))
            started = True
    return out


def encode(t: Table, fields: List<Header>) -> bytes:
    """Encodes with incremental indexing, except for what must never be indexed.

    The lookup is LINEAR over both tables, and that is a deliberate choice for
    this size: the static table is 61 entries and a dynamic table at the default
    4096 bytes holds a few dozen. An index would cost more to keep than it saves,
    and when it stops being true the measurement will say so.
    """
    out: List<u8> = []
    for f in fields:
        if never_index(f.name):
            write_int(out, 0, 4, 0x10)
            write_str(out, f.name)
            write_str(out, f.value)
            continue
        both = find_pair(t, f.name, f.value)
        if both > 0:
            write_int(out, both, 7, 0x80)
            continue
        just_name = find_name(t, f.name)
        write_int(out, just_name if just_name > 0 else 0, 6, 0x40)
        if just_name == 0:
            write_str(out, f.name)
        write_str(out, f.value)
        table_add(t, f.name, f.value)
    return bytes(out)


def never_index(name: str) -> bool:
    """What must not enter a table, and it is not a matter of privacy taste.

    A value that both varies with a secret and can be influenced by an attacker
    is what CRIME and BREACH exploit: the COMPRESSED LENGTH leaks whether a guess
    matched. `authorization` and `cookie` are the two that carry credentials, and
    they are the two the RFC's own security section (§7.1) names.
    """
    return name == "authorization" or name == "cookie" or name == "proxy-authorization"


# Two lookups and not one with an empty `value` meaning "any", because an empty
# value is a REAL value: `:path` with an empty value would have matched entry 4
# and gone out as `:path: /`, which is a different request. The bug is invisible
# until somebody sends an empty header, and then it is a wrong message on the
# wire with nothing in the logs.
def find_pair(t: Table, name: str, value: str) -> int:
    for i in range(61):
        if STATIC_NAME[i] == name and STATIC_VALUE[i] == value:
            return i + 1
    for j in range(len(t.names)):
        if t.names[j] == name and t.values[j] == value:
            return j + 62
    return 0


def find_name(t: Table, name: str) -> int:
    for i in range(61):
        if STATIC_NAME[i] == name:
            return i + 1
    for j in range(len(t.names)):
        if t.names[j] == name:
            return j + 62
    return 0
