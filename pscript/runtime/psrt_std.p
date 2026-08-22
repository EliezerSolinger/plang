# psrt_std.p — CAMADA 4: a biblioteca portada. `json`, `re`, `random` (o
# MT19937 do CPython), `bisect` e `heapq`.
#
# Chama a memória e os valores. Fica em P por decisão sua (108.4) — não vira
# módulo em pscript.
import "psrt_types.ph"
import "psrt_mem.ph"
import "psrt_val.ph"
import "psrt_std.ph"

# ---------- 106: `bisect` e `heapq`, portados do CPython ----------
#
# São os dois módulos do Python que são ALGORITMO PURO — `Lib/bisect.py` e
# `Lib/heapq.py` não têm nada de específico da linguagem dentro, então portar é
# transcrever. E são os dois que uma lista ordenada pede: `bisect` acha onde uma
# coisa entra sem quebrar a ordem, `heapq` mantém o menor no topo por 30 linhas
# em vez de reordenar a cada inserção.
#
# `kind` é o mesmo do `sorted`: 0 int, 1 float, 2 str — o comparador vem daí, e
# é o mesmo em todos os três caminhos, então a ordem que o `bisect` assume é
# exatamente a que o `sorted` produz.
private def ps_cmp_of(kind: i32) -> def(a: const *void, b: const *void) -> int:
    if kind == 1:
        return ps_cmp_float
    if kind == 2:
        return ps_cmp_str
    return ps_cmp_int

# `bisect_left`/`bisect_right`: o ponto de inserção. A diferença entre os dois é
# só o lado dos IGUAIS — `left` põe antes deles, `right` depois — e é por isso
# que os dois existem em vez de um.
def ps_bisect(l: *PsList, v: const *void, kind: i32, right: bool) -> i64:
    if l == None:
        return 0
    cmp: def(a: const *void, b: const *void) -> int = ps_cmp_of(kind)
    base: *char = ps_list_base(l)
    es: usize = usize(l->esize)
    lo: i64 = 0
    hi: i64 = l->len
    while lo < hi:
        # `(lo + hi) / 2` e não `lo + (hi - lo) / 2` porque o comprimento de uma
        # lista aqui já não cabe perto do estouro de i64
        mid: i64 = (lo + hi) / 2
        c: int = cmp((*void)(base + usize(mid) * es), v)
        if (c <= 0) if right else (c < 0):
            lo = mid + 1
        else:
            hi = mid
    return lo

def ps_insort(ctx: *PsCtx, l: *PsList, v: const *void, kind: i32, right: bool, file: const *char, line: i32):
    at: i64 = ps_bisect(l, v, kind, right)
    slot: *char = ps_list_insert(ctx, l, at, file, line)
    if slot != None:
        memcpy(slot, v, usize(l->esize))

# `heapq`: um heap mínimo binário no próprio vetor, com a mesma estrutura do
# `Lib/heapq.py` — `_siftdown` sobe o buraco, `_siftup` desce. A tradução
# conserva os nomes de lá porque a discussão que explica por que o `_siftup` do
# Python desce (e não sobe, como o nome sugere) está no comentário DELE.
private def ps_sift_down(base: *char, es: usize, startpos: i64, pos: i64, cmp: def(a: const *void, b: const *void) -> int, tmp: *char):
    # o novo item está em `pos`; sobe enquanto for menor que o pai
    memcpy(tmp, base + usize(pos) * es, es)
    p: i64 = pos
    while p > startpos:
        parent: i64 = (p - 1) / 2
        if cmp((*void)(tmp), (*void)(base + usize(parent) * es)) < 0:
            memcpy(base + usize(p) * es, base + usize(parent) * es, es)
            p = parent
        else:
            break
    memcpy(base + usize(p) * es, tmp, es)

private def ps_sift_up(base: *char, n: i64, es: usize, pos: i64, cmp: def(a: const *void, b: const *void) -> int, tmp: *char):
    # o buraco em `pos` desce sempre pelo FILHO MENOR até o fim, e só então o
    # item guardado sobe de volta pelo caminho — é o truque do heapq, que faz
    # uma comparação por nível em vez de duas
    startpos: i64 = pos
    memcpy(tmp, base + usize(pos) * es, es)
    child: i64 = 2 * pos + 1
    p: i64 = pos
    while child < n:
        right: i64 = child + 1
        if right < n and cmp((*void)(base + usize(child) * es), (*void)(base + usize(right) * es)) >= 0:
            child = right
        memcpy(base + usize(p) * es, base + usize(child) * es, es)
        p = child
        child = 2 * p + 1
    memcpy(base + usize(p) * es, tmp, es)
    ps_sift_down(base, es, startpos, p, cmp, tmp)

