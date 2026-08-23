# The RFC 8032 implementation. See `ed25519.ph` for the choices and for what
# this package does NOT promise.
import <ed25519/ed25519.ph>
import <sha2/sha2.ph>

# ---------- 256-bit integers, eight 32-bit words ----------
#
# Little depends on the representation: the field is F(2^255 - 19) and the scalar
# is modulo L. Both fit in 256 bits, and the product of two fits in 512.

struct Fe:
    v: u32[8]        # little-endian: v[0] is the lowest 32 bits

private def fe_zero(out r: Fe):
    for i in range(8):
        r.v[i] = u32(0)

private def fe_set(out r: Fe, n: u32):
    fe_zero(out r)
    r.v[0] = n

private def fe_copy(out r: Fe, a: Fe):
    for i in range(8):
        r.v[i] = a.v[i]

private def fe_is_zero(a: Fe) -> bool:
    acc: u32 = u32(0)
    for i in range(8):
        acc |= a.v[i]
    return acc == u32(0)

private def fe_eq(a: Fe, b: Fe) -> bool:
    for i in range(8):
        if a.v[i] != b.v[i]:
            return False
    return True

# p = 2^255 - 19
private const P: const u32[8] = {
    0xffffffed, 0xffffffff, 0xffffffff, 0xffffffff,
    0xffffffff, 0xffffffff, 0xffffffff, 0x7fffffff}

# addition with carry, without reducing: returns the final carry
private def add_raw(ref r: u32[8], a: Fe, b: Fe) -> u32:
    c: u64 = u64(0)
    for i in range(8):
        c += u64(a.v[i]) + u64(b.v[i])
        r[i] = u32(c & u64(0xffffffff))
        c >>= u64(32)
    return u32(c)

# subtraction with borrow: returns 1 when a < b
private def sub_raw(ref r: u32[8], a: Fe, b: Fe) -> u32:
    br: u64 = u64(0)
    for i in range(8):
        d: u64 = u64(a.v[i]) - u64(b.v[i]) - br
        r[i] = u32(d & u64(0xffffffff))
        br = u64(1) if (d >> u64(63)) != u64(0) else u64(0)
    return u32(br)

# a >= p ?
private def ge_p(a: Fe) -> bool:
    i: i32 = 7
    while i >= 0:
        if a.v[i] != P[i]:
            return a.v[i] > P[i]
        i -= 1
    return True

private def fe_reduce_once(ref a: Fe):
    if ge_p(a):
        pv: Fe
        for i in range(8):
            pv.v[i] = P[i]
        t: u32[8]
        sub_raw(ref t, a, pv)
        for i in range(8):
            a.v[i] = t[i]

private def fe_add(out r: Fe, a: Fe, b: Fe):
    t: u32[8]
    c: u32 = add_raw(ref t, a, b)
    for i in range(8):
        r.v[i] = t[i]
    # the carry out of 2^256 is worth 38 modulo p (because 2^255 ≡ 19)
    if c != u32(0):
        cc: u64 = u64(38)
        for i in range(8):
            cc += u64(r.v[i])
            r.v[i] = u32(cc & u64(0xffffffff))
            cc >>= u64(32)
    fe_reduce_once(ref r)

private def fe_sub(out r: Fe, a: Fe, b: Fe):
    t: u32[8]
    br: u32 = sub_raw(ref t, a, b)
    for i in range(8):
        r.v[i] = t[i]
    if br != u32(0):
        # a and b are both in [0, p), so a - b is in (-p, p): adding p ONCE is
        # enough, and the carry out of 2^256 is exactly what cancels the borrow
        # the subtraction left behind
        cc: u64 = u64(0)
        for i in range(8):
            cc += u64(r.v[i]) + u64(P[i])
            r.v[i] = u32(cc & u64(0xffffffff))
            cc >>= u64(32)
    fe_reduce_once(ref r)

