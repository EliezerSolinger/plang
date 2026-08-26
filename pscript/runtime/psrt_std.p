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
                        k = ps_utf8_put(buf, k, 0xFFFD)
                        cp = 0xFFFD if (lo >= 0xD800 and lo <= 0xDFFF) else lo
                else:
                    cp = 0xFFFD
            elif cp >= 0xDC00 and cp <= 0xDFFF:
                cp = 0xFFFD       # a low surrogate with nothing in front of it
            k = ps_utf8_put(buf, k, cp)
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


# 135.8: `off`/`cnt` in ELEMENTS, and `cnt < 0` means "everything from `off`",
# which is what a window over the whole buffer asks for.
def ps_buffer_view_at(ctx: *PsCtx, b: *PsBuffer, esize: i32, off: i64, cnt: i64, file: const *char, line: i32) -> *PsList:
    if ps_buffer_gone(ctx, b):
        ps_raise(ctx, "this buffer was transferred: it belongs to whoever received it (18.2)", PS_CAT_VALUE, file, line)
        return None
    if b == None or b->open == 0:
        ps_raise(ctx, "this buffer is closed", PS_CAT_VALUE, file, line)
        return None
    if b->nbytes % usize(esize) != usize(0):
        ps_raise(ctx, "the buffer does not divide into elements of this size", PS_CAT_VALUE, file, line)
        return None
    total: i64 = i64(b->nbytes / usize(esize))
    n: i64 = (total - off) if cnt < 0 else cnt
    # A window is NOT a slice: it does not clamp, it raises. A slice past the
    # end trims because 17.3 says so about copies; a window past the end would
    # be a window over memory the buffer does not own, and trimming that
    # quietly is how a read walks off a block.
    if off < 0 or n < 0 or off + n > total:
        ps_raise(ctx, "this window falls outside the Buffer", PS_CAT_INDEX, file, line)
        return None
    l: *PsList = ps_alloc(ctx, sizeof(PsList), PS_TY_LIST)
    l->len = n
    l->cap = n
    l->esize = esize
    l->eref = False
    l->etrace = None    # `ps_alloc` não zera; uma vista não o usa, mas o campo
                        #   existe e ficar com lixo é uma armadilha à espera
    l->data = None
    l->raw = b->data + usize(off) * usize(esize)
    l->owner = b
    return l


def ps_buffer_view(ctx: *PsCtx, b: *PsBuffer, esize: i32, file: const *char, line: i32) -> *PsList:
    return ps_buffer_view_at(ctx, b, esize, 0, -1, file, line)

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

# ---------- `codec` (155): base64 e hex ----------
#
# **No runtime pela mesma razão que o `json`**: uma codificação de fio com
# especificação CONGELADA e sem política. A RFC 4648 é de 2006 e está fechada, e
# as quatro variantes do base64 são PARÂMETROS — o alfabeto e o enchimento — e
# não escolhas de desenho. A 155.2 escreve a linha que impede o `csv` de vir
# atrás.
#
# **Base64 tem quatro variantes, e é a vida que as cobra.** O alfabeto padrão
# acaba em `+` e `/`, que são os dois caracteres que um URL não pode levar; por
# isso a §5 define um segundo alfabeto. E o enchimento `=` é obrigatório para uns
# leitores e proibido para outros (um JWT não tem nenhum). Duas perguntas, dois
# booleanos, quatro respostas — e oferecer só uma delas é o que faz cada projecto
# escrever as outras três à mão.

private const B64_STD: const *char = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
private const B64_URL: const *char = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
private const CODEC_HEX: const *char = "0123456789abcdef"
private const CODEC_HEXU: const *char = "0123456789ABCDEF"

def ps_b64_encode(ctx: *PsCtx, b: *PsBytes, urlsafe: bool, pad: bool) -> *PsStr:
    n: usize = b->len
    al: const *char = B64_URL if urlsafe else B64_STD
    # o tamanho exacto: quatro caracteres por cada três bytes, e o resto
    cap: usize = (n / 3) * 4 + (4 if pad else (2 if n % 3 == 1 else 3)) * (1 if n % 3 != 0 else 0)
    out: *char = (*char)(malloc(cap + 1))
    defer free(out)
    src: *u8 = (*u8)(b->data)
    k: usize = 0
    i: usize = 0
    while i + 3 <= n:
        v: u32 = (u32(src[i]) << 16) | (u32(src[i + 1]) << 8) | u32(src[i + 2])
        out[k] = al[(v >> 18) & u32(63)]
        out[k + 1] = al[(v >> 12) & u32(63)]
        out[k + 2] = al[(v >> 6) & u32(63)]
        out[k + 3] = al[v & u32(63)]
        k += 4
        i += 3
    left: usize = n - i
    if left == 1:
        v1: u32 = u32(src[i]) << 16
        out[k] = al[(v1 >> 18) & u32(63)]
        out[k + 1] = al[(v1 >> 12) & u32(63)]
        k += 2
        if pad:
            out[k] = '='
            out[k + 1] = '='
            k += 2
    elif left == 2:
        v2: u32 = (u32(src[i]) << 16) | (u32(src[i + 1]) << 8)
        out[k] = al[(v2 >> 18) & u32(63)]
        out[k + 1] = al[(v2 >> 12) & u32(63)]
        out[k + 2] = al[(v2 >> 6) & u32(63)]
        k += 3
        if pad:
            out[k] = '='
            k += 1
    out[k] = '\0'
    return ps_str_new(ctx, out, k)

# O valor de um caractere de base64, em QUALQUER dos dois alfabetos, ou -1.
private def b64_val(c: char) -> i32:
    o: i32 = i32(u8(c))
    if o >= 65 and o <= 90:
        return o - 65
    if o >= 97 and o <= 122:
        return o - 97 + 26
    if o >= 48 and o <= 57:
        return o - 48 + 52
    if c == '+' or c == '-':
        return 62
    if c == '/' or c == '_':
        return 63
    return -1

# **Descodificar ACEITA o que codificar não produziria**, e é de propósito: leva
# qualquer dos alfabetos, com ou sem enchimento. É a regra de Postel aplicada
# onde é segura — a entrada vem de outra pessoa, e há exactamente uma cadeia de
# bytes que ela pode querer dizer.
#
# **E devolve None quando não é base64** (4.2): entrada de fora que não analisa é
# um caso previsto, não um acidente.
def ps_b64_decode(ctx: *PsCtx, s: *PsStr) -> *PsBytes:
    n: usize = usize(s->len)
    out: *char = (*char)(malloc(n + 1))
    defer free(out)
    acc: u32 = u32(0)
    nbits: i32 = 0
    k: usize = 0
    for i in range(i64(n)):
        c: char = s->data[i]
        if c == '=':
            break
        v: i32 = b64_val(c)
        if v < 0:
            return None
        acc = (acc << 6) | u32(v)
        nbits += 6
        if nbits >= 8:
            nbits -= 8
            out[k] = char((acc >> u32(nbits)) & u32(0xFF))
            k += 1
    # o que sobra tem de ser ENCHIMENTO, e enchimento é zero. Um resto com bits a
    # um é texto que ninguém produziu a codificar, e aceitá-lo faria duas
    # entradas diferentes dar o mesmo resultado — que é como se forjam
    # assinaturas em base64.
    if nbits >= 6:
        return None
    if nbits > 0 and (acc & ((u32(1) << u32(nbits)) - u32(1))) != u32(0):
        return None
    return ps_bytes_new(ctx, out, k)

def ps_hex_encode(ctx: *PsCtx, b: *PsBytes, upper: bool) -> *PsStr:
    n: usize = b->len
    d: const *char = CODEC_HEXU if upper else CODEC_HEX
    out: *char = (*char)(malloc(n * 2 + 1))
    defer free(out)
    src: *u8 = (*u8)(b->data)
    for i in range(i64(n)):
        out[i * 2] = d[(u32(src[i]) >> 4) & u32(15)]
        out[i * 2 + 1] = d[u32(src[i]) & u32(15)]
    out[n * 2] = '\0'
    return ps_str_new(ctx, out, n * 2)

private def hex_val(c: char) -> i32:
    o: i32 = i32(u8(c))
    if o >= 48 and o <= 57:
        return o - 48
    if o >= 97 and o <= 102:
        return o - 97 + 10
    if o >= 65 and o <= 70:
        return o - 65 + 10
    return -1

def ps_hex_decode(ctx: *PsCtx, s: *PsStr) -> *PsBytes:
    n: usize = usize(s->len)
    # meio byte não é um byte
    if n % 2 != 0:
        return None
    out: *char = (*char)(malloc(n / 2 + 1))
    defer free(out)
    for i in range(i64(n / 2)):
        hi: i32 = hex_val(s->data[i * 2])
        lo: i32 = hex_val(s->data[i * 2 + 1])
        if hi < 0 or lo < 0:
            return None
        out[i] = char(hi * 16 + lo)
    return ps_bytes_new(ctx, out, n / 2)

