# util.p — arena, strbuf, errors, file reading (port of src/util.c)
#
# First module of the compiler written in P. Generates an equivalent util.c
# to the original and links with the rest of the compiler still in C.
# Uses P's fixed-width aliases (i32/u32/usize/... — spec §3.1.1).
include <stdio.h>
include <stdlib.h>
include <string.h>
include <stdarg.h>
include <sys/utsname.h>   # 99.3: `uname`, to know the host without a #ifdef
import "plang.ph"

private def read_open_file(f: *FILE, path: const *char, out out_len: usize) -> *char

# ---------- characters ----------
def is_hexc(c: char) -> bool:
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')

def hexc(c: char) -> i32:
    if c >= '0' and c <= '9':
        return i32(c - '0')
    if c >= 'a' and c <= 'f':
        return i32(c - 'a') + 10
    return i32(c - 'A') + 10

# ---------- arena ----------
const ARENA_MIN_BLOCK = 65536

private def arena_new_block(min: usize) -> *ArenaBlock:
    cap: usize = usize(ARENA_MIN_BLOCK) if min < usize(ARENA_MIN_BLOCK) else min
    b: *ArenaBlock = malloc(sizeof(ArenaBlock) + cap)
    if b == None:
        fatal("out of memory")
    b->next = None
    b->used = 0
    b->cap = cap
    return b

struct Arena:
    def alloc(self: *Arena, size: usize) -> *void:
        size = (size + 15) & ~usize(15)
        if self->head == None or self->head->used + size > self->head->cap:
            b: *ArenaBlock = arena_new_block(size)
            b->next = self->head
            self->head = b
        base: *char = (*char)(self->head + 1)
        p: *void = base + self->head->used
        self->head->used += size
        memset(p, 0, size)
        return p

    def strndup(self: *Arena, s: const *char, n: usize) -> *char:
        p: *char = self->alloc(n + 1)
        memcpy(p, s, n)
        p[n] = '\0'
        return p

    def strdup(self: *Arena, s: const *char) -> *char:
        return self->strndup(s, strlen(s))

    def printf(self: *Arena, fmt: const *char, ...) -> *char:
        ap: va_list
        ap2: va_list
        va_start(ap, fmt)
        va_copy(ap2, ap)
        n: i32 = vsnprintf(None, 0, fmt, ap)
        va_end(ap)
        if n < 0:
            fatal("Arena.printf: invalid format")
        p: *char = self->alloc(usize(n) + 1)
        vsnprintf(p, usize(n) + 1, fmt, ap2)
        va_end(ap2)
        return p

# ---------- dynamic array (replaces the VPUSH macro in the ports) ----------
# usage: arr = vec_grow(arr, len, ref cap, sizeof(T))  # *void converts on its own
#       arr[len] = item
#       len += 1
def vec_grow(arr: *void, len: i32, ref cap: i32, elem: usize) -> *void:
    if len < cap:
        return arr
    new_cap: i32 = 8 if cap == 0 else cap * 2
    arr = realloc(arr, elem * usize(new_cap))
    if arr == None:
        fatal("out of memory")
    cap = new_cap
    return arr

struct StrBuf:
    private def grow(self: *StrBuf, extra: usize):
        if self->len + extra + 1 > self->cap:
            nc: usize = 256 if self->cap == 0 else self->cap * 2
            while nc < self->len + extra + 1:
                nc *= 2
            self->data = realloc(self->data, nc)
            if self->data == None:
                fatal("out of memory")
            self->cap = nc

    def putc(self: *StrBuf, c: char):
        self->grow(1)
        self->data[self->len] = c
        self->len += 1
        self->data[self->len] = '\0'

    def puts(self: *StrBuf, s: const *char):
        n: usize = strlen(s)
        self->grow(n)
        memcpy(self->data + self->len, s, n)
        self->len += n
        self->data[self->len] = '\0'

    def printf(self: *StrBuf, fmt: const *char, ...):
        ap: va_list
        ap2: va_list
        va_start(ap, fmt)
        va_copy(ap2, ap)
        n: i32 = vsnprintf(None, 0, fmt, ap)
        va_end(ap)
        if n < 0:
            fatal("StrBuf.printf: invalid format")
        self->grow(usize(n))
        vsnprintf(self->data + self->len, usize(n) + 1, fmt, ap2)
        va_end(ap2)
        self->len += usize(n)

    # drops the trailing separator: QBE data items are comma-separated and the
    # last one must not carry one (`{ b 1, b 2 }`, never `{ b 1, b 2, }`)
    def trim_comma(self: *StrBuf):
        while self->len > 0 and (self->data[self->len - 1] == ' ' or self->data[self->len - 1] == ','):
            self->len -= 1
            self->data[self->len] = '\0'

    def deinit(self: *StrBuf):
        free(self->data)
        self->data = None
        self->len = 0
        self->cap = 0