# 512 bits -> 256, modulo p, using 2^256 ≡ 38
private def reduce512(ref w: u32[16], out r: Fe):
    # r = lo + 38 * hi, and the result of that fits in 256 bits plus a few
    acc: u64 = u64(0)
    t: u32[9]
    for i in range(8):
        acc += u64(w[i]) + u64(38) * u64(w[8 + i])
        t[i] = u32(acc & u64(0xffffffff))
        acc >>= u64(32)
    t[8] = u32(acc)
    # ... and again, now with only one word on top
    acc = u64(38) * u64(t[8])
    for i in range(8):
        acc += u64(t[i])
        r.v[i] = u32(acc & u64(0xffffffff))
        acc >>= u64(32)
    # whatever is left is still worth 38, and this time it does not overflow
    if acc != u64(0):
        acc *= u64(38)
        for i in range(8):
            acc += u64(r.v[i])
            r.v[i] = u32(acc & u64(0xffffffff))
            acc >>= u64(32)
    fe_reduce_once(ref r)

private def fe_mul(out r: Fe, a: Fe, b: Fe):
    w: u32[16]
    for i in range(16):
        w[i] = u32(0)
    for i in range(8):
        carry: u64 = u64(0)
        for j in range(8):
            # it fits: (2^32-1)^2 + 2*(2^32-1) < 2^64
            cur: u64 = u64(w[i + j]) + u64(a.v[i]) * u64(b.v[j]) + carry
            w[i + j] = u32(cur & u64(0xffffffff))
            carry = cur >> u64(32)
        k: i32 = i + 8
        while carry != u64(0):
            cur2: u64 = u64(w[k]) + carry
            w[k] = u32(cur2 & u64(0xffffffff))
            carry = cur2 >> u64(32)
            k += 1
    reduce512(ref w, out r)

private def fe_sq(out r: Fe, a: Fe):
    fe_mul(out r, a, a)

# a^(2^n) — only to chain in the inverse computation
private def fe_sq_n(ref a: Fe, n: i32):
    for i in range(n):
        t: Fe
        fe_sq(out t, a)
        fe_copy(out a, t)

# a^(p-2) = a^-1, by the RFC's addition chain (the same path as ref10)
private def fe_inv(out r: Fe, z: Fe):
    z2: Fe
    z9: Fe
    z11: Fe
    t0: Fe
    t1: Fe
    t2: Fe
    fe_sq(out z2, z)                 # 2
    fe_sq(out t1, z2)
    fe_sq(out t0, t1)                # 8
    fe_mul(out z9, t0, z)            # 9
    fe_mul(out z11, z9, z2)          # 11
    fe_sq(out t0, z11)               # 22
    fe_mul(out t1, t0, z9)           # 2^5 - 1
    fe_copy(out t0, t1)
    fe_sq_n(ref t0, 5)
    fe_mul(out t2, t0, t1)           # 2^10 - 1
    fe_copy(out t0, t2)
    fe_sq_n(ref t0, 10)
    fe_mul(out t1, t0, t2)           # 2^20 - 1
    fe_copy(out t0, t1)
    fe_sq_n(ref t0, 20)
    fe_mul(out t0, t0, t1)           # 2^40 - 1
    fe_sq_n(ref t0, 10)
    fe_mul(out t1, t0, t2)           # 2^50 - 1
    fe_copy(out t0, t1)
    fe_sq_n(ref t0, 50)
    fe_mul(out t2, t0, t1)           # 2^100 - 1
    fe_copy(out t0, t2)
    fe_sq_n(ref t0, 100)
    fe_mul(out t0, t0, t2)           # 2^200 - 1
    fe_sq_n(ref t0, 50)
    fe_mul(out t0, t0, t1)           # 2^250 - 1
    fe_sq_n(ref t0, 5)
    fe_mul(out r, t0, z11)           # 2^255 - 21 = p - 2