# ---------- `re`: o motor de Thompson (S2b) ----------
#
# O motor de expressões regulares (S2b): um autómato de Thompson, e a garantia
# que ele traz.
#
# **Substitui o `regcomp`/`regexec` da libc**, e o argumento não é gosto: um motor
# com retrocesso pode ser feito parar por uma cadeia de entrada. `(a+)+b` contra
# sessenta `a` pára um PCRE durante anos; aqui devolve. Uma linguagem que promete
# quatro eixos de segurança de memória (9.1) e depois oferece um regex que uma
# entrada consegue travar está a prometer com uma mão e a tirar com a outra.
#
# **O preço está pago à cabeça, e é matemática e não esforço:** um motor de tempo
# linear NÃO PODE ter retrocesso (`\\1`) nem lookaround (`(?=…)`). O autómato não
# guarda o texto que já casou — é essa a razão de ele ser linear. É o dialecto do
# RE2, que é o do Go e o do `regex` do Rust, e a lista do que isso impede na
# prática é curta.
#
# O que se ganha: `\\d` `\\w` `\\s` `\\b`, não-guloso (`*?`), grupos com nome,
# classes, âncoras, e a garantia.
#
# ---
#
# **A forma:** o padrão vira um PROGRAMA — uma lista de instruções — e a execução
# corre TODAS as linhas de execução ao mesmo tempo, um caractere de cada vez. É a
# máquina do Pike. O que a faz linear é uma linha só: **num dado passo, cada
# instrução entra na lista no máximo UMA vez**. Sem isso, duas linhas que chegam ao
# mesmo sítio duplicam-se, e a duplicação é exponencial.
#
# **A memória do programa é malloc'd e não coletada.** Um padrão compilado é
# estrutura interna, sem um único ponteiro para o monte, e assim uma coleta a meio
# de um `sub` não tem nada que ver com ele — que é a mesma razão por que o
# `PsWork` do pool também é malloc'd.


# P precisa de um TIPO para o `sizeof`, e `*char` não é um nome — é uma
# construção. Dois aliases de tamanho de ponteiro, como o `PsStrPtr` que o
# `psrt_types.ph` já tinha pela mesma razão.
struct PsCharPtr:
    p: *char

# ---------- as instruções ----------

enum ReOp:
    RE_CHAR = 0      # um codepoint exacto
    RE_ANY = 1       # qualquer um — e `.` NÃO casa `\n` (é a regra de toda a gente)
    RE_ANY_NL = 2    # ... e casa, com `(?s)`
    RE_CLASS = 3     # uma classe: intervalos, com ou sem negação
    RE_MATCH = 4
    RE_JMP = 5
    RE_SPLIT = 6     # duas continuações; a PRIMEIRA é a preferida
    RE_SAVE = 7      # marca uma posição de captura
    RE_BOL = 8       # `^`
    RE_EOL = 9       # `$`
    RE_BOT = 10      # `\A` — o começo do TEXTO, mesmo em modo multilinha
    RE_EOT = 11      # `\z`
    RE_WORDB = 12    # `\b`
    RE_NWORDB = 13   # `\B`

struct ReInst:
    op: i32
    c: u32           # RE_CHAR: o codepoint. RE_SAVE: a ranhura.
    x: i32           # RE_JMP/RE_SPLIT: para onde
    y: i32           # RE_SPLIT: a outra
    cls: i32         # RE_CLASS: o índice na tabela de classes

# Uma classe é uma lista de intervalos de codepoints, mais a marca de negação. Os
# intervalos ficam ORDENADOS e sem sobreposição, para a pergunta ser uma busca
# binária em vez de uma varredura — o que importa quando a classe é `\w` em
# Unicode e tem centenas deles.
struct ReClass:
    lo: *u32
    hi: *u32
    n: i32
    cap: i32
    neg: i32
    # 152.6: as categorias Unicode que esta classe também aceita. Um predicado e
    # não intervalos, porque `\p{L}` são cento e trinta mil pontos de código em
    # milhares de faixas — expandi-los daria uma tabela por padrão, e a tabela já
    # existe uma vez só, gerada e conferida (105).
    uni: *i32
    nuni: i32

struct ReProg:
    inst: *ReInst
    n: i32
    cap: i32
    cls: *ReClass
    ncls: i32
    clscap: i32
    ngroup: i32          # quantos grupos capturam (o 0 é o casamento inteiro)
    names: **char        # o nome de cada grupo, ou None
    nnames: i32          # quantos cabem hoje — CRESCE, e é por isso que não há
                         #   um tecto de grupos com nome nem um botão para ele
    icase: i32
    multiline: i32
    dotall: i32
    ok: i32
    err: *char           # a mensagem, quando não compilou


struct ReProgPtr:
    p: *ReProg

# ---------- construir o programa ----------

private def re_grow(p: *ReProg):
    if p->n < p->cap:
        return
    nc: i32 = p->cap * 2 if p->cap > 0 else 16
    p->inst = (*ReInst)(realloc((*void)(p->inst), usize(nc) * sizeof(ReInst)))
    p->cap = nc

private def re_emit(p: *ReProg, op: i32) -> i32:
    re_grow(p)
    at: i32 = p->n
    p->inst[at].op = op
    p->inst[at].c = u32(0)
    p->inst[at].x = 0
    p->inst[at].y = 0
    p->inst[at].cls = -1
    p->n += 1
    return at

private def re_class_new(p: *ReProg) -> i32:
    if p->ncls >= p->clscap:
        nc: i32 = p->clscap * 2 if p->clscap > 0 else 8
        p->cls = (*ReClass)(realloc((*void)(p->cls), usize(nc) * sizeof(ReClass)))
        p->clscap = nc
    at: i32 = p->ncls
    p->cls[at].lo = None
    p->cls[at].hi = None
    p->cls[at].n = 0
    p->cls[at].cap = 0
    p->cls[at].neg = 0
    p->cls[at].uni = None
    p->cls[at].nuni = 0
    p->ncls += 1
    return at

private def re_class_add(c: *ReClass, lo: u32, hi: u32):
    if c->n >= c->cap:
        nc: i32 = c->cap * 2 if c->cap > 0 else 8
        c->lo = (*u32)(realloc((*void)(c->lo), usize(nc) * sizeof(u32)))
        c->hi = (*u32)(realloc((*void)(c->hi), usize(nc) * sizeof(u32)))
        c->cap = nc
    c->lo[c->n] = lo
    c->hi[c->n] = hi
    c->n += 1

private def re_class_add_uni(c: *ReClass, which: i32):
    c->uni = (*i32)(realloc((*void)(c->uni), usize(c->nuni + 1) * sizeof(i32)))
    c->uni[c->nuni] = which
    c->nuni += 1

private def re_class_has(c: const *ReClass, ch: u32) -> bool:
    inside: bool = False
    for i in range(c->n):
        if ch >= c->lo[i] and ch <= c->hi[i]:
            inside = True
    if not inside:
        for i in range(c->nuni):
            if ps_cp_in_cat(i32(ch), c->uni[i]):
                inside = True
    return not inside if c->neg != 0 else inside


# ---------- o analisador ----------
#
# Descida recursiva, e a gramática é a de sempre:
#
#   alt   := cat ('|' cat)*
#   cat   := rep*
#   rep   := atom ('*' | '+' | '?' | '{m,n}') '?'?
#   atom  := '(' alt ')' | '[' class ']' | '.' | '^' | '$' | escape | literal
#
# O que ele emite é o programa directamente, sem árvore pelo meio: cada regra
# sabe onde começou e o que tem de remendar, que é o que torna a repetição uma
# questão de dois `SPLIT` e um `JMP`.

struct ReParser:
    pat: const *char
    n: i32
    i: i32
    p: *ReProg
    group: i32

private def rp_fail(P: *ReParser, msg: const *char):
    if P->p->ok != 0:
        P->p->ok = 0
        P->p->err = strdup(msg)

private def rp_eof(P: *ReParser) -> bool:
    return P->i >= P->n

# O padrão é UTF-8 e o que ele fala são CODEPOINTS — `.` casa um codepoint, e um
# `[á-ç]` tem de ter os extremos certos. Ler byte a byte daria uma classe com os
# bytes da codificação lá dentro, que é o defeito clássico de quem só testou em
# ASCII.
private def re_utf8_at(s: const *char, n: i32, at: i32, out_len: *i32) -> i32:
    if at >= n:
        *out_len = 0
        return -1
    b0: u32 = u32(u8(s[at]))
    if b0 < u32(0x80):
        *out_len = 1
        return i32(b0)
    if b0 >= u32(0xC2) and b0 <= u32(0xDF) and at + 1 < n:
        *out_len = 2
        return i32(((b0 & u32(0x1F)) << 6) | (u32(u8(s[at + 1])) & u32(0x3F)))
    if b0 >= u32(0xE0) and b0 <= u32(0xEF) and at + 2 < n:
        *out_len = 3
        return i32(((b0 & u32(0x0F)) << 12) | ((u32(u8(s[at + 1])) & u32(0x3F)) << 6) | (u32(u8(s[at + 2])) & u32(0x3F)))
    if b0 >= u32(0xF0) and b0 <= u32(0xF4) and at + 3 < n:
        *out_len = 4
        return i32(((b0 & u32(0x07)) << 18) | ((u32(u8(s[at + 1])) & u32(0x3F)) << 12) | ((u32(u8(s[at + 2])) & u32(0x3F)) << 6) | (u32(u8(s[at + 3])) & u32(0x3F)))
    # um byte que não é UTF-8 válido vale por si próprio: recusar aqui faria um
    # padrão legítimo sobre bytes soltos deixar de compilar
    *out_len = 1
    return i32(b0)

