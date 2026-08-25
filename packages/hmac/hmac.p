"""HMAC-SHA256 — RFC 2104 §2, written the way the RFC writes it."""

import <stl/cstr.ph>
import <sha2/sha2.ph>

private const HEXD: const *char = "0123456789abcdef"
private const BLK: const usize = usize(64)

def hmac_sha256_raw(in key: CBytes, in msg: CBytes, out_digest: *char):
    k: u8[64]
    for i in range(64):
        k[i] = u8(0)
    if key.len > BLK:
        # RFC 2104 §2: uma chave maior do que o bloco é HASHADA primeiro. Não é
        # truncada — truncar faria duas chaves diferentes dar o mesmo MAC.
        d0: char[32]
        s0: Sha256
        sha256_init(out s0)
        sha256_update(ref s0, (*char)(key.ptr), key.len)
        sha256_final(ref s0, d0)
        for i in range(32):
            k[i] = u8(d0[i])
    else:
        for i in range(i64(key.len)):
            k[i] = key.ptr[i]
    ipad: char[64]
    opad: char[64]
    for i in range(64):
        ipad[i] = char(k[i] ^ u8(0x36))
        opad[i] = char(k[i] ^ u8(0x5c))
    inner: char[32]
    si: Sha256
    sha256_init(out si)
    sha256_update(ref si, ipad, BLK)
    sha256_update(ref si, (*char)(msg.ptr), msg.len)
    sha256_final(ref si, inner)
    so: Sha256
    sha256_init(out so)
    sha256_update(ref so, opad, BLK)
    sha256_update(ref so, inner, usize(32))
    sha256_final(ref so, out_digest)

private g_hex: char[65]

def hmac_sha256(in key: CBytes, in msg: CBytes) -> CStr:
    d: char[32]
    hmac_sha256_raw(in key, in msg, d)
    for i in range(32):
        b: u8 = u8(d[i])
        g_hex[i * 2] = HEXD[(b >> 4) & u8(0xF)]
        g_hex[i * 2 + 1] = HEXD[b & u8(0xF)]
    g_hex[64] = '\0'
    return cstr_n(g_hex, usize(64))

def hmac_equal(in a: CStr, in b: CStr) -> bool:
    # o comprimento é comparado ABERTAMENTE, e de propósito: não é segredo, e um
    # MAC do tamanho errado nunca ia bater. O que não pode vazar é ONDE os dois
    # diferem — por isso o laço nunca sai a meio.
    if a.len != b.len:
        return False
    diff: u8 = u8(0)
    for i in range(i64(a.len)):
        diff |= u8(a.ptr[i]) ^ u8(b.ptr[i])
    return diff == u8(0)