# a^((p-5)/8), the square root's exponent
private def fe_pow22523(out r: Fe, z: Fe):
    t0: Fe
    t1: Fe
    t2: Fe
    fe_sq(out t0, z)
    fe_sq(out t1, t0)
    fe_sq(out t1, t1)
    fe_mul(out t1, z, t1)
    fe_mul(out t0, t0, t1)
    fe_sq(out t0, t0)
    fe_mul(out t0, t1, t0)           # 2^5 - 1
    fe_copy(out t1, t0)
    fe_sq_n(ref t1, 5)
    fe_mul(out t0, t1, t0)           # 2^10 - 1
    fe_copy(out t1, t0)
    fe_sq_n(ref t1, 10)
    fe_mul(out t1, t1, t0)           # 2^20 - 1
    fe_copy(out t2, t1)
    fe_sq_n(ref t2, 20)
    fe_mul(out t1, t2, t1)           # 2^40 - 1
    fe_sq_n(ref t1, 10)
    fe_mul(out t0, t1, t0)           # 2^50 - 1
    fe_copy(out t1, t0)
    fe_sq_n(ref t1, 50)
    fe_mul(out t1, t1, t0)           # 2^100 - 1
    fe_copy(out t2, t1)
    fe_sq_n(ref t2, 100)
    fe_mul(out t1, t2, t1)           # 2^200 - 1
    fe_sq_n(ref t1, 50)
    fe_mul(out t0, t1, t0)           # 2^250 - 1
    fe_sq_n(ref t0, 2)
    fe_mul(out r, t0, z)             # 2^252 - 3 = (p-5)/8

private def fe_neg(out r: Fe, a: Fe):
    z: Fe
    fe_zero(out z)
    fe_sub(out r, z, a)

private def fe_is_negative(a: Fe) -> bool:
    return (a.v[0] & u32(1)) != u32(0)

private def fe_from_bytes(out r: Fe, s: const *char):
    for i in range(8):
        r.v[i] = u32(u8(s[i * 4])) | (u32(u8(s[i * 4 + 1])) << 8) | (u32(u8(s[i * 4 + 2])) << 16) | (u32(u8(s[i * 4 + 3])) << 24)
    r.v[7] &= u32(0x7fffffff)        # bit 255 is x's sign, not part of y
    fe_reduce_once(ref r)

private def fe_to_bytes(a: Fe, out_s: *char):
    t: Fe
    fe_copy(out t, a)
    fe_reduce_once(ref t)
    for i in range(8):
        out_s[i * 4] = char(t.v[i] & u32(0xff))
        out_s[i * 4 + 1] = char((t.v[i] >> 8) & u32(0xff))
        out_s[i * 4 + 2] = char((t.v[i] >> 16) & u32(0xff))
        out_s[i * 4 + 3] = char((t.v[i] >> 24) & u32(0xff))


# ---------- the group: extended coordinates (X : Y : Z : T), with X*Y = Z*T ----------
#
# The curve is -x² + y² = 1 + d·x²·y². The formulas are those of "Twisted Edwards
# Curves Revisited" (Hisil et al.), which is what RFC 8032 uses: addition with no
# special cases — the same code serves for P + Q, for P + P and for the identity —
# and it is that absence of special cases that makes an implementation
# checkable.

struct Ge:
    X: Fe
    Y: Fe
    Z: Fe
    T: Fe

# d = -121665/121666 mod p
private const D_BYTES: const u32[8] = {
    0x135978a3, 0x75eb4dca, 0x4141d8ab, 0x00700a4d,
    0x7779e898, 0x8cc74079, 0x2b6ffe73, 0x52036cee}

# 2d
private const D2_BYTES: const u32[8] = {
    0x26b2f159, 0xebd69b94, 0x8283b156, 0x00e0149a,
    0xeef3d130, 0x198e80f2, 0x56dffce7, 0x2406d9dc}

# sqrt(-1) mod p
private const SQRTM1_BYTES: const u32[8] = {
    0x4a0ea0b0, 0xc4ee1b27, 0xad2fe478, 0x2f431806,
    0x3dfbd7a7, 0x2b4d0099, 0x4fc1df0b, 0x2b832480}

# the generator B: y = 4/5, x is the positive one
private const BX: const u32[8] = {
    0x8f25d51a, 0xc9562d60, 0x9525a7b2, 0x692cc760,
    0xfdd6dc5c, 0xc0a4e231, 0xcd6e53fe, 0x216936d3}
private const BY: const u32[8] = {
    0x66666658, 0x66666666, 0x66666666, 0x66666666,
    0x66666666, 0x66666666, 0x66666666, 0x66666666}

private def fe_const(out r: Fe, k: const *u32):
    for i in range(8):
        r.v[i] = k[i]

