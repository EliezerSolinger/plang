"""`compress` — DEFLATE, zlib e gzip, nossos.

Três formatos e um algoritmo. O algoritmo é o **DEFLATE** da RFC 1951; o **zlib**
(RFC 1950) é ele com dois bytes à frente e um Adler-32 atrás; o **gzip**
(RFC 1952) é ele com um cabeçalho maior e um CRC-32 atrás. Confundi-los é o erro
mais comum de quem usa a `zlib` pela primeira vez, e é por isso que aqui são três
pares de funções com três nomes e não um parâmetro.

**Porque é nosso e não a libc:** a `zlib` do sistema é uma dependência de
compilação com uma ABI e uma história de CVEs, e o que ela faz cabe aqui. O
`tar` já quer isto, e o cliente HTTP quer `Accept-Encoding: gzip` — que é onde a
descompressão deixa de ser um extra e passa a ser o que faz metade da web
responder.

**A descompressão é a parte que importa e é a que se faz primeiro.** Ler o que os
outros escreveram é o que desbloqueia consumidores; escrever bem é uma
optimização que se pode adiar sem que nada fique por fazer. Por isso o `deflate`
daqui **guarda em BLOCOS LITERAIS** — comprime zero, é válido para qualquer
leitor do mundo, e diz aqui que é isso que faz em vez de fingir.
"""


# ---------- ler bit a bit ----------
#
# O DEFLATE lê bits do byte menos significativo para cima, e os códigos de
# Huffman ao contrário disso — o bit mais significativo primeiro. As duas ordens
# no mesmo fluxo são a razão de metade das implementações caseiras não
# funcionarem, e estão separadas aqui em duas funções com nomes diferentes.

struct Bits:
    data: bytes
    pos: int        # o byte a seguir
    bit: int        # quantos bits já se tiraram deste byte
    acc: int        # o que ainda não se leu
    nacc: int


def bits_new(b: bytes) -> Bits:
    return Bits(b, 0, 0, 0, 0)


def need(s: Bits, n: int):
    while s.nacc < n:
        if s.pos >= len(s.data):
            raise error("deflate: the stream ends in the middle of a block", VALUE)
        s.acc = s.acc | (int(s.data[s.pos]) << s.nacc)
        s.nacc += 8
        s.pos += 1


def take(s: Bits, n: int) -> int:
    """`n` bits, do menos significativo para cima — a ordem dos CAMPOS."""
    if n == 0:
        return 0
    need(s, n)
    v = s.acc & ((1 << n) - 1)
    s.acc = s.acc >> n
    s.nacc -= n
    return v


def align(s: Bits):
    """Deita fora o resto do byte: é o que um bloco literal manda fazer."""
    s.acc = 0
    s.nacc = 0


# ---------- a árvore de Huffman ----------
#
# Guardada como o RFC 1951 §3.2.2 a descreve: os comprimentos dos códigos, e a
# partir deles os códigos canónicos. Descodificar é andar bit a bit e comparar
# com o primeiro código de cada comprimento — sem tabela, sem árvore de
# ponteiros, e portanto sem nada para alocar por símbolo.

struct Huff:
    counts: List<int>       # quantos códigos há de cada comprimento (0..15)
    symbols: List<int>      # os símbolos, por ordem de código


def huff_build(lengths: List<int>) -> Huff:
    counts: List<int> = []
    for _ in range(16):
        counts.append(0)
    for L in lengths:
        counts[L] += 1
    counts[0] = 0
    offs: List<int> = []
    for _ in range(16):
        offs.append(0)
    for k in range(1, 16):
        offs[k] = offs[k - 1] + counts[k - 1]
    syms: List<int> = []
    for _ in range(len(lengths)):
        syms.append(0)
    for i in range(len(lengths)):
        if lengths[i] != 0:
            syms[offs[lengths[i]]] = i
            offs[lengths[i]] += 1
    return Huff(counts, syms)