private def rp_peek(P: *ReParser) -> i32:
    L: i32 = 0
    return re_utf8_at(P->pat, P->n, P->i, &L)

private def rp_next(P: *ReParser) -> i32:
    L: i32 = 0
    c: i32 = re_utf8_at(P->pat, P->n, P->i, &L)
    P->i += L
    return c

private def rp_at(P: *ReParser, c: i32) -> bool:
    return rp_peek(P) == c


# ---------- as classes com nome ----------
#
# `\d`, `\w`, `\s` e os `[:alpha:]` do POSIX. Em ASCII por agora; a tabela de
# categorias do Unicode (que já existe, 27 KB) entra por aqui quando o `\p{L}`
# chegar, e é este o único sítio que muda.

private def re_add_named(p: *ReProg, cls: i32, kind: i32) -> bool:
    c: *ReClass = &p->cls[cls]
    if kind == 'd':
        re_class_add(c, u32(48), u32(57))
        return True
    if kind == 'w':
        re_class_add(c, u32(48), u32(57))
        re_class_add(c, u32(65), u32(90))
        re_class_add(c, u32(95), u32(95))
        re_class_add(c, u32(97), u32(122))
        return True
    if kind == 's':
        re_class_add(c, u32(9), u32(13))
        re_class_add(c, u32(32), u32(32))
        return True
    return False

# `\D`, `\W`, `\S`: a classe negada. Não é o mesmo que negar a classe INTEIRA
# quando ela está dentro de `[...]` — `[\D0]` é "não-dígito OU zero", e não
# "não (dígito ou zero)". Por isso uma classe negada dentro de outra vira o seu
# próprio intervalo complementar, calculado aqui.
private def re_add_named_neg(p: *ReProg, cls: i32, kind: i32) -> bool:
    tmp: i32 = re_class_new(p)
    if not re_add_named(p, tmp, kind):
        p->ncls -= 1
        return False
    t: *ReClass = &p->cls[tmp]
    c: *ReClass = &p->cls[cls]
    # os intervalos vêm ordenados de `re_add_named`, portanto o complemento é
    # uma passagem
    prev: u32 = u32(0)
    for i in range(t->n):
        if t->lo[i] > prev:
            re_class_add(c, prev, t->lo[i] - u32(1))
        prev = t->hi[i] + u32(1)
    re_class_add(c, prev, u32(0x10FFFF))
    p->ncls -= 1
    free((*void)(t->lo))
    free((*void)(t->hi))
    return True


# ---------- o corpo do analisador ----------

private def rp_alt(P: *ReParser) -> bool
private def rp_cat(P: *ReParser) -> bool
private def rp_rep(P: *ReParser) -> bool
private def rp_atom(P: *ReParser) -> bool
private def rp_class(P: *ReParser) -> bool
private def rp_escape(P: *ReParser) -> bool
private def re_fix_shift(p: *ReProg, from: i32, to: i32, by: i32)
private def re_star(p: *ReProg, start: i32, lazy: bool)
private def re_plus(p: *ReProg, start: i32, lazy: bool)
private def re_quest(p: *ReProg, start: i32, lazy: bool)
private def re_is_count(P: *ReParser) -> bool
private def re_counted(P: *ReParser, start: i32) -> bool
private def re_paste(p: *ReProg, body: *ReInst, blen: i32, orig: i32)
private def re_name_set(p: *ReProg, slot: i32, name: *char)
private def re_escape_char(P: *ReParser, c: i32) -> i32
private def re_hex(c: i32) -> i32
private def re_read_uni(P: *ReParser) -> i32
private def re_class_add_uni(c: *ReClass, which: i32)
private def re_cache_of(ctx: *PsCtx) -> *ReCache
private def ps_re_find(ctx: *PsCtx, pattern: *PsStr, pat: *PsPattern, text: *PsStr, from: i32, anchored: bool, file: const *char, line: i32) -> *PsList
private def re_group_by_name(p: *ReProg, nm: const *char) -> i32

# `a|b` — o `SPLIT` fica ANTES do primeiro ramo e o `JMP` no fim dele, e os dois
# só se sabem depois de o ramo estar emitido. Por isso o buraco é remendado a
# seguir, que é a única maneira de gerar isto numa passagem.
private def rp_alt(P: *ReParser) -> bool:
    start: i32 = P->p->n
    if not rp_cat(P):
        return False
    while rp_at(P, '|'):
        _ = rp_next(P)
        # abre espaço para o SPLIT no princípio: as instruções deslizam uma
        sp: i32 = re_emit(P->p, RE_SPLIT)
        memmove((*void)(&P->p->inst[start + 1]), (*void)(&P->p->inst[start]),
                usize(sp - start) * sizeof(ReInst))
        re_fix_shift(P->p, start, sp, 1)
        P->p->inst[start].op = RE_SPLIT
        P->p->inst[start].c = u32(0)
        P->p->inst[start].cls = -1
        P->p->inst[start].x = start + 1
        jm: i32 = re_emit(P->p, RE_JMP)
        P->p->inst[start].y = P->p->n
        if not rp_cat(P):
            return False
        P->p->inst[jm].x = P->p->n
    return True

# Quando uma instrução é inserida no meio, todos os saltos que apontavam para
# depois dela têm de andar. É a razão de o programa ser um ARRAY e não uma lista
# ligada: o remendo é uma passagem, e a execução é um índice.
private def re_fix_shift(p: *ReProg, from: i32, to: i32, by: i32):
    for i in range(p->n):
        if p->inst[i].op == RE_JMP or p->inst[i].op == RE_SPLIT:
            if p->inst[i].x >= from and p->inst[i].x <= to:
                p->inst[i].x += by
            if p->inst[i].op == RE_SPLIT and p->inst[i].y >= from and p->inst[i].y <= to:
                p->inst[i].y += by

private def rp_cat(P: *ReParser) -> bool:
    while not rp_eof(P) and not rp_at(P, '|') and not rp_at(P, ')'):
        if not rp_rep(P):
            return False
    return True

private def rp_rep(P: *ReParser) -> bool:
    start: i32 = P->p->n
    if not rp_atom(P):
        return False
    while True:
        c: i32 = rp_peek(P)
        if c != '*' and c != '+' and c != '?' and c != '{':
            return True
        if c == '{' and not re_is_count(P):
            return True          # `{` que não é uma contagem é um literal
        _ = rp_next(P)
        # o `?` a seguir torna o operador NÃO GULOSO: a única diferença é qual
        # dos dois ramos do SPLIT é o preferido
        lazy: bool = False
        if c != '{' and rp_at(P, '?'):
            _ = rp_next(P)
            lazy = True
        if c == '*':
            re_star(P->p, start, lazy)
        elif c == '+':
            re_plus(P->p, start, lazy)
        elif c == '?':
            re_quest(P->p, start, lazy)
        else:
            if not re_counted(P, start):
                return False
    return True


# ---------- os operadores de repetição ----------
#
# Cada um é dois ou três remendos sobre o pedaço que já está emitido. O `lazy`
# só troca a ordem dos dois ramos do `SPLIT`: o autómato prefere sempre o `x`, e
# guloso ou não guloso é só qual dos dois é o `x`.

private def re_star(p: *ReProg, start: i32, lazy: bool):
    #   L1: SPLIT L2, L3
    #   L2: <corpo>
    #       JMP L1
    #   L3:
    sp: i32 = re_emit(p, RE_SPLIT)
    memmove((*void)(&p->inst[start + 1]), (*void)(&p->inst[start]), usize(sp - start) * sizeof(ReInst))
    re_fix_shift(p, start, sp, 1)
    jm: i32 = re_emit(p, RE_JMP)
    p->inst[jm].x = start
    p->inst[start].op = RE_SPLIT
    p->inst[start].cls = -1
    if lazy:
        p->inst[start].x = p->n
        p->inst[start].y = start + 1
    else:
        p->inst[start].x = start + 1
        p->inst[start].y = p->n

private def re_plus(p: *ReProg, start: i32, lazy: bool):
    #   L1: <corpo>
    #       SPLIT L1, L2
    #   L2:
    sp: i32 = re_emit(p, RE_SPLIT)
    p->inst[sp].cls = -1
    if lazy:
        p->inst[sp].x = p->n
        p->inst[sp].y = start
    else:
        p->inst[sp].x = start
        p->inst[sp].y = p->n

