# plang.ph — common utilities for the P compiler (arena, strbuf, utf8, errors)
# Public interface of util.p and utf8.p.

struct Pos:
    line: i32    # 1-based
    col: i32     # 1-based, in codepoints (not bytes)

# ---------- arena ----------
struct ArenaBlock:
    next: *ArenaBlock
    used: usize
    cap: usize
    # the data follows the block header

struct Arena:
    head: *ArenaBlock

    def alloc(self: *Arena, size: usize) -> *void
    def strndup(self: *Arena, s: const *char, n: usize) -> *char
    def strdup(self: *Arena, s: const *char) -> *char
    def printf(self: *Arena, fmt: const *char, ...) -> *char

# ---------- dynamic vector ----------
# usage: arr = vec_grow(arr, len, &cap, sizeof(T))
#       arr[len] = item
#       len += 1
def vec_grow(arr: *void, len: i32, ref cap: i32, elem: usize) -> *void

# ---------- string builder ----------
struct StrBuf:
    data: *char
    len: usize
    cap: usize

    def putc(self: *StrBuf, c: char)
    def puts(self: *StrBuf, s: const *char)
    def printf(self: *StrBuf, fmt: const *char, ...)
    def trim_comma(self: *StrBuf)
    def deinit(self: *StrBuf)

# ---------- utf8 <-> utf32 ----------
# Decodes UTF-8 into UTF-32 codepoints, validating overlong/surrogates.
# out_off[i] = byte offset of codepoint i. Returns 0 or -1 (error,
# with *err_off = offset of the invalid byte).
def utf8_decode(bytes: const *char, nbytes: usize, a: *Arena, out out_cp: *u32, out out_off: *u32, out out_n: usize, err_off: *usize) -> i32
def utf8_encode(cp: u32, out: char[4]) -> i32

# ---------- errors ----------
def fatal(fmt: const *char, ...)
def fatal_at(file: const *char, pos: Pos, fmt: const *char, ...)

# clang-style warning-group diagnostics (util.p). Site defaults:
enum WDefault:
    WD_OFF = 0    # enabled only by an explicit -W<group>
    WD_WALL       # enabled by -Wall
    WD_WARN       # warning by default
    WD_EXTWARN    # EXTENSION diagnostic: warns by default, and -pedantic-errors
                  #   promotes it to an error (clang's ext_* class)
    WD_ERR        # error by default (demotable: -Wno-error=<group>)
def diag_set(name: const *char, state: i32)
def diag_config(werror: bool, wall: bool, pedantic: i32, suppress: bool)
def diag_set_no_error(name: const *char)
def wd_pedantic() -> i32
def cdiag_at(file: const *char, pos: Pos, group: const *char, wdef: i32, fmt: const *char, ...)
def warn_at(file: const *char, pos: Pos, fmt: const *char, ...)

# ---------- characters ----------
def is_hexc(c: char) -> bool
def hexc(c: char) -> i32

# ---------- files ----------
def read_entire_file(path: const *char, out out_len: usize) -> *char
def read_entire_file_opt(path: const *char, out out_len: usize) -> *char

# o registro de leituras (a pergunta 1 do protocolo): ligado sob demanda, guarda
# toda fonte que passou pelas duas funções acima — que é por onde TODA fonte
# passa. Ver o comentário em util.p para o que fica de fora e por quê.
def deps_enable()
def deps_add(path: const *char)
def deps_count() -> i32
def deps_get(i: i32) -> const *char
def plang_host_os() -> const *char

# ---------- paths ----------
def path_dir(a: *Arena, path: const *char) -> const *char
def path_join(a: *Arena, dir: const *char, rel: const *char) -> const *char
def path_relative(a: *Arena, from_dir: const *char, to: const *char) -> const *char
# resposta 6: o diagnóstico como DADO, além do texto (que continua a referência)
def diag_json_enable(path: const *char)
def diag_json_flush()
def diag_record(file: const *char, line: i32, col: i32, sev: i32, group: const *char, msg: const *char)
# `import <pkg/mod.ph>` nas raízes de `--pkg-path`: o caminho, ou None
def pkg_find(a: *Arena, roots: **char, nroots: i32, rel: const *char) -> const *char
def pkg_where(a: *Arena, roots: **char, nroots: i32) -> const *char
def same_space(a: const *char, b: const *char) -> bool

# ---------- C string literals ----------
def str_lit_decode(a: *Arena, lex: const *char, out out_len: usize) -> *char
def c_string_literal(a: *Arena, bytes: const *char, n: usize) -> const *char

# ---------- f-strings: the brace grammar, shared ----------
# `{expr}`, `{expr:spec}`, `{{` and `}}` mean the same thing in both languages.
# What differs is what each front end DOES with the pieces: pscript builds a
# `str` (45.1), P builds a printf format resolved at compile time (65.2). So the
# SPLIT lives here and each parser hands the hole text to its own expression
# parser — the same arrangement as the LexSpec: shared machinery, own language.
struct FStrParts:
    lits: const **char    # n+1 literal chunks; lits[i] comes BEFORE hole i
    lit_lens: *usize      # their lengths (a chunk can hold a NUL from `\0`)
    holes: const **char   # n hole expressions, as SOURCE TEXT
    specs: const **char   # n format specs; "" when the hole had none
    n: i32

# `body` is the DECODED bytes between the quotes (str_lit_decode already ran).
# Diagnostics point at `pos`, the position of the f-string as a whole: a hole is
# lexed on its own, so it has no position of its own to offer.
def fstr_split(a: *Arena, body: const *char, nbody: usize, file: const *char, pos: Pos) -> FStrParts
