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

# ---------- o diagnóstico como DADO (resposta 6) ----------
# O compilador já fala uma língua só de diagnóstico: `arquivo:linha:coluna:
# gravidade: mensagem [-Wgrupo]`, e há 692 casos que medem esse TEXTO. Ele fica
# como está — é a referência, e mexer nele seria trocar a coisa medida.
#
# O que se acrescenta é um SEGUNDO destino, ligado por `--diag-json <arquivo>`:
# os mesmos diagnósticos, como dado, para quem os consome em vez de os ler. A
# IDE quer sublinhar a coluna certa sem reparsear texto; o `pforge` quer contar e
# agrupar. Nenhum dos dois devia ter de escrever uma expressão regular para uma
# informação que o compilador tem estruturada na mão.
#
# Desligado por padrão, como o registro de leituras: um compilador normal não
# paga por isto.
struct Diag:
    file: const *char
    line: i32
    col: i32
    sev: i32            # 1 aviso, 2 erro
    group: const *char  # "" quando não há grupo -W
    msg: const *char

private def ps_dupstr(s: const *char) -> const *char
private def json_escape(f: *FILE, s: const *char)

g_diags: *Diag = None
g_ndiag: i32 = 0
g_diag_cap: i32 = 0
g_diag_path: const *char = None

def diag_json_enable(path: const *char):
    g_diag_path = path

def diag_record(file: const *char, line: i32, col: i32, sev: i32, group: const *char, msg: const *char):
    if g_diag_path == None:
        return
    if g_ndiag >= g_diag_cap:
        g_diag_cap = 32 if g_diag_cap == 0 else g_diag_cap * 2
        g_diags = (*Diag)(realloc(g_diags, usize(g_diag_cap) * sizeof(Diag)))
    g_diags[g_ndiag].file = ps_dupstr(file)
    g_diags[g_ndiag].line = line
    g_diags[g_ndiag].col = col
    g_diags[g_ndiag].sev = sev
    g_diags[g_ndiag].group = ps_dupstr(group)
    g_diags[g_ndiag].msg = ps_dupstr(msg)
    g_ndiag += 1

private def ps_dupstr(s: const *char) -> const *char:
    if s == None:
        return ""
    n: usize = strlen(s)
    p: *char = (*char)(malloc(n + 1))
    memcpy(p, s, n + 1)
    return p

private def json_escape(f: *FILE, s: const *char):
    i: usize = 0
    while s[i] != '\0':
        c: u8 = u8(s[i])
        if c == u8('"') or c == u8('\\'):
            fprintf(f, "\\%c", int(c))
        elif c == u8('\n'):
            fprintf(f, "\\n")
        elif c == u8('\t'):
            fprintf(f, "\\t")
        elif c < 0x20:
            fprintf(f, "\\u%04x", int(c))
        else:
            fputc(int(c), f)
        i += 1

# Chamado no fim, e TAMBÉM antes de um `exit` por erro: um diagnóstico que mata
# a compilação é justamente o que a IDE mais quer, e perdê-lo por o processo ter
# saído seria o único caso que não pode falhar.
def diag_json_flush():
    if g_diag_path == None:
        return
    f: *FILE = fopen(g_diag_path, "w")
    if f == None:
        g_diag_path = None
        return
    fprintf(f, "[")
    for i in range(g_ndiag):
        if i > 0:
            fprintf(f, ",")
        fprintf(f, "\n {\"file\": \"")
        json_escape(f, g_diags[i].file)
        fprintf(f, "\", \"line\": %d, \"col\": %d, \"severity\": \"%s\", \"group\": \"",
                g_diags[i].line, g_diags[i].col, "error" if g_diags[i].sev == 2 else "warning")
        json_escape(f, g_diags[i].group)
        fprintf(f, "\", \"message\": \"")
        json_escape(f, g_diags[i].msg)
        fprintf(f, "\"}")
    fprintf(f, "\n]\n")
    fclose(f)
    g_diag_path = None      # uma só vez: o `flush` do erro já escreveu tudo

