# psrt_val.ph — o que a camada dos valores oferece (erro, aritmética, str,
# list, dict/set, repr, ordenação, tabelas, formatação, any, buffer, pack).
import "psrt_types.ph"

def ps_sum_int(ctx: *PsCtx, l: *PsList, start: i64, file: const *char, line: i32) -> i64
def ps_sum_float(ctx: *PsCtx, l: *PsList, start: f64) -> f64
def ps_any(l: *PsList) -> bool
def ps_all(l: *PsList) -> bool
def ps_round(x: f64) -> i64
def ps_round_n(x: f64, n: i64) -> f64
def ps_list_min_int(ctx: *PsCtx, l: *PsList, want_max: bool, file: const *char, line: i32) -> i64
def ps_list_min_float(ctx: *PsCtx, l: *PsList, want_max: bool, file: const *char, line: i32) -> f64
def ps_list_min_str(ctx: *PsCtx, l: *PsList, want_max: bool, file: const *char, line: i32) -> *PsStr
def ps_buffer_new(ctx: *PsCtx, nbytes: i64, file: const *char, line: i32) -> *PsBuffer
def ps_buffer_close(ctx: *PsCtx, b: *PsBuffer)
def ps_buffer_size(b: *PsBuffer) -> i64
def ps_buffer_get_f64(ctx: *PsCtx, b: *PsBuffer, i: i64, file: const *char, line: i32) -> f64
def ps_buffer_set_f64(ctx: *PsCtx, b: *PsBuffer, i: i64, v: f64, file: const *char, line: i32)
def ps_sys_monotonic() -> f64
def ps_sys_time() -> f64
def ps_closure_new(ctx: *PsCtx, fn: *void, env: *PsObj, sig: const *char) -> *PsClosure
def ps_any_int(ctx: *PsCtx, v: i64) -> *PsObj
def ps_any_float(ctx: *PsCtx, v: f64) -> *PsObj
def ps_any_bool(ctx: *PsCtx, v: bool) -> *PsObj
def ps_any_none(ctx: *PsCtx) -> *PsObj
# `x as T`: the tag has to agree, and disagreeing RAISES with the type category.
# `want` is the PsTyId (or PsAnyKind, for the boxed scalars) the reader expects.
def ps_as_int(ctx: *PsCtx, v: *PsObj, file: const *char, line: i32) -> i64
def ps_as_float(ctx: *PsCtx, v: *PsObj, file: const *char, line: i32) -> f64
def ps_as_bool(ctx: *PsCtx, v: *PsObj, file: const *char, line: i32) -> bool
def ps_as_ref(ctx: *PsCtx, v: *PsObj, want: i32, what: const *char, file: const *char, line: i32) -> *PsObj
# `x is T` — the same question, answered instead of enforced
def ps_is_kind(v: *PsObj, ty: i32, kind: i32) -> bool
def ps_utf8_valid(b: const *char, n: usize) -> bool
def ps_str_from_bytes(ctx: *PsCtx, l: *PsList, file: const *char, line: i32) -> *PsStr
def ps_str_checked(ctx: *PsCtx, p: const *char, n: usize, file: const *char, line: i32) -> *PsStr
def ps_bytes_new(ctx: *PsCtx, p: const *u8, n: usize) -> *PsList
def ps_std_file(ctx: *PsCtx, which: i32) -> *PsFile
# The format is DEFINED: fields in declaration order, little-endian, DENSE —
# the padding a record has in memory simply does not exist in the format, which
# is why nothing has to be zeroed when one is built (59.2). The compiler knows
# the offsets and emits one call per field; these two only move bytes.
# The value crosses BY VALUE, and the width in the format is said out loud —
# so what a field takes in memory (where a bool may well be four bytes) never
# leaks into the format, and neither does this machine's byte order.
# `be` picks the byte order: 0 = little-endian (the default of 59.2), 1 = big.
# The format still says what it is — what changed is that the program gets to
# say it, because bytes that leave the process meet other people's rules.
def ps_pack_int(ctx: *PsCtx, l: *PsList, v: u64, nbytes: i32, be: i32)
def ps_unpack_int(l: *PsList, off: i64, nbytes: i32, be: i32) -> u64
def ps_pack_f64(ctx: *PsCtx, l: *PsList, v: f64, be: i32)
def ps_unpack_f64(l: *PsList, off: i64, be: i32) -> f64
def ps_pack_f32(ctx: *PsCtx, l: *PsList, v: f32, be: i32)
def ps_unpack_f32(l: *PsList, off: i64, be: i32) -> f32
# `unpack<T>(b)` knows the exact size of the format and RAISES when the length
# disagrees (59.3): validation by length, with no header in the format
def ps_unpack_check(ctx: *PsCtx, l: *PsList, want: i64, file: const *char, line: i32)
# `f as def(str) -> bool` (29.4): the descriptor has to agree, and it RAISES
# when it does not — the same shape `as` has for an `any` (55.2). A narrowed
# call is an ordinary indirect call afterwards: nothing is boxed, nothing is
# copied, and the check happened once.
def ps_closure_narrow(ctx: *PsCtx, c: *PsClosure, want: const *char, file: const *char, line: i32) -> *PsClosure
def ps_install_crash_handler(ctx: *PsCtx)
def ps_str_new(ctx: *PsCtx, bytes: const *char, len: usize) -> *PsStr
def ps_str_concat(ctx: *PsCtx, a: *PsStr, b: *PsStr) -> *PsStr
def ps_str_from_int(ctx: *PsCtx, v: i64) -> *PsStr
def ps_str_from_float(ctx: *PsCtx, v: f64) -> *PsStr
def ps_str_quoted(ctx: *PsCtx, s: *PsStr) -> *PsStr
def ps_repr_seq(ctx: *PsCtx, l: *PsList, open: const *char, close: const *char, fn: def(env: *void, ctx: *PsCtx, ep: const *void) -> *PsStr, env: *void) -> *PsStr
def ps_repr_dict(ctx: *PsCtx, d: *PsDict, kfn: def(env: *void, ctx: *PsCtx, ep: const *void) -> *PsStr, vfn: def(env: *void, ctx: *PsCtx, ep: const *void) -> *PsStr, env: *void) -> *PsStr
def ps_str_from_bool(ctx: *PsCtx, v: bool) -> *PsStr
def ps_str_eq(a: *PsStr, b: *PsStr) -> bool
# `<` `<=` `>` `>=` between strings compare CONTENT, byte by byte and then by
# length — the same order `sorted` uses (28.4), so the two never disagree.
# Comparing the pointers instead would order by where the collector happened to
# put them, which is not an order at all.
def ps_str_lt(a: *PsStr, b: *PsStr) -> i32
# `needle in hay` over strings (72.2): substring, by bytes — which is the same
# answer by codepoints, because UTF-8 never has one character's bytes inside
# another's
def ps_str_has(hay: *PsStr, needle: *PsStr) -> bool
# `for ch in s` (72.3): the character at byte offset `off`, and the offset
# moved past it. Walking the bytes ONCE is the whole point — reaching for
# `s[i]` on each round recounts the UTF-8 offset from the start, which turns a
# loop over a string into a quadratic one.
def ps_str_nbytes(s: *PsStr) -> i64
def ps_str_step(ctx: *PsCtx, s: *PsStr, off: *i64) -> *PsStr
def ps_str_len(ctx: *PsCtx, s: *PsStr) -> i64
# the bytes, for the few places a C string is what is wanted (an assert message,
# a path). The pointer belongs to the object and dies with it.
def ps_str_cstr(s: *PsStr) -> const *char
def ps_str_to_int(ctx: *PsCtx, s: *PsStr) -> i64
def ps_str_to_float(ctx: *PsCtx, s: *PsStr) -> f64
# `s[i]` — the i-th CHARACTER as a one-character string (3.4), with Python's
# negative index (31.4). Out of range raises (5.2).
#
# O(i), because the bytes are UTF-8: finding the i-th codepoint means walking.
# 7.1's adaptive width is what makes it O(1), and it is a change of
# REPRESENTATION, not of this signature — so it can land later without moving
# anything.
def ps_str_at(ctx: *PsCtx, s: *PsStr, i: i64, file: const *char, line: i32) -> *PsStr
# `ord` and `chr`, Python's pair: a character is a one-character STRING here
# (3.4), so these are the only door between text and the number a codepoint is
# — and the only way a string reaches an interface that speaks scalars.
def ps_str_ord(ctx: *PsCtx, s: *PsStr, file: const *char, line: i32) -> i64
def ps_str_chr(ctx: *PsCtx, cp: i64, file: const *char, line: i32) -> *PsStr
# `s[a:b]` — a COPY (17.3), so no interior pointer ever exists
def ps_str_slice(ctx: *PsCtx, s: *PsStr, a: i64, b: i64, st: i64, has_a: bool, has_b: bool, file: const *char, line: i32) -> *PsStr
def ps_str_split(ctx: *PsCtx, s: *PsStr, sep: *PsStr) -> *PsList
def ps_str_find(ctx: *PsCtx, s: *PsStr, needle: *PsStr) -> i64
def ps_str_count(s: *PsStr, needle: *PsStr) -> i64
def ps_str_nchars(s: *PsStr) -> i64
def ps_str_rfind(s: *PsStr, needle: *PsStr) -> i64
def ps_str_find_from(ctx: *PsCtx, s: *PsStr, needle: *PsStr, start: i64) -> i64
def ps_str_index_of(ctx: *PsCtx, s: *PsStr, needle: *PsStr, from_right: bool, file: const *char, line: i32) -> i64
def ps_str_is_space_cp(cp: i32) -> bool
def ps_str_split_ws(ctx: *PsCtx, s: *PsStr) -> *PsList
def ps_str_splitlines(ctx: *PsCtx, s: *PsStr) -> *PsList
def ps_str_removeaffix(ctx: *PsCtx, s: *PsStr, p: *PsStr, suffix: bool) -> *PsStr
def ps_str_strip_chars(ctx: *PsCtx, s: *PsStr, set: *PsStr, mode: i32) -> *PsStr
def ps_str_pad(ctx: *PsCtx, s: *PsStr, width: i64, fill: *PsStr, mode: i32, file: const *char, line: i32) -> *PsStr
def ps_str_zfill(ctx: *PsCtx, s: *PsStr, width: i64) -> *PsStr
def ps_str_contains(s: *PsStr, needle: *PsStr) -> bool
def ps_str_lower(ctx: *PsCtx, s: *PsStr) -> *PsStr
def ps_str_all_of(s: *PsStr, which: i32) -> bool
def ps_str_is_case(s: *PsStr, want_upper: bool) -> bool
def ps_str_is_title(s: *PsStr) -> bool
def ps_str_title(ctx: *PsCtx, s: *PsStr) -> *PsStr
def ps_str_capitalize(ctx: *PsCtx, s: *PsStr) -> *PsStr
def ps_str_swapcase(ctx: *PsCtx, s: *PsStr) -> *PsStr
def ps_str_upper(ctx: *PsCtx, s: *PsStr) -> *PsStr
def ps_str_repeat(ctx: *PsCtx, s: *PsStr, n: i64, file: const *char, line: i32) -> *PsStr
def ps_str_replace(ctx: *PsCtx, s: *PsStr, old: *PsStr, new: *PsStr) -> *PsStr
def ps_str_join(ctx: *PsCtx, sep: *PsStr, parts: *PsList) -> *PsStr
def ps_abs_int(ctx: *PsCtx, v: i64, file: const *char, line: i32) -> i64
def ps_abs_float(v: f64) -> f64
def ps_min_int(a: i64, b: i64) -> i64
def ps_max_int(a: i64, b: i64) -> i64
def ps_min_float(a: f64, b: f64) -> f64
def ps_max_float(a: f64, b: f64) -> f64
def ps_str_startswith(s: *PsStr, p: *PsStr) -> bool
def ps_str_endswith(s: *PsStr, p: *PsStr) -> bool
def ps_str_lstrip(ctx: *PsCtx, s: *PsStr) -> *PsStr
def ps_str_rstrip(ctx: *PsCtx, s: *PsStr) -> *PsStr
def ps_str_strip(ctx: *PsCtx, s: *PsStr) -> *PsStr
def ps_list_new(ctx: *PsCtx, esize: i32, eref: bool, cap: i64) -> *PsList
# ... and the two that say "walk INTO the element" (98.5), set right after the
# container is made because only the call site knows the element's shape
def ps_list_etrace(l: *PsList, fn: def(o: *void, to: *PsBlock)) -> *PsList
def ps_dict_vtrace(d: *PsDict, fn: def(o: *void, to: *PsBlock)) -> *PsDict
def ps_list_len(l: *PsList) -> i64
# base address of the elements. Valid until the next SAFE POINT, which is why
# the lowering only ever uses it inside one statement.
def ps_list_base(l: *PsList) -> *char
# bounds check with Python's negative indexing (31.4); raises on a bad index (5.2)
def ps_list_at(ctx: *PsCtx, l: *PsList, i: i64, file: const *char, line: i32) -> i64
# `xs[i]` on a `T[N]` (33.4): the size is known, so the check is one compare —
# and indexing still RAISES out of range (5.2), array or not
def ps_arr_at(ctx: *PsCtx, i: i64, n: i64, file: const *char, line: i32) -> i64
# grows by one and hands back the address of the new last element
def ps_list_push(ctx: *PsCtx, l: *PsList) -> *char
# `xs[a:b]` — a COPY (17.3), with Python's clamping: an out-of-range bound
# trims instead of raising, which is the one place indexing and slicing
# deliberately disagree.
def ps_list_slice(ctx: *PsCtx, l: *PsList, a: i64, b: i64, st: i64, has_a: bool, has_b: bool, file: const *char, line: i32) -> *PsList
def ps_list_index(ctx: *PsCtx, l: *PsList, needle: const *void, kind: i32, file: const *char, line: i32) -> i64
def ps_list_count(l: *PsList, needle: const *void, kind: i32) -> i64
def ps_list_remove(ctx: *PsCtx, l: *PsList, needle: const *void, kind: i32, file: const *char, line: i32)
def ps_list_clear(l: *PsList)
def ps_list_pop_at(ctx: *PsCtx, l: *PsList, i: i64, has_i: bool, file: const *char, line: i32) -> i64
def ps_list_concat(ctx: *PsCtx, a: *PsList, b: *PsList) -> *PsList
def ps_list_repeat(ctx: *PsCtx, l: *PsList, n: i64) -> *PsList
def ps_list_extend(ctx: *PsCtx, l: *PsList, b: *PsList)
def ps_list_insert(ctx: *PsCtx, l: *PsList, i: i64, file: const *char, line: i32) -> *char
def ps_list_remove_at(ctx: *PsCtx, l: *PsList, i: i64, file: const *char, line: i32)
def ps_list_reverse(l: *PsList)
# `sorted(xs)` — a COPY in natural order (28.4). `kind` says how to compare:
# 0 = int, 1 = float, 2 = str by content.
def ps_list_sorted(ctx: *PsCtx, l: *PsList, kind: i32) -> *PsList
# `sorted(xs, key=f)` (28.4). The key of each element is computed ONCE — n calls,
# not n log n — and what is sorted is the pairing. The adapter is written by the
# compiler, which is the only side that knows the element type.
def ps_list_sorted_by(ctx: *PsCtx, l: *PsList, keyfn: def(env: *void, ctx: *PsCtx, ep: const *void) -> f64, env: *void) -> *PsList
def ps_list_sorted_cmp(ctx: *PsCtx, l: *PsList, cmpfn: def(env: *void, ctx: *PsCtx, a: const *void, b: const *void) -> i64, env: *void) -> *PsList
def ps_dict_new(ctx: *PsCtx, ksize: i32, vsize: i32, kkind: i32, kref: bool, vref: bool) -> *PsDict
def ps_dict_len(d: *PsDict) -> i64
# the VALUE slot for `key`, inserting when absent — what `d[k] = v` writes into
def ps_dict_put(ctx: *PsCtx, d: *PsDict, key: const *char) -> *char
# the VALUE slot for `key`, or a raise when it is not there (5.2)
def ps_dict_get(ctx: *PsCtx, d: *PsDict, key: const *char, file: const *char, line: i32) -> *char
def ps_dict_has(d: *PsDict, key: const *char) -> bool
def ps_dict_del(d: *PsDict, key: const *char) -> bool
# iteration: walk 0..cap and skip the slots that are not live
def ps_dict_nent(d: *PsDict) -> i64
def ps_dict_live(d: *PsDict, i: i64) -> bool
def ps_dict_key_at(d: *PsDict, i: i64) -> *char
def ps_dict_val_at(d: *PsDict, i: i64) -> *char
def ps_set_op(ctx: *PsCtx, a: *PsDict, b: *PsDict, op: i32) -> *PsDict
def ps_set_subset(a: *PsDict, b: *PsDict, strict: bool) -> bool
def ps_dict_clear(d: *PsDict)
def ps_dict_copy(ctx: *PsCtx, d: *PsDict) -> *PsDict
def ps_dict_update(ctx: *PsCtx, a: *PsDict, b: *PsDict)
def ps_dict_keys(ctx: *PsCtx, d: *PsDict) -> *PsList
def ps_dict_values(ctx: *PsCtx, d: *PsDict) -> *PsList
def ps_raise(ctx: *PsCtx, msg: const *char, cat: i32, file: const *char, line: i32)
# Cleanup runs even while an exception is PENDING (68.4): `with` takes the
# error out, runs close() in a clean context, and puts it back. If the cleanup
# itself raises, the ORIGINAL error wins — the failure that started it is the
# one worth reporting.
def ps_exc_take(ctx: *PsCtx) -> *PsErr
def ps_exc_put(ctx: *PsCtx, e: *PsErr)
# `raise error(msg, cat)` — the message is already a pscript string
def ps_raise_str(ctx: *PsCtx, msg: *PsStr, cat: i64, file: const *char, line: i32)
# builds an error WITHOUT raising it: `error(...)` is a value until `raise`
def ps_err_new(ctx: *PsCtx, msg: *PsStr, cat: i64, file: const *char, line: i32) -> *PsErr
# re-raises an error that was caught: `raise e`
def ps_reraise(ctx: *PsCtx, e: *PsErr)
def ps_has_exc(ctx: *PsCtx) -> bool
# o relatório de um erro não apanhado, e o status que ele vira (1)
def ps_report_exc(ctx: *PsCtx) -> int
# CLEARS the flag and hands the error over — what `catch` does
def ps_take_exc(ctx: *PsCtx) -> *PsErr
def ps_err_message(e: *PsErr) -> *PsStr
def ps_err_category(e: *PsErr) -> i64
# The SPEC is parsed at compile time and arrives here already broken up, so no
# format string is built at run time and none is interpreted: `align` is one of
# '<', '>' or '^', `prec` is -1 when absent, and `ty` picks the integer base.
# `^` is why these exist at all rather than a printf format — printf cannot
# centre.
def ps_fmt_int(ctx: *PsCtx, v: i64, width: i32, align: char, zero: bool, ty: char) -> *PsStr
def ps_fmt_float(ctx: *PsCtx, v: f64, width: i32, prec: i32, align: char, zero: bool) -> *PsStr
def ps_fmt_str(ctx: *PsCtx, s: *PsStr, width: i32, align: char) -> *PsStr
def ps_print(ctx: *PsCtx, s: *PsStr)
# Overflow RAISES (7.2) — it does not wrap. The wrapping forms of 54.1 (`%+`,
# `%-`, `%*`) are the plain machine ops and need no runtime call.
def ps_add(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64
def ps_sub(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64
def ps_mul(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64
def ps_neg(ctx: *PsCtx, a: i64, file: const *char, line: i32) -> i64
# `/` is Python's: float even between ints (39.1). Division by zero raises.
def ps_div(ctx: *PsCtx, a: f64, b: f64, file: const *char, line: i32) -> f64
def ps_floordiv(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64
def ps_mod(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64
def ps_pow(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64
# A narrow int computes in i64 — its operands always fit, so only the RESULT
# can leave the width — and this is the check that catches it leaving. `what`
# names the type in the message.
def ps_fitw(ctx: *PsCtx, v: i64, lo: i64, hi: i64, what: const *char, file: const *char, line: i32) -> i64
# float -> integer width, truncating toward zero, range checked
def ps_f_to_iw(ctx: *PsCtx, v: f64, lo: i64, hi: i64, what: const *char, file: const *char, line: i32) -> i64
# u64 is the one integer i64 cannot carry, so it gets its own checked ops —
# overflow RAISES here too (53.1): the wrap is `%*`, never an accident
def ps_uadd(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64
def ps_usub(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64
def ps_umul(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64
def ps_udiv(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64
def ps_umod(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64
def ps_upow(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64
# the crossings between the two 64-bit worlds, checked
def ps_u_to_i(ctx: *PsCtx, v: u64, file: const *char, line: i32) -> i64
def ps_i_to_u64(ctx: *PsCtx, v: i64, file: const *char, line: i32) -> u64
def ps_f_to_u64(ctx: *PsCtx, v: f64, file: const *char, line: i32) -> u64
# `%+ %- %*` on a narrow width: mask to the width, sign-extend if signed —
# the DEFINED wrap the operators promise (54.1)
def ps_wrapw(v: i64, bits: i32, uns: bool) -> i64
def ps_str_from_uint(ctx: *PsCtx, v: u64) -> *PsStr
def ps_fmt_uint(ctx: *PsCtx, v: u64, width: i32, align: char, zero: bool, ty: char) -> *PsStr
# The float arithmetic pscript defines differently from C: `**` is a power,
# `//` floors and `%` takes the DIVISOR's sign, exactly as they do on integers
# (39.1) — one rule per operator, not one per type.
def ps_fpow(a: f64, b: f64) -> f64
def ps_ffloordiv(ctx: *PsCtx, a: f64, b: f64, file: const *char, line: i32) -> f64
def ps_fmod(ctx: *PsCtx, a: f64, b: f64, file: const *char, line: i32) -> f64
# 108: era privada do arquivo único; a divisão em camadas a tornou pública
def ps_cmp_float(a: const *void, b: const *void) -> int
# 108: era privada do arquivo único; a divisão em camadas a tornou pública
def ps_cmp_str(a: const *void, b: const *void) -> int
# 108: era privada do arquivo único; a divisão em camadas a tornou pública
def ps_cmp_int(a: const *void, b: const *void) -> int
# 108: era privada do arquivo único; a divisão em camadas a tornou pública
def ps_buffer_gone(ctx: *PsCtx, b: *PsBuffer) -> bool
# 108: era privada do arquivo único; o dict compartilhado (camada do que roda)
# hasheia com ela
def ps_hash_bytes(b: const *char, n: usize) -> u64
# 110: o estado do coletor deste contexto, como dict<str, int>
def ps_gc_stats(ctx: *PsCtx) -> *PsDict

# ---------- o repr como DADO (F5) ----------
def ps_repr_ty(ctx: *PsCtx, p: *void, ty: const *PsTy, depth: i32) -> *PsStr
def ps_repr_val(ctx: *PsCtx, o: *void, ty: const *PsTy, depth: i32) -> *PsStr
def ps_repr_desc(ctx: *PsCtx, o: *void, d: const *PsDesc, depth: i32) -> *PsStr
def ps_json_stringify(ctx: *PsCtx, o: *void, ty: const *PsTy, file: const *char, line: i32) -> *PsStr
def ps_json_stringify_at(ctx: *PsCtx, p: *void, ty: const *PsTy, file: const *char, line: i32) -> *PsStr
