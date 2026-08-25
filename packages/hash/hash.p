"""CRC32, SHA-1 and MD5 — the implementations.

Nothing clever anywhere on purpose: CRC32 is the bitwise form with the table
built once, SHA-1 is FIPS 180-4 §6.1 and MD5 is RFC 1321 §3.4, each written the
way its specification writes it. There is a test with the official vectors, and
that is what you depend on — not on the code being fast.
"""

import <stl/cstr.ph>

private const HEXD: const *char = "0123456789abcdef"

# ---------- CRC32 (IEEE) ----------
#
# The reflected form: the polynomial 0x04C11DB7 read backwards is 0xEDB88320, and
# reading it backwards is what lets the loop shift RIGHT — which is why every
# implementation in the world has that constant in it and not the other one.
private g_crc_ready: bool = False
private g_crc: u32[256]

private def crc_table():
    if g_crc_ready:
        return
    for i in range(256):
        c: u32 = u32(i)
        for b in range(8):
            # o polinómio 0x04C11DB7 lido ao contrário é 0xEDB88320, e ler ao
            # contrário é o que deixa o laço deslocar para a DIREITA — que é a
            # razão de toda a implementação do mundo ter esta constante e não a
            # outra
            if (c & u32(1)) != u32(0):
                c = (c >> 1) ^ u32(0xEDB88320)
            else:
                c = c >> 1
        g_crc[i] = c
    g_crc_ready = True

def crc32_update(seed: u32, in data: CBytes) -> u32:
    crc_table()
    c: u32 = ~seed
    p: const *u8 = data.ptr
    for i in range(i64(data.len)):
        c = g_crc[i32((c ^ u32(p[i])) & u32(0xFF))] ^ (c >> 8)
    return ~c

def crc32_of(in data: CBytes) -> u32:
    return crc32_update(u32(0), in data)

private g_crchex: char[9]

def crc32_hex(in data: CBytes) -> CStr:
    v: u32 = crc32_of(in data)
    for i in range(8):
        g_crchex[i] = HEXD[(v >> u32(28 - i * 4)) & u32(0xF)]
    g_crchex[8] = '\0'
    return cstr_n(g_crchex, usize(8))

# ---------- SHA-1 (FIPS 180-4 §6.1) ----------

private inline def rotl32(x: u32, n: i32) -> u32:
    return (x << u32(n)) | (x >> u32(32 - n))

private def sha1_block(ref h: u32[5], p: const *u8):
    w: u32[80]
    for i in range(16):
        w[i] = (u32(p[i * 4]) << 24) | (u32(p[i * 4 + 1]) << 16) | (u32(p[i * 4 + 2]) << 8) | u32(p[i * 4 + 3])
    for i in range(16, 80):
        w[i] = rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
    a: u32 = h[0]
    b: u32 = h[1]
    c: u32 = h[2]
    d: u32 = h[3]
    e: u32 = h[4]
    for i in range(80):
        f: u32 = u32(0)
        k: u32 = u32(0)
        if i < 20:
            f = (b & c) | ((~b) & d)
            k = u32(0x5A827999)
        elif i < 40:
            f = b ^ c ^ d
            k = u32(0x6ED9EBA1)
        elif i < 60:
            f = (b & c) | (b & d) | (c & d)
            k = u32(0x8F1BBCDC)
        else:
            f = b ^ c ^ d
            k = u32(0xCA62C1D6)
        t: u32 = rotl32(a, 5) + f + e + k + w[i]
        e = d
        d = c
        c = rotl32(b, 30)
        b = a
        a = t
    h[0] += a
    h[1] += b
    h[2] += c
    h[3] += d
    h[4] += e

private g_sha1hex: char[41]

def sha1_of(in data: CBytes) -> CStr:
    h: u32[5]
    h[0] = u32(0x67452301)
    h[1] = u32(0xEFCDAB89)
    h[2] = u32(0x98BADCFE)
    h[3] = u32(0x10325476)
    h[4] = u32(0xC3D2E1F0)
    p: const *u8 = data.ptr
    n: usize = data.len
    i: usize = 0
    while i + usize(64) <= n:
        sha1_block(ref h, p + i)
        i += usize(64)
    # o resto, o bit a um, os zeros, e o comprimento em bits BIG-ENDIAN
    tail: u8[128]
    rest: usize = n - i
    for j in range(i64(rest)):
        tail[j] = p[i + usize(j)]
    tail[rest] = u8(0x80)
    total: usize = usize(64) if rest < usize(56) else usize(128)
    for j in range(i64(rest) + 1, i64(total) - 8):
        tail[j] = u8(0)
    bits: u64 = u64(n) * u64(8)
    for j in range(8):
        tail[total - usize(1) - usize(j)] = u8((bits >> u64(j * 8)) & u64(0xFF))
    sha1_block(ref h, &tail[0])
    if total == usize(128):
        sha1_block(ref h, &tail[64])
    for j in range(5):
        for k2 in range(4):
            v: u32 = (h[j] >> u32(24 - k2 * 8)) & u32(0xFF)
            g_sha1hex[j * 8 + k2 * 2] = HEXD[(v >> 4) & u32(0xF)]
            g_sha1hex[j * 8 + k2 * 2 + 1] = HEXD[v & u32(0xF)]
    g_sha1hex[40] = '\0'
    return cstr_n(g_sha1hex, usize(40))