# ---------- errors ----------
def fatal(fmt: const *char, ...):
    ap: va_list
    va_start(ap, fmt)
    fprintf(stderr, "plangc: error: ")
    vfprintf(stderr, fmt, ap)
    fprintf(stderr, "\n")
    va_end(ap)
    exit(1)

def fatal_at(file: const *char, pos: Pos, fmt: const *char, ...):
    ap: va_list
    va_start(ap, fmt)
    fprintf(stderr, "%s:%d:%d: error: ", file, pos.line, pos.col)
    vfprintf(stderr, fmt, ap)
    fprintf(stderr, "\n")
    va_end(ap)
    exit(1)

def warn_at(file: const *char, pos: Pos, fmt: const *char, ...):
    ap: va_list
    va_start(ap, fmt)
    fprintf(stderr, "%s:%d:%d: warning: ", file, pos.line, pos.col)
    vfprintf(stderr, fmt, ap)
    fprintf(stderr, "\n")
    va_end(ap)

# ---------- clang-style warning groups ----------
# Each diagnostic call site names its GROUP (-Wincompatible-pointer-types...)
# and a site DEFAULT (WD_*). Explicit driver flags override the default:
#   -W<g> = warn   -Wno-<g> = off   -Werror=<g> = error   -Wno-error=<g> = demote
#   -Werror promotes all active warnings; -w silences warnings; -Wall enables
#   the WD_WALL set; -pedantic/-pedantic-errors drive the wd_pedantic() sites.
struct WGroup:
    name: const *char
    state: i32       # 0 off, 1 warn, 2 error (only meaningful if has_state)
    has_state: bool
    no_error: bool   # -Wno-error=<g>: never promoted to error

g_wgroups: WGroup[96]
g_nwgroups: i32 = 0
g_werror: bool = False
g_wall: bool = False
g_wpedantic: i32 = 0    # 0 off, 1 -pedantic (warn), 2 -pedantic-errors
g_wsuppress: bool = False   # -w
g_warn_count: i32 = 0

private def wgroup_idx(name: const *char) -> i32:
    for i in range(g_nwgroups):
        if strcmp(g_wgroups[i].name, name) == 0:
            return i
    if g_nwgroups >= 96:
        return -1
    g_wgroups[g_nwgroups].name = name
    g_wgroups[g_nwgroups].state = 1
    g_wgroups[g_nwgroups].has_state = False
    g_wgroups[g_nwgroups].no_error = False
    g_nwgroups += 1
    return g_nwgroups - 1

def diag_set(name: const *char, state: i32):
    i: i32 = wgroup_idx(name)
    if i >= 0:
        g_wgroups[i].state = state
        g_wgroups[i].has_state = True

def diag_set_no_error(name: const *char):
    i: i32 = wgroup_idx(name)
    if i >= 0:
        g_wgroups[i].no_error = True

# driver-level switches (parsed in main.p)
def diag_config(werror: bool, wall: bool, pedantic: i32, suppress: bool):
    g_werror = werror
    g_wall = wall
    g_wpedantic = pedantic
    g_wsuppress = suppress

# the default for pedantic-gated sites (GNU/C23 extensions)
def wd_pedantic() -> i32:
    if g_wpedantic == 2:
        return WD_ERR
    if g_wpedantic == 1:
        return WD_WARN
    return WD_OFF