def ps_heappush(ctx: *PsCtx, l: *PsList, v: const *void, kind: i32, file: const *char, line: i32):
    slot: *char = ps_list_push(ctx, l)
    if slot == None:
        return
    memcpy(slot, v, usize(l->esize))
    tmp: char[64]
    if usize(l->esize) > sizeof(tmp):
        return
    ps_sift_down(ps_list_base(l), usize(l->esize), 0, l->len - 1, ps_cmp_of(kind), &tmp[0])

# `heappop` devolve o menor E o tira: o menor sai para `out` (o chamador
# declarou onde), o último vai para a raiz e desce. Levanta na lista vazia,
# como o `IndexError` do Python.
def ps_heappop(ctx: *PsCtx, l: *PsList, out: *void, kind: i32, file: const *char, line: i32):
    if l == None or l->len == 0:
        ps_raise(ctx, "pop from an empty heap", PS_CAT_INDEX, file, line)
        return
    es: usize = usize(l->esize)
    base: *char = ps_list_base(l)
    memcpy(out, base, es)
    l->len -= 1
    if l->len > 0:
        memcpy(base, base + usize(l->len) * es, es)
        tmp: char[64]
        if es <= sizeof(tmp):
            ps_sift_up(base, l->len, es, 0, ps_cmp_of(kind), &tmp[0])

def ps_heapify(l: *PsList, kind: i32):
    if l == None or l->len < 2:
        return
    es: usize = usize(l->esize)
    tmp: char[64]
    if es > sizeof(tmp):
        return
    cmp: def(a: const *void, b: const *void) -> int = ps_cmp_of(kind)
    base: *char = ps_list_base(l)
    # de trás para frente a partir do último pai, como no `heapify` do Python
    i: i64 = l->len / 2 - 1
    while i >= 0:
        ps_sift_up(base, l->len, es, i, cmp, &tmp[0])
        i -= 1

# ---------- `json` (41.1) ----------
# Recursive descent over the text, straight into the values the language already
# has. RFC 8259 to the letter, which is not pedantry: this parser reads bytes
# that came from somewhere else, and every place it is lenient is a place where
# two programs disagree about what a document says.
#
# Measured against nst/JSONTestSuite (tests/conformance): 95 documents that must
# be accepted, 186 that must be refused, 35 the RFC leaves open. Where this
# parser lands on the open 35 is written down in tests/conformance/json.skips,
# next to what Python and node answer for the same file.
#
# The depth limit is a SECURITY boundary, not a preference. Recursive descent on
# attacker-supplied text without one is a stack overflow waiting to be asked
# for, and the corpus asks: `n_structure_100000_opening_arrays.json` is a
# hundred thousand `[`. The RFC blesses a limit (§9); silently dying does not.
# 110: a profundidade máxima que o json aceita (`-D PSRT_JSON_DEPTH=N`).
const if defined(PSRT_JSON_DEPTH):
    PS_JSON_MAX_DEPTH: const i32 = PSRT_JSON_DEPTH
else:
    PS_JSON_MAX_DEPTH: const i32 = 1000

struct PsJson:
    ctx: *PsCtx
    s: const *char
    n: usize
    i: usize
    bad: i32
    depth: i32
    file: const *char
    line: i32

private def js_fail(j: *PsJson, what: const *char):
    if j->bad != 0:
        return
    j->bad = 1
    msg: char[160]
    snprintf(msg, 160, "invalid JSON: %s at byte %d", what, int(j->i))
    ps_raise(j->ctx, msg, PS_CAT_VALUE, j->file, j->line)

private def js_space(j: *PsJson):
    while j->i < j->n and (j->s[j->i] == ' ' or j->s[j->i] == '\t' or j->s[j->i] == '\n' or j->s[j->i] == '\r'):
        j->i += 1

private def js_value(j: *PsJson) -> *PsObj

# four hexadecimal digits, or -1. Advances only when it succeeds, so a caller
# that fails reports the position of the escape rather than of its tail.
private def js_hex4(j: *PsJson) -> i32:
    if j->i + usize(4) > j->n:
        return -1
    v: i32 = 0
    k: usize = 0
    while k < usize(4):
        c: char = j->s[j->i + k]
        d: i32 = -1
        if c >= '0' and c <= '9':
            d = i32(c) - 48
        elif c >= 'a' and c <= 'f':
            d = i32(c) - 87
        elif c >= 'A' and c <= 'F':
            d = i32(c) - 55
        if d < 0:
            return -1
        v = v * 16 + d
        k += 1
    j->i += usize(4)
    return v

