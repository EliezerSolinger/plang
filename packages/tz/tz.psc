"""`tz` — os fusos com nome, lidos de onde eles vivem.

**Este pacote não traz uma cópia das regras. Lê a do sistema.** E a razão é a
mesma que o `tls` usa para a confiança:

> as regras de fuso mudam **várias vezes por ano** — um país adia o horário de
> verão, outro muda de fuso — e uma cópia nossa estaria errada em produção antes
> de a tinta secar. O sistema já tem a resposta certa, em
> `/usr/share/zoneinfo`, e é o mesmo `apt upgrade` que a corrige.

Por isso o pacote chama-se **`tz`** e não `tzdata`: o que ele tem não é dado, é o
leitor. O formato é o TZif da RFC 8536, que é o que está naqueles ficheiros.

**Quando não há zoneinfo, isto LEVANTA.** Nunca recua para UTC. Um programa que
pede `Europe/Lisbon` e recebe UTC em silêncio marca reuniões à hora errada
durante meio ano, e ninguém descobre porquê.

    import <tz/tz.psc> as tz
    import <datetime/datetime.psc> as dt

    z = await tz.load("Europe/Lisbon")
    agora = dt.now()
    print(dt.zoned_iso(dt.zoned(agora, tz.offset_at(z, agora.second))))
"""
import os
import path
import sys


record Trans:
    """Uma mudança: a partir deste segundo, vale este tipo."""
    at: int
    ty: int


record Kind:
    """Um tipo de tempo local: o deslocamento, e se aquilo é horário de verão."""
    offset: int
    isdst: int


struct Zone:
    """As regras de um fuso, como o ficheiro as tem.

    É um `struct` e não um `record` porque tem listas lá dentro — e é ele que se
    guarda quando um programa converte muitas datas do mesmo sítio, para não
    reler o ficheiro de cada vez.
    """
    name: str
    trans: List<Trans>
    kinds: List<Kind>
    # 149.2: o que vale DEPOIS da última mudança. Um ficheiro TZif acaba com uma
    # regra POSIX (`WET0WEST,M3.5.0/1,M10.5.0`) precisamente porque as mudanças
    # não podem ser listadas até ao infinito — e sem a ler, qualquer data para
    # lá do fim do ficheiro sairia errada em silêncio.
    rule: str


# ---------- ler o ficheiro ----------

def be32(b: bytes, at: int) -> int:
    """Um inteiro de 32 bits com sinal, big-endian — a ordem do TZif."""
    v = (int(b[at]) << 24) | (int(b[at + 1]) << 16) | (int(b[at + 2]) << 8) | int(b[at + 3])
    return v - 4294967296 if v >= 2147483648 else v


def beu32(b: bytes, at: int) -> int:
    return (int(b[at]) << 24) | (int(b[at + 1]) << 16) | (int(b[at + 2]) << 8) | int(b[at + 3])


def be64(b: bytes, at: int) -> int:
    """Um inteiro de 64 bits com sinal, big-endian.

    O sinal entra no PRIMEIRO byte e não no fim, e é de propósito: acumular os
    oito bytes como se fossem positivos passa de 2^63 e o `int` do pscript
    LEVANTA no transbordo (7.2). A partir do topo com sinal, a conta nunca sai
    do intervalo — o pior caso é exactamente -2^63, que cabe.
    """
    v = int(b[at])
    if v >= 128:
        v -= 256
    for k in range(1, 8):
        v = v * 256 + int(b[at + k])
    return v


record Head:
    """As seis contagens do cabeçalho, e onde acaba."""
    isut: int
    isstd: int
    leap: int
    time: int
    types: int
    chars: int
    end: int


def read_head(b: bytes, at: int) -> Head?:
    if at + 44 > len(b):
        return None
    if b[at:at + 4] != b"TZif":
        return None
    return Head(beu32(b, at + 20), beu32(b, at + 24), beu32(b, at + 28),
                beu32(b, at + 32), beu32(b, at + 36), beu32(b, at + 40), at + 44)


def block_size(h: Head, w: int) -> int:
    """Quanto ocupa um bloco de dados com transições de `w` bytes."""
    return h.time * w + h.time + h.types * 6 + h.chars + h.leap * (w + 4) + h.isstd + h.isut


