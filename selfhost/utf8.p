# utf8.p — stage 1 of the pipeline: bytes UTF-8 -> UTF-32 (port of src/utf8.c)
# Uses P's fixed-width aliases (u32/usize/i32 — spec §3.1.1).
import "plang.ph"
import <stl/utf8.ph>

def utf8_decode(bytes: const *char, nbytes: usize, a: *Arena, out out_cp: *u32, out out_off: *u32, out out_n: usize, err_off: *usize) -> i32:
    cp: *u32 = a->alloc((nbytes + 1) * sizeof(u32))
    off: *u32 = a->alloc((nbytes + 1) * sizeof(u32))
    i: usize = 0
    n: usize = 0

    # skip BOM if present ("& 0xFF" reads the byte as unsigned)
    if nbytes >= 3 and (bytes[0] & 0xFF) == 0xEF and (bytes[1] & 0xFF) == 0xBB and (bytes[2] & 0xFF) == 0xBF:
        i = 3

    while i < nbytes:
        # the code point itself is `stl/utf8`'s answer; what is LEFT here is the
        # decision this function exists to make — where the results go. Two
        # parallel arrays out of the arena, because the lexer wants the code
        # points to index and the byte offsets to point diagnostics at.
        v: u32
        w: usize = utf8_next(bytes, nbytes, i, out v)
        if w == 0:
            goto bad
        off[n] = u32(i)
        cp[n] = v
        n += 1
        i += w

    out_cp = cp
    out_off = off
    out_n = n
    return 0

    bad:
    if err_off != None:
        *err_off = i
    return -1