def huff_decode(s: Bits, h: Huff) -> int:
    """Um símbolo. Os bits de um código vêm do mais significativo para o menos —
    ao contrário dos campos, e é essa a armadilha desta secção."""
    code = 0
    first = 0
    index = 0
    for L in range(1, 16):
        code = code | take(s, 1)
        count = h.counts[L]
        if code - first < count:
            return h.symbols[index + (code - first)]
        index += count
        first = (first + count) << 1
        code = code << 1
    raise error("deflate: a Huffman code that is not in the tree", VALUE)


# ---------- as tabelas do RFC 1951 §3.2.5 ----------

const LEN_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
const LEN_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                   3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
const DIST_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                   257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                   8193, 12289, 16385, 24577]
const DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
# a ordem em que os comprimentos do alfabeto de comprimentos aparecem (§3.2.7):
# não é 0..18, e é assim porque os que quase nunca se usam ficam no fim e podem
# ser omitidos
const CLEN_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]


def fixed_lit() -> Huff:
    """A árvore FIXA dos literais (§3.2.6): 8 bits para 0..143, 9 para 144..255,
    7 para 256..279 e 8 para 280..287. Está na norma como número, e é por isso
    que um bloco de tipo 1 não carrega tabela nenhuma."""
    L: List<int> = []
    for i in range(288):
        if i < 144:
            L.append(8)
        elif i < 256:
            L.append(9)
        elif i < 280:
            L.append(7)
        else:
            L.append(8)
    return huff_build(L)


def fixed_dist() -> Huff:
    L: List<int> = []
    for _ in range(30):
        L.append(5)
    return huff_build(L)


# ---------- inflate ----------

def inflate(src: bytes) -> bytes:
    """DEFLATE cru (RFC 1951) — o que está DENTRO de um zlib ou de um gzip."""
    s = bits_new(src)
    out: List<u8> = []
    while True:
        final = take(s, 1)
        kind = take(s, 2)
        if kind == 0:
            # bloco literal: alinha, e o comprimento vem repetido ao contrário
            align(s)
            if s.pos + 4 > len(src):
                raise error("deflate: a stored block with no header", VALUE)
            n = int(src[s.pos]) | (int(src[s.pos + 1]) << 8)
            m = int(src[s.pos + 2]) | (int(src[s.pos + 3]) << 8)
            if n + m != 65535:
                # o complemento existe precisamente para apanhar um fluxo
                # truncado ou trocado, e ignorá-lo é deitar fora a verificação
                raise error("deflate: the stored block length does not match its complement", VALUE)
            s.pos += 4
            if s.pos + n > len(src):
                raise error("deflate: a stored block runs past the end", VALUE)
            for k in range(n):
                out.append(src[s.pos + k])
            s.pos += n
        elif kind == 1:
            inflate_block(s, out, fixed_lit(), fixed_dist())
        elif kind == 2:
            t = read_dynamic(s)
            inflate_block(s, out, t.lit, t.dist)
        else:
            raise error("deflate: block type 3 does not exist", VALUE)
        if final != 0:
            break
    return bytes(out)


def inflate_block(s: Bits, out: List<u8>, lit: Huff, dist: Huff):
    while True:
        sym = huff_decode(s, lit)
        if sym < 256:
            out.append(u8(sym))
            continue
        if sym == 256:
            return
        sym -= 257
        if sym >= 29:
            raise error("deflate: a length symbol that does not exist", VALUE)
        length = LEN_BASE[sym] + take(s, LEN_EXTRA[sym])
        dsym = huff_decode(s, dist)
        if dsym >= 30:
            raise error("deflate: a distance symbol that does not exist", VALUE)
        d = DIST_BASE[dsym] + take(s, DIST_EXTRA[dsym])
        if d > len(out):
            raise error("deflate: a back reference that points before the start", VALUE)
        # A cópia é byte a byte DE PROPÓSITO e não em bloco: com `d < length` a
        # referência lê o que ela própria acabou de escrever, e é assim que uma
        # sequência que se repete se escreve em três bytes. Copiar em bloco
        # partiria exactamente esse caso, que é o mais comum de todos.
        start = len(out) - d
        for k in range(length):
            out.append(out[start + k])


struct Trees:
    lit: Huff
    dist: Huff