# one codepoint, UTF-8, into the buffer. Same shape as `ps_str_chr` because it
# is the same encoding, and having two of them drift apart would be worse than
# the four lines of repetition.
private def js_utf8(buf: *char, k: usize, cp: i32) -> usize:
    v: u32 = u32(cp)
    if v < 0x80:
        buf[k] = char(v)
        return k + usize(1)
    if v < 0x800:
        buf[k] = char(0xC0 | (v >> 6))
        buf[k + usize(1)] = char(0x80 | (v & 0x3F))
        return k + usize(2)
    if v < 0x10000:
        buf[k] = char(0xE0 | (v >> 12))
        buf[k + usize(1)] = char(0x80 | ((v >> 6) & 0x3F))
        buf[k + usize(2)] = char(0x80 | (v & 0x3F))
        return k + usize(3)
    buf[k] = char(0xF0 | (v >> 18))
    buf[k + usize(1)] = char(0x80 | ((v >> 12) & 0x3F))
    buf[k + usize(2)] = char(0x80 | ((v >> 6) & 0x3F))
    buf[k + usize(3)] = char(0x80 | (v & 0x3F))
    return k + usize(4)

# A JSON string is not "bytes until the next quote". Three rules the RFC states
# and a lenient parser silently drops, each of which is a real disagreement:
#
#   * a byte below 0x20 has to be ESCAPED — a raw tab or newline inside a string
#     is not a string;
#   * the escape set is CLOSED (`" \ / b f n r t u`) — `\x` is not "x", it is a
#     malformed document, and a parser that reads it as "x" will disagree with
#     every other one about the value;
#   * `\uXXXX` is a codepoint, not the four letters after a `u`. This is the one
#     that was simply missing: `"é"` used to come back as `u00e9`.
#
# A LONE surrogate becomes U+FFFD, because a pscript `str` is valid UTF-8 by
# construction (83.2) and a surrogate is not encodable. That is what a browser's
# TextEncoder does with the same input, and the RFC leaves the case open.
private def js_string(j: *PsJson) -> *PsStr:
    j->i += 1                     # the opening quote
    # an escape never grows: `\uXXXX` is six bytes in and at most four out, a
    # surrogate PAIR twelve in and four out. So the input length is a ceiling.
    buf: *char = (*char)(malloc(j->n - j->i + usize(8)))
    k: usize = 0
    while True:
        if j->i >= j->n:
            js_fail(j, "a string that never ends")
            free(buf)
            return ps_str_new(j->ctx, "", 0)
        c: char = j->s[j->i]
        if c == '"':
            j->i += 1
            break
        if u8(c) < 0x20:
            js_fail(j, "a control character has to be escaped inside a string")
            free(buf)
            return ps_str_new(j->ctx, "", 0)
        if c != '\\':
            buf[k] = c
            k += 1
            j->i += 1
            continue
        j->i += 1
        if j->i >= j->n:
            js_fail(j, "a string that never ends")
            free(buf)
            return ps_str_new(j->ctx, "", 0)
        e: char = j->s[j->i]
        j->i += 1
        if e == 'n':
            buf[k] = '\n'
            k += 1
        elif e == 't':
            buf[k] = '\t'
            k += 1
        elif e == 'r':
            buf[k] = '\r'
            k += 1
        elif e == 'b':
            buf[k] = char(8)
            k += 1
        elif e == 'f':
            buf[k] = char(12)
            k += 1
        elif e == '"' or e == '\\' or e == '/':
            buf[k] = e
            k += 1
        elif e == 'u':
            cp: i32 = js_hex4(j)
            if cp < 0:
                js_fail(j, "a \\u escape needs four hexadecimal digits")
                free(buf)
                return ps_str_new(j->ctx, "", 0)
            if cp >= 0xD800 and cp <= 0xDBFF:
                # a HIGH surrogate: a low one may follow, and together they are
                # one codepoint above the BMP
                if j->i + usize(1) < j->n and j->s[j->i] == '\\' and j->s[j->i + usize(1)] == 'u':
                    j->i += usize(2)
                    lo: i32 = js_hex4(j)
                    if lo < 0:
                        js_fail(j, "a \\u escape needs four hexadecimal digits")
                        free(buf)
                        return ps_str_new(j->ctx, "", 0)
                    if lo >= 0xDC00 and lo <= 0xDFFF:
                        cp = 0x10000 + ((cp - 0xD800) * 1024) + (lo - 0xDC00)
                    else:
                        # the high one stood alone after all; the second escape
                        # is its own codepoint
                        k = js_utf8(buf, k, 0xFFFD)
                        cp = 0xFFFD if (lo >= 0xD800 and lo <= 0xDFFF) else lo
                else:
                    cp = 0xFFFD
            elif cp >= 0xDC00 and cp <= 0xDFFF:
                cp = 0xFFFD       # a low surrogate with nothing in front of it
            k = js_utf8(buf, k, cp)
        else:
            m: char[64]
            if u8(e) >= 0x20 and u8(e) < 0x7F:
                snprintf(m, 64, "'\\%c' is not a JSON escape", e)
            else:
                snprintf(m, 64, "byte 0x%02X is not a JSON escape", i32(u8(e)))
            js_fail(j, m)
            free(buf)
            return ps_str_new(j->ctx, "", 0)
    out: *PsStr = ps_str_new(j->ctx, buf, k)
    free(buf)
    return out