def cdiag_at(file: const *char, pos: Pos, group: const *char, wdef: i32, fmt: const *char, ...):
    sev: i32
    if wdef == WD_ERR:
        sev = 2
    elif wdef == WD_EXTWARN:
        sev = 2 if g_wpedantic == 2 else 1
    elif wdef == WD_WARN:
        sev = 1
    elif wdef == WD_WALL:
        sev = 1 if g_wall else 0
    else:
        sev = 0
    gi: i32 = wgroup_idx(group)
    if gi >= 0 and g_wgroups[gi].has_state:
        sev = g_wgroups[gi].state
    if sev == 1 and g_werror and not (gi >= 0 and g_wgroups[gi].no_error):
        sev = 2
    if sev == 2 and gi >= 0 and g_wgroups[gi].no_error:
        sev = 1
    if sev == 0:
        return
    if sev == 1 and g_wsuppress:
        return
    ap: va_list
    va_start(ap, fmt)
    fprintf(stderr, "%s:%d:%d: %s: ", file, pos.line, pos.col, "error" if sev == 2 else "warning")
    vfprintf(stderr, fmt, ap)
    fprintf(stderr, " [-W%s]\n", group)
    va_end(ap)
    if sev == 2:
        exit(1)
    g_warn_count += 1

# ---------- files ----------
def read_entire_file(path: const *char, out out_len: usize) -> *char:
    f: *FILE = fopen(path, "rb")
    if f == None:
        fatal("could not open '%s'", path)
    defer fclose(f)
    return read_open_file(f, path, out out_len)

# same, but the caller reports the failure: embed() wants a diagnostic that
# points at the call site instead of a bare fatal.
def read_entire_file_opt(path: const *char, out out_len: usize) -> *char:
    f: *FILE = fopen(path, "rb")
    if f == None:
        out_len = 0
        return None
    defer fclose(f)
    return read_open_file(f, path, out out_len)

private def read_open_file(f: *FILE, path: const *char, out out_len: usize) -> *char:
    if fseek(f, 0, SEEK_END) != 0:   # SEEK_END: ingested from <stdio.h> via `include`
        fatal("fseek failed on '%s'", path)
    sz: long = ftell(f)
    if sz < 0:
        fatal("ftell failed on '%s'", path)
    rewind(f)
    buf: *char = malloc(usize(sz) + 1)
    if buf == None:
        fatal("out of memory")
    if fread(buf, 1, usize(sz), f) != usize(sz):
        fatal("failed to read '%s'", path)
    buf[sz] = '\0'
    out_len = usize(sz)
    return buf

# ---------- paths ----------
# directory containing `path`, without the trailing slash ("." when there is
# no slash at all). The result is arena-owned.
def path_dir(a: *Arena, path: const *char) -> const *char:
    slash: const *char = strrchr(path, '/')
    if slash == None:
        return a->strdup(".")
    if slash == path:
        return a->strdup("/")
    return a->strndup(path, usize(slash - path))

# `rel` resolved against `dir`. An absolute `rel` wins outright.
def path_join(a: *Arena, dir: const *char, rel: const *char) -> const *char:
    if rel[0] == '/':
        return a->strdup(rel)
    if strcmp(dir, ".") == 0:
        return a->strdup(rel)
    if dir[strlen(dir) - 1] == '/':
        return a->printf("%s%s", dir, rel)
    return a->printf("%s/%s", dir, rel)

