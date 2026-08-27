"""Um pacote do protocolo MySQL, lido campo a campo.

Porte de `pymysql/protocol.py`. Um pacote é uma sequência de bytes com um cursor,
e o protocolo é uma gramática de inteiros de largura fixa, inteiros codificados
por comprimento, e strings — terminadas em NUL ou precedidas do seu tamanho.

O que muda do Python: lá um pacote é `bytes` com fatias; aqui é uma `bytes`
imutável com um índice que anda. `read(n)` devolve uma fatia nova (17.3 copia),
e o cursor é um campo do `struct` — coletado, mutável, com identidade —, porque
ele MUDA a cada leitura, que é o oposto de um `record`.

Todos os inteiros do protocolo são LITTLE-ENDIAN, e é isso que as montagens
manuais aqui embaixo assumem em cada `byte >> 8`.
"""

const NULL_COLUMN = 251
const UNSIGNED_CHAR_COLUMN = 251
const UNSIGNED_SHORT_COLUMN = 252
const UNSIGNED_INT24_COLUMN = 253
const UNSIGNED_INT64_COLUMN = 254


struct Packet:
    """A carga de um pacote (sem o cabeçalho de 4 bytes) e um cursor sobre ela."""
    data: bytes
    pos: int

    def read(self, size: int) -> bytes:
        """Os próximos `size` bytes, e o cursor anda. Pedir além do fim levanta —
        um protocolo que lê menos do que espera está dessincronizado, e seguir
        seria ler lixo como se fosse um valor."""
        if self.pos + size > len(self.data):
            raise error(f"pacote curto: pedidos {size} em {self.pos}, tamanho {len(self.data)}")
        r = self.data[self.pos:self.pos + size]
        self.pos += size
        return r

    def read_all(self) -> bytes:
        """O que resta, e o cursor vai para o fim."""
        r = self.data[self.pos:len(self.data)]
        self.pos = len(self.data)
        return r

    def remaining(self) -> int:
        return len(self.data) - self.pos

    def read_uint8(self) -> int:
        b = self.data[self.pos]
        self.pos += 1
        return b

    def read_uint16(self) -> int:
        d = self.data
        p = self.pos
        self.pos += 2
        # `int()` ANTES do shift: `d[p]` é u8, e `u8 << 8` fica preso em 8 bits
        # (68.2 mascara à largura), então sem a promoção o byte alto some. Ver
        # ACHADOS-PORTE.md — é uma armadilha silenciosa.
        return int(d[p]) | (int(d[p + 1]) << 8)

    def read_uint24(self) -> int:
        d = self.data
        p = self.pos
        self.pos += 3
        return int(d[p]) | (int(d[p + 1]) << 8) | (int(d[p + 2]) << 16)

    def read_uint32(self) -> int:
        d = self.data
        p = self.pos
        self.pos += 4
        return (int(d[p]) | (int(d[p + 1]) << 8)
                | (int(d[p + 2]) << 16) | (int(d[p + 3]) << 24))

    def read_uint64(self) -> int:
        # o resultado cabe em i64 sem sinal só até 2^63-1; acima disso o valor
        # é um id que ninguém compara como número, então a montagem dá a volta
        # de propósito — é o caso de `nocheck:` existir
        d = self.data
        p = self.pos
        self.pos += 8
        r = 0
        i = 7
        while i >= 0:
            r = (r << 8) | int(d[p + i])
            i -= 1
        return r

    def read_string(self) -> bytes?:
        """Uma string terminada em NUL. `None` se não houver NUL até o fim —
        que é como o protocolo diz "este campo opcional não veio"."""
        d = self.data
        i = self.pos
        n = len(d)
        while i < n and d[i] != 0:
            i += 1
        if i >= n:
            return None
        r = d[self.pos:i]
        self.pos = i + 1
        return r

    def read_length_encoded_integer(self) -> int?:
        """O "length coded binary" do MySQL: 1 a 9 bytes conforme o primeiro.
        `None` quando o primeiro byte é 251 — o NULL de uma coluna."""
        c = self.read_uint8()
        if c == NULL_COLUMN:
            return None
        if c < UNSIGNED_CHAR_COLUMN:
            return c
        if c == UNSIGNED_SHORT_COLUMN:
            return self.read_uint16()
        if c == UNSIGNED_INT24_COLUMN:
            return self.read_uint24()
        return self.read_uint64()

    def read_length_coded_string(self) -> bytes?:
        """Um inteiro codificado por comprimento seguido de tantos bytes. É
        assim que cada valor de uma linha de resultado chega."""
        length = self.read_length_encoded_integer()
        if length == None:
            return None
        return self.read(length)

    def is_ok_packet(self) -> bool:
        return len(self.data) >= 7 and self.data[0] == 0

    def is_eof_packet(self) -> bool:
        # cuidado: 0xFE também é o cabeçalho de um inteiro codificado; um EOF
        # verdadeiro tem menos de 9 bytes
        return self.data[0] == 0xFE and len(self.data) < 9

    def is_auth_switch_request(self) -> bool:
        return self.data[0] == 0xFE

    def is_extra_auth_data(self) -> bool:
        return self.data[0] == 1

    def is_resultset_packet(self) -> bool:
        c = self.data[0]
        return c >= 1 and c <= 250

    def is_error_packet(self) -> bool:
        return self.data[0] == 0xFF


def new_packet(data: bytes) -> Packet:
    return Packet(data, 0)


# ── inteiro codificado por comprimento, na ESCRITA ────────────────────────────
# O espelho de `read_length_encoded_integer`, para montar o pacote de resposta.

def lenenc_int(i: int) -> bytes:
    if i < 0:
        raise error(f"length-encoded negativo: {i}")
    out: List<u8> = []
    if i < 251:
        out.append(u8(i))
    elif i < 65536:
        out.append(u8(0xFC))
        out.append(u8(i & 0xFF))
        out.append(u8((i >> 8) & 0xFF))
    elif i < 16777216:
        out.append(u8(0xFD))
        out.append(u8(i & 0xFF))
        out.append(u8((i >> 8) & 0xFF))
        out.append(u8((i >> 16) & 0xFF))
    else:
        out.append(u8(0xFE))
        k = 0
        v = i
        while k < 8:
            out.append(u8(v & 0xFF))
            v = v >> 8
            k += 1
    return bytes(out)


def pack_uint24(n: int) -> bytes:
    """O comprimento no cabeçalho de 4 bytes de um pacote: 3 bytes little-endian."""
    return bytes([u8(n & 0xFF), u8((n >> 8) & 0xFF), u8((n >> 16) & 0xFF)])


def pack_uint32(n: int) -> bytes:
    return bytes([u8(n & 0xFF), u8((n >> 8) & 0xFF),
                  u8((n >> 16) & 0xFF), u8((n >> 24) & 0xFF)])