private def js_array(j: *PsJson) -> *PsObj:
    j->i += 1
    l: *PsList = ps_list_new(j->ctx, i32(sizeof(PsStrPtr)), True, 0)
    js_space(j)
    if j->i < j->n and j->s[j->i] == ']':
        j->i += 1
        return (*PsObj)(l)
    # the loop condition used to be `j->i < j->n`, and that is exactly how a
    # TRUNCATED document came back as a value: text that ran out mid-array left
    # the loop through the top and returned the elements read so far, with no
    # complaint. Running out of text is now a failure like any other.
    while j->bad == 0:
        if j->i >= j->n:
            js_fail(j, "an array that never ends")
            return (*PsObj)(l)
        v: *PsObj = js_value(j)
        if j->bad != 0:
            return (*PsObj)(l)
        slot: *char = ps_list_push(j->ctx, l)
        p: **PsObj = (**PsObj)(slot)
        *p = v
        js_space(j)
        if j->i < j->n and j->s[j->i] == ',':
            j->i += 1
            js_space(j)
            continue
        if j->i < j->n and j->s[j->i] == ']':
            j->i += 1
            return (*PsObj)(l)
        js_fail(j, "a ',' or a ']' was expected")
        return (*PsObj)(l)
    return (*PsObj)(l)

private def js_object(j: *PsJson) -> *PsObj:
    j->i += 1
    d: *PsDict = ps_dict_new(j->ctx, i32(sizeof(PsStrPtr)), i32(sizeof(PsStrPtr)), PS_K_STR, True, True)
    js_space(j)
    if j->i < j->n and j->s[j->i] == '}':
        j->i += 1
        return (*PsObj)(d)
    while j->bad == 0:
        js_space(j)
        if j->i >= j->n or j->s[j->i] != '"':
            js_fail(j, "a key has to be a string")
            return (*PsObj)(d)
        k: *PsStr = js_string(j)
        if j->bad != 0:
            return (*PsObj)(d)
        js_space(j)
        if j->i >= j->n or j->s[j->i] != ':':
            js_fail(j, "a ':' was expected")
            return (*PsObj)(d)
        j->i += 1
        js_space(j)
        v: *PsObj = js_value(j)
        if j->bad != 0:
            return (*PsObj)(d)
        slot: *char = ps_dict_put(j->ctx, d, (*char)(&k))
        vp: **PsObj = (**PsObj)(slot)
        *vp = v
        js_space(j)
        if j->i < j->n and j->s[j->i] == ',':
            j->i += 1
            continue
        if j->i < j->n and j->s[j->i] == '}':
            j->i += 1
            return (*PsObj)(d)
        js_fail(j, "a ',' or a '}' was expected")
        return (*PsObj)(d)
    return (*PsObj)(d)

# The JSON number grammar, walked by hand (RFC 8259 §6):
#
#     -?  (0 | [1-9][0-9]*)  ('.' [0-9]+)?  ([eE] [+-]? [0-9]+)?
#
# It used to be `strtod`, and strtod speaks C, not JSON: it takes `01`, `.5`,
# `2.`, `0x1F`, `NaN` and `Infinity`, none of which are JSON. Handing the text
# to the C library and trusting whatever it consumed is how a parser ends up
# accepting a superset nobody wrote down.
#
# The integer that does not fit is a REFUSAL, not a wrap. pscript has no bignum
# and int overflow raises everywhere else (7.2); a document whose number cannot
# be represented is better refused loudly than read as some other number.
private def js_number(j: *PsJson) -> *PsObj:
    start: usize = j->i
    neg: bool = False
    if j->s[j->i] == '-':
        neg = True
        j->i += 1
    if j->i >= j->n or j->s[j->i] < '0' or j->s[j->i] > '9':
        js_fail(j, "a number needs a digit")
        return ps_any_none(j->ctx)
    dstart: usize = j->i
    if j->s[j->i] == '0':
        j->i += 1
        if j->i < j->n and j->s[j->i] >= '0' and j->s[j->i] <= '9':
            js_fail(j, "a number may not have a leading zero")
            return ps_any_none(j->ctx)
    else:
        while j->i < j->n and j->s[j->i] >= '0' and j->s[j->i] <= '9':
            j->i += 1
    dend: usize = j->i
    integral: bool = True
    if j->i < j->n and j->s[j->i] == '.':
        integral = False
        j->i += 1
        if j->i >= j->n or j->s[j->i] < '0' or j->s[j->i] > '9':
            js_fail(j, "a fraction needs a digit after the point")
            return ps_any_none(j->ctx)
        while j->i < j->n and j->s[j->i] >= '0' and j->s[j->i] <= '9':
            j->i += 1
    if j->i < j->n and (j->s[j->i] == 'e' or j->s[j->i] == 'E'):
        integral = False
        j->i += 1
        if j->i < j->n and (j->s[j->i] == '+' or j->s[j->i] == '-'):
            j->i += 1
        if j->i >= j->n or j->s[j->i] < '0' or j->s[j->i] > '9':
            js_fail(j, "an exponent needs a digit")
            return ps_any_none(j->ctx)
        while j->i < j->n and j->s[j->i] >= '0' and j->s[j->i] <= '9':
            j->i += 1
    if not integral:
        return ps_any_float(j->ctx, strtod(j->s + start, None))
    # 68.6: an integral spelling is an int. Accumulate by hand, because
    # `strtoll` saturates at the edge and says so only through `errno` — which
    # is a per-thread macro P cannot see, and reading it here would be wrong
    # anyway. The limit is 2^63-1, or 2^63 when there is a minus in front.
    lim: u64 = u64(9223372036854775807)
    if neg:
        lim = u64(9223372036854775807) + u64(1)
    acc: u64 = 0
    p: usize = dstart
    while p < dend:
        dv: u64 = u64(i32(j->s[p]) - 48)
        if acc > (lim - dv) / u64(10):
            js_fail(j, "this integer does not fit in an int")
            return ps_any_none(j->ctx)
        acc = acc * u64(10) + dv
        p += 1
    if neg:
        if acc == u64(9223372036854775807) + u64(1):
            return ps_any_int(j->ctx, -9223372036854775807 - 1)
        return ps_any_int(j->ctx, -i64(acc))
    return ps_any_int(j->ctx, i64(acc))