private def re_quest(p: *ReProg, start: i32, lazy: bool):
    #   L1: SPLIT L2, L3
    #   L2: <corpo>
    #   L3:
    sp: i32 = re_emit(p, RE_SPLIT)
    memmove((*void)(&p->inst[start + 1]), (*void)(&p->inst[start]), usize(sp - start) * sizeof(ReInst))
    re_fix_shift(p, start, sp, 1)
    p->inst[start].op = RE_SPLIT
    p->inst[start].cls = -1
    if lazy:
        p->inst[start].x = p->n
        p->inst[start].y = start + 1
    else:
        p->inst[start].x = start + 1
        p->inst[start].y = p->n


# ---------- `{m,n}` ----------
#
# Olha para a frente antes de decidir: um `{` que não é seguido de dígitos é um
# literal, e é assim que `a{b}` continua a ser três caracteres. É o que o RE2
# faz, e o contrário — recusar — partiria padrões que existem.
private def re_is_count(P: *ReParser) -> bool:
    j: i32 = P->i + 1
    got: bool = False
    while j < P->n and u8(P->pat[j]) >= u8(48) and u8(P->pat[j]) <= u8(57):
        j += 1
        got = True
    if not got:
        return False
    if j < P->n and P->pat[j] == ',':
        j += 1
        while j < P->n and u8(P->pat[j]) >= u8(48) and u8(P->pat[j]) <= u8(57):
            j += 1
    return j < P->n and P->pat[j] == '}'

# `{m,n}` é EXPANDIDO: `a{2,4}` vira `aa(a(a)?)?`. Repetir o pedaço é a única
# forma que um autómato sem contadores tem, e é a que o RE2 usa — com o limite
# abaixo, que existe para um `a{1000000}` não fazer um programa de um milhão de
# instruções a partir de doze caracteres.
private const RE_MAX_REPEAT: const i32 = 1000

private def re_counted(P: *ReParser, start: i32) -> bool:
    lo: i32 = 0
    hi: i32 = -1
    while not rp_eof(P) and rp_peek(P) >= '0' and rp_peek(P) <= '9':
        lo = lo * 10 + (rp_next(P) - 48)
    if rp_at(P, ','):
        _ = rp_next(P)
        if rp_at(P, '}'):
            hi = -1
        else:
            hi = 0
            while not rp_eof(P) and rp_peek(P) >= '0' and rp_peek(P) <= '9':
                hi = hi * 10 + (rp_next(P) - 48)
    else:
        hi = lo
    if not rp_at(P, '}'):
        rp_fail(P, "a `{m,n}` that never closes")
        return False
    _ = rp_next(P)
    if lo > RE_MAX_REPEAT or hi > RE_MAX_REPEAT:
        rp_fail(P, "a repetition count above the ceiling: a pattern of a dozen characters would become a program of a million instructions")
        return False
    if hi >= 0 and hi < lo:
        rp_fail(P, "a `{m,n}` with n smaller than m")
        return False
    lazy: bool = False
    if rp_at(P, '?'):
        _ = rp_next(P)
        lazy = True
    # o pedaço original é a UNIDADE que se copia
    blen: i32 = P->p->n - start
    body: *ReInst = (*ReInst)(malloc(usize(blen) * sizeof(ReInst)))
    memcpy((*void)(body), (*void)(&P->p->inst[start]), usize(blen) * sizeof(ReInst))
    P->p->n = start
    for k in range(lo):
        re_paste(P->p, body, blen, start)
    if hi < 0:
        # `{m,}` — o último vira `+`, ou um `*` quando m é zero
        if lo == 0:
            at: i32 = P->p->n
            re_paste(P->p, body, blen, start)
            re_star(P->p, at, lazy)
        else:
            at2: i32 = P->p->n - blen
            re_plus(P->p, at2, lazy)
    else:
        for k in range(hi - lo):
            at3: i32 = P->p->n
            re_paste(P->p, body, blen, start)
            re_quest(P->p, at3, lazy)
    free((*void)(body))
    return True

# Cola uma cópia do pedaço no fim, com os saltos de dentro dele deslocados. Os
# saltos que apontavam para fora do pedaço não existem — um pedaço é fechado por
# construção —, portanto o ajuste é uma soma.
private def re_paste(p: *ReProg, body: *ReInst, blen: i32, orig: i32):
    at: i32 = p->n
    for k in range(blen):
        j: i32 = re_emit(p, body[k].op)
        p->inst[j].c = body[k].c
        p->inst[j].cls = body[k].cls
        p->inst[j].x = body[k].x - orig + at
        p->inst[j].y = body[k].y - orig + at


# ---------- os átomos ----------

private def rp_atom(P: *ReParser) -> bool:
    c: i32 = rp_peek(P)
    if c < 0:
        return True
    if c == '(':
        _ = rp_next(P)
        cap: bool = True
        name: *char = None
        if rp_at(P, '?'):
            _ = rp_next(P)
            k: i32 = rp_peek(P)
            if k == ':':
                _ = rp_next(P)
                cap = False
            elif k == 'P' or k == '<':
                # `(?P<nome>…)` do Python e `(?<nome>…)` do resto do mundo: os
                # dois, porque os dois existem e distingui-los não serve nada
                if k == 'P':
                    _ = rp_next(P)
                if not rp_at(P, '<'):
                    rp_fail(P, "a named group is written `(?<name>…)` or `(?P<name>…)`")
                    return False
                _ = rp_next(P)
                st: i32 = P->i
                while not rp_eof(P) and not rp_at(P, '>'):
                    _ = rp_next(P)
                if rp_eof(P):
                    rp_fail(P, "a group name that never closes")
                    return False
                name = strndup(P->pat + st, usize(P->i - st))
                _ = rp_next(P)
            elif k == '=' or k == '!':
                # 105.4/RE2: NÃO EXISTE, e é matemática e não esforço — o
                # autómato não guarda o texto que já casou, e é isso que o torna
                # linear. A mensagem diz porquê, para ninguém pensar que é uma
                # falta.
                rp_fail(P, "lookahead does not exist in this engine, and cannot: a linear-time automaton does not keep the text it already matched. That is the price of `(a+)+b` never hanging")
                return False
            else:
                # `(?i)`, `(?m)`, `(?s)` — as marcas, que valem do sítio em
                # diante e por isso se aplicam ao programa todo
                while not rp_eof(P) and not rp_at(P, ')') and not rp_at(P, ':'):
                    f: i32 = rp_next(P)
                    if f == 'i':
                        P->p->icase = 1
                    elif f == 'm':
                        P->p->multiline = 1
                    elif f == 's':
                        P->p->dotall = 1
                    else:
                        rp_fail(P, "an unknown flag: this engine has (?i), (?m) and (?s)")
                        return False
                if rp_at(P, ':'):
                    _ = rp_next(P)
                    cap = False
                else:
                    if not rp_at(P, ')'):
                        rp_fail(P, "a `(?…)` that never closes")
                        return False
                    _ = rp_next(P)
                    return True
        slot: i32 = -1
        if cap:
            P->group += 1
            slot = P->group
            re_name_set(P->p, slot, name)
            s1: i32 = re_emit(P->p, RE_SAVE)
            P->p->inst[s1].c = u32(slot * 2)
        if not rp_alt(P):
            return False
        if not rp_at(P, ')'):
            rp_fail(P, "a group that never closes")
            return False
        _ = rp_next(P)
        if cap:
            s2: i32 = re_emit(P->p, RE_SAVE)
            P->p->inst[s2].c = u32(slot * 2 + 1)
        return True
    if c == '[':
        _ = rp_next(P)
        return rp_class(P)
    if c == '.':
        _ = rp_next(P)
        _ = re_emit(P->p, RE_ANY_NL if P->p->dotall != 0 else RE_ANY)
        return True
    if c == '^':
        _ = rp_next(P)
        _ = re_emit(P->p, RE_BOL)
        return True
    if c == '$':
        _ = rp_next(P)
        _ = re_emit(P->p, RE_EOL)
        return True
    if c == '\\':
        _ = rp_next(P)
        return rp_escape(P)
    if c == ')':
        return True
    if c == '*' or c == '+' or c == '?':
        rp_fail(P, "a repetition with nothing before it")
        return False
    _ = rp_next(P)
    at: i32 = re_emit(P->p, RE_CHAR)
    P->p->inst[at].c = u32(c)
    return True

private def re_name_set(p: *ReProg, slot: i32, name: *char):
    # CRESCE em vez de truncar: um nome que se perdesse em silêncio faria
    # `\g<x>` devolver vazio sem dizer porquê, e o tecto seria um número
    # inventado num sítio onde não é preciso nenhum.
    if slot >= p->nnames:
        nn: i32 = slot + 8
        p->names = (**char)(realloc((*void)(p->names), usize(nn) * sizeof(PsCharPtr)))
        for i in range(p->nnames, nn):
            p->names[i] = None
        p->nnames = nn
    p->names[slot] = name


