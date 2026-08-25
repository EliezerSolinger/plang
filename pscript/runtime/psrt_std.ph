# psrt_std.ph — o que a biblioteca portada oferece (json, re, random, bisect,
# heapq).
import "psrt_types.ph"

def ps_bisect(l: *PsList, v: const *void, kind: i32, right: bool) -> i64
def ps_insort(ctx: *PsCtx, l: *PsList, v: const *void, kind: i32, right: bool, file: const *char, line: i32)
def ps_heappush(ctx: *PsCtx, l: *PsList, v: const *void, kind: i32, file: const *char, line: i32)
def ps_heappop(ctx: *PsCtx, l: *PsList, out: *void, kind: i32, file: const *char, line: i32)
def ps_heapify(l: *PsList, kind: i32)
# 18.2: the sender gives up the bytes. Nothing is copied and nothing is freed —
# what changes is who may use them.
def ps_buffer_transfer(ctx: *PsCtx, b: *PsBuffer)
# a typed WINDOW over the same bytes, with no copy (18.3): what comes back is a
# `List<T>` in every way that reads — len, index, iterate, slice — and refuses
# the ways that would need to own the memory
def ps_buffer_view(ctx: *PsCtx, b: *PsBuffer, esize: i32, file: const *char, line: i32) -> *PsList
# 135.8: a window over a REGION. `cnt < 0` = everything from `off`.
def ps_buffer_view_at(ctx: *PsCtx, b: *PsBuffer, esize: i32, off: i64, cnt: i64, file: const *char, line: i32) -> *PsList
# Parse into `any` (39.2): an object becomes `Dict<str, any>`, an array a
# `List<any>`, and the leaves are str, float, bool and None. There is no schema
# and no type to declare — reading it back is `as`, which checks (55.2), and
# that is the whole contract.
def ps_json_parse(ctx: *PsCtx, text: *PsStr, file: const *char, line: i32) -> *PsObj
# POSIX ERE, from libc: zero dependency, and "libc is the runtime" taken at its
# word. Classic ERE — groups and alternation yes; no lookahead, no `\d`. If a
# real program ever needs more, that conversation reopens with the use in hand.
#
# `match` answers the groups: [0] is the whole match and [1..] are the
# parenthesized ones. No match is None, which is what makes `if not m:` read the
# way it should (40.1).
def ps_re_match(ctx: *PsCtx, pattern: *PsStr, text: *PsStr, file: const *char, line: i32) -> *PsList
# S2b: o motor de Thompson. `search` procura, `match` exige o princípio — a
# diferença está na API e não no autómato, que responde às duas perguntas.
def ps_re_search(ctx: *PsCtx, pattern: *PsStr, text: *PsStr, file: const *char, line: i32) -> *PsList
def ps_re_findall(ctx: *PsCtx, pattern: *PsStr, text: *PsStr, file: const *char, line: i32) -> *PsList
def ps_re_finditer(ctx: *PsCtx, pattern: *PsStr, text: *PsStr, file: const *char, line: i32) -> *PsList
def ps_re_sub(ctx: *PsCtx, pattern: *PsStr, rep: *PsStr, text: *PsStr, count: i64, file: const *char, line: i32) -> *PsStr
def ps_re_split(ctx: *PsCtx, pattern: *PsStr, text: *PsStr, count: i64, file: const *char, line: i32) -> *PsList
def ps_re_ctx_free(ctx: *PsCtx)
# 103: `random`, portado do CPython (MT19937 + a camada de Lib/random.py)
def ps_random_seed(ctx: *PsCtx, n: i64)
def ps_random_random(ctx: *PsCtx) -> f64
def ps_random_getrandbits(ctx: *PsCtx, k: i64, file: const *char, line: i32) -> i64
def ps_random_below(ctx: *PsCtx, n: i64, file: const *char, line: i32) -> i64
def ps_random_randrange(ctx: *PsCtx, start: i64, stop: i64, step: i64, file: const *char, line: i32) -> i64
def ps_random_randint(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64
def ps_random_uniform(ctx: *PsCtx, a: f64, b: f64) -> f64
def ps_random_gauss(ctx: *PsCtx, mu: f64, sigma: f64) -> f64
def ps_random_expovariate(ctx: *PsCtx, lambd: f64, file: const *char, line: i32) -> f64
def ps_random_shuffle(ctx: *PsCtx, l: *PsList, file: const *char, line: i32)
# 108: o estado do gerador morre com o contexto
def ps_random_free(ctx: *PsCtx)

# 155: `codec` — base64 e hex. No runtime pela mesma razão que o `json`: uma
# codificação de fio com especificação congelada e sem política. As duas que
# LEEM devolvem None quando o texto não é aquilo (4.2).
def ps_b64_encode(ctx: *PsCtx, b: *PsBytes, urlsafe: bool, pad: bool) -> *PsStr
def ps_b64_decode(ctx: *PsCtx, s: *PsStr) -> *PsBytes
def ps_hex_encode(ctx: *PsCtx, b: *PsBytes, upper: bool) -> *PsStr
def ps_hex_decode(ctx: *PsCtx, s: *PsStr) -> *PsBytes
