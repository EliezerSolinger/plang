# A implementação do FIPS 180-4 §6.2. Ver `sha2.ph` para o porquê.
import <sha2/sha2.ph>

# as raízes cúbicas dos 64 primeiros primos, a parte fracionária em 32 bits
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

# UM bloco de 64 bytes. É aqui que o hash inteiro acontece; o resto do arquivo é
# contabilidade de quantos bytes já entraram.
private def bloco(ref h: u32[8], p: const *char):
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
    # o que sobrou da vez passada primeiro: um bloco só se processa cheio
    if s.nbuf > 0:
        while i < n and s.nbuf < 64:
            s.buf[s.nbuf] = u8(data[i])
            s.nbuf += 1
            i += 1
        if s.nbuf < 64:
            return
        bloco(ref s.h, (*char)(&s.buf[0]))
        s.nbuf = 0
    while n - i >= 64:
        bloco(ref s.h, data + i)
        i += 64
    while i < n:
        s.buf[s.nbuf] = u8(data[i])
        s.nbuf += 1
        i += 1

def sha256_final(ref s: Sha256, out_digest: *char):
    # o preenchimento: um bit 1, zeros, e o COMPRIMENTO EM BITS em 64 bits
    # big-endian. O comprimento é o que impede duas mensagens diferentes de
    # terem o mesmo preenchimento.
    bits: u64 = s.total * u64(8)
    s.buf[s.nbuf] = u8(0x80)
    s.nbuf += 1
    if s.nbuf > 56:
        while s.nbuf < 64:
            s.buf[s.nbuf] = u8(0)
            s.nbuf += 1
        bloco(ref s.h, (*char)(&s.buf[0]))
        s.nbuf = 0
    while s.nbuf < 56:
        s.buf[s.nbuf] = u8(0)
        s.nbuf += 1
    for i in range(8):
        s.buf[56 + i] = u8((bits >> u64((7 - i) * 8)) & u64(0xff))
    bloco(ref s.h, (*char)(&s.buf[0]))
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
