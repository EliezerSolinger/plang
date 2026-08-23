# The FIPS 180-4 §6.2 implementation. See `sha2.ph` for the why.
import <sha2/sha2.ph>

# the cube roots of the first 64 primes, the fractional part in 32 bits
private const K: const u32[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2}

private def rotr(x: u32, n: u32) -> u32:
    return (x >> n) | (x << (32 - n))

# ONE 64-byte block. This is where the whole hash happens; the rest of the file
# is bookkeeping of how many bytes have come in.
private def block(ref h: u32[8], p: const *char):
    w: u32[64]
    for i in range(16):
        w[i] = (u32(u8(p[i * 4])) << 24) | (u32(u8(p[i * 4 + 1])) << 16) | (u32(u8(p[i * 4 + 2])) << 8) | u32(u8(p[i * 4 + 3]))
    for i in range(48):
        t: i32 = i + 16
        s0: u32 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
        s1: u32 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
        w[t] = w[t - 16] + s0 + w[t - 7] + s1
    a: u32 = h[0]
    b: u32 = h[1]
    c: u32 = h[2]
    d: u32 = h[3]
    e: u32 = h[4]
    f: u32 = h[5]
    g: u32 = h[6]
    hh: u32 = h[7]
    for i in range(64):
        S1: u32 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
        ch: u32 = (e & f) ^ ((~e) & g)
        t1: u32 = hh + S1 + ch + K[i] + w[i]
        S0: u32 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
        maj: u32 = (a & b) ^ (a & c) ^ (b & c)
        t2: u32 = S0 + maj
        hh = g
        g = f
        f = e
        e = d + t1
        d = c
        c = b
        b = a
        a = t1 + t2
    h[0] += a
    h[1] += b
    h[2] += c
    h[3] += d
    h[4] += e
    h[5] += f
    h[6] += g
    h[7] += hh

def sha256_init(out s: Sha256):
    s.h[0] = 0x6a09e667
    s.h[1] = 0xbb67ae85
    s.h[2] = 0x3c6ef372
    s.h[3] = 0xa54ff53a
    s.h[4] = 0x510e527f
    s.h[5] = 0x9b05688c
    s.h[6] = 0x1f83d9ab
    s.h[7] = 0x5be0cd19
    s.nbuf = 0
    s.total = 0

def sha256_update(ref s: Sha256, data: const *char, n: usize):
    s.total += u64(n)
    i: usize = 0
    # what was left over from last time first: a block is only processed full
    if s.nbuf > 0:
        while i < n and s.nbuf < 64:
            s.buf[s.nbuf] = u8(data[i])
            s.nbuf += 1
            i += 1
        if s.nbuf < 64:
            return
        block(ref s.h, (*char)(&s.buf[0]))
        s.nbuf = 0
    while n - i >= 64:
        block(ref s.h, data + i)
        i += 64
    while i < n:
        s.buf[s.nbuf] = u8(data[i])
        s.nbuf += 1
        i += 1

def sha256_final(ref s: Sha256, out_digest: *char):
    # the padding: a 1 bit, zeros, and the LENGTH IN BITS as a big-endian
    # 64-bit value. The length is what stops two different messages from having
    # the same padding.
    bits: u64 = s.total * u64(8)
    s.buf[s.nbuf] = u8(0x80)
    s.nbuf += 1
    if s.nbuf > 56:
        while s.nbuf < 64:
            s.buf[s.nbuf] = u8(0)
            s.nbuf += 1
        block(ref s.h, (*char)(&s.buf[0]))
        s.nbuf = 0
    while s.nbuf < 56:
        s.buf[s.nbuf] = u8(0)
        s.nbuf += 1
    for i in range(8):
        s.buf[56 + i] = u8((bits >> u64((7 - i) * 8)) & u64(0xff))
    block(ref s.h, (*char)(&s.buf[0]))
    for i in range(8):
        out_digest[i * 4] = char((s.h[i] >> 24) & 0xff)
        out_digest[i * 4 + 1] = char((s.h[i] >> 16) & 0xff)
        out_digest[i * 4 + 2] = char((s.h[i] >> 8) & 0xff)
        out_digest[i * 4 + 3] = char(s.h[i] & 0xff)

private const HEXD: const *char = "0123456789abcdef"

def sha256_hex(data: const *char, n: usize, out_hex: *char):
    s: Sha256
    sha256_init(out s)
    sha256_update(ref s, data, n)
    d: char[32]
    sha256_final(ref s, d)
    for i in range(32):
        b: u8 = u8(d[i])
        out_hex[i * 2] = HEXD[b >> 4]
        out_hex[i * 2 + 1] = HEXD[b & u8(0xf)]
    out_hex[64] = '\0'