# ---------- MD5 (RFC 1321 §3.4) ----------
#
# Little-endian everywhere, which is the one thing that distinguishes it from
# SHA-1 at a glance — and the one thing everybody gets wrong the first time.

private const MD5S: const i32[64] = {
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
}

# floor(abs(sin(i+1)) * 2^32), which is RFC 1321's own table
private const MD5K: const u32[64] = {
    u32(0xd76aa478), u32(0xe8c7b756), u32(0x242070db), u32(0xc1bdceee),
    u32(0xf57c0faf), u32(0x4787c62a), u32(0xa8304613), u32(0xfd469501),
    u32(0x698098d8), u32(0x8b44f7af), u32(0xffff5bb1), u32(0x895cd7be),
    u32(0x6b901122), u32(0xfd987193), u32(0xa679438e), u32(0x49b40821),
    u32(0xf61e2562), u32(0xc040b340), u32(0x265e5a51), u32(0xe9b6c7aa),
    u32(0xd62f105d), u32(0x02441453), u32(0xd8a1e681), u32(0xe7d3fbc8),
    u32(0x21e1cde6), u32(0xc33707d6), u32(0xf4d50d87), u32(0x455a14ed),
    u32(0xa9e3e905), u32(0xfcefa3f8), u32(0x676f02d9), u32(0x8d2a4c8a),
    u32(0xfffa3942), u32(0x8771f681), u32(0x6d9d6122), u32(0xfde5380c),
    u32(0xa4beea44), u32(0x4bdecfa9), u32(0xf6bb4b60), u32(0xbebfbc70),
    u32(0x289b7ec6), u32(0xeaa127fa), u32(0xd4ef3085), u32(0x04881d05),
    u32(0xd9d4d039), u32(0xe6db99e5), u32(0x1fa27cf8), u32(0xc4ac5665),
    u32(0xf4292244), u32(0x432aff97), u32(0xab9423a7), u32(0xfc93a039),
    u32(0x655b59c3), u32(0x8f0ccc92), u32(0xffeff47d), u32(0x85845dd1),
    u32(0x6fa87e4f), u32(0xfe2ce6e0), u32(0xa3014314), u32(0x4e0811a1),
    u32(0xf7537e82), u32(0xbd3af235), u32(0x2ad7d2bb), u32(0xeb86d391)
}

private def md5_block(ref h: u32[4], p: const *u8):
    m: u32[16]
    for i in range(16):
        m[i] = u32(p[i * 4]) | (u32(p[i * 4 + 1]) << 8) | (u32(p[i * 4 + 2]) << 16) | (u32(p[i * 4 + 3]) << 24)
    a: u32 = h[0]
    b: u32 = h[1]
    c: u32 = h[2]
    d: u32 = h[3]
    for i in range(64):
        f: u32 = u32(0)
        g: i32 = 0
        if i < 16:
            f = (b & c) | ((~b) & d)
            g = i
        elif i < 32:
            f = (d & b) | ((~d) & c)
            g = (5 * i + 1) % 16
        elif i < 48:
            f = b ^ c ^ d
            g = (3 * i + 5) % 16
        else:
            f = c ^ (b | (~d))
            g = (7 * i) % 16
        f = f + a + MD5K[i] + m[g]
        a = d
        d = c
        c = b
        b = b + rotl32(f, MD5S[i])
    h[0] += a
    h[1] += b
    h[2] += c
    h[3] += d

private g_md5hex: char[33]

def md5_of(in data: CBytes) -> CStr:
    h: u32[4]
    h[0] = u32(0x67452301)
    h[1] = u32(0xefcdab89)
    h[2] = u32(0x98badcfe)
    h[3] = u32(0x10325476)
    p: const *u8 = data.ptr
    n: usize = data.len
    i: usize = 0
    while i + usize(64) <= n:
        md5_block(ref h, p + i)
        i += usize(64)
    tail: u8[128]
    rest: usize = n - i
    for j in range(i64(rest)):
        tail[j] = p[i + usize(j)]
    tail[rest] = u8(0x80)
    total: usize = usize(64) if rest < usize(56) else usize(128)
    for j in range(i64(rest) + 1, i64(total) - 8):
        tail[j] = u8(0)
    bits: u64 = u64(n) * u64(8)
    for j in range(8):
        tail[total - usize(8) + usize(j)] = u8((bits >> u64(j * 8)) & u64(0xFF))
    md5_block(ref h, &tail[0])
    if total == usize(128):
        md5_block(ref h, &tail[64])
    for j in range(4):
        for k2 in range(4):
            v: u32 = (h[j] >> u32(k2 * 8)) & u32(0xFF)
            g_md5hex[j * 8 + k2 * 2] = HEXD[(v >> 4) & u32(0xF)]
            g_md5hex[j * 8 + k2 * 2 + 1] = HEXD[v & u32(0xF)]
    g_md5hex[32] = '\0'
    return cstr_n(g_md5hex, usize(32))