def read_dynamic(s: Bits) -> Trees:
    """A tabela de um bloco de tipo 2 (§3.2.7).

    É a parte mais barroca do formato, e a razão dela é boa: os comprimentos dos
    códigos são eles próprios comprimidos, com uma terceira árvore que vem à
    frente. Dezanove símbolos, numa ordem escolhida para os raros ficarem no fim
    e poderem ser omitidos.
    """
    hlit = take(s, 5) + 257
    hdist = take(s, 5) + 1
    hclen = take(s, 4) + 4
    clens: List<int> = []
    for _ in range(19):
        clens.append(0)
    for k in range(hclen):
        clens[CLEN_ORDER[k]] = take(s, 3)
    ctree = huff_build(clens)
    lens: List<int> = []
    prev = 0
    while len(lens) < hlit + hdist:
        c = huff_decode(s, ctree)
        if c < 16:
            lens.append(c)
            prev = c
        elif c == 16:
            # repete o ANTERIOR, 3 a 6 vezes
            if len(lens) == 0:
                raise error("deflate: a repeat with nothing before it", VALUE)
            n = 3 + take(s, 2)
            for _ in range(n):
                lens.append(prev)
        elif c == 17:
            n = 3 + take(s, 3)
            for _ in range(n):
                lens.append(0)
        else:
            n = 11 + take(s, 7)
            for _ in range(n):
                lens.append(0)
    if len(lens) > hlit + hdist:
        raise error("deflate: the code lengths overflow their table", VALUE)
    litl: List<int> = []
    for k in range(hlit):
        litl.append(lens[k])
    distl: List<int> = []
    for k in range(hdist):
        distl.append(lens[hlit + k])
    return Trees(huff_build(litl), huff_build(distl))


# ---------- as somas de verificação ----------

def adler32(b: bytes) -> int:
    """A do zlib (RFC 1950 §9). Mais fraca do que o CRC-32 e muito mais barata —
    e é a escolha que a norma fez, não a nossa."""
    a = 1
    c = 0
    for x in b:
        a = (a + int(x)) % 65521
        c = (c + a) % 65521
    return (c << 16) | a


def crc32(b: bytes) -> int:
    """A do gzip (RFC 1952), a mesma do pacote `hash` — repetida aqui para este
    pacote não depender daquele por uma função de vinte linhas."""
    tbl = crc_table()
    c = 4294967295
    for x in b:
        c = tbl[(c ^ int(x)) & 255] ^ (c >> 8)
    return c ^ 4294967295


def crc_table() -> List<int>:
    t: List<int> = []
    for i in range(256):
        c = i
        for _ in range(8):
            if (c & 1) != 0:
                c = (c >> 1) ^ 3988292384
            else:
                c = c >> 1
        t.append(c)
    return t


# ---------- zlib (RFC 1950) ----------

def zlib_decompress(src: bytes) -> bytes:
    if len(src) < 6:
        raise error("zlib: too short to be a zlib stream", VALUE)
    cmf = int(src[0])
    flg = int(src[1])
    if (cmf & 15) != 8:
        raise error("zlib: the only compression method is 8 (deflate)", VALUE)
    if (cmf * 256 + flg) % 31 != 0:
        raise error("zlib: the header check does not pass", VALUE)
    if (flg & 32) != 0:
        raise error("zlib: a preset dictionary is not supported", VALUE)
    out = inflate(bytes(src[2:len(src) - 4]))
    want = (int(src[len(src) - 4]) << 24) | (int(src[len(src) - 3]) << 16) | (int(src[len(src) - 2]) << 8) | int(src[len(src) - 1])
    got = adler32(out)
    if got != want:
        # 4.2: um CRC que não bate NÃO é uma condição do algoritmo — é o
        # ficheiro a dizer uma coisa e a ser outra, e isso levanta
        raise error("zlib: the Adler-32 does not match — the stream is corrupt", VALUE)
    return out


def zlib_compress(src: bytes) -> bytes:
    out: List<u8> = []
    out.append(u8(0x78))
    out.append(u8(0x01))
    for x in deflate(src):
        out.append(x)
    a = adler32(src)
    out.append(u8((a >> 24) & 255))
    out.append(u8((a >> 16) & 255))
    out.append(u8((a >> 8) & 255))
    out.append(u8(a & 255))
    return bytes(out)