# ---------- C string literals ----------
# decodes the BODY of a narrow C string literal (lexeme with the quotes) into
# the raw bytes it denotes. Adjacent literals ("a" "b") concatenate, as in C.
# Returns arena memory; `out_len` counts the bytes WITHOUT a terminating nul
# (the buffer is nul-terminated anyway, so it also works as a C string when the
# content has no embedded nul).
def str_lit_decode(a: *Arena, lex: const *char, out out_len: usize) -> *char:
    n: usize = strlen(lex)
    buf: *char = a->alloc(n + 1)
    len: usize = 0
    i: usize = 0
    q: char = '"'
    for k in range(n):
        if lex[k] == '"' or lex[k] == '\'':
            q = lex[k]     # whichever quote this literal opened with
            break
    while i < n:
        if lex[i] != q:        # opening quote (or whitespace between literals)
            i += 1
            continue
        i += 1
        while i < n and lex[i] != q:
            if lex[i] != '\\':
                buf[len] = lex[i]
                len += 1
                i += 1
                continue
            i += 1
            if i >= n:
                break
            c: char = lex[i]
            i += 1
            if c == 'n':
                buf[len] = '\n'
            elif c == 't':
                buf[len] = '\t'
            elif c == 'r':
                buf[len] = '\r'
            elif c == 'a':
                buf[len] = '\a'
            elif c == 'b':
                buf[len] = '\b'
            elif c == 'f':
                buf[len] = '\f'
            elif c == 'v':
                buf[len] = '\v'
            elif c == 'e':
                buf[len] = char(27)          # GNU \e
            elif c == 'x':
                v: u32 = 0
                while i < n and is_hexc(lex[i]):
                    v = v * 16 + u32(hexc(lex[i]))
                    i += 1
                buf[len] = char(v & 0xFF)
            elif c >= '0' and c <= '7':
                o: u32 = u32(c - '0')
                k: i32 = 1
                while i < n and k < 3 and lex[i] >= '0' and lex[i] <= '7':
                    o = o * 8 + u32(lex[i] - '0')
                    i += 1
                    k += 1
                buf[len] = char(o & 0xFF)
            else:
                buf[len] = c                 # \\ \" \' \? and anything else
            len += 1
        i += 1                               # closing quote
    buf[len] = '\0'
    out_len = len
    return buf

# renders `n` raw bytes as a complete C string literal, quotes included.
# Non-printables become THREE-digit octal: unlike \xHH, which greedily eats
# every following hex digit, \NNN is self-delimiting, so binary data followed
# by a digit character survives. EVERY `?` is escaped, not just the ones that
# start a trigraph: trigraph replacement is textual and runs before escapes are
# read, so `\??=` still becomes `\#` — only breaking up every pair is safe.
def c_string_literal(a: *Arena, bytes: const *char, n: usize) -> const *char:
    out: *char = a->alloc(n * 4 + 3)
    j: usize = 0
    out[j] = '"'
    j += 1
    for i in range(n):
        c: u8 = u8(bytes[i])
        if c == u8('"') or c == u8('\\'):
            out[j] = '\\'
            out[j + 1] = char(c)
            j += 2
        elif c == u8('?'):
            out[j] = '\\'
            out[j + 1] = '?'
            j += 2
        elif c == u8('\n') or c == u8('\t') or c == u8('\r'):
            out[j] = '\\'
            out[j + 1] = 'n' if c == u8('\n') else ('t' if c == u8('\t') else 'r')
            j += 2
        elif c >= 0x20 and c < 0x7F:
            out[j] = char(c)
            j += 1
        else:
            out[j] = '\\'
            out[j + 1] = char(u8('0') + (c >> 6))
            out[j + 2] = char(u8('0') + ((c >> 3) & 7))
            out[j + 3] = char(u8('0') + (c & 7))
            j += 4
    out[j] = '"'
    out[j + 1] = '\0'
    return out

# `to` expressed relative to the directory `from`, so that a generated file in
# `from` can refer to it. Both are taken as written (both repo-relative, or both
# absolute); when they disagree there is no honest answer and `to` comes back
# unchanged — the caller gets what it gave rather than a wrong path.
#
# Used by the pscript lowering to point at its runtime: an absolute path baked
# into generated C would not survive being moved, and a bare path would not
# survive --out-dir mirroring the source tree.
def path_relative(a: *Arena, from_dir: const *char, to: const *char) -> const *char:
    if (from_dir[0] == '/') != (to[0] == '/'):
        return a->strdup(to)
    # "." is the current directory: no components to climb out of
    if from_dir[0] == '\0' or (from_dir[0] == '.' and from_dir[1] == '\0'):
        return a->strdup(to)
    f: usize = 0
    t: usize = 0
    # walk the common prefix, component by component (never byte by byte: "ab"
    # and "abc" share no directory)
    lastf: usize = 0
    lastt: usize = 0
    while True:
        fe: usize = f
        while from_dir[fe] != '\0' and from_dir[fe] != '/':
            fe += 1
        te: usize = t
        while to[te] != '\0' and to[te] != '/':
            te += 1
        if fe - f != te - t or memcmp(from_dir + f, to + t, fe - f) != 0:
            break
        if from_dir[fe] == '\0' or to[te] == '\0':
            if from_dir[fe] == '\0':
                lastf = fe
                lastt = te if to[te] == '\0' else te + 1
            break
        f = fe + 1
        t = te + 1
        lastf = f
        lastt = t
    if lastf == 0 and lastt == 0:
        lastf = f
        lastt = t
    # one `..` per component still left in `from`
    out: StrBuf = {0}
    i: usize = lastf
    while from_dir[i] != '\0':
        if from_dir[i] == '/':
            out.puts("../")
        i += 1
    if lastf < strlen(from_dir):
        out.puts("../")
    out.puts(to + lastt)
    r: const *char = a->strdup(out.data if out.data != None else "")
    out.deinit()
    return r