private def js_value(j: *PsJson) -> *PsObj:
    js_space(j)
    if j->i >= j->n:
        js_fail(j, "the text ended")
        return ps_any_none(j->ctx)
    c: char = j->s[j->i]
    if c == '{' or c == '[':
        # the depth is counted HERE, in the one place both aggregates pass
        # through, so neither of them has to remember to give it back
        j->depth += 1
        if j->depth > PS_JSON_MAX_DEPTH:
            js_fail(j, "this JSON nests deeper than the limit")
            j->depth -= 1
            return ps_any_none(j->ctx)
        agg: *PsObj = js_object(j) if c == '{' else js_array(j)
        j->depth -= 1
        return agg
    if c == '"':
        return (*PsObj)(js_string(j))
    if strncmp(j->s + j->i, "true", 4) == 0:
        j->i += 4
        return ps_any_bool(j->ctx, True)
    if strncmp(j->s + j->i, "false", 5) == 0:
        j->i += 5
        return ps_any_bool(j->ctx, False)
    if strncmp(j->s + j->i, "null", 4) == 0:
        j->i += 4
        return ps_any_none(j->ctx)
    if c == '-' or (c >= '0' and c <= '9'):
        return js_number(j)
    js_fail(j, "a value was expected")
    return ps_any_none(j->ctx)

# 18.3: the SAME bytes, read as elements of `esize` each. Nothing is copied and
# nothing is owned — the list header is collected, the bytes are the buffer's,
# and holding the buffer in `owner` is what keeps them alive.
def ps_buffer_transfer(ctx: *PsCtx, b: *PsBuffer):
    if b != None:
        b->gone_from = (*void)(ctx)


def ps_buffer_view(ctx: *PsCtx, b: *PsBuffer, esize: i32, file: const *char, line: i32) -> *PsList:
    if ps_buffer_gone(ctx, b):
        ps_raise(ctx, "this buffer was transferred: it belongs to whoever received it (18.2)", PS_CAT_VALUE, file, line)
        return None
    if b == None or b->open == 0:
        ps_raise(ctx, "this buffer is closed", PS_CAT_VALUE, file, line)
        return None
    if b->nbytes % usize(esize) != usize(0):
        ps_raise(ctx, "the buffer does not divide into elements of this size", PS_CAT_VALUE, file, line)
        return None
    l: *PsList = ps_alloc(ctx, sizeof(PsList), PS_TY_LIST)
    l->len = i64(b->nbytes / usize(esize))
    l->cap = l->len
    l->esize = esize
    l->eref = False
    l->data = None
    l->raw = b->data
    l->owner = b
    return l

def ps_json_parse(ctx: *PsCtx, text: *PsStr, file: const *char, line: i32) -> *PsObj:
    j: PsJson
    j.ctx = ctx
    j.s = text->data
    j.n = usize(text->len)
    j.i = 0
    j.bad = 0
    j.depth = 0
    j.file = file
    j.line = line
    v: *PsObj = js_value(&j)
    js_space(&j)
    if j.bad == 0 and j.i < j.n:
        js_fail(&j, "there is text after the value")
    return v