# ---------- gzip (RFC 1952) ----------

def gzip_decompress(src: bytes) -> bytes:
    if len(src) < 18:
        raise error("gzip: too short to be a gzip stream", VALUE)
    if int(src[0]) != 31 or int(src[1]) != 139:
        raise error("gzip: the magic number is not 1f 8b", VALUE)
    if int(src[2]) != 8:
        raise error("gzip: the only compression method is 8 (deflate)", VALUE)
    flg = int(src[3])
    p = 10
    if (flg & 4) != 0:                      # FEXTRA
        if p + 2 > len(src):
            raise error("gzip: the extra field runs past the end", VALUE)
        xlen = int(src[p]) | (int(src[p + 1]) << 8)
        p += 2 + xlen
    if (flg & 8) != 0:                      # FNAME
        p = skip_zstring(src, p, "the file name")
    if (flg & 16) != 0:                     # FCOMMENT
        p = skip_zstring(src, p, "the comment")
    if (flg & 2) != 0:                      # FHCRC
        p += 2
    if p + 8 > len(src):
        raise error("gzip: nothing left after the header", VALUE)
    out = inflate(bytes(src[p:len(src) - 8]))
    n = len(src)
    want = int(src[n - 8]) | (int(src[n - 7]) << 8) | (int(src[n - 6]) << 16) | (int(src[n - 5]) << 24)
    if crc32(out) != want:
        raise error("gzip: the CRC-32 does not match — the stream is corrupt", VALUE)
    size = int(src[n - 4]) | (int(src[n - 3]) << 8) | (int(src[n - 2]) << 16) | (int(src[n - 1]) << 24)
    # o tamanho está no ficheiro em 32 bits, portanto a comparação é módulo 2^32
    # — e para um ficheiro maior do que 4 GiB é ele que está errado, não nós
    if (len(out) % 4294967296) != size:
        raise error("gzip: the length does not match — the stream is truncated", VALUE)
    return out


def skip_zstring(b: bytes, at: int, what: str) -> int:
    j = at
    while j < len(b) and int(b[j]) != 0:
        j += 1
    if j >= len(b):
        raise error("gzip: " + what + " has no terminator", VALUE)
    return j + 1


def gzip_compress(src: bytes) -> bytes:
    out: List<u8> = []
    for x in [31, 139, 8, 0, 0, 0, 0, 0, 0, 255]:
        out.append(u8(x))
    for x in deflate(src):
        out.append(x)
    c = crc32(src)
    n = len(src) % 4294967296
    for k in range(4):
        out.append(u8((c >> (k * 8)) & 255))
    for k in range(4):
        out.append(u8((n >> (k * 8)) & 255))
    return bytes(out)


# ---------- deflate ----------

def deflate(src: bytes) -> bytes:
    """DEFLATE em **blocos literais**, e o docstring diz porquê em vez de fingir.

    Comprime zero e é válido para qualquer leitor do mundo — o formato tem um
    tipo de bloco para exactamente isto. É o que permite ao `gzip_compress` e ao
    `zlib_compress` existirem e produzirem ficheiros que o `gunzip` abre, sem que
    a parte que importa (LER o que os outros escreveram) espere por um
    compressor bom.

    Quando o compressor a sério chegar, é esta função que muda e mais nada.
    """
    # 148: chegou. O `deflate_fixed` lá em baixo é LZ77 com a árvore fixa, e esta
    # função é o que a promessa acima dizia que mudaria — o `gzip_compress` e o
    # `zlib_compress` não mexeram numa linha. O caminho dos blocos literais fica
    # abaixo, inalcançável mas legível: é a explicação do formato mais curta que
    # existe, e um dia serve para um `nivel=0`.
    return deflate_fixed(src)