def parse_block(b: bytes, h: Head, w: int, z: Zone):
    """Lê um bloco de dados: as mudanças, os índices e os tipos.

    O `w` é a largura de uma transição — 4 no bloco antigo, 8 no de versão 2. É a
    ÚNICA diferença entre os dois, e é por isso que esta função serve os dois.
    """
    p = h.end
    for k in range(h.time):
        at = be32(b, p + k * w) if w == 4 else be64(b, p + k * w)
        z.trans.append(Trans(at, 0))
    p += h.time * w
    for k in range(h.time):
        z.trans[k] = Trans(z.trans[k].at, int(b[p + k]))
    p += h.time
    for k in range(h.types):
        z.kinds.append(Kind(be32(b, p + k * 6), int(b[p + k * 6 + 4])))


async def load(name: str) -> Zone:
    """As regras de um fuso, pelo nome da IANA (`Europe/Lisbon`).

    `TZDIR` sobrepõe-se ao caminho, que é a variável que o próprio zoneinfo
    define para isso. Um nome com `..` é RECUSADO: este pacote abre um ficheiro
    a partir de um nome que muitas vezes veio de fora, e `../../etc/shadow` é um
    nome perfeitamente válido para quem não olha.
    """
    if name == "" or name.startswith("/") or ".." in name:
        raise error("tz.load(" + name + "): a zone name is like `Europe/Lisbon` — no absolute paths, no `..`", VALUE)
    root = sys.env.get("TZDIR", "/usr/share/zoneinfo")
    p = path.join(root, name)
    if not path.isfile(p):
        # 149.2: LEVANTA, e nunca recua para UTC. Um programa que pede um fuso e
        # recebe UTC em silêncio marca reuniões à hora errada durante meio ano.
        raise error("tz.load(" + name + "): no such zone in " + root
                    + " — is the system's tzdata installed? (TZDIR overrides the path)", IO)
    b: bytes = b""
    with await open(p, "r") as f:
        b = bytes(await f.read_all())
    h1 = read_head(b, 0)
    if h1 == None:
        raise error("tz.load(" + name + "): not a TZif file", VALUE)
    z = Zone(name, [], [], "")
    ver = int(b[4])
    if ver == 0:
        # TZif version 1: só o bloco de 32 bits, e sem regra no fim. Já quase não
        # existe, mas é o que a norma chama o formato base.
        parse_block(b, h1, 4, z)
        return z
    # versão 2 ou mais: o que interessa é o SEGUNDO bloco, com as transições de
    # 64 bits — o primeiro está lá só para quem só sabe ler a versão 1
    at2 = h1.end + block_size(h1, 4)
    h2 = read_head(b, at2)
    if h2 == None:
        raise error("tz.load(" + name + "): the second TZif block is missing", VALUE)
    parse_block(b, h2, 8, z)
    # ... e o rodapé: uma linha entre dois `\n` com a regra POSIX
    tail = h2.end + block_size(h2, 8)
    if tail < len(b) and b[tail] == u8(10):
        j = tail + 1
        while j < len(b) and b[j] != u8(10):
            j += 1
        z.rule = str(b[tail + 1:j])
    return z


# ---------- perguntar ----------

def offset_at(z: Zone, secs: int) -> int:
    """O deslocamento em segundos a leste de UTC, naquele instante.

    Busca BINÁRIA sobre as mudanças: um ficheiro de fuso tem centenas delas, e
    um programa que converta um log inteiro faz esta pergunta uma vez por linha.
    """
    if len(z.trans) == 0:
        return posix_offset(z.rule, secs) if z.rule != "" else first_offset(z)
    if secs < z.trans[0].at:
        # antes da primeira mudança vale o primeiro tipo que NÃO é de verão, que
        # é a regra que a RFC 8536 §3.2 dá
        return first_offset(z)
    if secs >= z.trans[len(z.trans) - 1].at and z.rule != "":
        # depois da última, manda a regra POSIX do rodapé — e é aqui que uma
        # implementação apressada devolve o último deslocamento e erra todas as
        # datas futuras
        return posix_offset(z.rule, secs)
    lo = 0
    hi = len(z.trans) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if z.trans[mid].at <= secs:
            lo = mid
        else:
            hi = mid - 1
    return z.kinds[z.trans[lo].ty].offset