# ---------- `re` (41.2) ----------
# 110: quantos grupos de captura uma regex devolve (`-D PSRT_RE_GROUPS=N`).
const if defined(PSRT_RE_GROUPS):
    PS_RE_MAX_GROUPS: const i32 = PSRT_RE_GROUPS
else:
    PS_RE_MAX_GROUPS: const i32 = 16

def ps_re_match(ctx: *PsCtx, pattern: *PsStr, text: *PsStr, file: const *char, line: i32) -> *PsList:
    rx: regex_t
    rc: int = regcomp(&rx, pattern->data, REG_EXTENDED)
    if rc != 0:
        buf: char[256]
        regerror(rc, &rx, buf, 256)
        ps_raise(ctx, buf, PS_CAT_VALUE, file, line)
        return None
    m: regmatch_t[16]
    got: int = regexec(&rx, text->data, usize(PS_RE_MAX_GROUPS), m, 0)
    if got != 0:
        regfree(&rx)
        return None          # no match: the option is empty (9.4/40.1)
    n: i32 = 0
    while n < PS_RE_MAX_GROUPS and m[n].rm_so >= 0:
        n += 1
    out: *PsList = ps_list_new(ctx, i32(sizeof(PsStrPtr)), True, i64(n))
    for i in range(n):
        st: *char = text->data + m[i].rm_so
        ln: usize = usize(m[i].rm_eo - m[i].rm_so)
        slot: *char = ps_list_push(ctx, out)
        sp: **PsStr = (**PsStr)(slot)
        *sp = ps_str_new(ctx, st, ln)
    regfree(&rx)
    return out

# ---------- `random`: o Mersenne Twister do CPython, portado (103) ----------
#
# PORTADO, não inventado: é o MT19937 de `Modules/_randommodule.c` do CPython,
# que por sua vez é o download de Makoto Matsumoto e Takuji Nishimura
# (Copyright (C) 1997-2002, licença BSD de três cláusulas, incluída no arquivo
# original), com a camada Python de `Lib/random.py` — `_randbelow_with_
# getrandbits`, `randint`, `choice`, `shuffle`, `uniform` — transcrita linha por
# linha. CPython é PSF-2.0.
#
# O motivo de PORTAR em vez de escrever um gerador qualquer: com a mesma semente
# a sequência tem de ser a MESMA do Python, e aí o oráculo compara número por
# número em vez de "parece aleatório". Um gerador escrito à mão passaria em
# qualquer teste que eu mesmo escrevesse.
#
# O estado é POR CONTEXTO, alocado na primeira chamada: cada worker tem heap,
# coletor e laço próprios (18.1), e compartilhar 624 palavras de estado entre
# threads seria uma corrida de dados com aparência de número aleatório.
private PS_MT_N: const i32 = 624
private PS_MT_M: const i32 = 397

struct PsRng:
    mt: u32[624]
    index: i32
    seeded: i32
    # o par que o método polar produz de uma vez: o `gauss` devolve um e guarda
    # o outro, e é por guardar que a sequência do Python bate — quem joga o
    # segundo fora consome o dobro de números e divide na segunda chamada
    gauss_next: f64
    has_gauss: i32

private def ps_mt_init_genrand(r: *PsRng, s: u32):
    r->mt[0] = s
    mti: i32 = 1
    while mti < PS_MT_N:
        # Knuth TAOCP vol. 2, 3rd ed., p. 106 — o multiplicador é do original
        r->mt[mti] = u32(1812433253) * (r->mt[mti - 1] ^ (r->mt[mti - 1] >> 30)) + u32(mti)
        mti += 1
    r->index = mti

private def ps_mt_init_by_array(r: *PsRng, key: *u32, klen: usize):
    ps_mt_init_genrand(r, u32(19650218))
    i: usize = 1
    j: usize = 0
    k: usize = usize(PS_MT_N) if usize(PS_MT_N) > klen else klen
    while k > usize(0):
        r->mt[i] = (r->mt[i] ^ ((r->mt[i - 1] ^ (r->mt[i - 1] >> 30)) * u32(1664525))) + key[j] + u32(j)
        i += 1
        j += 1
        if i >= usize(PS_MT_N):
            r->mt[0] = r->mt[PS_MT_N - 1]
            i = 1
        if j >= klen:
            j = 0
        k -= 1
    k = usize(PS_MT_N - 1)
    while k > usize(0):
        r->mt[i] = (r->mt[i] ^ ((r->mt[i - 1] ^ (r->mt[i - 1] >> 30)) * u32(1566083941))) - u32(i)
        i += 1
        if i >= usize(PS_MT_N):
            r->mt[0] = r->mt[PS_MT_N - 1]
            i = 1
        k -= 1
    r->mt[0] = u32(0x80000000)      # o bit alto em 1: garante estado não-nulo