def deflate_stored(src: bytes) -> bytes:
    """DEFLATE em blocos LITERAIS: comprime zero e é válido para qualquer leitor
    do mundo, porque o formato tem um tipo de bloco para exactamente isto."""
    out: List<u8> = []
    n = len(src)
    if n == 0:
        # um fluxo vazio ainda tem de ter um bloco final, senão não acaba
        out.append(u8(1))
        out.append(u8(0))
        out.append(u8(0))
        out.append(u8(255))
        out.append(u8(255))
        return bytes(out)
    at = 0
    while at < n:
        take_n = 65535 if n - at > 65535 else n - at
        last = 1 if at + take_n >= n else 0
        out.append(u8(last))
        out.append(u8(take_n & 255))
        out.append(u8((take_n >> 8) & 255))
        out.append(u8((65535 - take_n) & 255))
        out.append(u8(((65535 - take_n) >> 8) & 255))
        for k in range(take_n):
            out.append(src[at + k])
        at += take_n
    return bytes(out)


# ---------- 148: o COMPRESSOR a serio ----------
#
# O `deflate` acima comprime zero por desenho, e o docstring dele diz que quando o
# compressor a serio chegar e essa funcao que muda. Chegou; ela passou a chamar
# esta, e mais nada mudou.
#
# **LZ77 mais Huffman FIXO**, e a escolha do fixo em vez do dinamico e uma
# decisao de custo: uma arvore dinamica ganha uns 10% em texto e obriga a contar
# frequencias, construir duas arvores canonicas e emiti-las com o terceiro
# alfabeto do RFC -- cerca de tres vezes o codigo que esta aqui, para dez por
# cento. O fixo esta na norma como numero, portanto um bloco de tipo 1 nao leva
# tabela nenhuma, e num servidor o que se poupa e a viagem pela rede e nao o
# ultimo byte.
#
# **A ARMADILHA DA ORDEM DOS BITS**, que e onde todo o mundo se corta: o fluxo do
# DEFLATE escreve-se do bit menos significativo para o mais, MAS um codigo de
# Huffman escreve-se do bit MAIS significativo para o menos. Portanto os dois
# escritores abaixo sao diferentes de proposito -- `put` e `put_code` -- e trocar
# um pelo outro da um ficheiro que nenhum leitor abre.

struct Out:
    """O escritor de bits, do menos significativo para o mais (RFC 1951 s3.1.1)."""
    b: List<u8>
    acc: int        # os bits ainda nao escritos
    n: int          # quantos ha no acumulador


def out_new() -> Out:
    return Out([], 0, 0)


def put(o: Out, v: int, n: int):
    """`n` bits de `v`, do menos significativo primeiro."""
    nocheck:
        o.acc = o.acc | ((v & ((1 << n) - 1)) << o.n)
        o.n += n
        while o.n >= 8:
            o.b.append(u8(o.acc & 255))
            o.acc = o.acc >> 8
            o.n -= 8


def put_code(o: Out, codigo: int, n: int):
    """Um codigo de Huffman: do bit MAIS significativo primeiro.

    E a inversao que faz o formato parecer contraditorio e nao e: o FLUXO e
    little-endian nos bits, e um CODIGO e big-endian. O RFC diz as duas coisas em
    paragrafos diferentes, e quem le so uma escreve um ficheiro que nao abre.
    """
    nocheck:
        i = n - 1
        while i >= 0:
            put(o, (codigo >> i) & 1, 1)
            i -= 1


def out_flush(o: Out) -> bytes:
    if o.n > 0:
        o.b.append(u8(o.acc & 255))
        o.acc = 0
        o.n = 0
    return bytes(o.b)


# os codigos da arvore FIXA, em valor e em largura (s3.2.6). Sao numeros da norma:
# 0..143 em 8 bits comecando em 0x30, 144..255 em 9 comecando em 0x190, 256..279
# em 7 comecando em 0, 280..287 em 8 comecando em 0xC0.
def lit_code(s: int) -> int:
    if s < 144:
        return 0x30 + s
    if s < 256:
        return 0x190 + (s - 144)
    if s < 280:
        return s - 256
    return 0xC0 + (s - 280)


def lit_bits(s: int) -> int:
    if s < 144:
        return 8
    if s < 256:
        return 9
    if s < 280:
        return 7
    return 8