def first_offset(z: Zone) -> int:
    for k in z.kinds:
        if k.isdst == 0:
            return k.offset
    return z.kinds[0].offset if len(z.kinds) > 0 else 0


def is_dst_at(z: Zone, secs: int) -> bool:
    """Se aquele instante está em horário de verão naquele sítio."""
    if len(z.trans) == 0 or secs < z.trans[0].at:
        return False
    lo = 0
    hi = len(z.trans) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if z.trans[mid].at <= secs:
            lo = mid
        else:
            hi = mid - 1
    return z.kinds[z.trans[lo].ty].isdst != 0


# ---------- a regra POSIX do rodapé ----------
#
# `WET0WEST,M3.5.0/1,M10.5.0/2` — o nome padrão, o deslocamento, o nome de verão,
# e as duas datas em que se muda. É o que vale DEPOIS da última transição do
# ficheiro, e sem ela qualquer data para lá de ~2037 sairia errada em silêncio.
#
# O sinal do deslocamento é ao CONTRÁRIO do resto do mundo — no POSIX, `EST5` são
# cinco horas a OESTE. É a armadilha desta secção inteira, e está aqui num sítio
# só.

record PosixRule:
    std_off: int        # já convertido para "a leste", como tudo o resto
    dst_off: int
    has_dst: int
    start_m: int        # M<mes>.<semana>.<dia>
    start_w: int
    start_d: int
    start_secs: int
    end_m: int
    end_w: int
    end_d: int
    end_secs: int
    ok: int


def skip_name(s: str, at: int) -> int:
    """O nome de um fuso: ou entre `<` e `>`, ou letras seguidas."""
    if at < len(s) and s[at] == "<":
        j = at + 1
        while j < len(s) and s[j] != ">":
            j += 1
        return j + 1
    j = at
    while j < len(s):
        c = ord(s[j])
        if (c >= 65 and c <= 90) or (c >= 97 and c <= 122):
            j += 1
        else:
            break
    return j


def read_off(s: str, at: int, out_end: List<int>) -> int:
    """`[+|-]hh[:mm[:ss]]`, devolvido JÁ com o sinal do resto do mundo.

    No POSIX o sinal é INVERTIDO — `EST5` são cinco horas a oeste — e é aqui que
    isso se corrige, uma vez, para que nada mais nesta secção tenha de pensar.
    """
    j = at
    neg = False
    if j < len(s) and (s[j] == "+" or s[j] == "-"):
        neg = s[j] == "-"
        j += 1
    fields: List<int> = []
    cur = 0
    got = False
    while j < len(s):
        c = ord(s[j])
        if c >= 48 and c <= 57:
            cur = cur * 10 + (c - 48)
            got = True
            j += 1
        elif s[j] == ":" and got and len(fields) < 2:
            fields.append(cur)
            cur = 0
            got = False
            j += 1
        else:
            break
    if not got:
        out_end.append(at)
        return 0
    fields.append(cur)
    total = fields[0] * 3600
    if len(fields) > 1:
        total += fields[1] * 60
    if len(fields) > 2:
        total += fields[2]
    out_end.append(j)
    return total if neg else -total


def parse_posix(rule: str) -> PosixRule:
    r = PosixRule(0, 0, 0, 0, 0, 0, 7200, 0, 0, 0, 7200, 0)
    if rule == "":
        return r
    i = skip_name(rule, 0)
    if i == 0 or i > len(rule):
        return r
    e: List<int> = []
    r = PosixRule(read_off(rule, i, e), 0, 0, 0, 0, 0, 7200, 0, 0, 0, 7200, 1)
    i = e[0]
    if i >= len(rule):
        return r
    # há nome de verão: o deslocamento dele é opcional e por omissão é uma hora
    j = skip_name(rule, i)
    if j == i:
        return r
    dst = r.std_off + 3600
    i = j
    if i < len(rule) and rule[i] != ",":
        e2: List<int> = []
        dst = read_off(rule, i, e2)
        i = e2[0]
    if i >= len(rule) or rule[i] != ",":
        return PosixRule(r.std_off, dst, 1, 0, 0, 0, 7200, 0, 0, 0, 7200, 1)
    a: List<int> = []
    i = read_when(rule, i + 1, a)
    if i >= len(rule) or rule[i] != ",":
        return PosixRule(r.std_off, dst, 1, 0, 0, 0, 7200, 0, 0, 0, 7200, 1)
    b: List<int> = []
    i = read_when(rule, i + 1, b)
    if len(a) != 4 or len(b) != 4:
        return PosixRule(r.std_off, dst, 1, 0, 0, 0, 7200, 0, 0, 0, 7200, 1)
    return PosixRule(r.std_off, dst, 1, a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3], 1)


