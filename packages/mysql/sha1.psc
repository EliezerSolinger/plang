"""SHA-1 (RFC 3174), em pscript puro.

Por que não reusar o do pacote `hash`: aquele é escrito em P e devolve `CStr`
(hex), e trazê-lo para um programa pscript é a fronteira 45.5 — um shim `.ph`, um
reexport, um ponteiro que atravessa. O `mysql_native_password` precisa dos 20
BYTES crus (`SHA1(x) XOR ...`), não do hex, e precisa de UM hash só. Setenta
linhas autocontidas custam menos do que a ponte, não têm ponteiro nenhum, e são
conferidas aqui contra os vetores oficiais.

**Não é para decidir confiança.** SHA-1 tem colisões desde 2017. Está aqui porque
o protocolo do MySQL o exige no aperto de mão, e ali ele é uma prova de posse da
senha sobre um desafio novo a cada conexão, não um resumo em que se confia.

Toda a aritmética de 32 bits DÁ A VOLTA por definição (é o que o SHA-1 pede), e é
por isso que o laço quente vai num `nocheck:`: sem ele, a primeira soma que
transborda os 32 bits levantaria.
"""


private def rotl32(x: int, n: int) -> int:
    """Gira um valor de 32 bits à esquerda. `x` já vem mascarado a 32 bits."""
    nocheck:
        return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF


def sha1(msg: bytes) -> bytes:
    """Os 20 bytes do SHA-1 de `msg`."""
    h0 = 0x67452301
    h1 = 0xEFCDAB89
    h2 = 0x98BADCFE
    h3 = 0x10325476
    h4 = 0xC3D2E1F0

    ml = len(msg)
    # padding: um 0x80, zeros, e o comprimento em BITS como u64 big-endian
    padded: List<int> = []
    i = 0
    while i < ml:
        padded.append(int(msg[i]))
        i += 1
    padded.append(0x80)
    while len(padded) % 64 != 56:
        padded.append(0)
    bitlen = ml * 8
    k = 7
    while k >= 0:
        padded.append((bitlen >> (k * 8)) & 0xFF)
        k -= 1

    MASK = 0xFFFFFFFF
    w: List<int> = []
    wi = 0
    while wi < 80:
        w.append(0)
        wi += 1

    nocheck:
        chunk = 0
        while chunk < len(padded):
            t = 0
            while t < 16:
                b = chunk + t * 4
                w[t] = ((padded[b] << 24) | (padded[b + 1] << 16)
                        | (padded[b + 2] << 8) | padded[b + 3])
                t += 1
            t = 16
            while t < 80:
                w[t] = rotl32(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1)
                t += 1

            a = h0
            bb = h1
            c = h2
            d = h3
            e = h4

            t = 0
            while t < 80:
                f = 0
                kc = 0
                if t < 20:
                    f = (bb & c) | ((~bb & MASK) & d)
                    kc = 0x5A827999
                elif t < 40:
                    f = bb ^ c ^ d
                    kc = 0x6ED9EBA1
                elif t < 60:
                    f = (bb & c) | (bb & d) | (c & d)
                    kc = 0x8F1BBCDC
                else:
                    f = bb ^ c ^ d
                    kc = 0xCA62C1D6
                tmp = (rotl32(a, 5) + f + e + kc + w[t]) & MASK
                e = d
                d = c
                c = rotl32(bb, 30)
                bb = a
                a = tmp
                t += 1

            h0 = (h0 + a) & MASK
            h1 = (h1 + bb) & MASK
            h2 = (h2 + c) & MASK
            h3 = (h3 + d) & MASK
            h4 = (h4 + e) & MASK
            chunk += 64

    out: List<u8> = []
    for hv in [h0, h1, h2, h3, h4]:
        out.append(u8((hv >> 24) & 0xFF))
        out.append(u8((hv >> 16) & 0xFF))
        out.append(u8((hv >> 8) & 0xFF))
        out.append(u8(hv & 0xFF))
    return bytes(out)
