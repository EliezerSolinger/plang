"""URL, the WHATWG one, ported from the reference implementation.

Not written from scratch and not invented: this is `whatwg-url`'s
`lib/url-state-machine.js` (MIT, jsdom) transcribed state for state, which is
itself a transcription of https://url.spec.whatwg.org. That is the point — the
corpus it is measured against (`tests/external/wpt-url/urltestdata.json`, 891
cases, the same file every browser is measured on) tests the WHATWG algorithm,
and nothing else would pass it.

Worth knowing, because it is the reason Python was not the source: `urllib.parse`
implements RFC 3986, which is a DIFFERENT specification. It disagrees with this
one about backslashes, about how many slashes `http:/example.com` needs, about
what a Windows drive letter means in a `file:` URL, and about whether a host
gets IDNA. Porting it would have produced a parser that fails the corpus for
reasons that are not bugs.

The one place this diverges from the reference, and it is named rather than
hidden: **IDNA**. `domain_to_ascii` here does the ASCII half of UTS-46 —
lowercasing, the forbidden-code-point check, and Punycode (RFC 3492) for labels
that need it — but not the Unicode mapping tables or NFC normalisation, which
are megabytes of data and belong in a `unicodedata` module this language does
not have yet. The cases that need them are listed in
`tests/conformance/url.skips`, with what they would take.

What is exposed is the parser and the serialiser, not a JavaScript object: no
setters, no `URLSearchParams`. A URL here is a value you parse and read.
"""

# ---------- what a URL is ----------

struct Url:
    scheme: str
    username: str
    password: str
    host: str            # already serialised; `has_host` says whether it exists
    has_host: bool
    port: int            # -1 when there is none
    path: List<str>      # the segments, when the path is not opaque
    opaque: str          # ... and the whole thing, when it is
    is_opaque: bool
    query: str
    has_query: bool
    fragment: str
    has_fragment: bool


def blank_url() -> Url:
    return Url("", "", "", "", False, -1, [], "", False, "", False, "", False)


# ---------- the small predicates the spec keeps referring to ----------

def is_alpha(c: int) -> bool:
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122)


def is_digit(c: int) -> bool:
    return c >= 48 and c <= 57


def is_alnum(c: int) -> bool:
    return is_alpha(c) or is_digit(c)


def is_hex(c: int) -> bool:
    return is_digit(c) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)


def hex_val(c: int) -> int:
    if is_digit(c):
        return c - 48
    if c >= 97 and c <= 102:
        return c - 87
    if c >= 65 and c <= 70:
        return c - 55
    return -1


def lower_c(c: int) -> int:
    return c + 32 if c >= 65 and c <= 90 else c


def lower(s: str) -> str:
    return s.lower()


# computed rather than indexed out of a module-level string: an IMPORTED module
# cannot hold a module-level value of a collected type today — building it would
# need a context, and a module has no entry point where one exists yet. Noted in
# PLAN.md, bateria 88.
def hex_digit(v: int) -> str:
    return chr(48 + v) if v < 10 else chr(55 + v)


