"""`datetime` — o modelo do `java.time`, e a razão de ser esse.

**O TIPO responde se tem fuso.** É a decisão inteira, e é a correcção do bug mais
documentado da biblioteca do Python: lá, um `datetime` pode ou não ter fuso, a
mesma função recebe os dois, e o programa descobre a diferença em produção. Aqui
não há como perguntar — `LocalDateTime` **não tem** fuso, `ZonedDateTime` **tem**,
e uma função que precisa de um não aceita o outro.

Os seis tipos, e o que cada um é bom a responder:

| tipo | responde |
|---|---|
| `Instant` | **um ponto na linha do tempo**, o mesmo para toda a gente. É o que se grava num log e o que atravessa uma rede |
| `LocalDate` | um dia do calendário: `2026-08-25`. Um aniversário não tem hora |
| `LocalTime` | uma hora do relógio: `09:00`. "Às nove" numa agenda não é um instante — é nove em cada sítio onde for nove |
| `LocalDateTime` | os dois juntos, e **de propósito sem fuso** |
| `ZonedDateTime` | um `LocalDateTime` MAIS o deslocamento que o torna um instante |
| `Duration` | **segundos exactos**. Uma hora é sempre 3600 segundos |
| `Period` | **anos, meses e dias**, que NÃO são segundos exactos — um mês tem 28, 29, 30 ou 31 dias, e somar "um mês" a 31 de Janeiro tem de decidir alguma coisa |

**São todos `record`, portanto valores** — copiam-se, comparam-se por conteúdo, e
não custam uma alocação. Isso é de graça aqui e é a razão de o modelo caber.

**A aritmética que não é exacta diz que não é.** `Duration` soma-se a um
`Instant` sem pensar; `Period` só se soma a uma data, porque só aí "mais um mês"
quer dizer alguma coisa — e o que ele faz quando o dia não existe está escrito em
`plus_months`: fica no ÚLTIMO dia do mês, que é o que toda a gente faz e o que
menos surpreende.

**O que este pacote NÃO faz:** fusos com nome (`Europe/Lisbon`). Isso é DADO que
envelheceu ontem, vive no pacote `tzdata`, e entra por um deslocamento — que é
exactamente o que `ZonedDateTime` guarda. Aqui há UTC e deslocamentos fixos, que
é o que noventa por cento dos programas usa e cem por cento dos formatos escreve.
"""
import time


# ---------- os tipos ----------

record LocalDate:
    year: int
    month: int      # 1..12
    day: int        # 1..31


record LocalTime:
    hour: int       # 0..23
    minute: int     # 0..59
    second: int     # 0..59 — sem segundo bissexto, ver a nota em `Instant`
    nano: int       # 0..999999999


record LocalDateTime:
    date: LocalDate
    time: LocalTime


record Instant:
    """Segundos desde 1970-01-01T00:00:00Z, mais os nanos.

    **Sem segundos bissextos**, e é a mesma escolha que o POSIX, o Java e toda a
    gente faz: a linha do tempo é contínua e um dia tem sempre 86400 segundos.
    A alternativa — contá-los — obrigaria este pacote a ter uma TABELA que
    envelhece, e a tabela mudaria o resultado de uma subtracção feita ontem.
    """
    second: int
    nano: int


record ZonedDateTime:
    """Um `LocalDateTime` mais o deslocamento que o torna um instante.

    O deslocamento é em SEGUNDOS e não em horas: há fusos a meia hora (`+05:30`,
    a Índia) e a quarenta e cinco minutos (`+05:45`, o Nepal), e uma API que
    contasse horas não os saberia escrever.

    **Não guarda o NOME do fuso**, e não é esquecimento: um `record` é bytes
    puros (58.2) e uma `str` é coletada, portanto não cabe cá dentro — e mais
    importante do que isso, o nome sem as REGRAS não vale nada. As regras são o
    `tzdata`, que é dado que envelheceu ontem; quando ele existir, o que ele
    devolve é um deslocamento, e é este campo que o recebe.
    """
    local: LocalDateTime
    offset: int     # segundos a leste de UTC


record Duration:
    """Segundos exactos. Uma hora é 3600 segundos, sempre."""
    second: int
    nano: int


record Period:
    """Anos, meses e dias — que NÃO são segundos exactos."""
    year: int
    month: int
    day: int