private def ge_zero(out r: Ge):
    fe_set(out r.X, u32(0))
    fe_set(out r.Y, u32(1))
    fe_set(out r.Z, u32(1))
    fe_set(out r.T, u32(0))

private def ge_base(out r: Ge):
    fe_const(out r.X, BX)
    fe_const(out r.Y, BY)
    fe_set(out r.Z, u32(1))
    fe_mul(out r.T, r.X, r.Y)

private def ge_copy(out r: Ge, a: Ge):
    fe_copy(out r.X, a.X)
    fe_copy(out r.Y, a.Y)
    fe_copy(out r.Z, a.Z)
    fe_copy(out r.T, a.T)

# P + Q, with no special cases
private def ge_add(out r: Ge, p1: Ge, q: Ge):
    d2: Fe
    fe_const(out d2, D2_BYTES)
    a: Fe
    b: Fe
    c: Fe
    dd: Fe
    e: Fe
    f: Fe
    g: Fe
    h: Fe
    t0: Fe
    t1: Fe
    fe_sub(out t0, p1.Y, p1.X)
    fe_sub(out t1, q.Y, q.X)
    fe_mul(out a, t0, t1)                 # A = (Y1-X1)(Y2-X2)
    fe_add(out t0, p1.Y, p1.X)
    fe_add(out t1, q.Y, q.X)
    fe_mul(out b, t0, t1)                 # B = (Y1+X1)(Y2+X2)
    fe_mul(out t0, p1.T, q.T)
    fe_mul(out c, t0, d2)                 # C = T1*T2*2d
    fe_mul(out dd, p1.Z, q.Z)
    fe_add(out dd, dd, dd)                # D = Z1*Z2*2
    fe_sub(out e, b, a)
    fe_sub(out f, dd, c)
    fe_add(out g, dd, c)
    fe_add(out h, b, a)
    fe_mul(out r.X, e, f)
    fe_mul(out r.Y, g, h)
    fe_mul(out r.T, e, h)
    fe_mul(out r.Z, f, g)

private def ge_double(out r: Ge, p1: Ge):
    ge_add(out r, p1, p1)

# k*P, double-and-add over the scalar's bits, from the highest to the lowest.
# NOT constant time — see the note in the `.ph`.
private def ge_scalarmult(out r: Ge, k: const *char, p1: Ge):
    acc: Ge
    ge_zero(out acc)
    i: i32 = 255
    while i >= 0:
        t: Ge
        ge_double(out t, acc)
        ge_copy(out acc, t)
        bit: u8 = (u8(k[i / 8]) >> u8(i % 8)) & u8(1)
        if bit != u8(0):
            t2: Ge
            ge_add(out t2, acc, p1)
            ge_copy(out acc, t2)
        i -= 1
    ge_copy(out r, acc)

private def ge_scalarmult_base(out r: Ge, k: const *char):
    b: Ge
    ge_base(out b)
    ge_scalarmult(out r, k, b)

# (X:Y:Z) -> the 32 bytes: y in little-endian, and bit 255 carries x's sign
private def ge_encode(p1: Ge, out_s: *char):
    zi: Fe
    x: Fe
    y: Fe
    fe_inv(out zi, p1.Z)
    fe_mul(out x, p1.X, zi)
    fe_mul(out y, p1.Y, zi)
    fe_to_bytes(y, out_s)
    if fe_is_negative(x):
        out_s[31] = char(u8(out_s[31]) | u8(0x80))

