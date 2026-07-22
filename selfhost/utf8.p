# utf8.p — stage 1 of the pipeline: bytes UTF-8 -> UTF-32 (port of src/utf8.c)
# Uses P's fixed-width aliases (u32/usize/i32 — spec §3.1.1).
import "plang.ph"

def utf8_encode(cp: u32, out: char[4]) -> i32:
    if cp < 0x80:
        out[0] = char(cp)
        return 1
    if cp < 0x800:
        out[0] = char(0xC0 | (cp >> 6))
        out[1] = char(0x80 | (cp & 0x3F))
        return 2
    if cp < 0x10000:
        out[0] = char(0xE0 | (cp >> 12))
        out[1] = char(0x80 | ((cp >> 6) & 0x3F))
        out[2] = char(0x80 | (cp & 0x3F))
        return 3
    out[0] = char(0xF0 | (cp >> 18))
    out[1] = char(0x80 | ((cp >> 12) & 0x3F))
    out[2] = char(0x80 | ((cp >> 6) & 0x3F))
    out[3] = char(0x80 | (cp & 0x3F))
    return 4

def utf8_decode(bytes: const *char, nbytes: usize, a: *Arena, out_cp: **u32, out_off: **u32, out_n: *usize, err_off: *usize) -> i32:
    cp: *u32 = arena_alloc(a, (nbytes + 1) * sizeof(u32))
    off: *u32 = arena_alloc(a, (nbytes + 1) * sizeof(u32))
    i: usize = 0
    n: usize = 0

    # skip BOM if present ("& 0xFF" reads the byte as unsigned)
    if nbytes >= 3 and (bytes[0] & 0xFF) == 0xEF and (bytes[1] & 0xFF) == 0xBB and (bytes[2] & 0xFF) == 0xBF:
        i = 3

    while i < nbytes:
        b: i32 = bytes[i] & 0xFF
        v: u32
        len: i32
        if b < 0x80:
            v = u32(b); len = 1
        elif (b & 0xE0) == 0xC0:
            v = u32(b & 0x1F); len = 2
        elif (b & 0xF0) == 0xE0:
            v = u32(b & 0x0F); len = 3
        elif (b & 0xF8) == 0xF0:
            v = u32(b & 0x07); len = 4
        else:
            goto bad
        if i + usize(len) > nbytes:
            goto bad
        for k in range(1, len):
            c: i32 = bytes[i + k] & 0xFF
            if (c & 0xC0) != 0x80:
                goto bad
            v = (v << 6) | u32(c & 0x3F)
        # overlong, surrogates, and max range
        if (len == 2 and v < 0x80) or (len == 3 and v < 0x800) or (len == 4 and v < 0x10000):
            goto bad
        if v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF):
            goto bad

        off[n] = u32(i)
        cp[n] = v
        n += 1
        i += usize(len)

    *out_cp = cp
    *out_off = off
    *out_n = n
    return 0

    bad:
    if err_off != None:
        *err_off = i
    return -1