const NANOS = 1000000000
const DAY_SECS = 86400


# ---------- o calendário: dias <-> ano/mês/dia ----------
#
# O algoritmo do Howard Hinnant, e a razão de ser este é que ele é EXACTO para
# qualquer ano — não tem tabela, não tem laço, e não tem o buraco de 1582 que
# quase toda a implementação caseira tem. A era é de 400 anos porque é esse o
# período do calendário gregoriano: 146097 dias, exactamente.
#
# A divisão aqui é a do pscript, que arredonda para BAIXO (39.1) — e é por isso
# que não é preciso o remendo para anos negativos que a versão em C++ tem.

def days_from_civil(y: int, m: int, d: int) -> int:
    """O número do dia, com 1970-01-01 = 0. Anda para trás sem se queixar."""
    yy = y - 1 if m <= 2 else y
    era = yy // 400
    yoe = yy - era * 400                                          # 0..399
    mp = m - 3 if m > 2 else m + 9                                # 0..11
    doy = (153 * mp + 2) // 5 + d - 1                             # 0..365
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy                 # 0..146096
    return era * 146097 + doe - 719468


def civil_from_days(z: int) -> LocalDate:
    """O inverso exacto de `days_from_civil`."""
    zz = z + 719468
    era = zz // 146097
    doe = zz - era * 146097                                       # 0..146096
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)               # 0..365
    mp = (5 * doy + 2) // 153                                     # 0..11
    d = doy - (153 * mp + 2) // 5 + 1                             # 1..31
    m = mp + 3 if mp < 10 else mp - 9                             # 1..12
    return LocalDate(y + 1 if m <= 2 else y, m, d)


def is_leap(y: int) -> bool:
    """Bissexto: de quatro em quatro, menos de cem em cem, mais de 400 em 400."""
    if y % 4 != 0:
        return False
    if y % 100 != 0:
        return True
    return y % 400 == 0


def days_in_month(y: int, m: int) -> int:
    if m == 2:
        return 29 if is_leap(y) else 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


def weekday(d: LocalDate) -> int:
    """0 = segunda … 6 = domingo, que é a ordem da ISO 8601.

    1970-01-01 foi uma QUINTA, e a conta é essa: dia 0 é 3 na ordem da ISO.
    """
    return (days_from_civil(d.year, d.month, d.day) + 3) % 7


def day_of_year(d: LocalDate) -> int:
    """1..366."""
    return days_from_civil(d.year, d.month, d.day) - days_from_civil(d.year, 1, 1) + 1


def valid_date(y: int, m: int, d: int) -> bool:
    if m < 1 or m > 12 or d < 1:
        return False
    return d <= days_in_month(y, m)


def valid_time(h: int, mi: int, s: int, n: int) -> bool:
    return h >= 0 and h <= 23 and mi >= 0 and mi <= 59 and s >= 0 and s <= 59 and n >= 0 and n < NANOS


# ---------- construir ----------
#
# Os construtores VALIDAM e levantam, porque uma data impossível num literal é um
# erro de PROGRAMA e não uma condição do algoritmo (4.2). O que vem de fora
# analisa-se com `parse_*`, e essas devolvem `T?`.

def date(y: int, m: int, d: int) -> LocalDate:
    if not valid_date(y, m, d):
        raise error("no such date: " + str(y) + "-" + str(m) + "-" + str(d), VALUE)
    return LocalDate(y, m, d)


def time_of(h: int, mi: int, s: int, n: int = 0) -> LocalTime:
    if not valid_time(h, mi, s, n):
        raise error("no such time: " + str(h) + ":" + str(mi) + ":" + str(s), VALUE)
    return LocalTime(h, mi, s, n)


def datetime_of(y: int, m: int, d: int, h: int, mi: int, s: int, n: int = 0) -> LocalDateTime:
    return LocalDateTime(date(y, m, d), time_of(h, mi, s, n))


def instant_of(secs: int, nanos: int = 0) -> Instant:
    # normaliza: nanos fora de 0..999999999 entram nos segundos, incluindo
    # negativos — senão duas representações do mesmo instante não comparariam
    s = secs + nanos // NANOS
    n = nanos % NANOS
    return Instant(s, n)