# ... and the way back: recovering x from y. It fails when the point is not on
# the curve, which is what stops an invented "public key" from being accepted.
private def ge_decode(out r: Ge, s: const *char) -> bool:
    y: Fe
    u: Fe
    v: Fe
    x: Fe
    one: Fe
    d: Fe
    fe_from_bytes(out y, s)
    fe_set(out one, u32(1))
    fe_const(out d, D_BYTES)
    fe_sq(out u, y)
    fe_mul(out v, u, d)
    fe_sub(out u, u, one)                 # u = y² - 1
    fe_add(out v, v, one)                 # v = d·y² + 1
    # x = u·v³ · (u·v⁷)^((p-5)/8)
    v3: Fe
    v7: Fe
    t: Fe
    fe_sq(out t, v)
    fe_mul(out v3, t, v)                  # v³
    fe_sq(out t, v3)
    fe_mul(out v7, t, v)                  # v⁷
    fe_mul(out t, u, v7)
    pw: Fe
    fe_pow22523(out pw, t)
    fe_mul(out t, u, v3)
    fe_mul(out x, t, pw)
    # check: v·x² == u ? otherwise try x·sqrt(-1)
    chk: Fe
    fe_sq(out chk, x)
    fe_mul(out chk, chk, v)
    diff: Fe
    fe_sub(out diff, chk, u)
    if not fe_is_zero(diff):
        fe_add(out diff, chk, u)
        if not fe_is_zero(diff):
            return False                  # not on the curve
        sq: Fe
        fe_const(out sq, SQRTM1_BYTES)
        fe_mul(out x, x, sq)
    # and the sign has to match the bit that came in
    quer_neg: bool = (u8(s[31]) >> u8(7)) != u8(0)
    if fe_is_zero(x) and quer_neg:
        return False                      # x = 0 with a negative sign does not exist
    if fe_is_negative(x) != quer_neg:
        fe_neg(out x, x)
    fe_copy(out r.X, x)
    fe_copy(out r.Y, y)
    fe_set(out r.Z, u32(1))
    fe_mul(out r.T, x, y)
    return True


# ---------- the scalar, modulo L ----------
#
# L = 2^252 + 27742317777372353535851937790883648493 is the subgroup's order. It
# has no shape that helps (unlike p), so the reduction here is bit-by-bit long
# division: five hundred and twelve iterations of "shift, and subtract if it
# fits". It is the slowest thing in this file and the easiest to check by
# reading, and it is the right trade — this runs half a dozen times per
# publication.

private const L: const u32[8] = {
    0x5cf5d3ed, 0x5812631a, 0xa2f79cd6, 0x14def9de,
    0x00000000, 0x00000000, 0x00000000, 0x10000000}

private def sc_ge_l(ref r: u32[8]) -> bool:
    i: i32 = 7
    while i >= 0:
        if r[i] != L[i]:
            return r[i] > L[i]
        i -= 1
    return True

private def sc_sub_l(ref r: u32[8]):
    br: u64 = u64(0)
    for i in range(8):
        d: u64 = u64(r[i]) - u64(L[i]) - br
        r[i] = u32(d & u64(0xffffffff))
        br = u64(1) if (d >> u64(63)) != u64(0) else u64(0)

# `w` is `nbytes` in little-endian; the output is 32 bytes holding w mod L
private def sc_reduce_bytes(w: const *char, nbytes: i32, out_s: *char):
    r: u32[8]
    for z in range(8):
        r[z] = u32(0)
    i: i32 = nbytes * 8 - 1
    while i >= 0:
        # shift one place
        carry: u32 = u32(0)
        for j in range(8):
            nx: u32 = r[j] >> 31
            r[j] = (r[j] << 1) | carry
            carry = nx
        r[0] |= u32((u8(w[i / 8]) >> u8(i % 8)) & u8(1))
        if sc_ge_l(ref r):
            sc_sub_l(ref r)
        i -= 1
    for k in range(8):
        out_s[k * 4] = char(r[k] & u32(0xff))
        out_s[k * 4 + 1] = char((r[k] >> 8) & u32(0xff))
        out_s[k * 4 + 2] = char((r[k] >> 16) & u32(0xff))
        out_s[k * 4 + 3] = char((r[k] >> 24) & u32(0xff))