# ---------- errors ----------
# O texto vai primeiro para um buffer, e só depois para o `stderr`: é o que
# permite o MESMO texto ir também para o registro estruturado, sem percorrer a
# lista variádica duas vezes. O tamanho é folgado — a mensagem mais longa deste
# compilador tem algumas centenas de bytes.
const DIAG_BUF: const usize = 8192

def fatal(fmt: const *char, ...):
    buf: char[8192]
    ap: va_list
    va_start(ap, fmt)
    vsnprintf(buf, DIAG_BUF, fmt, ap)
    va_end(ap)
    fprintf(stderr, "plangc: error: %s\n", buf)
    diag_record("", 0, 0, 2, "", buf)
    diag_json_flush()
    exit(1)

def fatal_at(file: const *char, pos: Pos, fmt: const *char, ...):
    buf: char[8192]
    ap: va_list
    va_start(ap, fmt)
    vsnprintf(buf, DIAG_BUF, fmt, ap)
    va_end(ap)
    fprintf(stderr, "%s:%d:%d: error: %s\n", file, pos.line, pos.col, buf)
    diag_record(file, pos.line, pos.col, 2, "", buf)
    diag_json_flush()
    exit(1)

def warn_at(file: const *char, pos: Pos, fmt: const *char, ...):
    buf: char[8192]
    ap: va_list
    va_start(ap, fmt)
    vsnprintf(buf, DIAG_BUF, fmt, ap)
    va_end(ap)
    fprintf(stderr, "%s:%d:%d: warning: %s\n", file, pos.line, pos.col, buf)
    diag_record(file, pos.line, pos.col, 1, "", buf)

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
    buf: char[8192]
    ap: va_list
    va_start(ap, fmt)
    vsnprintf(buf, DIAG_BUF, fmt, ap)
    va_end(ap)
    fprintf(stderr, "%s:%d:%d: %s: %s [-W%s]\n", file, pos.line, pos.col,
            "error" if sev == 2 else "warning", buf, group)
    diag_record(file, pos.line, pos.col, sev, group, buf)
    if sev == 2:
        diag_json_flush()
        exit(1)
    g_warn_count += 1

# ---------- files ----------
# ---------- o registro de leituras (a pergunta 1 do protocolo) ----------
# "o que você leu?" — toda fonte que entrou nesta compilação, para quem monta um
# grafo de build não ter de adivinhar (nem manter a lista à mão em seis lugares).
# Fica DESLIGADO por padrão: um compilador normal não paga por isto.
#
# O funil é este arquivo: todo `.p`, `.ph`, `.psc`, `.c`, `.i` e todo `embed()`
# passa por `read_entire_file`/`_opt`. O que NÃO aparece aqui, e é honesto dizer:
# os headers de sistema por trás de um `include <stdio.h>`, porque quem os
# resolve é o pré-processador externo (`--cpp`) e só ele os enxerga.
g_deps: **char = None
g_ndeps: i32 = 0
g_deps_cap: i32 = 0
g_deps_on: bool = False

def deps_enable():
    g_deps_on = True

# `a/../packages/stl/vec.ph` e `packages/stl/vec.ph` são o MESMO arquivo, e um grafo de
# build que os visse como dois nós recompilaria o mundo por nada. A conta é
# léxica (não pergunta ao disco), como o `normpath` do posixpath: `.` some, `..`
# sobe um componente quando há um para subir, e `..` no começo de um caminho
# relativo fica — porque ali ele significa alguma coisa.
# `a/../b/c.ph` e `b/c.ph` são o MESMO arquivo, e quem os visse como dois
# carregaria o módulo duas vezes — que é um erro de "redefinido" a explicar. É a
# mesma conta que o registro de leituras já fazia; aqui ela ganha nome próprio
# porque o carregador de módulos passou a precisar dela: desde que um `import
# <pkg/x.ph>` é reescrito para relativo, o mesmo header chega por duas grafias.
private def path_norm_into(dst: *char, src: const *char)