private def rp_escape(P: *ReParser) -> bool:
    c: i32 = rp_next(P)
    if c < 0:
        rp_fail(P, "a `\\\\` at the end of the pattern")
        return False
    if c == '1' or c == '2' or c == '3' or c == '4' or c == '5' or c == '6' or c == '7' or c == '8' or c == '9':
        # 105.4/RE2: NÃO EXISTE, pela mesma razão que o lookahead não existe.
        rp_fail(P, "a backreference does not exist in this engine, and cannot: a linear-time automaton does not keep the text it already matched. That is the price of `(a+)+b` never hanging")
        return False
    if c == 'b':
        _ = re_emit(P->p, RE_WORDB)
        return True
    if c == 'B':
        _ = re_emit(P->p, RE_NWORDB)
        return True
    if c == 'A':
        _ = re_emit(P->p, RE_BOT)
        return True
    if c == 'z':
        _ = re_emit(P->p, RE_EOT)
        return True
    if c == 'p' or c == 'P':
        u: i32 = re_read_uni(P)
        if u < 0:
            return False
        ku: i32 = re_class_new(P->p)
        re_class_add_uni(&P->p->cls[ku], u)
        if c == 'P':
            P->p->cls[ku].neg = 1
        atu: i32 = re_emit(P->p, RE_CLASS)
        P->p->inst[atu].cls = ku
        return True
    if c == 'd' or c == 'w' or c == 's':
        k: i32 = re_class_new(P->p)
        _ = re_add_named(P->p, k, c)
        at: i32 = re_emit(P->p, RE_CLASS)
        P->p->inst[at].cls = k
        return True
    if c == 'D' or c == 'W' or c == 'S':
        k2: i32 = re_class_new(P->p)
        _ = re_add_named(P->p, k2, c + 32)
        P->p->cls[k2].neg = 1
        at2: i32 = re_emit(P->p, RE_CLASS)
        P->p->inst[at2].cls = k2
        return True
    v: i32 = re_escape_char(P, c)
    if v < 0:
        return False
    at3: i32 = re_emit(P->p, RE_CHAR)
    P->p->inst[at3].c = u32(v)
    return True

# As escapadas que dão UM caractere. `\n`, `\t`, `\xHH`, `\uHHHH` — e qualquer
# outro caractere escapado vale por si próprio, que é o que faz `\.` ser um ponto
# e `\\` ser uma barra.
private def re_escape_char(P: *ReParser, c: i32) -> i32:
    if c == 'n':
        return 10
    if c == 't':
        return 9
    if c == 'r':
        return 13
    if c == 'f':
        return 12
    if c == 'v':
        return 11
    if c == '0':
        return 0
    if c == 'a':
        return 7
    if c == 'x' or c == 'u' or c == 'U':
        want: i32 = 2 if c == 'x' else (4 if c == 'u' else 8)
        v: i32 = 0
        for _ in range(want):
            h: i32 = re_hex(rp_next(P))
            if h < 0:
                rp_fail(P, "a `\\\\x`, `\\\\u` or `\\\\U` with too few hex digits")
                return -1
            v = v * 16 + h
        return v
    return c

# `\p{L}`, `\p{Lu}`, `\p{N}`, `\p{Nd}` — e a forma curta `\pL` de uma letra só,
# que o Perl e o RE2 aceitam.
private def re_read_uni(P: *ReParser) -> i32:
    nm: char[16]
    k: i32 = 0
    if rp_at(P, '{'):
        _ = rp_next(P)
        while not rp_eof(P) and not rp_at(P, '}'):
            ch: i32 = rp_next(P)
            if k < 15:
                nm[k] = char(ch)
                k += 1
        if rp_eof(P):
            rp_fail(P, "a `\\p{...}` that never closes")
            return -1
        _ = rp_next(P)
    else:
        ch2: i32 = rp_next(P)
        if ch2 < 0:
            rp_fail(P, "a `\\p` with no category after it")
            return -1
        nm[0] = char(ch2)
        k = 1
    nm[k] = '\0'
    if strcmp(nm, "L") == 0 or strcmp(nm, "Letter") == 0 or strcmp(nm, "Alpha") == 0:
        return PS_UCAT_L
    if strcmp(nm, "Lu") == 0:
        return PS_UCAT_LU
    if strcmp(nm, "Ll") == 0:
        return PS_UCAT_LL
    if strcmp(nm, "Lt") == 0:
        return PS_UCAT_LT
    if strcmp(nm, "N") == 0 or strcmp(nm, "Number") == 0:
        return PS_UCAT_N
    if strcmp(nm, "Nd") == 0 or strcmp(nm, "Digit") == 0:
        return PS_UCAT_ND
    if strcmp(nm, "Alnum") == 0:
        return PS_UCAT_ALNUM
    if strcmp(nm, "Space") == 0 or strcmp(nm, "White_Space") == 0:
        return PS_UCAT_SPACE
    rp_fail(P, "an unknown Unicode category: this engine knows L, Lu, Ll, Lt, N, Nd, Alnum and Space")
    return -1

private def re_hex(c: i32) -> i32:
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 97 and c <= 102:
        return c - 87
    if c >= 65 and c <= 70:
        return c - 55
    return -1


# ---------- `[...]` ----------

private def rp_class(P: *ReParser) -> bool:
    k: i32 = re_class_new(P->p)
    c: *ReClass = &P->p->cls[k]
    if rp_at(P, '^'):
        _ = rp_next(P)
        c->neg = 1
    first: bool = True
    while True:
        if rp_eof(P):
            rp_fail(P, "a `[` that never closes")
            return False
        if rp_at(P, ']') and not first:
            _ = rp_next(P)
            break
        first = False
        lo: i32 = rp_next(P)
        if lo == '\\':
            e: i32 = rp_next(P)
            if e == 'p' or e == 'P':
                u2: i32 = re_read_uni(P)
                if u2 < 0:
                    return False
                if e == 'P':
                    # `[\P{L}]` dentro de uma classe seria o complemento de UMA
                    # categoria, e o complemento de um predicado não é uma lista
                    # de faixas — não há como o juntar às outras. Recusar é
                    # melhor do que responder mal.
                    rp_fail(P, "`\\P{...}` inside a `[...]` is not supported: negate the whole class with `[^...]`")
                    return False
                re_class_add_uni(&P->p->cls[k], u2)
                c = &P->p->cls[k]
                continue
            if e == 'd' or e == 'w' or e == 's':
                _ = re_add_named(P->p, k, e)
                continue
            if e == 'D' or e == 'W' or e == 'S':
                # o complemento CALCULADO, e não a negação da classe inteira:
                # `[\D0]` é "não-dígito OU zero", não "não (dígito ou zero)"
                _ = re_add_named_neg(P->p, k, e + 32)
                continue
            lo = re_escape_char(P, e)
            if lo < 0:
                return False
        hi: i32 = lo
        if rp_at(P, '-'):
            save: i32 = P->i
            _ = rp_next(P)
            if rp_at(P, ']'):
                # um `-` mesmo antes do `]` é um traço literal
                P->i = save
            else:
                h: i32 = rp_next(P)
                if h == '\\':
                    h = re_escape_char(P, rp_next(P))
                    if h < 0:
                        return False
                if h < lo:
                    rp_fail(P, "a range whose end comes before its start")
                    return False
                hi = h
        re_class_add(c, u32(lo), u32(hi))
        c = &P->p->cls[k]        # `re_class_add` pode ter mexido no array
    at: i32 = re_emit(P->p, RE_CLASS)
    P->p->inst[at].cls = k
    return True


# ---------- compilar ----------

def re_compile(pat: const *char, n: i32) -> *ReProg:
    p: *ReProg = (*ReProg)(calloc(usize(1), sizeof(ReProg)))
    p->ok = 1
    p->ngroup = 0
    P: ReParser = {pat, n, 0, p, 0}
    # a ranhura 0/1 é o casamento INTEIRO, e é por isso que o grupo 1 do
    # programa é o primeiro parêntesis do padrão
    s0: i32 = re_emit(p, RE_SAVE)
    p->inst[s0].c = u32(0)
    if rp_alt(&P):
        if not rp_eof(&P):
            rp_fail(&P, "a `)` with no `(` before it")
    s1: i32 = re_emit(p, RE_SAVE)
    p->inst[s1].c = u32(1)
    _ = re_emit(p, RE_MATCH)
    p->ngroup = P.group
    return p

def re_free(p: *ReProg):
    if p == None:
        return
    for i in range(p->ncls):
        free((*void)(p->cls[i].lo))
        free((*void)(p->cls[i].hi))
        free((*void)(p->cls[i].uni))
    free((*void)(p->cls))
    free((*void)(p->inst))
    if p->names != None:
        for i in range(p->nnames):
            free((*void)(p->names[i]))
        free((*void)(p->names))
    free((*void)(p->err))
    free((*void)(p))


# ---------- a máquina do Pike ----------
#
# Corre TODAS as linhas de execução ao mesmo tempo, um codepoint de cada vez. O
# que a torna linear é uma linha só:
#
#   **num dado passo, cada instrução entra na lista no máximo UMA vez.**
#
# Sem isso, duas linhas que chegam ao mesmo sítio duplicam-se, e a duplicação é
# exponencial — que é exactamente o que faz `(a+)+b` parar um motor com
# retrocesso. Com isso, o trabalho por caractere é no máximo o tamanho do
# programa, e o total é `len(texto) × len(programa)`.

