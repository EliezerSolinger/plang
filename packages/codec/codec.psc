"""`codec` — base64 and hex, in both directions.

The two encodings that every program that touches a network or a config file
needs, and that nobody should write twice. They are pure computation over
`bytes`, so this is a package and not runtime — the first clause of 141.1.

**Base64 has four variants, and the reason is the life it leads.** The standard
alphabet ends in `+` and `/`, which are the two characters a URL cannot carry, so
RFC 4648 §5 defines a second alphabet ending in `-` and `_`. And the `=` padding
is required by some readers and forbidden by others (a JWT has none). Two
questions, two booleans, four answers — and offering only one of them is what
makes every project write the other three by hand.

**Decoding ACCEPTS what encoding would not produce**, and that is deliberate: it
takes either alphabet, and padding or no padding. The rule is Postel's, applied
where it is safe — the input comes from somebody else, and there is exactly one
byte string it can mean.

**What is not text is not an error to guess about** (4.2): `base64_decode` and
`hex_decode` return `bytes?`, and None means the input was not that encoding.
Input from outside that does not parse is a case the caller planned for, not an
accident.
"""


const STD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
const URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
const HEXD = "0123456789abcdef"


def base64_encode(b: bytes, urlsafe: bool = False, pad: bool = True) -> str:
    """The bytes as base64. `urlsafe` swaps `+/` for `-_` (RFC 4648 §5); `pad`
    writes the trailing `=`, which some readers require and others forbid."""
    alpha = URL if urlsafe else STD
    out: List<str> = []
    n = len(b)
    i = 0
    while i + 2 < n:
        v = (int(b[i]) << 16) | (int(b[i + 1]) << 8) | int(b[i + 2])
        out.append(alpha[(v >> 18) & 63])
        out.append(alpha[(v >> 12) & 63])
        out.append(alpha[(v >> 6) & 63])
        out.append(alpha[v & 63])
        i += 3
    left = n - i
    if left == 1:
        v1 = int(b[i]) << 16
        out.append(alpha[(v1 >> 18) & 63])
        out.append(alpha[(v1 >> 12) & 63])
        if pad:
            out.append("=")
            out.append("=")
    elif left == 2:
        v2 = (int(b[i]) << 16) | (int(b[i + 1]) << 8)
        out.append(alpha[(v2 >> 18) & 63])
        out.append(alpha[(v2 >> 12) & 63])
        out.append(alpha[(v2 >> 6) & 63])
        if pad:
            out.append("=")
    return "".join(out)


def b64_val(c: str) -> int:
    """The value of one base64 character, in EITHER alphabet, or -1."""
    o = ord(c)
    if o >= 65 and o <= 90:
        return o - 65
    if o >= 97 and o <= 122:
        return o - 97 + 26
    if o >= 48 and o <= 57:
        return o - 48 + 52
    if c == "+" or c == "-":
        return 62
    if c == "/" or c == "_":
        return 63
    return -1


def base64_decode(s: str) -> bytes?:
    """Back to bytes, taking either alphabet and padded or not. None when the
    text is not base64 — which is a case the caller planned for, not an
    accident (4.2)."""
    acc = 0
    nbits = 0
    out: List<u8> = []
    for c in s:
        if c == "=":
            break
        v = b64_val(c)
        if v < 0:
            return None
        acc = (acc << 6) | v
        nbits += 6
        if nbits >= 8:
            nbits -= 8
            out.append(u8((acc >> nbits) & 255))
    # o que sobra tem de ser ENCHIMENTO, e enchimento é zero. Um resto com bits
    # a um é texto que ninguém produziu a codificar, e aceitá-lo faria duas
    # entradas diferentes dar o mesmo resultado — que é como se forjam
    # assinaturas em base64.
    if nbits >= 6:
        return None
    if nbits > 0 and (acc & ((1 << nbits) - 1)) != 0:
        return None
    return bytes(out)


def hex_encode(b: bytes, upper: bool = False) -> str:
    """The bytes as hex, two characters each."""
    out: List<str> = []
    for x in b:
        v = int(x)
        hi = HEXD[(v >> 4) & 15]
        lo = HEXD[v & 15]
        out.append(hi.upper() if upper else hi)
        out.append(lo.upper() if upper else lo)
    return "".join(out)


def hex_val(c: str) -> int:
    o = ord(c)
    if o >= 48 and o <= 57:
        return o - 48
    if o >= 97 and o <= 102:
        return o - 97 + 10
    if o >= 65 and o <= 70:
        return o - 65 + 10
    return -1


def hex_decode(s: str) -> bytes?:
    """Back to bytes, upper or lower case. None when the text is not hex — an
    odd number of characters included, because half a byte is not a byte."""
    if len(s) % 2 != 0:
        return None
    out: List<u8> = []
    i = 0
    while i < len(s):
        hi = hex_val(s[i])
        lo = hex_val(s[i + 1])
        if hi < 0 or lo < 0:
            return None
        out.append(u8(hi * 16 + lo))
        i += 2
    return bytes(out)