def path_norm(a: *Arena, src: const *char) -> const *char:
    n: usize = strlen(src)
    dst: *char = a->alloc(n + 2)
    path_norm_into(dst, src)
    return dst

private def path_norm_into(dst: *char, src: const *char):
    cstart: usize[256]
    clen: usize[256]
    nc: i32 = 0
    isabs: bool = src[0] == '/'
    i: usize = 0
    while src[i] != '\0':
        while src[i] == '/':
            i += 1
        if src[i] == '\0':
            break
        j: usize = i
        while src[j] != '\0' and src[j] != '/':
            j += 1
        l: usize = j - i
        if l == 1 and src[i] == '.':
            pass
        elif l == 2 and src[i] == '.' and src[i + 1] == '.':
            up: bool = False
            if nc > 0:
                pi: usize = cstart[nc - 1]
                if not (clen[nc - 1] == 2 and src[pi] == '.' and src[pi + 1] == '.'):
                    up = True
            if up:
                nc -= 1
            elif not isabs and nc < 256:
                cstart[nc] = i
                clen[nc] = l
                nc += 1
            # num caminho absoluto, `..` na raiz É a raiz: descarta
        elif nc < 256:
            cstart[nc] = i
            clen[nc] = l
            nc += 1
        i = j
    n: usize = 0
    if isabs:
        dst[0] = '/'
        n = 1
    for k in range(nc):
        if k > 0:
            dst[n] = '/'
            n += 1
        memcpy(dst + n, src + cstart[k], clen[k])
        n += clen[k]
    if n == 0:
        dst[0] = '.'
        n = 1
    dst[n] = '\0'

def deps_add(path: const *char):
    if not g_deps_on or path == None:
        return
    norm: *char = malloc(strlen(path) + 2)
    path_norm_into(norm, path)
    for i in range(g_ndeps):
        if strcmp(g_deps[i], norm) == 0:
            free(norm)
            return
    if g_ndeps == g_deps_cap:
        g_deps_cap = 32 if g_deps_cap == 0 else g_deps_cap * 2
        g_deps = realloc(g_deps, usize(g_deps_cap) * sizeof(*g_deps))
        if g_deps == None:
            fatal("out of memory")
    g_deps[g_ndeps] = norm
    g_ndeps += 1

def deps_count() -> i32:
    return g_ndeps

def deps_get(i: i32) -> const *char:
    return g_deps[i]

def read_entire_file(path: const *char, out out_len: usize) -> *char:
    # 142: os DOIS leitores passam pelo embebido, e não só o `_opt`. O driver usa
    # este para as entradas, e um módulo do `stl` é uma entrada como outra
    # qualquer — só que não está em lado nenhum.
    b: *char = read_entire_file_opt(path, out out_len)
    if b == None:
        fatal("could not open '%s'", path)
    return b

# same, but the caller reports the failure: embed() wants a diagnostic that
# points at the call site instead of a bare fatal.
def read_entire_file_opt(path: const *char, out out_len: usize) -> *char