struct ReThread:
    pc: i32
    cap: *i32        # 2 × (ngroup+1) posições, em BYTES do texto

struct ReList:
    t: *ReThread
    n: i32
    seen: *i32       # a última geração em que cada instrução entrou nesta lista
    gen: i32         # a geração desta lista, subida sempre que ela é esvaziada

private def rl_init(l: *ReList, ninst: i32, ncap: i32):
    l->t = (*ReThread)(calloc(usize(ninst), sizeof(ReThread)))
    for i in range(ninst):
        l->t[i].cap = (*i32)(malloc(usize(ncap) * sizeof(i32)))
    l->seen = (*i32)(calloc(usize(ninst), sizeof(i32)))
    l->n = 0
    l->gen = 0

private def rl_free(l: *ReList, ninst: i32):
    for i in range(ninst):
        free((*void)(l->t[i].cap))
    free((*void)(l->t))
    free((*void)(l->seen))


# Onde o texto está, e o que a máquina precisa de saber para responder às
# âncoras sem voltar atrás.
struct ReIn:
    s: const *char
    n: i32
    icase: i32
    multiline: i32

private def re_fold(c: u32) -> u32:
    """A dobra de caixa SIMPLES do Unicode: `(?i)Ä` casa `ä`, e `(?i)Σ` casa `σ`.

    **Simples e não completa**, e é a escolha do RE2 e do `regexp` do Go — não
    uma limitação nossa. A dobra completa mapeia `ß` para `ss`, ou seja UM
    caractere para DOIS, e um autómato que anda um caractere de cada vez não tem
    como casar dois de entrada contra um do padrão sem guardar o que já leu — que
    é a propriedade que ele não tem, e a razão de ele ser linear.
    """
    return u32(ps_cp_fold(i32(c)))

private def re_isword(c: i32) -> bool:
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or c == 95 or (c >= 97 and c <= 122)

private def re_assert_ok(IN: *ReIn, op: i32, at: i32) -> bool:
    if op == RE_BOT:
        return at == 0
    if op == RE_EOT:
        return at == IN->n
    if op == RE_BOL:
        if at == 0:
            return True
        return IN->multiline != 0 and IN->s[at - 1] == '\n'
    if op == RE_EOL:
        if at == IN->n:
            return True
        return IN->multiline != 0 and IN->s[at] == '\n'
    # `\b` e `\B`: a fronteira é entre um caractere de palavra e um que não é
    L: i32 = 0
    before: bool = False
    if at > 0:
        # o byte anterior chega: um caractere de palavra é ASCII neste motor, e
        # a continuação de um UTF-8 nunca é um deles
        before = re_isword(i32(u8(IN->s[at - 1])))
    after: bool = False
    if at < IN->n:
        after = re_isword(re_utf8_at(IN->s, IN->n, at, &L))
    b: bool = before != after
    return b if op == RE_WORDB else not b

# Acrescenta uma linha de execução, seguindo os saltos e as marcas de captura
# até parar numa instrução que CONSOME. É aqui que a dedup por geração mora, e é
# aqui que a garantia se cumpre.
private def re_addthread(l: *ReList, p: *ReProg, IN: *ReIn, pc: i32, cap: *i32, ncap: i32, at: i32):
    # **A garantia mora nestas três linhas.** Uma instrução entra nesta lista no
    # máximo uma vez por geração; sem isso, duas linhas que chegam ao mesmo sítio
    # duplicam-se, e a duplicação é exponencial — que é exactamente o que faz
    # `(a+)+b` parar um motor com retrocesso.
    if l->seen[pc] == l->gen:
        return
    l->seen[pc] = l->gen
    op: i32 = p->inst[pc].op
    if op == RE_JMP:
        re_addthread(l, p, IN, p->inst[pc].x, cap, ncap, at)
        return
    if op == RE_SPLIT:
        re_addthread(l, p, IN, p->inst[pc].x, cap, ncap, at)
        re_addthread(l, p, IN, p->inst[pc].y, cap, ncap, at)
        return
    if op == RE_SAVE:
        k: i32 = i32(p->inst[pc].c)
        if k < ncap:
            old: i32 = cap[k]
            cap[k] = at
            re_addthread(l, p, IN, pc + 1, cap, ncap, at)
            cap[k] = old         # desfaz: a marca é DESTA linha e não das irmãs
        else:
            re_addthread(l, p, IN, pc + 1, cap, ncap, at)
        return
    if op == RE_BOL or op == RE_EOL or op == RE_BOT or op == RE_EOT or op == RE_WORDB or op == RE_NWORDB:
        if re_assert_ok(IN, op, at):
            re_addthread(l, p, IN, pc + 1, cap, ncap, at)
        return
    # consome (ou é o MATCH): entra na lista
    l->t[l->n].pc = pc
    memcpy((*void)(l->t[l->n].cap), (*void)(cap), usize(ncap) * sizeof(i32))
    l->n += 1


# O passo: corre o programa sobre o texto a partir de `from`, e devolve as
# capturas do casamento mais à ESQUERDA e mais LONGO na ordem de preferência do
# autómato (a "leftmost-first" do Perl, que é o que toda a gente espera).
#
# `out_cap` tem 2 × (ngroup+1) posições e fica com -1 onde um grupo não casou.
def re_run(p: *ReProg, s: const *char, slen: i32, from: i32, out_cap: *i32) -> bool:
    ncap: i32 = (p->ngroup + 1) * 2
    IN: ReIn = {s, slen, p->icase, p->multiline}
    cur: ReList
    nxt: ReList
    rl_init(&cur, p->n, ncap)
    rl_init(&nxt, p->n, ncap)
    defer rl_free(&cur, p->n)
    defer rl_free(&nxt, p->n)
    seed: *i32 = (*i32)(malloc(usize(ncap) * sizeof(i32)))
    defer free((*void)(seed))
    matched: *i32 = (*i32)(malloc(usize(ncap) * sizeof(i32)))
    defer free((*void)(matched))
    found: bool = False
    at: i32 = from
    cur.gen = 1
    cur.n = 0
    n: i32 = i32(slen)
    while at <= n:
        # A busca é NÃO ANCORADA: uma linha nova nasce em cada posição, e é
        # isso que faz `re.search` procurar em vez de exigir o princípio. Mas
        # só enquanto nada casou — assim que houve casamento, semear outra vez
        # daria um resultado mais à direita, e o que se quer é o mais à esquerda.
        if not found:
            for k in range(ncap):
                seed[k] = -1
            re_addthread(&cur, p, &IN, 0, seed, ncap, at)
        # Sair aqui com a lista vazia seria terminar a busca na primeira posição
        # que não deixa nenhuma linha viva — e uma busca NÃO ANCORADA tem de
        # continuar até ao fim do texto. Só depois de haver casamento é que uma
        # lista vazia quer dizer "acabou", porque aí semear outra vez daria um
        # resultado mais à direita.
        if cur.n == 0 and found:
            break
        L: i32 = 0
        ch: i32 = re_utf8_at(s, slen, at, &L)
        nxt.n = 0
        nxt.gen += 1
        i: i32 = 0
        while i < cur.n:
            pc: i32 = cur.t[i].pc
            op: i32 = p->inst[pc].op
            if op == RE_MATCH:
                memcpy((*void)(matched), (*void)(cur.t[i].cap), usize(ncap) * sizeof(i32))
                found = True
                # As linhas MENOS preferidas morrem aqui, e não é uma
                # optimização: a ordem em que elas entraram na lista É a ordem
                # de preferência do autómato, portanto o primeiro MATCH é o
                # resultado. Continuar com as outras daria o casamento errado.
                i = cur.n
                continue
            if ch >= 0:
                ok: bool = False
                if op == RE_CHAR:
                    a: u32 = u32(ch)
                    b: u32 = p->inst[pc].c
                    ok = (re_fold(a) == re_fold(b)) if p->icase != 0 else (a == b)
                elif op == RE_ANY:
                    ok = ch != 10
                elif op == RE_ANY_NL:
                    ok = True
                elif op == RE_CLASS:
                    c2: const *ReClass = &p->cls[p->inst[pc].cls]
                    ok = re_class_has(c2, u32(ch))
                    if not ok and p->icase != 0:
                        ok = re_class_has(c2, re_fold(u32(ch)))
                        if not ok and u32(ch) >= u32(97) and u32(ch) <= u32(122):
                            ok = re_class_has(c2, u32(ch) - u32(32))
                if ok:
                    re_addthread(&nxt, p, &IN, pc + 1, cur.t[i].cap, ncap, at + L)
            i += 1
        # as duas listas trocam de papel; a que passa a ser a corrente já tem a
        # geração dela, e a outra vai ser esvaziada na volta seguinte
        tmp: ReList = cur
        cur = nxt
        nxt = tmp
        if ch < 0:
            break
        at += L
    if found:
        memcpy((*void)(out_cap), (*void)(matched), usize(ncap) * sizeof(i32))
    return found