def read_when(s: str, at: int, out: List<int>) -> int:
    """`M<m>.<w>.<d>[/<hora>]` — o único formato que a tzdata usa hoje."""
    if at >= len(s) or s[at] != "M":
        return len(s)
    i = at + 1
    nums: List<int> = []
    cur = 0
    got = False
    while i < len(s):
        c = ord(s[i])
        if c >= 48 and c <= 57:
            cur = cur * 10 + (c - 48)
            got = True
            i += 1
        elif s[i] == "." and got:
            nums.append(cur)
            cur = 0
            got = False
            i += 1
        else:
            break
    if got:
        nums.append(cur)
    secs = 7200
    if i < len(s) and s[i] == "/":
        e: List<int> = []
        # a hora aqui NÃO é um deslocamento: o sinal não se inverte
        secs = -read_off(s, i + 1, e)
        i = e[0]
    if len(nums) != 3:
        return len(s)
    out.append(nums[0])
    out.append(nums[1])
    out.append(nums[2])
    out.append(secs)
    return i


def nth_weekday(y: int, m: int, w: int, d: int) -> int:
    """O dia do mês do `w`-ésimo `d` (0 = domingo, à moda do POSIX).

    `w == 5` quer dizer **o ÚLTIMO**, e não o quinto — é assim que a norma o
    escreve, e é o que faz `M10.5.0` ser "o último domingo de Outubro".
    """
    # 1970-01-01 foi uma quinta; +4 põe o domingo em zero
    first = (days_from_civil_local(y, m, 1) + 4) % 7
    delta = (d - first + 7) % 7
    day = 1 + delta + (w - 1) * 7
    lim = days_in_month_local(y, m)
    while day > lim:
        day -= 7
    return day


def days_from_civil_local(y: int, m: int, d: int) -> int:
    yy = y - 1 if m <= 2 else y
    era = yy // 400
    yoe = yy - era * 400
    mp = m - 3 if m > 2 else m + 9
    doy = (153 * mp + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def days_in_month_local(y: int, m: int) -> int:
    if m == 2:
        if y % 4 != 0:
            return 28
        if y % 100 != 0:
            return 29
        return 29 if y % 400 == 0 else 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


def year_of(secs: int) -> int:
    z = secs // 86400 + 719468
    era = z // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    m = mp + 3 if mp < 10 else mp - 9
    return y + 1 if m <= 2 else y


def posix_offset(rule: str, secs: int) -> int:
    """O deslocamento que a regra do rodapé dá para aquele instante."""
    r = parse_posix(rule)
    if r.ok == 0:
        return 0
    if r.has_dst == 0:
        return r.std_off
    y = year_of(secs)
    # o instante da mudança é dado em hora LOCAL — a de antes da mudança, que
    # para o começo do verão é a padrão e para o fim é a de verão. Confundir as
    # duas erra por uma hora durante uma hora, duas vezes por ano.
    start = (days_from_civil_local(y, r.start_m, nth_weekday(y, r.start_m, r.start_w, r.start_d)) * 86400
             + r.start_secs - r.std_off)
    end = (days_from_civil_local(y, r.end_m, nth_weekday(y, r.end_m, r.end_w, r.end_d)) * 86400
           + r.end_secs - r.dst_off)
    if start <= end:
        # hemisfério norte: o verão é no meio do ano
        return r.dst_off if secs >= start and secs < end else r.std_off
    # ... e no sul o verão atravessa o Ano Novo, portanto a condição inverte-se
    return r.std_off if secs >= end and secs < start else r.dst_off