# ---------- 142: o `stl` VEM DENTRO do compilador ----------
#
# Um recém-chegado que escreve um `.p` com um `Vec` batia em duas falésias de
# configuração antes de compilar o que quer que fosse: `--pkg-path` em falta, e
# depois a regra de os dois lados serem nomeados da mesma maneira. Nada disso é
# sobre o programa dele.
#
# O compilador já tinha resolvido isto uma vez, para o prelúdio do pscript, e a
# justificação escrita ao lado dele serve palavra por palavra:
#
#   *"`embed` é o que lhe permite ser um ficheiro de verdade e não custar nada em
#   tempo de execução: os bytes são lidos em tempo de COMPILAÇÃO e viram um
#   vector estático, portanto NÃO HÁ FICHEIRO PARA ENCONTRAR, NÃO HÁ CAMINHO
#   PARA CONFIGURAR, e o prelúdio que um compilador carrega é exactamente o que
#   foi compilado para dentro dele."*
#
# **Os ficheiros continuam a ser os de `packages/stl/`** — uma cópia só, que é o
# que o `embed` garante: o que vai para dentro do binário é lido daquele
# directório em tempo de compilação. O que muda é que já não é preciso
# encontrá-los em tempo de execução.
#
# **E o embebido GANHA** (142.3): a raiz virtual é a PRIMEIRA que se procura, e
# um `stl` instalado noutro sítio é simplesmente ignorado. A razão é a mesma
# frase do prelúdio — um ficheiro que pudesse substituí-lo em silêncio traz de
# volta a classe de erro que o `embed` existe para matar, a de duas cópias e
# ninguém saber qual correu.
# A raiz virtual é o CAMINHO REAL, e essa é a escolha que faz o resto
# desaparecer. Um nome inventado (`__plang_builtin`) obrigaria o espelho do
# `--out-dir`, o `bootstrap/`, o `reseed.sh` e o motor de build a aprenderem-no —
# e o único ganho seria o `#include` do C emitido dizer de onde o texto veio.
#
# Com o caminho real, **nada disso muda**: os includes continuam a ser
# `../packages/stl/x.h`, o seed continua onde estava, e o que muda é só isto —
# quando alguém LÊ `packages/stl/vec.ph`, o texto vem de dentro do compilador em
# vez de vir do disco.
#
# O preço, dito porque é real e porque a 142 já o tinha visto: mexer num
# ficheiro do `stl` só tem efeito depois de o compilador ser reconstruído. É um
# efeito em dois tempos, é o mesmo que o `ps_prelude.psc` já tem, e o portão do
# ponto fixo (`s2 == s3`) mais a regeneração do `bootstrap/` cobrem-no.
const STL_ROOT: const *char = "packages"

private const STL_UTF8: const *char = embed("../packages/stl/utf8.ph")
private const STL_VEC: const *char = embed("../packages/stl/vec.ph")
private const STL_MAP: const *char = embed("../packages/stl/map.ph")
private const STL_SET: const *char = embed("../packages/stl/set.ph")
private const STL_DICT: const *char = embed("../packages/stl/dict.ph")
private const STL_LIST: const *char = embed("../packages/stl/list.ph")
private const STL_QUEUE: const *char = embed("../packages/stl/queue.ph")
private const STL_SLICE: const *char = embed("../packages/stl/slice.ph")
private const STL_STR: const *char = embed("../packages/stl/str.ph")
private const STL_HASH: const *char = embed("../packages/stl/hash.ph")
private const STL_TRAITS: const *char = embed("../packages/stl/traits.ph")
private const STL_CSTR_H: const *char = embed("../packages/stl/cstr.ph")
private const STL_CSTR_P: const *char = embed("../packages/stl/cstr.p")

# O texto de um módulo do `stl`, ou None quando o caminho não é um deles. O
# caminho que chega aqui é o virtual — `__plang_builtin/stl/vec.ph` —, e é ele
# que o `pkg_find` devolve quando resolve pela raiz embebida.
def stl_builtin(path: const *char) -> const *char:
    n: usize = strlen(STL_ROOT)
    if strncmp(path, STL_ROOT, n) != 0 or path[n] != '/':
        return None
    rel: const *char = path + n + 1
    if strncmp(rel, "stl/", 4) != 0:
        return None
    m: const *char = rel + 4
    if strcmp(m, "vec.ph") == 0:
        return STL_VEC
    if strcmp(m, "map.ph") == 0:
        return STL_MAP
    if strcmp(m, "set.ph") == 0:
        return STL_SET
    if strcmp(m, "dict.ph") == 0:
        return STL_DICT
    if strcmp(m, "list.ph") == 0:
        return STL_LIST
    if strcmp(m, "queue.ph") == 0:
        return STL_QUEUE
    if strcmp(m, "slice.ph") == 0:
        return STL_SLICE
    if strcmp(m, "str.ph") == 0:
        return STL_STR
    if strcmp(m, "hash.ph") == 0:
        return STL_HASH
    if strcmp(m, "traits.ph") == 0:
        return STL_TRAITS
    if strcmp(m, "cstr.ph") == 0:
        return STL_CSTR_H
    if strcmp(m, "cstr.p") == 0:
        return STL_CSTR_P
    if strcmp(m, "utf8.ph") == 0:
        return STL_UTF8
    return None

