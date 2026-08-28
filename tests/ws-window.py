"""Le um fluxo DEFLATE cru de arvore FIXA e diz qual foi a maior DISTANCIA de
casamento que ele emite.

Existe porque o `zlib` do CPython **nao serve de oraculo** para esta pergunta: um
`decompressobj(wbits=-8)` aceita alegremente um fluxo com casamentos a 400 bytes
de distancia, portanto passa tanto o codigo certo como o errado. O que o RFC 7692
exige quando se responde `server_max_window_bits=N` e que nenhuma distancia passe
2^N — e a unica maneira de o conferir e olhar para os simbolos.

E um descodificador INDEPENDENTE, escrito do RFC 1951 e nao do nosso compressor:
se os dois estivessem errados da mesma maneira concordariam entre si e com mais
ninguem, e por isso a tabela da arvore fixa esta aqui escrita a mao.
"""
import sys

LEN_BASE = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258]
LEN_EXTRA = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0]
DIST_BASE = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577]
DIST_EXTRA = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13]


class Bits:
    def __init__(self, data):
        self.d, self.i, self.acc, self.n = data, 0, 0, 0

    def get(self, k):
        """k bits, LSB primeiro — a ordem de empacotamento do DEFLATE."""
        while self.n < k:
            if self.i >= len(self.d):
                raise EOFError("o fluxo acabou a meio")
            self.acc |= self.d[self.i] << self.n
            self.i += 1
            self.n += 8
        v = self.acc & ((1 << k) - 1)
        self.acc >>= k
        self.n -= k
        return v

    def code(self, k):
        """k bits de um CODIGO de Huffman — MSB primeiro, ao contrario dos
        valores. Trocar as duas ordens e o erro classico deste formato."""
        v = 0
        for _ in range(k):
            v = (v << 1) | self.get(1)
        return v


def fixed_symbol(b):
    """Um simbolo da arvore fixa (RFC 1951 s3.2.6), decodificado pelo comprimento.

    As quatro faixas estao escritas por extenso de propositio: e a tabela da
    norma, e derivavel-la de uma construcao de Huffman seria repetir a estrutura
    que se quer conferir.
    """
    c = b.code(7)                       # 0000000-0010111 -> 256..279
    if c <= 0b0010111:
        return 256 + c
    c = (c << 1) | b.get(1)             # 8 bits
    if 0b00110000 <= c <= 0b10111111:
        return c - 0b00110000           # 0..143
    if 0b11000000 <= c <= 0b11000111:
        return 280 + (c - 0b11000000)   # 280..287
    c = (c << 1) | b.get(1)             # 9 bits
    if 0b110010000 <= c <= 0b111111111:
        return 144 + (c - 0b110010000)  # 144..255
    raise ValueError(f"codigo invalido na arvore fixa: {c:b}")


def max_distance(raw):
    """A maior distancia emitida, e quantos casamentos houve."""
    b = Bits(raw)
    maior, quantos, literais = 0, 0, 0
    while True:
        final = b.get(1)
        tipo = b.get(2)
        if tipo == 0:                   # bloco ARMAZENADO: alinha e salta
            b.acc, b.n = 0, 0
            if b.i + 4 > len(b.d):
                break
            ln = b.d[b.i] | (b.d[b.i + 1] << 8)
            b.i += 4 + ln
            if final or b.i >= len(b.d):
                break
            continue
        if tipo != 1:
            raise ValueError(f"este leitor so trata a arvore fixa, veio BTYPE={tipo}")
        while True:
            s = fixed_symbol(b)
            if s == 256:
                break
            if s < 256:
                literais += 1
                continue
            k = s - 257
            b.get(LEN_EXTRA[k])
            ds = b.code(5)
            d = DIST_BASE[ds] + (b.get(DIST_EXTRA[ds]) if DIST_EXTRA[ds] else 0)
            quantos += 1
            maior = max(maior, d)
        if final:
            break
        if b.i >= len(b.d) and b.n == 0:
            break
    return maior, quantos, literais


if __name__ == "__main__":
    mau = 0
    for linha in sys.stdin:
        linha = linha.strip()
        if not linha:
            continue
        bits, hexs = linha.split()
        # o fluxo vem SEM os quatro bytes do sync flush, como o s7.2.1 manda
        raw = bytes.fromhex(hexs) + b"\x00\x00\xff\xff"
        maior, quantos, lit = max_distance(raw)
        limite = 1 << int(bits)
        ok = maior <= limite
        if not ok:
            mau = 1
        print(f"bits={bits} limite={limite} maior_distancia={maior} "
              f"casamentos={quantos} literais={lit} {'ok' if ok else 'PASSOU O LIMITE'}")
    sys.exit(mau)