# Returns BORROWED: a buffer belonging to this module, valid until the next call
# — `strerror`'s convention (83.1), and the only one that does not force anybody
# to free anything. Whoever crosses the boundary copies on the spot, so the
# validity that matters is the call's.
private g_hex: char[65]

def sha256_of(in data: CBytes) -> CStr:
    sha256_hex((*char)(data.ptr), data.len, g_hex)
    return cstr_n(g_hex, usize(64))


# ---------- SHA-512 ----------

# the cube roots of the first 80 primes, the fractional part in 64 bits
private const K512: const u64[80] = {
    u64(0x428a2f98d728ae22), u64(0x7137449123ef65cd),
    u64(0xb5c0fbcfec4d3b2f), u64(0xe9b5dba58189dbbc),
    u64(0x3956c25bf348b538), u64(0x59f111f1b605d019),
    u64(0x923f82a4af194f9b), u64(0xab1c5ed5da6d8118),
    u64(0xd807aa98a3030242), u64(0x12835b0145706fbe),
    u64(0x243185be4ee4b28c), u64(0x550c7dc3d5ffb4e2),
    u64(0x72be5d74f27b896f), u64(0x80deb1fe3b1696b1),
    u64(0x9bdc06a725c71235), u64(0xc19bf174cf692694),
    u64(0xe49b69c19ef14ad2), u64(0xefbe4786384f25e3),
    u64(0x0fc19dc68b8cd5b5), u64(0x240ca1cc77ac9c65),
    u64(0x2de92c6f592b0275), u64(0x4a7484aa6ea6e483),
    u64(0x5cb0a9dcbd41fbd4), u64(0x76f988da831153b5),
    u64(0x983e5152ee66dfab), u64(0xa831c66d2db43210),
    u64(0xb00327c898fb213f), u64(0xbf597fc7beef0ee4),
    u64(0xc6e00bf33da88fc2), u64(0xd5a79147930aa725),
    u64(0x06ca6351e003826f), u64(0x142929670a0e6e70),
    u64(0x27b70a8546d22ffc), u64(0x2e1b21385c26c926),
    u64(0x4d2c6dfc5ac42aed), u64(0x53380d139d95b3df),
    u64(0x650a73548baf63de), u64(0x766a0abb3c77b2a8),
    u64(0x81c2c92e47edaee6), u64(0x92722c851482353b),
    u64(0xa2bfe8a14cf10364), u64(0xa81a664bbc423001),
    u64(0xc24b8b70d0f89791), u64(0xc76c51a30654be30),
    u64(0xd192e819d6ef5218), u64(0xd69906245565a910),
    u64(0xf40e35855771202a), u64(0x106aa07032bbd1b8),
    u64(0x19a4c116b8d2d0c8), u64(0x1e376c085141ab53),
    u64(0x2748774cdf8eeb99), u64(0x34b0bcb5e19b48a8),
    u64(0x391c0cb3c5c95a63), u64(0x4ed8aa4ae3418acb),
    u64(0x5b9cca4f7763e373), u64(0x682e6ff3d6b2b8a3),
    u64(0x748f82ee5defb2fc), u64(0x78a5636f43172f60),
    u64(0x84c87814a1f0ab72), u64(0x8cc702081a6439ec),
    u64(0x90befffa23631e28), u64(0xa4506cebde82bde9),
    u64(0xbef9a3f7b2c67915), u64(0xc67178f2e372532b),
    u64(0xca273eceea26619c), u64(0xd186b8c721c0c207),
    u64(0xeada7dd6cde0eb1e), u64(0xf57d4f7fee6ed178),
    u64(0x06f067aa72176fba), u64(0x0a637dc5a2c898a6),
    u64(0x113f9804bef90dae), u64(0x1b710b35131c471b),
    u64(0x28db77f523047d84), u64(0x32caab7b40c72493),
    u64(0x3c9ebe0a15c9bebc), u64(0x431d67c49c100d4c),
    u64(0x4cc5d4becb3e42b6), u64(0x597f299cfc657e2a),
    u64(0x5fcb6fab3ad6faec), u64(0x6c44198c4a475817),}

private def rotr64(x: u64, n: u64) -> u64:
    return (x >> n) | (x << (u64(64) - n))