def read_entire_file_opt(path: const *char, out out_len: usize) -> *char:
    # 142: um módulo do `stl` não está em lado nenhum — está aqui dentro. Este é
    # o funil por onde TUDO passa (o `pkg_find`, o colector de entradas do
    # driver, as duas sema), portanto uma linha aqui serve os quinze sítios.
    emb: const *char = stl_builtin(path)
    if emb != None:
        out_len = strlen(emb)
        cp: *char = (*char)(malloc(out_len + 1))
        memcpy(cp, emb, out_len + 1)
        return cp
    f: *FILE = fopen(path, "rb")
    if f == None:
        out_len = 0
        return None
    defer fclose(f)
    deps_add(path)
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
# copies `lex[from..end)` into `buf+len0`, resolving backslash escapes, and
# stops early at an unescaped `q`. Returns the new length; `stop` is where it
# stopped. Pulled out of `str_lit_decode` because there are now two callers with
# DIFFERENT stopping rules — a C literal ends at its quote, a triple-quoted one
# ends where the lexeme does — and one escape table is what keeps them agreeing.
# `\x` is where the two languages part company, and it is not a detail.
#
# **C's rule is GREEDY**: `\x` eats every hex digit that follows, so `"\x7fELF"`
# is `\x7FE` truncated to one byte plus `LF` — three bytes, not four. That is
# why C programmers write `"\x7f" "ELF"`. **Python takes exactly two**, which is
# why `b"\x7fELF"` is the four bytes of an ELF header and reads like it.
#
# P keeps C's rule because P's literals become C's literals and a P string that
# meant something else than the C it turns into would be a trap. pscript takes
# Python's, because that is the language it is.
#
# It was the example in 135.7 that found this: `if src[0:4] == b"\x7fELF"` was
# written down as the reason the literal exists, and under C's rule it compares
# four bytes against three and is False forever.
private def decode_run(buf: *char, len0: usize, lex: const *char, from: usize,
                       end: usize, q: char, py: bool, out stop: usize) -> usize:
    len: usize = len0
    i: usize = from
    while i < end and lex[i] != q:
        if lex[i] != '\\':
            buf[len] = lex[i]
            len += 1
            i += 1
            continue
        i += 1
        if i >= end:
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
            nx: i32 = 0
            while i < end and is_hexc(lex[i]) and not (py and nx == 2):
                v = v * 16 + u32(hexc(lex[i]))
                i += 1
                nx += 1
            buf[len] = char(v & 0xFF)
        elif c >= '0' and c <= '7':
            o: u32 = u32(c - '0')
            k: i32 = 1
            while i < end and k < 3 and lex[i] >= '0' and lex[i] <= '7':
                o = o * 8 + u32(lex[i] - '0')
                i += 1
                k += 1
            buf[len] = char(o & 0xFF)
        else:
            buf[len] = c                 # \\ \" \' \? and anything else
        len += 1
    stop = i
    return len

# P's spelling: `\x` is C's, greedy. This is the entry point every P call site
# uses and it does not change.
def str_lit_decode(a: *Arena, lex: const *char, out out_len: usize) -> *char:
    return str_lit_decode_ex(a, lex, False, out out_len)