def now() -> Instant:
    """O relógio DE PAREDE, que é o único que sabe que horas são.

    O monotónico (`time.monotonic()`) é o que serve para medir duração, e é o que
    o escalonador usa; este pode saltar quando o sistema acerta a hora, e é
    exactamente por isso que não se mede nada com ele.
    """
    t = time.time()
    s = int(t)
    return Instant(s, int((t - float(s)) * 1000000000.0))


def epoch() -> Instant:
    return Instant(0, 0)


# ---------- converter ----------

def to_utc(i: Instant) -> LocalDateTime:
    days = i.second // DAY_SECS
    rest = i.second - days * DAY_SECS
    d = civil_from_days(days)
    return LocalDateTime(d, LocalTime(rest // 3600, (rest // 60) % 60, rest % 60, i.nano))


def from_utc(dt: LocalDateTime) -> Instant:
    days = days_from_civil(dt.date.year, dt.date.month, dt.date.day)
    return Instant(days * DAY_SECS + dt.time.hour * 3600 + dt.time.minute * 60 + dt.time.second, dt.time.nano)


def zoned(i: Instant, offset: int) -> ZonedDateTime:
    """O instante visto de um sítio. O deslocamento é em SEGUNDOS a leste."""
    return ZonedDateTime(to_utc(instant_of(i.second + offset, i.nano)), offset)


def to_instant(z: ZonedDateTime) -> Instant:
    """... e o caminho de volta, que é o que faz de um `ZonedDateTime` um ponto
    na linha do tempo e de um `LocalDateTime` apenas uma leitura de relógio."""
    return instant_of(from_utc(z.local).second - z.offset, z.local.time.nano)


# ---------- aritmética ----------
#
# A regra está nos TIPOS: `Duration` são segundos exactos e soma-se a um
# instante; `Period` são anos, meses e dias, e só se soma a uma DATA — porque só
# aí "mais um mês" quer dizer alguma coisa.

def seconds(n: int) -> Duration:
    return Duration(n, 0)


def minutes(n: int) -> Duration:
    return Duration(n * 60, 0)


def hours(n: int) -> Duration:
    return Duration(n * 3600, 0)


def days(n: int) -> Duration:
    """Um dia de vinte e quatro horas EXACTAS.

    Não é o mesmo que `Period(0, 0, 1)`: num fuso com horário de verão há um dia
    de 23 horas e outro de 25, e "amanhã à mesma hora" é o `Period`. Isto é
    "daqui a 86400 segundos", que é outra pergunta.
    """
    return Duration(n * DAY_SECS, 0)


def millis(n: int) -> Duration:
    return normalize_duration(n // 1000, (n % 1000) * 1000000)


def normalize_duration(s: int, n: int) -> Duration:
    return Duration(s + n // NANOS, n % NANOS)


def plus(i: Instant, d: Duration) -> Instant:
    return instant_of(i.second + d.second, i.nano + d.nano)


def minus(i: Instant, d: Duration) -> Instant:
    return instant_of(i.second - d.second, i.nano - d.nano)


def between(a: Instant, b: Instant) -> Duration:
    """De `a` até `b`. Negativo quando `b` é antes."""
    return normalize_duration(b.second - a.second, b.nano - a.nano)


def compare(a: Instant, b: Instant) -> int:
    if a.second != b.second:
        return -1 if a.second < b.second else 1
    if a.nano != b.nano:
        return -1 if a.nano < b.nano else 1
    return 0


def total_seconds(d: Duration) -> float:
    return float(d.second) + float(d.nano) / 1000000000.0


def plus_days(d: LocalDate, n: int) -> LocalDate:
    return civil_from_days(days_from_civil(d.year, d.month, d.day) + n)


def plus_months(d: LocalDate, n: int) -> LocalDate:
    """Mais `n` meses, e o dia FICA NO ÚLTIMO do mês quando não existe.

    31 de Janeiro mais um mês dá 28 (ou 29) de Fevereiro. É o que o `java.time`,
    o `dateutil` e toda a gente faz — e é uma decisão, não uma consequência: a
    alternativa (transbordar para 3 de Março) faz `x + 1 mês - 1 mês` deixar de
    voltar ao sítio, e ninguém espera isso.
    """
    total = d.year * 12 + (d.month - 1) + n
    y = total // 12
    m = total % 12 + 1
    dd = d.day
    lim = days_in_month(y, m)
    return LocalDate(y, m, lim if dd > lim else dd)


def plus_period(d: LocalDate, p: Period) -> LocalDate:
    """A ordem importa, e é a da ISO: anos e meses PRIMEIRO, dias depois.

    31 de Janeiro mais `Period(0, 1, 1)` dá 1 de Março: primeiro 31/01 → 28/02
    (o mês encolheu), depois mais um dia. Pela outra ordem daria 29 de Fevereiro
    — outro dia, com as mesmas parcelas.
    """
    return plus_days(plus_months(d, p.year * 12 + p.month), p.day)


def days_between(a: LocalDate, b: LocalDate) -> int:
    return days_from_civil(b.year, b.month, b.day) - days_from_civil(a.year, a.month, a.day)


def compare_date(a: LocalDate, b: LocalDate) -> int:
    x = days_from_civil(a.year, a.month, a.day)
    y = days_from_civil(b.year, b.month, b.day)
    return 0 if x == y else (-1 if x < y else 1)


# ---------- escrever: ISO 8601 / RFC 3339 ----------
#
# O único formato obrigatório, e a razão é a vida: é o que qualquer JSON,
# qualquer log e qualquer cabeçalho moderno escreve, e é o único em que a ordem
# alfabética é a ordem cronológica.

def pad(n: int, w: int) -> str:
    s = str(n)
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    while len(s) < w:
        s = "0" + s
    return "-" + s if neg else s


def date_iso(d: LocalDate) -> str:
    return pad(d.year, 4) + "-" + pad(d.month, 2) + "-" + pad(d.day, 2)


def time_iso(t: LocalTime) -> str:
    s = pad(t.hour, 2) + ":" + pad(t.minute, 2) + ":" + pad(t.second, 2)
    if t.nano == 0:
        return s
    # os nanos saem com 3, 6 ou 9 casas — nunca com um zero à direita que não
    # diz nada, e nunca com um número de casas que não seja uma dessas três
    f = pad(t.nano, 9)
    if t.nano % 1000000 == 0:
        return s + "." + f[0:3]
    if t.nano % 1000 == 0:
        return s + "." + f[0:6]
    return s + "." + f


def datetime_iso(dt: LocalDateTime) -> str:
    return date_iso(dt.date) + "T" + time_iso(dt.time)


def offset_iso(secs: int) -> str:
    """`Z` para zero, e `+05:45` para o Nepal — em MINUTOS, que é o que a norma
    escreve e o que os fusos a quarenta e cinco minutos obrigam."""
    if secs == 0:
        return "Z"
    sign = "+"
    v = secs
    if v < 0:
        sign = "-"
        v = -v
    return sign + pad(v // 3600, 2) + ":" + pad((v // 60) % 60, 2)


def instant_iso(i: Instant) -> str:
    """`2026-08-25T14:30:00Z` — o que se grava e o que atravessa."""
    return datetime_iso(to_utc(i)) + "Z"


def zoned_iso(z: ZonedDateTime) -> str:
    return datetime_iso(z.local) + offset_iso(z.offset)


def duration_iso(d: Duration) -> str:
    """`PT2H30M` — a forma da ISO 8601 para uma duração.

    Só horas, minutos e segundos: dias, meses e anos numa duração seriam a
    mentira que o `Period` existe para não contar.
    """
    v = d.second
    sign = ""
    if v < 0 or (v == 0 and d.nano < 0):
        sign = "-"
        v = -v
    h = v // 3600
    m = (v // 60) % 60
    s = v % 60
    out = sign + "PT"
    if h != 0:
        out += str(h) + "H"
    if m != 0:
        out += str(m) + "M"
    if s != 0 or d.nano != 0 or (h == 0 and m == 0):
        out += str(s)
        if d.nano != 0:
            f = pad(d.nano, 9)
            while len(f) > 1 and f.endswith("0"):
                f = f[0:len(f) - 1]
            out += "." + f
        out += "S"
    return out


# ---------- ler: ISO 8601 / RFC 3339 ----------
#
# **Devolvem `T?`, e None quer dizer "isto não é uma data"** (4.2): o texto veio
# de fora, e não analisar é um caso previsto. O que levanta é o programa que
# ESCREVE uma data impossível, que é outra coisa.

def digits(s: str, at: int, n: int) -> int:
    """`n` dígitos a partir de `at`, ou -1 se não houver `n` dígitos ali."""
    if at + n > len(s):
        return -1
    v = 0
    for k in range(n):
        c = ord(s[at + k])
        if c < 48 or c > 57:
            return -1
        v = v * 10 + (c - 48)
    return v


def parse_date(s: str) -> LocalDate?:
    """`YYYY-MM-DD`, e mais nada — a forma alargada da ISO, que é a que se lê."""
    if len(s) != 10 or s[4] != "-" or s[7] != "-":
        return None
    y = digits(s, 0, 4)
    m = digits(s, 5, 2)
    d = digits(s, 8, 2)
    if y < 0 or m < 0 or d < 0 or not valid_date(y, m, d):
        return None
    return LocalDate(y, m, d)


def parse_time(s: str) -> LocalTime?:
    """`HH:MM:SS`, com fracção opcional e com os segundos opcionais."""
    if len(s) < 5 or s[2] != ":":
        return None
    h = digits(s, 0, 2)
    mi = digits(s, 3, 2)
    if h < 0 or mi < 0:
        return None
    if len(s) == 5:
        return LocalTime(h, mi, 0, 0) if valid_time(h, mi, 0, 0) else None
    if s[5] != ":":
        return None
    sec = digits(s, 6, 2)
    if sec < 0:
        return None
    nano = 0
    if len(s) > 8:
        if s[8] != ".":
            return None
        # até nove casas; o que passar disso é truncado, e o que faltar é
        # completado com zeros — `.5` são quinhentos milhões de nanos
        k = 9
        mult = 100000000
        while k < len(s):
            c = ord(s[k])
            if c < 48 or c > 57:
                return None
            if mult > 0:
                nano += (c - 48) * mult
                mult = mult // 10
            k += 1
        if k == 9:
            return None
    if not valid_time(h, mi, sec, nano):
        return None
    return LocalTime(h, mi, sec, nano)


def parse_offset(s: str) -> int?:
    """`Z`, `z`, `+HH:MM` ou `-HH:MM`. O `Z` maiúsculo é o que se escreve; o
    minúsculo aceita-se porque a RFC 3339 o permite e há quem o escreva."""
    if s == "Z" or s == "z":
        return 0
    if len(s) != 6 or (s[0] != "+" and s[0] != "-") or s[3] != ":":
        return None
    h = digits(s, 1, 2)
    m = digits(s, 4, 2)
    if h < 0 or m < 0 or h > 23 or m > 59:
        return None
    v = h * 3600 + m * 60
    return -v if s[0] == "-" else v


def split_iso(s: str) -> int:
    """Onde começa o deslocamento, ou -1. Procura de TRÁS para a frente porque o
    `-` de um deslocamento negativo tem os `-` da data à frente dele."""
    if len(s) == 0:
        return -1
    last = s[len(s) - 1]
    if last == "Z" or last == "z":
        return len(s) - 1
    if len(s) >= 6:
        c = s[len(s) - 6]
        if c == "+" or c == "-":
            return len(s) - 6
    return -1


def parse_datetime(s: str) -> LocalDateTime?:
    """`YYYY-MM-DDTHH:MM:SS`, com o `T` ou com um espaço no lugar dele.

    O espaço não é ISO 8601 mas é RFC 3339 §5.6, e é o que um log e um SQL
    escrevem — recusá-lo tornaria este analisador inútil metade das vezes.
    """
    if len(s) < 16:
        return None
    sep = s[10]
    if sep != "T" and sep != "t" and sep != " ":
        return None
    d = parse_date(s[0:10])
    if d == None:
        return None
    t = parse_time(s[11:])
    if t == None:
        return None
    return LocalDateTime(d, t)


def parse_instant(s: str) -> Instant?:
    """Um RFC 3339 completo: data, hora e deslocamento."""
    cut = split_iso(s)
    if cut < 0:
        return None
    off = parse_offset(s[cut:])
    if off == None:
        return None
    dt = parse_datetime(s[0:cut])
    if dt == None:
        return None
    return instant_of(from_utc(dt).second - off, dt.time.nano)


def parse_zoned(s: str) -> ZonedDateTime?:
    cut = split_iso(s)
    if cut < 0:
        return None
    off = parse_offset(s[cut:])
    if off == None:
        return None
    dt = parse_datetime(s[0:cut])
    if dt == None:
        return None
    return ZonedDateTime(dt, off)


# ---------- as datas do HTTP (RFC 7231 §7.1.1.1) ----------
#
# **Três formatos, e a norma manda ACEITAR os três e GERAR só o primeiro.** Os
# outros dois são de 1982 e de 1978 e estão proibidos há décadas — mas há
# servidores a escrevê-los hoje, e um cliente que os recuse é um cliente partido.
#
# Sem isto o `http` escreveria o seu próprio analisador de datas, que é o começo
# de haver dois.

const WDAY = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
const WDAY_LONG = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def http_date(i: Instant) -> str:
    """`Sun, 06 Nov 1994 08:49:37 GMT` — o IMF-fixdate, o único que se gera."""
    dt = to_utc(i)
    return (WDAY[weekday(dt.date)] + ", " + pad(dt.date.day, 2) + " " + MON[dt.date.month - 1]
            + " " + pad(dt.date.year, 4) + " " + pad(dt.time.hour, 2) + ":" + pad(dt.time.minute, 2)
            + ":" + pad(dt.time.second, 2) + " GMT")


def month_index(s: str) -> int:
    for k in range(12):
        if MON[k] == s:
            return k + 1
    return -1


def parse_http_date(s: str) -> Instant?:
    """Os TRÊS: o IMF-fixdate, o RFC 850 e o do `asctime`."""
    t = s.strip()
    c = t.find(",")
    if c < 0:
        # asctime: `Sun Nov  6 08:49:37 1994` — o dia com espaço à esquerda, e o
        # ANO no fim, que é o que o torna reconhecível sem vírgula
        p = t.split()
        if len(p) != 5:
            return None
        m = month_index(p[1])
        d = to_int(p[2])
        y = to_int(p[4])
        if m < 0 or d < 0 or y < 0:
            return None
        tm = parse_time(p[3])
        if tm == None or not valid_date(y, m, d):
            return None
        return from_utc(LocalDateTime(LocalDate(y, m, d), tm))
    head = t[0:c]
    rest = t[c + 1:].strip()
    if len(head) == 3:
        # IMF-fixdate: `Sun, 06 Nov 1994 08:49:37 GMT` — dia, mês, ano de QUATRO
        # dígitos, hora e a zona, que a norma fixa em `GMT` e mais nada
        p = rest.split()
        if len(p) != 5 or p[4] != "GMT":
            return None
        d = to_int(p[0])
        m = month_index(p[1])
        y = to_int(p[2])
        if d < 0 or m < 0 or y < 0 or len(p[2]) != 4:
            return None
        tm = parse_time(p[3])
        if tm == None or not valid_date(y, m, d):
            return None
        return from_utc(LocalDateTime(LocalDate(y, m, d), tm))
    # RFC 850: `Sunday, 06-Nov-94 08:49:37 GMT` — e o ano de DOIS dígitos, que é
    # a razão de este formato estar proibido
    p = rest.split()
    if len(p) != 3 or p[2] != "GMT":
        return None
    q = p[0].split("-")
    if len(q) != 3:
        return None
    d = to_int(q[0])
    m = month_index(q[1])
    y = to_int(q[2])
    if d < 0 or m < 0 or y < 0 or len(q[2]) != 2:
        return None
    # a regra do RFC 6265 §5.1.1, que é a que toda a gente segue: 0..69 é 20xx e
    # 70..99 é 19xx. Uma janela, e não uma adivinha — o formato não dá para mais.
    y = y + 2000 if y < 70 else y + 1900
    tm = parse_time(p[1])
    if tm == None or not valid_date(y, m, d):
        return None
    return from_utc(LocalDateTime(LocalDate(y, m, d), tm))


def to_int(s: str) -> int:
    """Um inteiro não negativo, ou -1. Não usa `int(s)` porque essa LEVANTA, e
    aqui não analisar é uma resposta."""
    if len(s) == 0:
        return -1
    v = 0
    for ch in s:
        c = ord(ch)
        if c < 48 or c > 57:
            return -1
        v = v * 10 + (c - 48)
    return v


# ---------- `strftime` / `strptime` ----------
#
# Os `%Y-%m-%d` que toda a gente decorou. Não substituem a ISO — substituem o
# laço de concatenações que alguém escreveria para pôr uma data num nome de
# ficheiro.
#
# **Sem localização**, e é a decisão da ronda 8: sem língua só dá inglês, e
# inglês a fingir de universal é pior do que não haver. Portanto `%A` e `%B` dão
# os nomes ingleses e dizem-no aqui, em vez de fingirem que são a língua de quem
# lê.

def strftime(fmt: str, dt: LocalDateTime) -> str:
    out: List<str> = []
    i = 0
    while i < len(fmt):
        c = fmt[i]
        if c != "%" or i + 1 >= len(fmt):
            out.append(c)
            i += 1
            continue
        k = fmt[i + 1]
        i += 2
        if k == "Y":
            out.append(pad(dt.date.year, 4))
        elif k == "y":
            out.append(pad(dt.date.year % 100, 2))
        elif k == "m":
            out.append(pad(dt.date.month, 2))
        elif k == "d":
            out.append(pad(dt.date.day, 2))
        elif k == "H":
            out.append(pad(dt.time.hour, 2))
        elif k == "M":
            out.append(pad(dt.time.minute, 2))
        elif k == "S":
            out.append(pad(dt.time.second, 2))
        elif k == "f":
            out.append(pad(dt.time.nano // 1000, 6))
        elif k == "j":
            out.append(pad(day_of_year(dt.date), 3))
        elif k == "a":
            out.append(WDAY[weekday(dt.date)])
        elif k == "A":
            out.append(WDAY_LONG[weekday(dt.date)])
        elif k == "b":
            out.append(MON[dt.date.month - 1])
        elif k == "B":
            out.append(MONTH_LONG[dt.date.month - 1])
        elif k == "p":
            out.append("AM" if dt.time.hour < 12 else "PM")
        elif k == "I":
            h = dt.time.hour % 12
            out.append(pad(12 if h == 0 else h, 2))
        elif k == "%":
            out.append("%")
        else:
            # um especificador que não existe é um erro de PROGRAMA, e por isso
            # LEVANTA — não é entrada de fora, é o formato que alguém escreveu
            raise error("strftime: there is no %" + k, VALUE)
    return "".join(out)


const MONTH_LONG = ["January", "February", "March", "April", "May", "June",
                    "July", "August", "September", "October", "November", "December"]


def strptime(s: str, fmt: str) -> LocalDateTime?:
    """O inverso, e devolve `T?`: o texto vem de fora (4.2)."""
    y = 1970
    mo = 1
    d = 1
    h = 0
    mi = 0
    sec = 0
    nano = 0
    si = 0
    fi = 0
    while fi < len(fmt):
        c = fmt[fi]
        if c != "%" or fi + 1 >= len(fmt):
            if si >= len(s) or s[si] != c:
                return None
            si += 1
            fi += 1
            continue
        k = fmt[fi + 1]
        fi += 2
        if k == "%":
            if si >= len(s) or s[si] != "%":
                return None
            si += 1
            continue
        w = 2
        if k == "Y":
            w = 4
        elif k == "j":
            w = 3
        elif k == "f":
            w = 6
        if k == "a" or k == "A" or k == "b" or k == "B" or k == "p":
            got = word_at(s, si)
            if got == "":
                return None
            si += len(got)
            if k == "b":
                mo = month_index(got)
                if mo < 0:
                    return None
            elif k == "B":
                mo = long_month_index(got)
                if mo < 0:
                    return None
            continue
        v = digits(s, si, w)
        if v < 0:
            return None
        si += w
        if k == "Y":
            y = v
        elif k == "y":
            y = v + 2000 if v < 70 else v + 1900
        elif k == "m":
            mo = v
        elif k == "d":
            d = v
        elif k == "H" or k == "I":
            h = v
        elif k == "M":
            mi = v
        elif k == "S":
            sec = v
        elif k == "f":
            nano = v * 1000
        elif k == "j":
            pass
        else:
            return None
    if si != len(s):
        return None
    if not valid_date(y, mo, d) or not valid_time(h, mi, sec, nano):
        return None
    return LocalDateTime(LocalDate(y, mo, d), LocalTime(h, mi, sec, nano))


def word_at(s: str, at: int) -> str:
    j = at
    while j < len(s):
        c = ord(s[j])
        if (c >= 65 and c <= 90) or (c >= 97 and c <= 122):
            j += 1
        else:
            break
    return s[at:j]


def long_month_index(s: str) -> int:
    for k in range(12):
        if MONTH_LONG[k] == s:
            return k + 1
    return -1