private def ps_mt_u32(r: *PsRng) -> u32:
    y: u32 = 0
    if r->index >= PS_MT_N:
        kk: i32 = 0
        while kk < PS_MT_N - PS_MT_M:
            y = (r->mt[kk] & u32(0x80000000)) | (r->mt[kk + 1] & u32(0x7fffffff))
            r->mt[kk] = r->mt[kk + PS_MT_M] ^ (y >> 1) ^ (u32(0x9908b0df) if (y & u32(1)) != u32(0) else u32(0))
            kk += 1
        while kk < PS_MT_N - 1:
            y = (r->mt[kk] & u32(0x80000000)) | (r->mt[kk + 1] & u32(0x7fffffff))
            r->mt[kk] = r->mt[kk + (PS_MT_M - PS_MT_N)] ^ (y >> 1) ^ (u32(0x9908b0df) if (y & u32(1)) != u32(0) else u32(0))
            kk += 1
        y = (r->mt[PS_MT_N - 1] & u32(0x80000000)) | (r->mt[0] & u32(0x7fffffff))
        r->mt[PS_MT_N - 1] = r->mt[PS_MT_M - 1] ^ (y >> 1) ^ (u32(0x9908b0df) if (y & u32(1)) != u32(0) else u32(0))
        r->index = 0
    y = r->mt[r->index]
    r->index += 1
    # o temperamento, que é o que torna a saída equidistribuída
    y = y ^ (y >> 11)
    y = y ^ ((y << 7) & u32(0x9d2c5680))
    y = y ^ ((y << 15) & u32(0xefc60000))
    y = y ^ (y >> 18)
    return y

private def ps_rng(ctx: *PsCtx) -> *PsRng:
    if ctx->rng != None:
        return (*PsRng)(ctx->rng)
    r: *PsRng = (*PsRng)(calloc(1, sizeof(PsRng)))
    ctx->rng = (*void)(r)
    if r == None:
        return None
    # sem semente explícita: hora e pid, que é o caminho de reserva do próprio
    # CPython quando não consegue ler entropia do sistema
    key: u32[4]
    now: f64 = ps_sys_monotonic()
    key[0] = u32(u64(now * 1000000.0) & u64(0xffffffff))
    key[1] = u32((u64(now * 1000000.0) >> 32) & u64(0xffffffff))
    key[2] = u32(getpid())
    key[3] = u32(0x5bf03635)
    ps_mt_init_by_array(r, &key[0], usize(4))
    r->seeded = 1
    return r

def ps_random_free(ctx: *PsCtx):
    if ctx->rng != None:
        free(ctx->rng)
        ctx->rng = None

# `random.seed(n)`: os pedaços de 32 bits do VALOR ABSOLUTO, do menos
# significativo para o mais, que é o que o CPython faz — e é o que faz a
# sequência ser a mesma dele
def ps_random_seed(ctx: *PsCtx, n: i64):
    r: *PsRng = ps_rng(ctx)
    if r == None:
        return
    un: u64 = u64(n) if n >= 0 else u64(-n)
    key: u32[2]
    key[0] = u32(un & u64(0xffffffff))
    key[1] = u32((un >> 32) & u64(0xffffffff))
    used: usize = usize(2) if key[1] != u32(0) else usize(1)
    ps_mt_init_by_array(r, &key[0], used)
    r->seeded = 1
    # semear repõe TUDO: com o par do `gauss` pendente, a mesma semente daria
    # números diferentes conforme o que tivesse sido sorteado antes dela
    r->has_gauss = 0
    r->gauss_next = 0.0

# 53 bits de resolução, exatamente como o `genrand_res53` do original: 27 bits
# deslocados 26 mais 26 bits embaixo
def ps_random_random(ctx: *PsCtx) -> f64:
    r: *PsRng = ps_rng(ctx)
    if r == None:
        return 0.0
    a: u32 = ps_mt_u32(r) >> 5
    b: u32 = ps_mt_u32(r) >> 6
    return (f64(a) * 67108864.0 + f64(b)) * (1.0 / 9007199254740992.0)

def ps_random_getrandbits(ctx: *PsCtx, k: i64, file: const *char, line: i32) -> i64:
    r: *PsRng = ps_rng(ctx)
    if r == None:
        return 0
    if k < 0:
        ps_raise(ctx, "getrandbits() takes a non-negative number of bits", PS_CAT_VALUE, file, line)
        return 0
    if k == 0:
        return 0
    if k > 63:
        # o Python devolveria um inteiro grande; aqui int é 64 bits (7.2), então
        # o limite é dito em voz alta em vez de truncar em silêncio
        ps_raise(ctx, "getrandbits() above 63 bits would need a big integer, and int is 64 bits here (7.2)", PS_CAT_VALUE, file, line)
        return 0
    if k <= 32:
        return i64(ps_mt_u32(r) >> u32(32 - i32(k)))
    lo: u64 = u64(ps_mt_u32(r))
    hi: u64 = u64(ps_mt_u32(r) >> u32(64 - i32(k)))
    return i64(lo | (hi << 32))