def pct(c: int) -> str:
    return "%" + hex_digit(c // 16) + hex_digit(c % 16)


# The special schemes, and their default ports. `file` is special and has none.
def is_special_scheme(s: str) -> bool:
    return s == "ftp" or s == "file" or s == "http" or s == "https" or s == "ws" or s == "wss"


def default_port(s: str) -> int:
    if s == "ftp":
        return 21
    if s == "http" or s == "ws":
        return 80
    if s == "https" or s == "wss":
        return 443
    return -1


# ---------- percent encoding (url.spec.whatwg.org #percent-encoded-bytes) ----------
#
# The sets NEST: fragment ⊂ query ⊂ path ⊂ userinfo ⊂ component. Written as
# separate predicates rather than as sets of characters because that is how the
# spec reads and it is what makes each one checkable against the text.

def in_c0_set(c: int) -> bool:
    return c <= 0x1F or c > 0x7E


def in_fragment_set(c: int) -> bool:
    return in_c0_set(c) or c == 0x20 or c == 0x22 or c == 0x3C or c == 0x3E or c == 0x60


def in_query_set(c: int) -> bool:
    return in_c0_set(c) or c == 0x20 or c == 0x22 or c == 0x23 or c == 0x3C or c == 0x3E


def in_special_query_set(c: int) -> bool:
    return in_query_set(c) or c == 0x27


def in_path_set(c: int) -> bool:
    # `^` belongs HERE, not in the userinfo set — the first cut had it one level
    # down, which left `^` bare in a path and encoded everywhere else
    return in_query_set(c) or c == 0x3F or c == 0x5E or c == 0x60 or c == 0x7B or c == 0x7D


def in_userinfo_set(c: int) -> bool:
    if in_path_set(c):
        return True
    return c == 0x2F or c == 0x3A or c == 0x3B or c == 0x3D or c == 0x40 or c == 0x5B or c == 0x5C or c == 0x5D or c == 0x5E or c == 0x7C


# UTF-8 of one code point, percent-encoded byte by byte. The encoding happens on
# BYTES, never on the code point — this is the step that makes `é` into `%C3%A9`
# and not into `%E9`, which is the old, lossy, pre-Unicode answer.
def pct_encode_cp(cp: int) -> str:
    if cp < 0x80:
        return pct(cp)
    if cp < 0x800:
        return pct(0xC0 | (cp >> 6)) + pct(0x80 | (cp & 0x3F))
    if cp < 0x10000:
        return pct(0xE0 | (cp >> 12)) + pct(0x80 | ((cp >> 6) & 0x3F)) + pct(0x80 | (cp & 0x3F))
    return pct(0xF0 | (cp >> 18)) + pct(0x80 | ((cp >> 12) & 0x3F)) + pct(0x80 | ((cp >> 6) & 0x3F)) + pct(0x80 | (cp & 0x3F))


# Percent-DECODE, to bytes. What comes out is not text yet: a `%C3%A9` pair is
# two bytes that only mean `é` once somebody decodes UTF-8 over them.
def pct_decode(s: str) -> List<u8> :
    out: List<u8> = []
    i = 0
    n = len(s)
    while i < n:
        c = ord(s[i])
        if c != 0x25 or i + 2 >= n or not is_hex(ord(s[i + 1])) or not is_hex(ord(s[i + 2])):
            # not a valid escape: the `%` is itself, as the spec says
            for b in utf8_bytes(c):
                out.append(b)
            i += 1
        else:
            out.append(u8(hex_val(ord(s[i + 1])) * 16 + hex_val(ord(s[i + 2]))))
            i += 3
    return out


def utf8_bytes(cp: int) -> List<u8>:
    out: List<u8> = []
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


# ---------- code points in and out ----------

def codepoints(s: str) -> List<int>:
    out: List<int> = []
    for ch in s:
        out.append(ord(ch))
    return out


def from_codepoints(cs: List<int>) -> str:
    out = ""
    for c in cs:
        out += chr(c)
    return out


# ---------- IPv4 (url.spec.whatwg.org #concept-ipv4-parser) ----------
#
# The part everyone gets wrong, and the reason `http://0x7f.1` is a valid way to
# write `127.0.0.1`: a "number" here is decimal, octal with a leading `0`, or
# hexadecimal with a leading `0x`, and there may be one, two, three or four of
# them. A parser that only accepts dotted decimal disagrees with every browser.

record NumRes:
    ok: bool
    hex: bool
    value: int


def parse_ipv4_number(s: str) -> NumRes:
    bad: NumRes = NumRes(False, False, 0)
    if len(s) == 0:
        return bad
    r = 10
    t = s
    if len(t) >= 2 and t[0] == "0" and (t[1] == "x" or t[1] == "X"):
        t = t[2:len(t)]
        r = 16
    elif len(t) >= 2 and t[0] == "0":
        t = t[1:len(t)]
        r = 8
    if len(t) == 0:
        return NumRes(True, True, 0)
    v = 0
    for ch in t:
        d = hex_val(ord(ch))
        if d < 0 or d >= r:
            return bad
        v = v * r + d
        # The range check does NOT belong here — the spec puts it in the IPv4
        # parser, and the difference is visible: `http://0x100000000` refused
        # here reads as a DOMAIN named `0x100000000`, which then resolves like a
        # name, while refused there it is what it is, an address out of range.
        # So the number stays well-formed and merely large, and is clamped only
        # so that a very long digit string cannot overflow on the way.
        if v > 4294967296:
            v = 4294967296
    return NumRes(True, r != 10, v)


# -1 when the input is not an IPv4 address at all; the spec's `failure` is
# distinguished from "this is a domain" by the caller.
def parse_ipv4(input: str) -> int:
    parts = input.split(".")
    if len(parts) > 1 and parts[len(parts) - 1] == "":
        parts = parts[0:len(parts) - 1]
    if len(parts) > 4:
        return -1
    numbers: List<int> = []
    for p in parts:
        n = parse_ipv4_number(p)
        if not n.ok:
            return -1
        numbers.append(n.value)
    i = 0
    while i < len(numbers) - 1:
        if numbers[i] > 255:
            return -1
        i += 1
    cap = 1
    k = 0
    while k < 5 - len(numbers):
        cap = cap * 256
        k += 1
    if numbers[len(numbers) - 1] >= cap:
        return -1
    ipv4 = numbers[len(numbers) - 1]
    counter = 0
    j = 0
    while j < len(numbers) - 1:
        mul = 1
        m = 0
        while m < 3 - counter:
            mul = mul * 256
            m += 1
        ipv4 += numbers[j] * mul
        counter += 1
        j += 1
    return ipv4


def serialize_ipv4(address: int) -> str:
    out = ""
    n = address
    i = 1
    while i <= 4:
        out = str(n % 256) + out
        if i != 4:
            out = "." + out
        n = n // 256
        i += 1
    return out


# `ends in a number` decides whether a domain is really an IPv4 address: the
# LAST label being all digits, or a valid IPv4 number, is what makes
# `http://1.2.3.4` an address and `http://a.b.c.d` a name.
def ends_in_a_number(input: str) -> bool:
    parts = input.split(".")
    if len(parts) > 1 and parts[len(parts) - 1] == "":
        parts = parts[0:len(parts) - 1]
    if len(parts) == 0:
        return False
    last = parts[len(parts) - 1]
    if len(last) > 0:
        alldig = True
        for ch in last:
            if not is_digit(ord(ch)):
                alldig = False
        if alldig:
            return True
    return parse_ipv4_number(last).ok


# ---------- IPv6 ----------
# Returns the eight pieces, or None. Transcribed from the spec's state machine,
# including the embedded-IPv4 tail (`::ffff:1.2.3.4`) and the `::` compression.

def cp_at(cs: List<int>, k: int) -> int:
    return cs[k] if k >= 0 and k < len(cs) else -1


def parse_ipv6(input: str) -> List<int>:
    fail: List<int> = []
    address: List<int> = [0, 0, 0, 0, 0, 0, 0, 0]
    piece = 0
    compress = -1
    ptr = 0
    cs = codepoints(input)
    n = len(cs)

    if cp_at(cs, ptr) == 0x3A:
        if cp_at(cs, ptr + 1) != 0x3A:
            return fail
        ptr += 2
        piece += 1
        compress = piece
    while ptr < n:
        if piece == 8:
            return fail
        if cp_at(cs, ptr) == 0x3A:
            if compress >= 0:
                return fail
            ptr += 1
            piece += 1
            compress = piece
            continue
        value = 0
        length = 0
        while length < 4 and is_hex(cp_at(cs, ptr)):
            value = value * 16 + hex_val(cp_at(cs, ptr))
            ptr += 1
            length += 1
        if cp_at(cs, ptr) == 0x2E:
            if length == 0:
                return fail
            ptr -= length
            if piece > 6:
                return fail
            seen = 0
            while cp_at(cs, ptr) != -1:
                piece4 = -1
                if seen > 0:
                    if cp_at(cs, ptr) == 0x2E and seen < 4:
                        ptr += 1
                    else:
                        return fail
                if not is_digit(cp_at(cs, ptr)):
                    return fail
                while is_digit(cp_at(cs, ptr)):
                    number = cp_at(cs, ptr) - 48
                    if piece4 < 0:
                        piece4 = number
                    elif piece4 == 0:
                        return fail
                    else:
                        piece4 = piece4 * 10 + number
                    if piece4 > 255:
                        return fail
                    ptr += 1
                address[piece] = address[piece] * 256 + piece4
                seen += 1
                if seen == 2 or seen == 4:
                    piece += 1
            if seen != 4:
                return fail
            break
        elif cp_at(cs, ptr) == 0x3A:
            ptr += 1
            if cp_at(cs, ptr) == -1:
                return fail
        elif cp_at(cs, ptr) != -1:
            return fail
        address[piece] = value
        piece += 1
    if compress >= 0:
        swaps = piece - compress
        piece = 7
        while piece != 0 and swaps > 0:
            tmp = address[compress + swaps - 1]
            address[compress + swaps - 1] = address[piece]
            address[piece] = tmp
            piece -= 1
            swaps -= 1
    elif piece != 8:
        return fail
    return address


def serialize_ipv6(address: List<int>) -> str:
    # the longest run of zeroes, longer than one, is the one that becomes `::`
    longest = -1
    longest_size = 1
    found = -1
    found_size = 0
    i = 0
    while i < 8:
        if address[i] != 0:
            if found_size > longest_size:
                longest = found
                longest_size = found_size
            found = -1
            found_size = 0
        else:
            if found < 0:
                found = i
            found_size += 1
        i += 1
    if found_size > longest_size:
        longest = found
    out = ""
    ignore0 = False
    i = 0
    while i <= 7:
        if ignore0 and address[i] == 0:
            i += 1
            continue
        elif ignore0:
            ignore0 = False
        if longest == i:
            out += "::" if i == 0 else ":"
            ignore0 = True
            i += 1
            continue
        out += to_hex(address[i])
        if i != 7:
            out += ":"
        i += 1
    return out


def to_hex(v: int) -> str:
    if v == 0:
        return "0"
    out = ""
    n = v
    while n > 0:
        d = n % 16
        out = (chr(48 + d) if d < 10 else chr(87 + d)) + out
        n = n // 16
    return out


# ---------- host ----------
#
# Forbidden host code points, and the wider set forbidden in a DOMAIN. The
# difference matters: `%` is fine in an opaque host (it is percent-encoded) and
# forbidden in a domain, because a domain gets percent-DECODED first and a `%`
# surviving that means the input was malformed.

def forbidden_host_cp(c: int) -> bool:
    return c == 0x00 or c == 0x09 or c == 0x0A or c == 0x0D or c == 0x20 or c == 0x23 or c == 0x2F or c == 0x3A or c == 0x3C or c == 0x3E or c == 0x3F or c == 0x40 or c == 0x5B or c == 0x5C or c == 0x5D or c == 0x5E or c == 0x7C


def forbidden_domain_cp(c: int) -> bool:
    return forbidden_host_cp(c) or c <= 0x1F or c == 0x25 or c == 0x7F


# ---------- Punycode (RFC 3492), the ASCII half of IDNA ----------
#
# What it does NOT do is the Unicode half of UTS-46: the mapping tables that fold
# `Ⅎ` to `f` and the NFC normalisation. Those are data, not algorithm, and the
# data is megabytes. A label that needs them is on the skip list rather than
# quietly wrong.

const PUNY_BASE = 36
const PUNY_TMIN = 1
const PUNY_TMAX = 26
const PUNY_SKEW = 38
const PUNY_DAMP = 700
const PUNY_INITIAL_BIAS = 72
const PUNY_INITIAL_N = 128


def puny_adapt(delta: int, numpoints: int, firsttime: bool) -> int:
    d = delta // PUNY_DAMP if firsttime else delta // 2
    d += d // numpoints
    k = 0
    while d > ((PUNY_BASE - PUNY_TMIN) * PUNY_TMAX) // 2:
        d = d // (PUNY_BASE - PUNY_TMIN)
        k += PUNY_BASE
    return k + (((PUNY_BASE - PUNY_TMIN + 1) * d) // (d + PUNY_SKEW))


# RFC 3492 §5: 0..25 are `a`..`z`, 26..35 are `0`..`9`. The `+22` is what puts
# digit 26 on `0` (26 + 22 = 48). Getting this wrong turns `xn--n3h` into
# `xn--n~h` — a host that resolves to nothing, and the kind of mistake only a
# corpus catches, because both halves look equally plausible.
def puny_digit(d: int) -> str:
    return chr(d + 22) if d >= 26 else chr(d + 97)


# "" means the label cannot be encoded
def puny_encode(cps: List<int>) -> str:
    out = ""
    basic = 0
    for c in cps:
        if c < 128:
            out += chr(c)
            basic += 1
    h = basic
    if basic > 0:
        out += "-"
    n = PUNY_INITIAL_N
    delta = 0
    bias = PUNY_INITIAL_BIAS
    total = len(cps)
    while h < total:
        m = 0x7FFFFFFF
        for c in cps:
            if c >= n and c < m:
                m = c
        if m == 0x7FFFFFFF:
            return ""
        delta += (m - n) * (h + 1)
        n = m
        for c in cps:
            if c < n:
                delta += 1
            elif c == n:
                q = delta
                k = PUNY_BASE
                while True:
                    t = PUNY_TMIN if k <= bias else (PUNY_TMAX if k >= bias + PUNY_TMAX else k - bias)
                    if q < t:
                        break
                    out += puny_digit(t + ((q - t) % (PUNY_BASE - t)))
                    q = (q - t) // (PUNY_BASE - t)
                    k += PUNY_BASE
                out += puny_digit(q)
                bias = puny_adapt(delta, h + 1, h == basic)
                delta = 0
                h += 1
        delta += 1
        n += 1
    return out


# UTS-46's DISALLOWED set, to the extent it can be stated without the tables:
# the noncharacters and the replacement character. A domain containing one is a
# failure, not something to encode — and a parser that encodes it produces a
# name that looks legitimate and resolves to nothing, which is the shape of a
# spoofing bug rather than a typo.
def idna_disallowed(c: int) -> bool:
    if c == 0xFFFD:
        return True
    if c >= 0xFDD0 and c <= 0xFDEF:
        return True
    if (c & 0xFFFE) == 0xFFFE:          # U+xFFFE and U+xFFFF of every plane
        return True
    # the spaces. A host that reads as `GOO<nbsp>goo.com` and encodes cleanly is
    # a name that LOOKS like googoo.com and is not — which is the whole reason
    # UTS-46 refuses them rather than folding them away.
    if c == 0x00A0 or c == 0x1680 or c == 0x202F or c == 0x205F or c == 0x3000:
        return True
    if c >= 0x2000 and c <= 0x200A:
        return True
    if c == 0x2028 or c == 0x2029:
        return True
    return False


# UTS-46 IGNORED: removed outright, before anything else looks at the label.
# These are the invisible ones — a soft hyphen or a zero-width joiner between
# two letters must not make a different name.
def idna_ignored(c: int) -> bool:
    return c == 0x00AD or c == 0x200B or c == 0x200C or c == 0x200D or c == 0x2060 or c == 0xFEFF


# UTS-46 MAPPED, the part of the table that is a formula rather than data: the
# fullwidth ASCII block folds onto ASCII by a constant offset, and the three
# other full stops are label separators like `.` is. What is left out is the
# rest of the table — case folding beyond ASCII, the compatibility blocks, NFC.
def idna_map(c: int) -> int:
    if c >= 0xFF01 and c <= 0xFF5E:
        return c - 0xFEE0
    if c == 0x3002 or c == 0xFF61:
        return 0x2E
    return c


# UTS-46 to the extent this implementation goes: lowercase the ASCII, refuse the
# forbidden and disallowed code points, and Punycode any label that is not
# already ASCII. "" means failure.
#
# What is NOT here is the mapping half — the tables that fold `Ｇｏ` to `go`,
# `。` to `.`, and strip the zero-width joiners — plus NFC. Those are data, and
# the data is megabytes; `tests/conformance/url.skips` names the cases that need
# them.
def domain_to_ascii(domain: str) -> str:
    if len(domain) == 0:
        return ""
    # map and ignore FIRST, and only then split: U+3002 is a label separator,
    # so folding it to `.` has to happen before anybody looks for dots
    mapped = ""
    for ch in domain:
        c0 = ord(ch)
        if idna_disallowed(c0):
            return ""
        if idna_ignored(c0):
            continue
        mapped += chr(idna_map(c0))
    if len(mapped) == 0:
        return ""
    out = ""
    first = True
    for label in mapped.split("."):
        if not first:
            out += "."
        first = False
        cps: List<int> = []
        ascii_only = True
        for ch in label:
            c = lower_c(ord(ch))
            if c > 127:
                ascii_only = False
            cps.append(c)
        if ascii_only:
            out += from_codepoints(cps)
            continue
        enc = puny_encode(cps)
        if len(enc) == 0:
            return ""
        out += "xn--" + enc
    for ch in out:
        if forbidden_domain_cp(ord(ch)):
            return ""
    return out


# The whole host parser. "" with `ok == False` is the spec's `failure`.
record HostRes:
    ok: bool


struct Host:
    ok: bool
    value: str


def parse_host(input: str, is_opaque: bool) -> Host:
    bad: Host = Host(False, "")
    if len(input) > 0 and input[0] == "[":
        if input[len(input) - 1] != "]":
            return bad
        pieces = parse_ipv6(input[1:len(input) - 1])
        if len(pieces) == 0:
            return bad
        return Host(True, "[" + serialize_ipv6(pieces) + "]")
    if is_opaque:
        for ch in input:
            if forbidden_host_cp(ord(ch)):
                return bad
        out = ""
        for ch in input:
            c = ord(ch)
            out += pct_encode_cp(c) if in_c0_set(c) else ch
        return Host(True, out)
    # a domain is percent-DECODED, then UTF-8 decoded, then run through IDNA
    decoded = decode_utf8(pct_decode(input))
    ascii_domain = domain_to_ascii(decoded)
    if len(ascii_domain) == 0:
        return bad
    if ends_in_a_number(ascii_domain):
        v = parse_ipv4(ascii_domain)
        if v < 0:
            return bad
        return Host(True, serialize_ipv4(v))
    return Host(True, ascii_domain)


# Bytes to text, replacing anything that is not valid UTF-8 with U+FFFD — which
# is what the spec's "UTF-8 decode without BOM" does, and what keeps the result
# a `str` (83.2 says a str is valid UTF-8, so there is no other option here).
def decode_utf8(bs: List<u8>) -> str:
    out = ""
    i = 0
    n = len(bs)
    while i < n:
        b = int(bs[i])
        if b < 0x80:
            out += chr(b)
            i += 1
            continue
        need = 0
        cp = 0
        lo = 0
        if (b & 0xE0) == 0xC0:
            need = 1
            cp = b & 0x1F
            lo = 0x80
        elif (b & 0xF0) == 0xE0:
            need = 2
            cp = b & 0x0F
            lo = 0x800
        elif (b & 0xF8) == 0xF0:
            need = 3
            cp = b & 0x07
            lo = 0x10000
        else:
            out += chr(0xFFFD)
            i += 1
            continue
        if i + need >= n:
            out += chr(0xFFFD)
            i += 1
            continue
        good = True
        k = 1
        while k <= need:
            cb = int(bs[i + k])
            if (cb & 0xC0) != 0x80:
                good = False
            else:
                cp = (cp << 6) | (cb & 0x3F)
            k += 1
        if not good or cp < lo or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF):
            out += chr(0xFFFD)
            i += 1
            continue
        out += chr(cp)
        i += need + 1
    return out


# ---------- the basic URL parser ----------
#
# One state per spec state, one branch per spec sentence. It is long because the
# specification is long; it is not clever anywhere, on purpose — the value of a
# transcription is that anybody can hold it next to the text and check it.

enum UState:
    S_SCHEME_START = 0
    S_SCHEME
    S_NO_SCHEME
    S_SPECIAL_RELATIVE_OR_AUTHORITY
    S_PATH_OR_AUTHORITY
    S_RELATIVE
    S_RELATIVE_SLASH
    S_SPECIAL_AUTHORITY_SLASHES
    S_SPECIAL_AUTHORITY_IGNORE_SLASHES
    S_AUTHORITY
    S_HOST
    S_PORT
    S_FILE
    S_FILE_SLASH
    S_FILE_HOST
    S_PATH_START
    S_PATH
    S_OPAQUE_PATH
    S_QUERY
    S_FRAGMENT


def is_windows_drive(a: int, b: int) -> bool:
    return is_alpha(a) and (b == 0x3A or b == 0x7C)


def is_normalized_windows_drive_str(s: str) -> bool:
    return len(s) == 2 and is_alpha(ord(s[0])) and ord(s[1]) == 0x3A


def is_windows_drive_str(s: str) -> bool:
    return len(s) == 2 and is_windows_drive(ord(s[0]), ord(s[1]))


def is_single_dot(b: str) -> bool:
    return b == "." or b.lower() == "%2e"


def is_double_dot(b: str) -> bool:
    l = b.lower()
    return l == ".." or l == "%2e." or l == ".%2e" or l == "%2e%2e"


struct Parser:
    input: List<int>
    ptr: int
    base: Url
    has_base: bool
    url: Url
    state: UState
    buffer: str
    at_seen: bool
    in_brackets: bool
    pw_seen: bool
    failed: bool
    stop: bool


def special(u: Url) -> bool:
    return is_special_scheme(u.scheme)


def has_credentials(u: Url) -> bool:
    return len(u.username) > 0 or len(u.password) > 0


def shorten_path(u: Url):
    if len(u.path) == 0:
        return
    if u.scheme == "file" and len(u.path) == 1 and is_normalized_windows_drive_str(u.path[0]):
        return
    u.path = u.path[0:len(u.path) - 1]


# Everything below 0x20 at either end is stripped, and TAB/LF/CR are removed
# from ANYWHERE inside. Both are in the spec and both are load-bearing: without
# the second, `http://example\t.\norg` is a different host.
def clean_input(s: str) -> str:
    a = 0
    b = len(s)
    while a < b and ord(s[a]) <= 0x20:
        a += 1
    while b > a and ord(s[b - 1]) <= 0x20:
        b -= 1
    t = s[a:b]
    out = ""
    for ch in t:
        c = ord(ch)
        if c != 0x09 and c != 0x0A and c != 0x0D:
            out += ch
    return out


def starts_windows_drive(cs: List<int>, i: int) -> bool:
    n = len(cs)
    if i + 1 >= n:
        return False
    if not is_windows_drive(cs[i], cs[i + 1]):
        return False
    if i + 2 >= n:
        return True
    c = cs[i + 2]
    return c == 0x2F or c == 0x5C or c == 0x3F or c == 0x23


def copy_list(xs: List<str>) -> List<str>:
    out: List<str> = []
    for x in xs:
        out.append(x)
    return out


def enc_cp(c: int, which: int) -> str:
    # 0 = C0, 1 = fragment, 2 = path, 3 = userinfo, 4 = query, 5 = special query
    bad = False
    if which == 0:
        bad = in_c0_set(c)
    elif which == 1:
        bad = in_fragment_set(c)
    elif which == 2:
        bad = in_path_set(c)
    elif which == 3:
        bad = in_userinfo_set(c)
    elif which == 4:
        bad = in_query_set(c)
    else:
        bad = in_special_query_set(c)
    return pct_encode_cp(c) if bad else chr(c)


def enc_str(s: str, which: int) -> str:
    out = ""
    for ch in s:
        out += enc_cp(ord(ch), which)
    return out


# The whole thing. None means the spec's `failure`.
def parse(input: str, base: Url, has_base: bool) -> Url?:
    P = Parser(codepoints(clean_input(input)), 0, base, has_base, blank_url(),
               S_SCHEME_START, "", False, False, False, False, False)
    n = len(P.input)
    while P.ptr <= n:
        c = P.input[P.ptr] if P.ptr < n else -1
        step(P, c, n)
        if P.failed:
            return None
        if P.stop:
            break
        P.ptr += 1
    return P.url


def step(P: Parser, c: int, n: int):
    u = P.url

    if P.state == S_SCHEME_START:
        if is_alpha(c):
            P.buffer += chr(lower_c(c))
            P.state = S_SCHEME
        else:
            P.state = S_NO_SCHEME
            P.ptr -= 1

    elif P.state == S_SCHEME:
        if is_alnum(c) or c == 0x2B or c == 0x2D or c == 0x2E:
            P.buffer += chr(lower_c(c))
        elif c == 0x3A:
            u.scheme = P.buffer
            P.buffer = ""
            if u.scheme == "file":
                P.state = S_FILE
            elif is_special_scheme(u.scheme) and P.has_base and P.base.scheme == u.scheme:
                P.state = S_SPECIAL_RELATIVE_OR_AUTHORITY
            elif is_special_scheme(u.scheme):
                P.state = S_SPECIAL_AUTHORITY_SLASHES
            elif P.ptr + 1 < n and P.input[P.ptr + 1] == 0x2F:
                P.state = S_PATH_OR_AUTHORITY
                P.ptr += 1
            else:
                u.is_opaque = True
                u.opaque = ""
                P.state = S_OPAQUE_PATH
        else:
            # NO SCHEME, not scheme start: rewinding to scheme start would read
            # the same characters as a scheme again and never get anywhere. The
            # first cut of this said `S_SCHEME_START` and hung on ` foo.com  `.
            P.buffer = ""
            P.state = S_NO_SCHEME
            P.ptr = -1

    elif P.state == S_NO_SCHEME:
        if not P.has_base or (P.base.is_opaque and c != 0x23):
            P.failed = True
        elif P.base.is_opaque and c == 0x23:
            u.scheme = P.base.scheme
            u.is_opaque = True
            u.opaque = P.base.opaque
            u.query = P.base.query
            u.has_query = P.base.has_query
            u.fragment = ""
            u.has_fragment = True
            P.state = S_FRAGMENT
        elif P.base.scheme != "file":
            P.state = S_RELATIVE
            P.ptr -= 1
        else:
            P.state = S_FILE
            P.ptr -= 1

    elif P.state == S_SPECIAL_RELATIVE_OR_AUTHORITY:
        if c == 0x2F and P.ptr + 1 < n and P.input[P.ptr + 1] == 0x2F:
            P.state = S_SPECIAL_AUTHORITY_IGNORE_SLASHES
            P.ptr += 1
        else:
            P.state = S_RELATIVE
            P.ptr -= 1

    elif P.state == S_PATH_OR_AUTHORITY:
        if c == 0x2F:
            P.state = S_AUTHORITY
        else:
            P.state = S_PATH
            P.ptr -= 1

    elif P.state == S_RELATIVE:
        u.scheme = P.base.scheme
        if c == 0x2F or (is_special_scheme(u.scheme) and c == 0x5C):
            P.state = S_RELATIVE_SLASH
        else:
            u.username = P.base.username
            u.password = P.base.password
            u.host = P.base.host
            u.has_host = P.base.has_host
            u.port = P.base.port
            u.path = copy_list(P.base.path)
            u.is_opaque = P.base.is_opaque
            u.opaque = P.base.opaque
            u.query = P.base.query
            u.has_query = P.base.has_query
            if c == 0x3F:
                u.query = ""
                u.has_query = True
                P.state = S_QUERY
            elif c == 0x23:
                u.fragment = ""
                u.has_fragment = True
                P.state = S_FRAGMENT
            elif c != -1:
                u.has_query = False
                u.query = ""
                shorten_path(u)
                P.state = S_PATH
                P.ptr -= 1

    elif P.state == S_RELATIVE_SLASH:
        if is_special_scheme(u.scheme) and (c == 0x2F or c == 0x5C):
            P.state = S_SPECIAL_AUTHORITY_IGNORE_SLASHES
        elif c == 0x2F:
            P.state = S_AUTHORITY
        else:
            u.username = P.base.username
            u.password = P.base.password
            u.host = P.base.host
            u.has_host = P.base.has_host
            u.port = P.base.port
            P.state = S_PATH
            P.ptr -= 1

    elif P.state == S_SPECIAL_AUTHORITY_SLASHES:
        if c == 0x2F and P.ptr + 1 < n and P.input[P.ptr + 1] == 0x2F:
            P.state = S_SPECIAL_AUTHORITY_IGNORE_SLASHES
            P.ptr += 1
        else:
            P.state = S_SPECIAL_AUTHORITY_IGNORE_SLASHES
            P.ptr -= 1

    elif P.state == S_SPECIAL_AUTHORITY_IGNORE_SLASHES:
        if c != 0x2F and c != 0x5C:
            P.state = S_AUTHORITY
            P.ptr -= 1

    elif P.state == S_AUTHORITY:
        if c == 0x40:
            if P.at_seen:
                P.buffer = "%40" + P.buffer
            P.at_seen = True
            for ch in P.buffer:
                cp = ord(ch)
                if cp == 0x3A and not P.pw_seen:
                    P.pw_seen = True
                    continue
                e = enc_cp(cp, 3)
                if P.pw_seen:
                    u.password += e
                else:
                    u.username += e
            P.buffer = ""
        elif c == -1 or c == 0x2F or c == 0x3F or c == 0x23 or (is_special_scheme(u.scheme) and c == 0x5C):
            if P.at_seen and len(P.buffer) == 0:
                P.failed = True
                return
            P.ptr -= len(P.buffer) + 1
            P.buffer = ""
            P.state = S_HOST
        else:
            P.buffer += chr(c)

    elif P.state == S_HOST:
        if c == 0x3A and not P.in_brackets:
            if len(P.buffer) == 0:
                P.failed = True
                return
            h = parse_host(P.buffer, not is_special_scheme(u.scheme))
            if not h.ok:
                P.failed = True
                return
            u.host = h.value
            u.has_host = True
            P.buffer = ""
            P.state = S_PORT
        elif c == -1 or c == 0x2F or c == 0x3F or c == 0x23 or (is_special_scheme(u.scheme) and c == 0x5C):
            P.ptr -= 1
            if is_special_scheme(u.scheme) and len(P.buffer) == 0:
                P.failed = True
                return
            h2 = parse_host(P.buffer, not is_special_scheme(u.scheme))
            if not h2.ok:
                P.failed = True
                return
            u.host = h2.value
            u.has_host = True
            P.buffer = ""
            P.state = S_PATH_START
        else:
            if c == 0x5B:
                P.in_brackets = True
            if c == 0x5D:
                P.in_brackets = False
            P.buffer += chr(c)

    elif P.state == S_PORT:
        if is_digit(c):
            P.buffer += chr(c)
        elif c == -1 or c == 0x2F or c == 0x3F or c == 0x23 or (is_special_scheme(u.scheme) and c == 0x5C):
            if len(P.buffer) > 0:
                v = 0
                for ch in P.buffer:
                    v = v * 10 + (ord(ch) - 48)
                    if v > 65535:
                        P.failed = True
                        return
                u.port = -1 if v == default_port(u.scheme) else v
                P.buffer = ""
            P.state = S_PATH_START
            P.ptr -= 1
        else:
            P.failed = True

    elif P.state == S_FILE:
        u.scheme = "file"
        u.host = ""
        u.has_host = True
        if c == 0x2F or c == 0x5C:
            P.state = S_FILE_SLASH
        elif P.has_base and P.base.scheme == "file":
            u.host = P.base.host
            u.has_host = P.base.has_host
            u.path = copy_list(P.base.path)
            u.query = P.base.query
            u.has_query = P.base.has_query
            if c == 0x3F:
                u.query = ""
                u.has_query = True
                P.state = S_QUERY
            elif c == 0x23:
                u.fragment = ""
                u.has_fragment = True
                P.state = S_FRAGMENT
            elif c != -1:
                u.has_query = False
                u.query = ""
                if not starts_windows_drive(P.input, P.ptr):
                    shorten_path(u)
                else:
                    u.path = []
                P.state = S_PATH
                P.ptr -= 1
        else:
            P.state = S_PATH
            P.ptr -= 1

    elif P.state == S_FILE_SLASH:
        if c == 0x2F or c == 0x5C:
            P.state = S_FILE_HOST
        else:
            if P.has_base and P.base.scheme == "file":
                u.host = P.base.host
                u.has_host = P.base.has_host
                if not starts_windows_drive(P.input, P.ptr) and len(P.base.path) > 0 and is_normalized_windows_drive_str(P.base.path[0]):
                    u.path.append(P.base.path[0])
            P.state = S_PATH
            P.ptr -= 1

    elif P.state == S_FILE_HOST:
        if c == -1 or c == 0x2F or c == 0x5C or c == 0x3F or c == 0x23:
            P.ptr -= 1
            if is_windows_drive_str(P.buffer):
                P.state = S_PATH
            elif len(P.buffer) == 0:
                u.host = ""
                u.has_host = True
                P.state = S_PATH_START
            else:
                h3 = parse_host(P.buffer, not is_special_scheme(u.scheme))
                if not h3.ok:
                    P.failed = True
                    return
                u.host = "" if h3.value == "localhost" else h3.value
                u.has_host = True
                P.buffer = ""
                P.state = S_PATH_START
        else:
            P.buffer += chr(c)

    elif P.state == S_PATH_START:
        if is_special_scheme(u.scheme):
            P.state = S_PATH
            if c != 0x2F and c != 0x5C:
                P.ptr -= 1
        elif c == 0x3F:
            u.query = ""
            u.has_query = True
            P.state = S_QUERY
        elif c == 0x23:
            u.fragment = ""
            u.has_fragment = True
            P.state = S_FRAGMENT
        elif c != -1:
            P.state = S_PATH
            if c != 0x2F:
                P.ptr -= 1

    elif P.state == S_PATH:
        if c == -1 or c == 0x2F or (is_special_scheme(u.scheme) and c == 0x5C) or c == 0x3F or c == 0x23:
            if is_double_dot(P.buffer):
                shorten_path(u)
                if c != 0x2F and not (is_special_scheme(u.scheme) and c == 0x5C):
                    u.path.append("")
            elif is_single_dot(P.buffer) and c != 0x2F and not (is_special_scheme(u.scheme) and c == 0x5C):
                u.path.append("")
            elif not is_single_dot(P.buffer):
                if u.scheme == "file" and len(u.path) == 0 and is_windows_drive_str(P.buffer):
                    P.buffer = P.buffer[0:1] + ":"
                u.path.append(P.buffer)
            P.buffer = ""
            if c == 0x3F:
                u.query = ""
                u.has_query = True
                P.state = S_QUERY
            if c == 0x23:
                u.fragment = ""
                u.has_fragment = True
                P.state = S_FRAGMENT
        else:
            P.buffer += enc_cp(c, 2)

    elif P.state == S_OPAQUE_PATH:
        if c == 0x3F:
            u.query = ""
            u.has_query = True
            P.state = S_QUERY
        elif c == 0x23:
            u.fragment = ""
            u.has_fragment = True
            P.state = S_FRAGMENT
        elif c == 0x20:
            nx = P.input[P.ptr + 1] if P.ptr + 1 < n else -1
            u.opaque += "%20" if nx == 0x3F or nx == 0x23 else " "
        elif c != -1:
            u.opaque += enc_cp(c, 0)

    elif P.state == S_QUERY:
        if c == 0x23 or c == -1:
            which = 5 if is_special_scheme(u.scheme) else 4
            u.query += enc_str(P.buffer, which)
            P.buffer = ""
            if c == 0x23:
                u.fragment = ""
                u.has_fragment = True
                P.state = S_FRAGMENT
        else:
            P.buffer += chr(c)

    elif P.state == S_FRAGMENT:
        if c != -1:
            u.fragment += enc_cp(c, 1)


# ---------- serialising ----------

def serialize_path(u: Url) -> str:
    if u.is_opaque:
        return u.opaque
    out = ""
    for seg in u.path:
        out += "/" + seg
    return out


def serialize(u: Url, exclude_fragment: bool) -> str:
    out = u.scheme + ":"
    if u.has_host:
        out += "//"
        if len(u.username) > 0 or len(u.password) > 0:
            out += u.username
            if len(u.password) > 0:
                out += ":" + u.password
            out += "@"
        out += u.host
        if u.port >= 0:
            out += ":" + str(u.port)
    if not u.has_host and not u.is_opaque and len(u.path) > 1 and u.path[0] == "":
        out += "/."
    out += serialize_path(u)
    if u.has_query:
        out += "?" + u.query
    if not exclude_fragment and u.has_fragment:
        out += "#" + u.fragment
    return out


def href(u: Url) -> str:
    return serialize(u, False)


def origin(u: Url) -> str:
    if u.scheme == "blob":
        # narrowing wants a statement, not a ternary: the `!= None` in a
        # conditional expression does not make the branch see a non-null type
        inner = parse(serialize_path(u), blank_url(), False)
        if inner != None:
            return origin(inner)
        return "null"
    if u.scheme == "http" or u.scheme == "https" or u.scheme == "ws" or u.scheme == "wss" or u.scheme == "ftp":
        out = u.scheme + "://" + u.host
        if u.port >= 0:
            out += ":" + str(u.port)
        return out
    if u.scheme == "file":
        return "null"
    return "null"