def len_symbol(n: int) -> int:
    """Qual simbolo de comprimento cobre `n` bytes (3..258), pela tabela do RFC."""
    i = 28
    while i > 0 and LEN_BASE[i] > n:
        i -= 1
    return i


def dist_symbol(d: int) -> int:
    i = 29
    while i > 0 and DIST_BASE[i] > d:
        i -= 1
    return i


const HASH_BITS = 15
const HASH_SIZE = 32768
const JANELA = 32768
const MAX_MATCH = 258
const MIN_MATCH = 3
# quantas posicoes da cadeia se experimentam antes de aceitar o que se tem. E o
# botao de "quao bom" -- 128 e o territorio do nivel 6 do zlib, e subi-lo paga
# cada vez menos.
const MAX_CADEIA = 128


def deflate_fixed(src: bytes) -> bytes:
    """LZ77 com a arvore fixa. Um bloco so, final."""
    o = out_new()
    # tipo 1 (arvore fixa), e este e o ultimo bloco
    put(o, 1, 1)
    put(o, 1, 2)
    n = len(src)
    # a tabela de dispersao e as cadeias: `cabeca[h]` e a posicao mais recente
    # com aquele hash, e `anterior[p]` e a anterior a `p`. E a estrutura do zlib,
    # e cabe em duas listas.
    cabeca: List<int> = []
    for _ in range(HASH_SIZE):
        cabeca.append(-1)
    anterior: List<int> = []
    for _ in range(n if n > 0 else 1):
        anterior.append(-1)
    at = 0
    while at < n:
        melhor_len = 0
        melhor_dist = 0
        if at + MIN_MATCH <= n:
            h = 0
            nocheck:
                h = ((int(src[at]) << 10) ^ (int(src[at + 1]) << 5) ^ int(src[at + 2])) & (HASH_SIZE - 1)
            p = cabeca[h]
            # a INSCRICAO vem antes da busca, e a ordem e o defeito facil: o
            # `anterior[at]` tem de guardar a cabeca ANTIGA, e so depois e que a
            # cabeca passa a ser `at`. Ao contrario, `anterior[at]` fica igual a
            # `at` -- um laco sobre si mesmo, e a busca seguinte gira para sempre.
            anterior[at] = p
            cabeca[h] = at
            tentativas = 0
            while p >= 0 and tentativas < MAX_CADEIA:
                if at - p > JANELA:
                    break
                k = 0
                lim = MAX_MATCH if n - at > MAX_MATCH else n - at
                while k < lim and src[p + k] == src[at + k]:
                    k += 1
                if k > melhor_len:
                    melhor_len = k
                    melhor_dist = at - p
                    if k >= lim:
                        break
                p = anterior[p]
                tentativas += 1
        if melhor_len >= MIN_MATCH:
            sl = len_symbol(melhor_len)
            put_code(o, lit_code(257 + sl), lit_bits(257 + sl))
            if LEN_EXTRA[sl] > 0:
                put(o, melhor_len - LEN_BASE[sl], LEN_EXTRA[sl])
            sd = dist_symbol(melhor_dist)
            put_code(o, sd, 5)
            if DIST_EXTRA[sd] > 0:
                put(o, melhor_dist - DIST_BASE[sd], DIST_EXTRA[sd])
            # as posicoes DENTRO do casamento tambem entram na tabela: sem isso a
            # cadeia perde-as e os casamentos seguintes ficam curtos
            k2 = 1
            while k2 < melhor_len and at + k2 + MIN_MATCH <= n:
                h2 = 0
                nocheck:
                    h2 = ((int(src[at + k2]) << 10) ^ (int(src[at + k2 + 1]) << 5) ^ int(src[at + k2 + 2])) & (HASH_SIZE - 1)
                anterior[at + k2] = cabeca[h2]
                cabeca[h2] = at + k2
                k2 += 1
            at += melhor_len
        else:
            s = int(src[at])
            put_code(o, lit_code(s), lit_bits(s))
            at += 1
    # 256 e o fim do bloco
    put_code(o, lit_code(256), lit_bits(256))
    return out_flush(o)
