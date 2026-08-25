# utf8.ph — UTF-8, ONE code point at a time.
#
# This is the only UTF-8 in the tree. It used to be five: the pscript runtime
# had three (`ps_utf8_put`, `ps_str_chr` and a `js_utf8` in the JSON writer whose
# comment argued that copies could not drift — repetition is what MAKES drift),
# the `url` package had two, and out in the packages three more had been written
# by hand that were not UTF-8 at all but Latin-1 wearing the name. An operation
# with no home is written again by everyone who needs it, and each writing is
# only as correct as that caller's inputs demanded that day.
#
# Both functions are PURE: no allocation, no arena, no error object. They take
# a buffer you own and an index into it, and they answer with a count. That is
# what lets the same two lines serve a lexer reading a file, a runtime building
# a string, and a program that just wants to write an accent.
#
#   # write
#   k = utf8_put(buf, k, 0x1F600)
#
#   # read
#   w: usize = utf8_next(buf, n, i, out cp)
#   if w == 0:
#       ...   # `i` is the offending byte
#   i += w
#
# Both are `private`, which is to say STATIC: the bodies live in this header and
# every translation unit that imports it gets its own copy. That is not a
# compromise, it is the requirement — `pcode` links the compiler's lexer and the
# pscript runtime into one binary, and both read UTF-8. A module with external
# linkage would give that link two definitions of the same symbol, which is
# exactly the collision `cstr.p`'s comment describes and which `implement` solves
# for types. Free functions have no `implement`; `private` is the answer, and it
# costs twelve lines of machine code per binary.
#
# What is NOT here: decoding a whole buffer. That needs somewhere to put the
# result, and "somewhere" is a decision (an arena, a vector, two parallel
# arrays) that belongs to the caller. `selfhost/utf8.p` makes exactly that
# choice for the lexer, on top of `utf8_next`.

# One code point, UTF-8, written at `buf[k]`; returns where the next one goes.
#
# It does NOT validate `cp`: a surrogate or a value above U+10FFFF produces
# bytes that are not UTF-8. Callers that take code points from outside (a
# parser, a `chr()`) check first — the check has a different answer in each of
# them, and burying one here would make it the wrong answer somewhere.
private def utf8_put(buf: *char, k: usize, cp: u32) -> usize:
    if cp < 0x80:
        buf[k] = char(cp)
        return k + usize(1)
    if cp < 0x800:
        buf[k] = char(0xC0 | (cp >> 6))
        buf[k + usize(1)] = char(0x80 | (cp & 0x3F))
        return k + usize(2)
    if cp < 0x10000:
        buf[k] = char(0xE0 | (cp >> 12))
        buf[k + usize(1)] = char(0x80 | ((cp >> 6) & 0x3F))
        buf[k + usize(2)] = char(0x80 | (cp & 0x3F))
        return k + usize(3)
    buf[k] = char(0xF0 | (cp >> 18))
    buf[k + usize(1)] = char(0x80 | ((cp >> 12) & 0x3F))
    buf[k + usize(2)] = char(0x80 | ((cp >> 6) & 0x3F))
    buf[k + usize(3)] = char(0x80 | (cp & 0x3F))
    return k + usize(4)

# One code point, read from `buf[i]` of a buffer `n` bytes long. Returns how
# many bytes it consumed (1 to 4), or ZERO if what is there is not UTF-8 —
# in which case `i` is the offending byte and `cp` is untouched.
#
# Zero and not -1 because the return is a WIDTH: the caller's loop is `i += w`,
# and a width of zero is the only value that cannot be added to `i` by mistake.
#
# What it refuses, and every one of them is a real attack or a real bug:
# a truncated sequence, a continuation byte that is not one, an OVERLONG
# encoding (`0xC0 0x80` for NUL, the classic filter bypass), a surrogate half
# (U+D800..U+DFFF, which UTF-8 has no business carrying), and anything above
# U+10FFFF.
private def utf8_next(buf: const *char, n: usize, i: usize, out cp: u32) -> usize:
    if i >= n:
        return 0
    # "& 0xFF" reads the byte as unsigned: `char` is signed on most targets, and
    # without this every byte above 0x7F arrives negative
    b: i32 = buf[i] & 0xFF
    v: u32
    w: i32
    if b < 0x80:
        v = u32(b); w = 1
    elif (b & 0xE0) == 0xC0:
        v = u32(b & 0x1F); w = 2
    elif (b & 0xF0) == 0xE0:
        v = u32(b & 0x0F); w = 3
    elif (b & 0xF8) == 0xF0:
        v = u32(b & 0x07); w = 4
    else:
        # a continuation byte with nothing in front of it, or 0xF8..0xFF, which
        # no UTF-8 sequence has ever started with
        return 0
    if i + usize(w) > n:
        return 0
    for k in range(1, w):
        c: i32 = buf[i + usize(k)] & 0xFF
        if (c & 0xC0) != 0x80:
            return 0
        v = (v << 6) | u32(c & 0x3F)
    # OVERLONG: the same code point written in more bytes than it needs. It is
    # not a curiosity — `0xC0 0x80` is NUL wearing two bytes, and a decoder that
    # accepts it walks a filter that was looking for a plain 0x00.
    if (w == 2 and v < 0x80) or (w == 3 and v < 0x800) or (w == 4 and v < 0x10000):
        return 0
    if v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF):
        return 0
    cp = v
    return usize(w)