# pscript's: `\x` takes exactly two hex digits, like Python's.
def str_lit_decode_py(a: *Arena, lex: const *char, out out_len: usize) -> *char:
    return str_lit_decode_ex(a, lex, True, out out_len)


def str_lit_decode_ex(a: *Arena, lex: const *char, py: bool, out out_len: usize) -> *char:
    n: usize = strlen(lex)
    buf: *char = a->alloc(n + 1)
    len: usize = 0
    i: usize = 0
    stop: usize = 0
    q: char = '"'
    for k in range(n):
        if lex[k] == '"' or lex[k] == '\'':
            q = lex[k]     # whichever quote this literal opened with
            break
    # a TRIPLE-quoted lexeme carries all six quotes, and everything between them
    # is body — an inner `"` included. The concatenation rule below is C's, and
    # applying it here would CUT the body at every inner quote: `"""a "b" c"""`
    # would come out as `a  c`. The stopping quote is a NUL, which a lexeme
    # (itself a C string) cannot contain.
    if n >= 6 and lex[0] == q and lex[1] == q and lex[2] == q:
        len = decode_run(buf, 0, lex, 3, n - 3, char(0), py, out stop)
        buf[len] = '\0'
        out_len = len
        return buf
    while i < n:
        if lex[i] != q:        # opening quote (or whitespace between literals)
            i += 1
            continue
        i += 1
        len = decode_run(buf, len, lex, i, n, q, py, out stop)
        i = stop
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
# `import <pkg/mod.ph>`: onde ele está, procurando em cada raiz na ORDEM em que
# foram dadas — a mesma regra do `-I` do C, e pela mesma razão: é a única que dá
# para explicar numa linha. Devolve None quando não acha; quem chama é que sabe
# dizer o erro com a posição certa.
#
# Mora aqui, e não na sema, porque as DUAS front ends precisam dela e nenhuma das
# duas deve aprender a maquinaria da outra.
def pkg_find(a: *Arena, roots: **char, nroots: i32, rel: const *char) -> const *char:
    # 142.3: a raiz embebida é a PRIMEIRA, e por isso ganha. Um `stl` instalado
    # noutro sítio é ignorado — um ficheiro que pudesse substituir o embebido em
    # silêncio traz de volta a classe de erro que o `embed` existe para matar.
    built: const *char = path_join(a, STL_ROOT, rel)
    if stl_builtin(built) != None:
        return built
    for i in range(nroots):
        cand: const *char = path_join(a, roots[i], rel)
        n: usize = 0
        b: *char = read_entire_file_opt(cand, out n)
        if b != None:
            # o arquivo será lido de novo (com cache) por quem o carrega. Ler
            # duas vezes um header de pacote custa microssegundos e evita
            # declarar `access` (POSIX) mais uma vez à mão
            free(b)
            return cand
    return None

# A frase que diz ONDE se procurou. Sem ela, "não achei" deixa quem lê a
# adivinhar se o pacote não foi resolvido, se o nome está errado, ou se o
# `--pkg-path` não chegou até aqui.
def pkg_where(a: *Arena, roots: **char, nroots: i32) -> const *char:
    if nroots == 0:
        return a->strdup("none was given: `--pkg-path <dir>`, repeatable")
    sb: StrBuf = {0}
    sb.puts("looked in:")
    for j in range(nroots):
        sb.puts(a->printf(" %s", roots[j]))
    r: const *char = a->printf("%.*s", i32(sb.len), sb.data)
    sb.deinit()
    return r

# Os dois caminhos estão no MESMO espaço (ambos relativos ao diretório de
# trabalho, ou ambos absolutos)? Um `import <>` resolvido só vira include
# relativo quando estão: com um de cada lado não há caminho relativo entre eles
# que valha também dentro do espelho do `--out-dir`.
def same_space(a: const *char, b: const *char) -> bool:
    return (a[0] == '/') == (b[0] == '/')

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