# ---------- a cache de padrões compilados ----------
#
# Um padrão num laço compila UMA vez. A cache é pequena e por CONTEXTO — um
# worker tem o seu heap e o seu laço (18.1), e uma cache partilhada entre threads
# seria um cadeado por chamada a `re.match`.
#
# Vinte e quatro entradas, e a mais velha sai. Não é um número mágico: é mais do
# que qualquer programa tem de padrões distintos num caminho quente, e pouco o
# bastante para a busca linear ser mais rápida do que uma tabela.

private const RE_CACHE: const i32 = 24

struct ReCache:
    pat: **char
    prog: **ReProg
    n: i32
    tick: i32

private def re_cache_get(c: *ReCache, pat: const *char, n: i32) -> *ReProg:
    for i in range(c->n):
        if strlen(c->pat[i]) == usize(n) and memcmp((*void)(c->pat[i]), (*void)(pat), usize(n)) == 0:
            return c->prog[i]
    p: *ReProg = re_compile(pat, n)
    if c->pat == None:
        c->pat = (**char)(calloc(usize(RE_CACHE), sizeof(PsCharPtr)))
        c->prog = (**ReProg)(calloc(usize(RE_CACHE), sizeof(ReProgPtr)))
    if c->n < RE_CACHE:
        c->pat[c->n] = strndup(pat, usize(n))
        c->prog[c->n] = p
        c->n += 1
    else:
        # a mais velha sai, em roda: sem isto um programa que compõe padrões
        # cresceria sem fim, que é o defeito que o `re` do Python teve
        free((*void)(c->pat[c->tick]))
        re_free(c->prog[c->tick])
        c->pat[c->tick] = strndup(pat, usize(n))
        c->prog[c->tick] = p
        c->tick = (c->tick + 1) % RE_CACHE
    return p

def re_cache_free(c: *ReCache):
    if c == None or c->pat == None:
        return
    for i in range(c->n):
        free((*void)(c->pat[i]))
        re_free(c->prog[i])
    free((*void)(c->pat))
    free((*void)(c->prog))
    c->pat = None
    c->prog = None
    c->n = 0


# ---------- a API que o pscript vê ----------
#
# `re.match`, `re.search`, `re.findall`, `re.finditer`, `re.sub`, `re.split`.
# O que sai são valores do heap coletado; o que entra é texto. O programa
# compilado fica na cache, fora do heap, e é isso que faz um `re` num laço não
# alocar nada por volta.

private def re_bad(ctx: *PsCtx, p: *ReProg, pat: *PsStr, file: const *char, line: i32) -> bool:
    if p != None and p->ok != 0:
        return False
    msg: char[512]
    snprintf(msg, usize(512), "re: %s — in the pattern %.*s",
             p->err if p != None and p->err != None else "does not compile",
             int(pat->len), pat->data)
    ps_raise(ctx, msg, PS_CAT_VALUE, file, line)
    return True

# 41.2, e a assinatura NÃO MUDA: os grupos, ou None. O [0] é o casamento inteiro,
# e um grupo que não casou dá string vazia — que é o que já era, portanto nenhum
# programa que existe hoje muda uma linha.
# 152.8: o programa a usar. Já compilado quando veio de um `Pattern`, ou da
# cache quando o padrão foi escrito no sítio. Exactamente um dos dois é None, e é
# quem chama que o garante — não há caminho em que os dois cheguem.
private def re_prog_for(ctx: *PsCtx, pattern: *PsStr, pat: *PsPattern, file: const *char, line: i32) -> *ReProg:
    if pat != None:
        return (*ReProg)(pat->prog)
    p: *ReProg = re_cache_get(re_cache_of(ctx), pattern->data, i32(pattern->len))
    if re_bad(ctx, p, pattern, file, line):
        return None
    return p


# 152.8: compila UMA vez e guarda. O `*ReProg` é malloc'd e não é do coletor,
# portanto sai com um finalizador (136) — a mesma forma do `Mapping` e do
# `Watcher`. E um padrão que não compila levanta AQUI, onde `re.compile` foi
# escrito, em vez de três funções à frente na primeira vez que alguém o usar.
def ps_re_compile(ctx: *PsCtx, pattern: *PsStr, file: const *char, line: i32) -> *PsPattern:
    p: *ReProg = re_compile(pattern->data, i32(pattern->len))
    if p == None or p->ok == 0:
        _ = re_bad(ctx, p, pattern, file, line)
        return None
    pt: *PsPattern = ps_alloc(ctx, sizeof(PsPattern), PS_TY_PATTERN)
    pt->prog = (*void)(p)
    pt->src = pattern
    ps_add_final(ctx, (*PsObj)(pt), ps_pattern_release)
    return pt


def ps_pattern_release(o: *void):
    pt: *PsPattern = (*PsPattern)(o)
    if pt->prog != None:
        re_free((*ReProg)(pt->prog))
        pt->prog = None


def ps_pattern_src(pt: *PsPattern) -> *PsStr:
    return pt->src


def ps_re_match(ctx: *PsCtx, pattern: *PsStr, pat: *PsPattern, text: *PsStr, file: const *char, line: i32) -> *PsList:
    return ps_re_find(ctx, pattern, pat, text, 0, True, file, line)

def ps_re_search(ctx: *PsCtx, pattern: *PsStr, pat: *PsPattern, text: *PsStr, file: const *char, line: i32) -> *PsList:
    return ps_re_find(ctx, pattern, pat, text, 0, False, file, line)

private def ps_re_find(ctx: *PsCtx, pattern: *PsStr, pat: *PsPattern, text: *PsStr, from: i32, anchored: bool,
                       file: const *char, line: i32) -> *PsList:
    p: *ReProg = re_prog_for(ctx, pattern, pat, file, line)
    if p == None:
        return None
    ncap: i32 = (p->ngroup + 1) * 2
    cap: *i32 = (*i32)(malloc(usize(ncap) * sizeof(i32)))
    defer free((*void)(cap))
    if not re_run(p, text->data, i32(text->len), from, cap):
        return None
    # `match` exige o PRINCÍPIO e `search` não: a diferença está aqui e não no
    # motor, porque um autómato não ancorado responde às duas perguntas — e
    # ancorar por dentro obrigaria a compilar o mesmo padrão duas vezes
    if anchored and cap[0] != from:
        return None
    out: *PsList = ps_list_new(ctx, i32(sizeof(PsStrPtr)), True, i64(p->ngroup + 1))
    for g in range(p->ngroup + 1):
        a: i32 = cap[g * 2]
        b: i32 = cap[g * 2 + 1]
        piece: *PsStr = ps_str_new(ctx, "", 0) if a < 0 or b < a else ps_str_new(ctx, text->data + a, usize(b - a))
        pp: *PsStr = piece
        memcpy((*void)(ps_list_push(ctx, out)), (*void)(&pp), sizeof(PsStrPtr))
    return out


# ---------- `findall` e `finditer` ----------
#
# A diferença entre os dois é o que sai, não o trabalho: um dá as strings e o
# outro dá as POSIÇÕES, e quem quer substituir precisa das posições.
#
# **O casamento vazio avança uma posição**, e é a regra que impede um laço
# infinito: `re.findall("a*", "bb")` casa o vazio em cada sítio e tem de acabar.
# Toda a gente faz isto, e uma implementação que não o faça pendura o programa
# no primeiro padrão que possa casar nada.

def ps_re_findall(ctx: *PsCtx, pattern: *PsStr, pat: *PsPattern, text: *PsStr, file: const *char, line: i32) -> *PsList:
    p: *ReProg = re_prog_for(ctx, pattern, pat, file, line)
    if p == None:
        return None
    ncap: i32 = (p->ngroup + 1) * 2
    cap: *i32 = (*i32)(malloc(usize(ncap) * sizeof(i32)))
    defer free((*void)(cap))
    out: *PsList = ps_list_new(ctx, i32(sizeof(PsStrPtr)), True, 0)
    slots: **PsObj[2]
    slots[0] = (**PsObj)(&out)
    slots[1] = (**PsObj)(&text)
    f: PsFrame
    ps_push_frame(ctx, &f, slots, 2)
    defer ps_pop_frame(ctx, &f)
    at: i32 = 0
    n: i32 = i32(text->len)
    while at <= n:
        if not re_run(p, text->data, n, at, cap):
            break
        a: i32 = cap[0]
        b: i32 = cap[1]
        # o grupo 1 quando há grupos, o casamento inteiro quando não há — é o
        # que o `findall` do Python faz, e é o que quem chama espera
        g: i32 = 1 if p->ngroup >= 1 else 0
        ga: i32 = cap[g * 2]
        gb: i32 = cap[g * 2 + 1]
        piece: *PsStr = ps_str_new(ctx, "", 0) if ga < 0 or gb < ga else ps_str_new(ctx, text->data + ga, usize(gb - ga))
        pp: *PsStr = piece
        memcpy((*void)(ps_list_push(ctx, out)), (*void)(&pp), sizeof(PsStrPtr))
        at = b + 1 if b == a else b
    return out