private def block512(ref h: u64[8], p: const *char):
    w: u64[80]
    for i in range(16):
        v: u64 = u64(0)
        for j in range(8):
            v = (v << u64(8)) | u64(u8(p[i * 8 + j]))
        w[i] = v
    for i in range(64):
        t: i32 = i + 16
        s0: u64 = rotr64(w[t - 15], u64(1)) ^ rotr64(w[t - 15], u64(8)) ^ (w[t - 15] >> u64(7))
        s1: u64 = rotr64(w[t - 2], u64(19)) ^ rotr64(w[t - 2], u64(61)) ^ (w[t - 2] >> u64(6))
        w[t] = w[t - 16] + s0 + w[t - 7] + s1
    a: u64 = h[0]
    b: u64 = h[1]
    c: u64 = h[2]
    d: u64 = h[3]
    e: u64 = h[4]
    f: u64 = h[5]
    g: u64 = h[6]
    hh: u64 = h[7]
    for i in range(80):
        S1: u64 = rotr64(e, u64(14)) ^ rotr64(e, u64(18)) ^ rotr64(e, u64(41))
        ch: u64 = (e & f) ^ ((~e) & g)
        t1: u64 = hh + S1 + ch + K512[i] + w[i]
        S0: u64 = rotr64(a, u64(28)) ^ rotr64(a, u64(34)) ^ rotr64(a, u64(39))
        maj: u64 = (a & b) ^ (a & c) ^ (b & c)
        t2: u64 = S0 + maj
        hh = g
        g = f
        f = e
        e = d + t1
        d = c
        c = b
        b = a
        a = t1 + t2
    h[0] += a
    h[1] += b
    h[2] += c
    h[3] += d
    h[4] += e
    h[5] += f
    h[6] += g
    h[7] += hh

def sha512_init(out s: Sha512):
    # the SQUARE roots of the first 8 primes, in 64 bits
    s.h[0] = u64(0x6a09e667f3bcc908)
    s.h[1] = u64(0xbb67ae8584caa73b)
    s.h[2] = u64(0x3c6ef372fe94f82b)
    s.h[3] = u64(0xa54ff53a5f1d36f1)
    s.h[4] = u64(0x510e527fade682d1)
    s.h[5] = u64(0x9b05688c2b3e6c1f)
    s.h[6] = u64(0x1f83d9abfb41bd6b)
    s.h[7] = u64(0x5be0cd19137e2179)
    s.nbuf = usize(0)
    s.total = u64(0)

def sha512_update(ref s: Sha512, data: const *char, n: usize):
    s.total += u64(n)
    i: usize = usize(0)
    while i < n:
        s.buf[s.nbuf] = u8(data[i])
        s.nbuf += usize(1)
        i += usize(1)
        if s.nbuf == usize(128):
            block512(ref s.h, (*char)(&s.buf[0]))
            s.nbuf = usize(0)

def sha512_final(ref s: Sha512, out_digest: *char):
    bits: u64 = s.total * u64(8)
    s.buf[s.nbuf] = u8(0x80)
    s.nbuf += usize(1)
    if s.nbuf > usize(112):
        while s.nbuf < usize(128):
            s.buf[s.nbuf] = u8(0)
            s.nbuf += usize(1)
        block512(ref s.h, (*char)(&s.buf[0]))
        s.nbuf = usize(0)
    while s.nbuf < usize(112):
        s.buf[s.nbuf] = u8(0)
        s.nbuf += usize(1)
    # the length is 128 bits: the high half is zero as long as the message fits
    # in 2^61 bytes, which is every message that exists
    for i in range(8):
        s.buf[112 + i] = u8(0)
    for i in range(8):
        s.buf[120 + i] = u8((bits >> u64((7 - i) * 8)) & u64(0xff))
    block512(ref s.h, (*char)(&s.buf[0]))
    for i in range(8):
        for j in range(8):
            out_digest[i * 8 + j] = char((s.h[i] >> u64((7 - j) * 8)) & u64(0xff))

def sha512_hex(data: const *char, n: usize, out_hex: *char):
    s: Sha512
    sha512_init(out s)
    sha512_update(ref s, data, n)
    d: char[64]
    sha512_final(ref s, d)
    for i in range(64):
        b: u8 = u8(d[i])
        out_hex[i * 2] = HEXD[b >> 4]
        out_hex[i * 2 + 1] = HEXD[b & u8(0xf)]
    out_hex[128] = '\0'

private g_hex512: char[129]

def sha512_of(in data: CBytes) -> CStr:
    sha512_hex((*char)(data.ptr), data.len, g_hex512)
    return cstr_n(g_hex512, usize(128))