# `Lib/random.py`: `_randbelow_with_getrandbits` — k bits, e sorteia de novo
# enquanto cair fora. É o que dá uniformidade sem viés de módulo.
def ps_random_below(ctx: *PsCtx, n: i64, file: const *char, line: i32) -> i64:
    if n <= 0:
        ps_raise(ctx, "there is nothing to choose from an empty range", PS_CAT_VALUE, file, line)
        return 0
    # `k = n.bit_length()` — de N, não de n-1. A diferença aparece exatamente na
    # potência de dois: `bit_length(4)` é 3, então o Python sorteia 3 bits e
    # descarta metade. Contar os bits de n-1 dá 2 e a sequência divergiria da
    # dele na primeira lista de tamanho 4 — que foi como o `shuffle` me pegou.
    k: i64 = 0
    m: u64 = u64(n)
    while m > u64(0):
        k += 1
        m = m >> 1
    if k == 0:
        return 0
    v: i64 = ps_random_getrandbits(ctx, k, file, line)
    while v >= n:
        if ctx->exc != None:
            return 0
        v = ps_random_getrandbits(ctx, k, file, line)
    return v

# `randrange(start, stop, step)`: o Python conta quantos itens o range tem e
# sorteia um índice — não sorteia até cair dentro, senão a distribuição
# dependeria do passo. As três formas chegam aqui já normalizadas.
def ps_random_randrange(ctx: *PsCtx, start: i64, stop: i64, step: i64, file: const *char, line: i32) -> i64:
    if step == 0:
        ps_raise(ctx, "randrange() step may not be zero", PS_CAT_VALUE, file, line)
        return 0
    n: i64 = 0
    if step > 0:
        if stop > start:
            n = (stop - start + step - 1) / step
    else:
        if stop < start:
            n = (start - stop + (-step) - 1) / (-step)
    if n <= 0:
        ps_raise(ctx, "empty range for randrange()", PS_CAT_VALUE, file, line)
        return 0
    return start + step * ps_random_below(ctx, n, file, line)

def ps_random_randint(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64:
    if b < a:
        ps_raise(ctx, "randint(a, b) needs b >= a", PS_CAT_VALUE, file, line)
        return 0
    return a + ps_random_below(ctx, b - a + 1, file, line)

def ps_random_uniform(ctx: *PsCtx, a: f64, b: f64) -> f64:
    return a + (b - a) * ps_random_random(ctx)

# `Lib/random.py`, `gauss`: o método polar de Box-Muller, que sai aos pares.
# `sigma` é o desvio padrão, não a variância.
def ps_random_gauss(ctx: *PsCtx, mu: f64, sigma: f64) -> f64:
    r: *PsRng = ps_rng(ctx)
    z: f64 = 0.0
    if r->has_gauss != 0:
        z = r->gauss_next
        r->has_gauss = 0
    else:
        x2pi: f64 = ps_random_random(ctx) * 6.283185307179586
        g2rad: f64 = sqrt(-2.0 * log(1.0 - ps_random_random(ctx)))
        z = cos(x2pi) * g2rad
        r->gauss_next = sin(x2pi) * g2rad
        r->has_gauss = 1
    return mu + z * sigma

# `1.0 - random()` e não `random()`: o sorteio inclui o zero e excluí-lo aqui é
# o que impede o log de -0.0
def ps_random_expovariate(ctx: *PsCtx, lambd: f64, file: const *char, line: i32) -> f64:
    if lambd == 0.0:
        ps_raise(ctx, "expovariate() lambda may not be zero", PS_CAT_VALUE, file, line)
        return 0.0
    return -log(1.0 - ps_random_random(ctx)) / lambd

# `Lib/random.py`: Fisher-Yates de trás para frente, com o mesmo `_randbelow` —
# então a permutação de uma semente dada é a mesma do Python
def ps_random_shuffle(ctx: *PsCtx, l: *PsList, file: const *char, line: i32):
    if l == None or l->len < 2:
        return
    es: usize = usize(l->esize)
    tmp: *char = (*char)(malloc(es))
    if tmp == None:
        return
    base: *char = (*char)(l->data) + sizeof(PsArr)
    i: i64 = l->len - 1
    while i > 0:
        j: i64 = ps_random_below(ctx, i + 1, file, line)
        if ctx->exc != None:
            break
        if j != i:
            memcpy(tmp, base + usize(i) * es, es)
            memcpy(base + usize(i) * es, base + usize(j) * es, es)
            memcpy(base + usize(j) * es, tmp, es)
        i -= 1
    free(tmp)
