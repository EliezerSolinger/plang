import "pmod_text.ph"
implement CStr
implement CBytes

def texto_tamanho(in s: CStr) -> i64:
    return i64(s.len)

# devolve memória DE QUEM CHAMA? não: um buffer estático deste módulo, válido
# até a próxima chamada — a convenção do `strerror`, e a única que não precisa
# que alguém libere
static g_buf: char[256]

def texto_maiusculo(in s: CStr) -> CStr:
    n: usize = s.len if s.len < usize(255) else usize(255)
    for i in range(n):
        c: char = s.ptr[i]
        g_buf[i] = char(i32(c) - 32) if c >= 'a' and c <= 'z' else c
    g_buf[n] = '\0'
    return cstr_n(g_buf, n)

def bytes_soma(in b: CBytes) -> i64:
    t: i64 = 0
    for i in range(b.len):
        t += i64(b.ptr[i])
    return t

def versao() -> CStr:
    return cstr("1.2.3")

# bytes que NÃO são UTF-8: a travessia tem de recusar
static g_bad: char[4]

def nao_utf8() -> CStr:
    g_bad[0] = char(0xFF)
    g_bad[1] = char(0xFE)
    g_bad[2] = '\0'
    return cstr_n(g_bad, usize(2))