# 99.3: the host this compiler is running on, named the way a `const if` reads
# it. `uname` and not a `#ifdef`, for the reason the whole feature exists: this
# file is compiled from generated C that has no preprocessor of its own, and the
# answer has to come from somewhere that does not need one.
#
# `-D __PLANG_OS__="..."` overrides it, which is what a cross build needs.
def plang_host_os() -> const *char:
    u: utsname
    if uname(&u) != 0:
        return "other"
    if strcmp(u.sysname, "Linux") == 0:
        return "linux"
    if strcmp(u.sysname, "Darwin") == 0:
        return "macos"
    if strstr(u.sysname, "BSD") != None:
        return "bsd"
    return "other"

# ---------- f-strings: the brace grammar, shared ----------
def fstr_split(a: *Arena, body: const *char, nbody: usize, file: const *char, pos: Pos) -> FStrParts:
    # An upper bound is enough to size the arrays once: a hole needs a '{', so
    # there can never be more holes than there are open braces.
    nmax: usize = 1
    for i in range(nbody):
        if body[i] == '{':
            nmax += 1
    r: FStrParts = {None, None, None, None, 0}
    r.lits = a->alloc((nmax + 1) * sizeof(*r.lits))
    r.lit_lens = a->alloc((nmax + 1) * sizeof(*r.lit_lens))
    r.holes = a->alloc(nmax * sizeof(*r.holes))
    r.specs = a->alloc(nmax * sizeof(*r.specs))

    lit: StrBuf = {0}
    defer lit.deinit()
    i: usize = 0
    while i < nbody:
        c: char = body[i]
        if c == '{' and i + 1 < nbody and body[i + 1] == '{':
            lit.putc('{')
            i += 2
            continue
        if c == '}' and i + 1 < nbody and body[i + 1] == '}':
            lit.putc('}')
            i += 2
            continue
        if c != '{':
            lit.putc(c)
            i += 1
            continue
        # a hole: everything up to the matching '}', split at the LAST ':' that
        # is not inside brackets
        j: usize = i + 1
        depth: i32 = 0
        colon: usize = 0
        while j < nbody and (body[j] != '}' or depth > 0):
            if body[j] == '[' or body[j] == '(':
                depth += 1
            elif body[j] == ']' or body[j] == ')':
                depth -= 1
            elif body[j] == ':' and depth == 0:
                colon = j
            elif body[j] == '{':
                fatal_at(file, pos, "a nested brace in an f-string spec is not supported")
            j += 1
        if j >= nbody:
            fatal_at(file, pos, "unterminated '{' in an f-string")
        # the chunk that precedes this hole, even when empty: the consumer walks
        # lits and holes in lockstep
        r.lits[r.n] = a->strndup(lit.data, lit.len) if lit.len > 0 else ""
        r.lit_lens[r.n] = lit.len
        lit.len = 0
        if lit.data != None:
            lit.data[0] = '\0'
        r.holes[r.n] = a->strndup(body + i + 1, (colon if colon > 0 else j) - i - 1)
        r.specs[r.n] = a->strndup(body + colon + 1, j - colon - 1) if colon > 0 else ""
        r.n += 1
        i = j + 1
    r.lits[r.n] = a->strndup(lit.data, lit.len) if lit.len > 0 else ""
    r.lit_lens[r.n] = lit.len
    return r
