"""HMAC-SHA256 visto do lado do P (RFC 4231), e a comparação que não vaza.

Os vectores oficiais estão no teste do pscript, que é onde eles atravessam a
fronteira; aqui prova-se o que só se vê deste lado: que a forma CRUA e a forma em
hex dizem a mesma coisa, e que `hmac_equal` olha para todos os bytes.
"""

include <stdio.h>
include <string.h>
import <stl/cstr.ph>
import <hmac/hmac.ph>

def main() -> int:
    key: const *char = "key"
    msg: const *char = "The quick brown fox jumps over the lazy dog"
    k: CBytes = {(*u8)(key), strlen(key)}
    m: CBytes = {(*u8)(msg), strlen(msg)}
    hex: CStr = hmac_sha256(in k, in m)
    printf("hex  %.*s\n", i32(hex.len), hex.ptr)

    # a mesma coisa em bruto, escrita à mão em hex: se as duas não baterem, uma
    # das duas está errada e não se sabe qual — que é a razão de haver as duas
    raw: char[32]
    hmac_sha256_raw(in k, in m, raw)
    HEXD: const *char = "0123456789abcdef"
    out: char[65]
    for i in range(32):
        b: u8 = u8(raw[i])
        out[i * 2] = HEXD[(b >> 4) & u8(0xF)]
        out[i * 2 + 1] = HEXD[b & u8(0xF)]
    out[64] = '\0'
    printf("raw  %s\n", out)

    a1: CStr = {.ptr = (*char)(out), .len = usize(64)}
    printf("batem: %s\n", "sim" if hmac_equal(in hex, in a1) else "nao")

    # e um MAC diferente não bate, nem um do tamanho errado
    out[63] = '0' if out[63] != '0' else '1'
    a2: CStr = {.ptr = (*char)(out), .len = usize(64)}
    printf("um byte diferente: %s\n", "nao bate" if not hmac_equal(in hex, in a2) else "BATEU?!")
    a3: CStr = {.ptr = (*char)(out), .len = usize(10)}
    printf("tamanho diferente: %s\n", "nao bate" if not hmac_equal(in hex, in a3) else "BATEU?!")
    return 0