# (a*b + c) mod L, with a, b and c of 32 bytes
private def sc_muladd(a: const *char, b: const *char, c: const *char, out_s: *char):
    av: u32[8]
    bv: u32[8]
    for i in range(8):
        av[i] = u32(u8(a[i * 4])) | (u32(u8(a[i * 4 + 1])) << 8) | (u32(u8(a[i * 4 + 2])) << 16) | (u32(u8(a[i * 4 + 3])) << 24)
        bv[i] = u32(u8(b[i * 4])) | (u32(u8(b[i * 4 + 1])) << 8) | (u32(u8(b[i * 4 + 2])) << 16) | (u32(u8(b[i * 4 + 3])) << 24)
    w: u32[17]
    for i in range(17):
        w[i] = u32(0)
    for i in range(8):
        carry: u64 = u64(0)
        for j in range(8):
            cur: u64 = u64(w[i + j]) + u64(av[i]) * u64(bv[j]) + carry
            w[i + j] = u32(cur & u64(0xffffffff))
            carry = cur >> u64(32)
        k: i32 = i + 8
        while carry != u64(0):
            cur2: u64 = u64(w[k]) + carry
            w[k] = u32(cur2 & u64(0xffffffff))
            carry = cur2 >> u64(32)
            k += 1
    # + c
    cc: u64 = u64(0)
    for i in range(8):
        ci: u32 = u32(u8(c[i * 4])) | (u32(u8(c[i * 4 + 1])) << 8) | (u32(u8(c[i * 4 + 2])) << 16) | (u32(u8(c[i * 4 + 3])) << 24)
        cc += u64(w[i]) + u64(ci)
        w[i] = u32(cc & u64(0xffffffff))
        cc >>= u64(32)
    k2: i32 = 8
    while cc != u64(0):
        cc += u64(w[k2])
        w[k2] = u32(cc & u64(0xffffffff))
        cc >>= u64(32)
        k2 += 1
    bytes: char[68]
    for i in range(17):
        bytes[i * 4] = char(w[i] & u32(0xff))
        bytes[i * 4 + 1] = char((w[i] >> 8) & u32(0xff))
        bytes[i * 4 + 2] = char((w[i] >> 16) & u32(0xff))
        bytes[i * 4 + 3] = char((w[i] >> 24) & u32(0xff))
    sc_reduce_bytes(bytes, 68, out_s)

# S < L ? — RFC 8032 §5.1.7 requires refusing anything else, and that is the
# difference between a signature and its malleable variants
private def sc_lt_l(s: const *char) -> bool:
    i: i32 = 7
    while i >= 0:
        wi: u32 = u32(u8(s[i * 4])) | (u32(u8(s[i * 4 + 1])) << 8) | (u32(u8(s[i * 4 + 2])) << 16) | (u32(u8(s[i * 4 + 3])) << 24)
        if wi != L[i]:
            return wi < L[i]
        i -= 1
    return False


# ---------- the RFC's three operations ----------

private def clamp(ref a: char[32]):
    # the low three bits to zero (the cofactor is 8) and bit 254 to one: it is
    # what makes the scalar always land in the right subgroup and always have the
    # same length
    a[0] = char(u8(a[0]) & u8(248))
    a[31] = char((u8(a[31]) & u8(127)) | u8(64))

def ed25519_pubkey(seed: const *char, out_pub: *char):
    h: char[64]
    sha512_hex_unused: i32 = 0
    s: Sha512
    sha512_init(out s)
    sha512_update(ref s, seed, usize(32))
    sha512_final(ref s, h)
    a: char[32]
    memcpy(a, h, usize(32))
    clamp(ref a)
    A: Ge
    ge_scalarmult_base(out A, a)
    ge_encode(A, out_pub)

def ed25519_sign(seed: const *char, pub: const *char, msg: const *char, n: usize, out_sig: *char):
    h: char[64]
    s1: Sha512
    sha512_init(out s1)
    sha512_update(ref s1, seed, usize(32))
    sha512_final(ref s1, h)
    a: char[32]
    memcpy(a, h, usize(32))
    clamp(ref a)
    # r = H(prefix || M) mod L — deterministic, and that is why there is no
    # random generator at all between the key and the signature
    rh: char[64]
    s2: Sha512
    sha512_init(out s2)
    sha512_update(ref s2, h + 32, usize(32))
    sha512_update(ref s2, msg, n)
    sha512_final(ref s2, rh)
    r: char[32]
    sc_reduce_bytes(rh, 64, r)
    R: Ge
    ge_scalarmult_base(out R, r)
    ge_encode(R, out_sig)
    # k = H(R || A || M) mod L
    kh: char[64]
    s3: Sha512
    sha512_init(out s3)
    sha512_update(ref s3, out_sig, usize(32))
    sha512_update(ref s3, pub, usize(32))
    sha512_update(ref s3, msg, n)
    sha512_final(ref s3, kh)
    k: char[32]
    sc_reduce_bytes(kh, 64, k)
    sc_muladd(k, a, r, out_sig + 32)