# As posições, quatro números por casamento: início e fim do casamento inteiro,
# e depois cada grupo. Uma lista plana e não uma de listas porque é o que o
# `sub` precisa e é o que não aloca uma lista por casamento.
def ps_re_finditer(ctx: *PsCtx, pattern: *PsStr, pat: *PsPattern, text: *PsStr, file: const *char, line: i32) -> *PsList:
    p: *ReProg = re_prog_for(ctx, pattern, pat, file, line)
    if p == None:
        return None
    ncap: i32 = (p->ngroup + 1) * 2
    cap: *i32 = (*i32)(malloc(usize(ncap) * sizeof(i32)))
    defer free((*void)(cap))
    out: *PsList = ps_list_new(ctx, i32(sizeof(i64)), False, 0)
    slots: **PsObj[2]
    slots[0] = (**PsObj)(&out)
    slots[1] = (**PsObj)(&text)
    f: PsFrame
    ps_push_frame(ctx, &f, slots, 2)
    defer ps_pop_frame(ctx, &f)
    at: i32 = 0
    n: i32 = i32(text->len)
    while at <= n:
        if not re_run(p, text->data, n, at, cap):
            break
        for k in range(ncap):
            v: i64 = i64(cap[k])
            memcpy((*void)(ps_list_push(ctx, out)), (*void)(&v), sizeof(i64))
        at = cap[1] + 1 if cap[1] == cap[0] else cap[1]
    return out


# ---------- `sub` e `split` ----------

# `\1`, `\2`, `\g<nome>` na substituição. **É a única coisa que `\1` faz neste
# motor** — no PADRÃO ele não existe, e é a mesma razão dita ao contrário: no
# padrão exigiria guardar o texto já casado, e aqui o texto já está todo casado.
private def re_expand(ctx: *PsCtx, p: *ReProg, rep: *PsStr, text: *PsStr, cap: *i32, ncap: i32) -> *PsStr:
    out: *PsStr = ps_str_new(ctx, "", 0)
    i: i32 = 0
    n: i32 = i32(rep->len)
    start: i32 = 0
    while i < n:
        if rep->data[i] != '\\' or i + 1 >= n:
            i += 1
            continue
        if i > start:
            out = ps_str_concat(ctx, out, ps_str_new(ctx, rep->data + start, usize(i - start)))
        c: char = rep->data[i + 1]
        g: i32 = -1
        i += 2
        if c >= '0' and c <= '9':
            g = i32(c) - 48
            while i < n and rep->data[i] >= '0' and rep->data[i] <= '9':
                g = g * 10 + (i32(rep->data[i]) - 48)
                i += 1
        elif c == 'g' and i < n and rep->data[i] == '<':
            i += 1
            st: i32 = i
            while i < n and rep->data[i] != '>':
                i += 1
            nm: *char = strndup(rep->data + st, usize(i - st))
            g = re_group_by_name(p, nm)
            free((*void)(nm))
            if i < n:
                i += 1
        elif c == 'n':
            out = ps_str_concat(ctx, out, ps_str_new(ctx, "\n", 1))
        elif c == 't':
            out = ps_str_concat(ctx, out, ps_str_new(ctx, "\t", 1))
        else:
            out = ps_str_concat(ctx, out, ps_str_new(ctx, &c, 1))
        if g >= 0 and g * 2 + 1 < ncap:
            a: i32 = cap[g * 2]
            b: i32 = cap[g * 2 + 1]
            if a >= 0 and b >= a:
                out = ps_str_concat(ctx, out, ps_str_new(ctx, text->data + a, usize(b - a)))
        start = i
    if n > start:
        out = ps_str_concat(ctx, out, ps_str_new(ctx, rep->data + start, usize(n - start)))
    return out

private def re_group_by_name(p: *ReProg, nm: const *char) -> i32:
    if p->names == None:
        return -1
    for i in range(p->nnames):
        if p->names[i] != None and strcmp(p->names[i], nm) == 0:
            return i
    return -1

def ps_re_sub(ctx: *PsCtx, pattern: *PsStr, pat: *PsPattern, rep: *PsStr, text: *PsStr, count: i64,
              file: const *char, line: i32) -> *PsStr:
    p: *ReProg = re_prog_for(ctx, pattern, pat, file, line)
    if p == None:
        return ps_str_new(ctx, "", 0)
    ncap: i32 = (p->ngroup + 1) * 2
    cap: *i32 = (*i32)(malloc(usize(ncap) * sizeof(i32)))
    defer free((*void)(cap))
    out: *PsStr = ps_str_new(ctx, "", 0)
    slots: **PsObj[4]
    slots[0] = (**PsObj)(&out)
    slots[1] = (**PsObj)(&text)
    slots[2] = (**PsObj)(&rep)
    slots[3] = (**PsObj)(&pattern)
    f: PsFrame
    ps_push_frame(ctx, &f, slots, 4)
    defer ps_pop_frame(ctx, &f)
    at: i32 = 0
    n: i32 = i32(text->len)
    done: i64 = 0
    while at <= n:
        if count > 0 and done >= count:
            break
        if not re_run(p, text->data, n, at, cap):
            break
        a: i32 = cap[0]
        b: i32 = cap[1]
        if a > at:
            out = ps_str_concat(ctx, out, ps_str_new(ctx, text->data + at, usize(a - at)))
        out = ps_str_concat(ctx, out, re_expand(ctx, p, rep, text, cap, ncap))
        done += 1
        if b == a:
            # um casamento vazio: copia o caractere e anda, senão o laço não sai
            if a < n:
                L: i32 = 0
                _ = re_utf8_at(text->data, n, a, &L)
                out = ps_str_concat(ctx, out, ps_str_new(ctx, text->data + a, usize(L)))
                at = a + L
            else:
                at = a + 1
        else:
            at = b
    if at < n:
        out = ps_str_concat(ctx, out, ps_str_new(ctx, text->data + at, usize(n - at)))
    return out

def ps_re_split(ctx: *PsCtx, pattern: *PsStr, pat: *PsPattern, text: *PsStr, count: i64,
                file: const *char, line: i32) -> *PsList:
    p: *ReProg = re_prog_for(ctx, pattern, pat, file, line)
    if p == None:
        return None
    ncap: i32 = (p->ngroup + 1) * 2
    cap: *i32 = (*i32)(malloc(usize(ncap) * sizeof(i32)))
    defer free((*void)(cap))
    out: *PsList = ps_list_new(ctx, i32(sizeof(PsStrPtr)), True, 0)
    slots: **PsObj[2]
    slots[0] = (**PsObj)(&out)
    slots[1] = (**PsObj)(&text)
    f: PsFrame
    ps_push_frame(ctx, &f, slots, 2)
    defer ps_pop_frame(ctx, &f)
    at: i32 = 0
    n: i32 = i32(text->len)
    last: i32 = 0
    done: i64 = 0
    while at <= n:
        if count > 0 and done >= count:
            break
        if not re_run(p, text->data, n, at, cap):
            break
        a: i32 = cap[0]
        b: i32 = cap[1]
        if b == a:
            # 79: um separador VAZIO não separa nada. O `re.split` do Python
            # mudou de comportamento na 3.7 por causa disto, e a escolha certa é
            # ignorá-lo em vez de partir o texto entre cada dois caracteres.
            at = a + 1
            continue
        piece: *PsStr = ps_str_new(ctx, text->data + last, usize(a - last))
        pp: *PsStr = piece
        memcpy((*void)(ps_list_push(ctx, out)), (*void)(&pp), sizeof(PsStrPtr))
        # os GRUPOS do separador entram no resultado, como no Python: é o que
        # permite partir guardando por onde se partiu
        for g in range(1, p->ngroup + 1):
            ga: i32 = cap[g * 2]
            gb: i32 = cap[g * 2 + 1]
            gp: *PsStr = ps_str_new(ctx, "", 0) if ga < 0 or gb < ga else ps_str_new(ctx, text->data + ga, usize(gb - ga))
            gq: *PsStr = gp
            memcpy((*void)(ps_list_push(ctx, out)), (*void)(&gq), sizeof(PsStrPtr))
        last = b
        at = b
        done += 1
    tail: *PsStr = ps_str_new(ctx, text->data + last, usize(n - last))
    tq: *PsStr = tail
    memcpy((*void)(ps_list_push(ctx, out)), (*void)(&tq), sizeof(PsStrPtr))
    return out


private def re_cache_of(ctx: *PsCtx) -> *ReCache:
    if ctx->recache == None:
        ctx->recache = calloc(usize(1), sizeof(ReCache))
    return (*ReCache)(ctx->recache)

def ps_re_ctx_free(ctx: *PsCtx):
    """Chamada quando o contexto morre. Os programas compilados são malloc'd —
    o coletor não sabe deles, e é essa a razão de haver esta linha."""
    if ctx->recache != None:
        re_cache_free((*ReCache)(ctx->recache))
        free(ctx->recache)
        ctx->recache = None

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
