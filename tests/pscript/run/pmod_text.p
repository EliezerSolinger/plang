import "pmod_text.ph"

def text_length(in s: CStr) -> i64:
    return i64(s.len)

# does it hand back the CALLER's memory? no: a static buffer of this module,
# valid until the next call — the `strerror` convention, and the only one that
# needs nobody to free anything
private g_buf: char[256]

def text_upper(in s: CStr) -> CStr:
    n: usize = s.len if s.len < usize(255) else usize(255)
    for i in range(n):
        c: char = s.ptr[i]
        g_buf[i] = char(i32(c) - 32) if c >= 'a' and c <= 'z' else c
    g_buf[n] = '\0'
    return cstr_n(g_buf, n)

def bytes_sum(in b: CBytes) -> i64:
    t: i64 = 0
    for i in range(b.len):
        t += i64(b.ptr[i])
    return t

def version() -> CStr:
    return cstr("1.2.3")

# bytes that are NOT UTF-8: the crossing has to refuse them
private g_bad: char[4]

def not_utf8() -> CStr:
    g_bad[0] = char(0xFF)
    g_bad[1] = char(0xFE)
    g_bad[2] = '\0'
    return cstr_n(g_bad, usize(2))