def ed25519_verify(pub: const *char, msg: const *char, n: usize, sig: const *char) -> bool:
    if not sc_lt_l(sig + 32):
        return False
    A: Ge
    if not ge_decode(out A, pub):
        return False
    R: Ge
    if not ge_decode(out R, sig):
        return False
    kh: char[64]
    s: Sha512
    sha512_init(out s)
    sha512_update(ref s, sig, usize(32))
    sha512_update(ref s, pub, usize(32))
    sha512_update(ref s, msg, n)
    sha512_final(ref s, kh)
    k: char[32]
    sc_reduce_bytes(kh, 64, k)
    # [S]B == R + [k]A ?  — the RFC's form, comparing the encodings
    negA: Ge
    fe_neg(out negA.X, A.X)
    fe_copy(out negA.Y, A.Y)
    fe_copy(out negA.Z, A.Z)
    fe_neg(out negA.T, A.T)
    kA: Ge
    ge_scalarmult(out kA, k, negA)
    SB: Ge
    ge_scalarmult_base(out SB, sig + 32)
    soma: Ge
    ge_add(out soma, SB, kA)
    e1: char[32]
    e2: char[32]
    ge_encode(soma, e1)
    ge_encode(R, e2)
    return memcmp(e1, e2, usize(32)) == 0


# ---------- the crossing into pscript ----------

private const HEX16: const *char = "0123456789abcdef"

private def hexify(src: const *char, n: usize, dst: *char):
    for i in range(n):
        b: u8 = u8(src[i])
        dst[i * 2] = HEX16[b >> 4]
        dst[i * 2 + 1] = HEX16[b & u8(0xf)]
    dst[n * 2] = '\0'

private def unhex1(c: char) -> i32:
    if c >= '0' and c <= '9':
        return i32(c) - i32('0')
    if c >= 'a' and c <= 'f':
        return i32(c) - i32('a') + 10
    if c >= 'A' and c <= 'F':
        return i32(c) - i32('A') + 10
    return -1

private def unhexify(src: const *char, nhex: usize, dst: *char) -> bool:
    if nhex % usize(2) != usize(0):
        return False
    for i in range(nhex / usize(2)):
        hi: i32 = unhex1(src[i * 2])
        lo: i32 = unhex1(src[i * 2 + 1])
        if hi < 0 or lo < 0:
            return False
        dst[i] = char(hi * 16 + lo)
    return True

private g_pubhex: char[65]
private g_sighex: char[129]

def ed25519_pub_hex(in seed: CBytes) -> CStr:
    if seed.len != usize(32):
        g_pubhex[0] = '\0'
        return cstr_n(g_pubhex, usize(0))
    pub: char[32]
    ed25519_pubkey((*char)(seed.ptr), pub)
    hexify(pub, usize(32), g_pubhex)
    return cstr_n(g_pubhex, usize(64))

def ed25519_sign_hex(in seed: CBytes, in msg: CBytes) -> CStr:
    if seed.len != usize(32):
        g_sighex[0] = '\0'
        return cstr_n(g_sighex, usize(0))
    pub: char[32]
    ed25519_pubkey((*char)(seed.ptr), pub)
    sig: char[64]
    ed25519_sign((*char)(seed.ptr), pub, (*char)(msg.ptr), msg.len, sig)
    hexify(sig, usize(64), g_sighex)
    return cstr_n(g_sighex, usize(128))

def ed25519_verify_hex(in pub_hex: CStr, in msg: CBytes, in sig_hex: CStr) -> bool:
    if pub_hex.len != usize(64) or sig_hex.len != usize(128):
        return False
    pub: char[32]
    sig: char[64]
    if not unhexify(pub_hex.ptr, usize(64), pub):
        return False
    if not unhexify(sig_hex.ptr, usize(128), sig):
        return False
    return ed25519_verify(pub, (*char)(msg.ptr), msg.len, sig)
