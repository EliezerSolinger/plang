# main.p — driver: orchestrates the pipeline (port of src/main.c)
#   file -> utf8 -> lexer -> parser -> sema -> backend -> output
include <stdio.h>
include <sys/stat.h>
include <stdlib.h>
include <string.h>
import "backend.ph"
import "lexer.ph"
import "parser.ph"
import "sema.ph"
import "cfront.ph"
import "ps_parser.ph"
import "ps_sema.ph"
import "ps_lower.ph"
import "api.ph"
import "../stl/vec.ph"
import "../stl/hash.ph"
import "vecs.ph"

# `execv` and `access` are POSIX and <unistd.h> is not included here (the same
# reason `popen` is declared by hand above): declared with libc's own types so
# the declaration is compatible wherever the system header is also visible.
def execv(path: const *char, argv: **char) -> int
def access(path: const *char, mode: int) -> int


# popen/pclose are POSIX and <stdio.h> hides them under strict -std=c11, so the
# prototypes are ours (see the same pair in sema.p). NOT `static`: these name the
# libc functions, and a static declaration of one is invalid where the system
# header does declare them (macOS: "static declaration follows non-static").
# Spelled with libc's own types — `FILE`, `int` — so the declaration is
# compatible with the system header's wherever both are visible.
def popen(cmd: const *char, mode: const *char) -> *FILE
def pclose(stream: *FILE) -> int

# runs the configured C preprocessor over a RAW .c file (cpp resolves
# #include/#define/#if); the cpp's stderr flows through to the user. A cpp
# failure is a compile error — invalid preprocessing IS invalid input.
private def preprocess_c(cc: *Cc, path: const *char, out out_len: usize) -> *char:
    cpp: const *char = cc->cpp if cc->cpp != None else "cc"
    cmd: const *char = cc->arena.printf("%s -E -P -x c \"%s\"", cpp, path)
    f: *FILE = popen(cmd, "r")
    if f == None:
        fatal("could not run the C preprocessor '%s' (see --cpp / PLANGC_CPP)", cpp)
    b: StrBuf = {0}
    chunk: char[4097]
    while True:
        n: usize = fread(&chunk[0], 1, 4096, f)
        if n == 0:
            break
        chunk[n] = '\0'
        b.puts(&chunk[0])
    rc: i32 = pclose(f)
    if rc != 0:
        fatal("C preprocessing failed for '%s' ('%s -E'; fix the errors above or see --cpp / PLANGC_CPP)", path, cpp)
    res: *char = cc->arena.strdup(b.data if b.data != None else "")
    out_len = strlen(res)
    b.deinit()
    return res

# one more file for this build, unless it is already there (75.3)
def add_input(v: *Vec<*char>, w: *Vec<*char>, path: const *char):
    for i in range(v->len):
        if strcmp(v->get(i), path) == 0:
            return
    v->push((*char)(path))
    w->push((*char)(path))

def is_pulled(w: *Vec<*char>, path: const *char) -> bool:
    for i in range(w->len):
        if strcmp(w->get(i), path) == 0:
            return True
    return False

# the last component of a path
def path_base(path: const *char) -> const *char:
    slash: const *char = strrchr(path, '/')
    return slash + 1 if slash != None else path

def has_suffix(s: const *char, suf: const *char) -> bool:
    n: usize = strlen(s)
    m: usize = strlen(suf)
    return n >= m and strcmp(s + n - m, suf) == 0

# 0.1.0 — a versão da LINGUAGEM, não do binário: menor = recurso novo, maior =
# quebra. O manifesto de um pacote declara a faixa que ele exige e o `ppack` a
# confere ANTES de compilar (a fase 1 do ciclo). O hash dos próprios bytes vai
# junto porque é ELE que decide sujeira de build: dois compiladores da mesma
# versão com bytes diferentes emitem C diferente.
const PLANG_VERSION = "0.1.0"

private def usage():
    fprintf(stderr, "usage: plangc [options] file.p [file2.ph ...]\n")
    fprintf(stderr, "\n")
    fprintf(stderr, "options:\n")
    fprintf(stderr, "  -o <file>        output (single input only; '-' = stdout)\n")
    fprintf(stderr, "  --out-dir <dir>  mirror each input's path under <dir> (out/stl/x.h,\n")
    fprintf(stderr, "                   out/selfhost/x.c ...): builds never touch the sources\n")
    fprintf(stderr, "  -D NAME[=VAL]    define a compile-time const (int/float/\"str\")\n")
    fprintf(stderr, "  --std=c89        emit strict C89 (C backend; default: c99)\n")
    fprintf(stderr, "  --i64-downgrade  under c89: map 64-bit ints to 32-bit\n")
    fprintf(stderr, "  --i64-longlong   under c89: use the long long extension\n")
    fprintf(stderr, "  --backend <b>    codegen target (default: c)\n")
    fprintf(stderr, "  --cpp <cc>       C compiler used to preprocess `include <h>` headers\n")
    fprintf(stderr, "                   (default: PLANGC_CPP env, else \"cc\")\n")
    fprintf(stderr, "  -W<group>        clang-style warning control: -W<g>, -Wno-<g>,\n")
    fprintf(stderr, "                   -Werror, -Werror=<g>, -Wno-error=<g>, -Wall, -w\n")
    fprintf(stderr, "  --inline-runtime helpers injected by the compiler (e.g. the 'in'\n")
    fprintf(stderr, "                   operator's strcmp) become self-contained inline\n")
    fprintf(stderr, "                   functions - the output has no libc dependency for them\n")
    fprintf(stderr, "  -pedantic        warn on GNU/C23 extensions in C input\n")
    fprintf(stderr, "  -pedantic-errors reject GNU/C23 extensions in C input\n")
    fprintf(stderr, "  --version        the LANGUAGE version and the compiler's own hash\n")
    fprintf(stderr, "  --deps           list every source this compilation read, and stop\n")
    fprintf(stderr, "  --outputs        list what it WOULD emit, without emitting\n")
    fprintf(stderr, "  --api            the canonical public API of each module, and its hash\n")
    fprintf(stderr, "  --tokens         dump tokens and exit\n")
    fprintf(stderr, "  --parse-only     stop after the front end (a syntax check)\n")
    fprintf(stderr, "  run <f.psc> [args] compile (cached) and RUN it (6.3/15.3); as `pscript f.psc`\n")
    fprintf(stderr, "  --ps-runtime <d> where pscript's runtime lives, for .psc input\n")
    fprintf(stderr, "  --no-assert, -O  drop `assert` from a .psc build (46.4), as Python's -O does\n")
    fprintf(stderr, "  -g, --debug      frame in EVERY pscript function (stack trace names them all), and cc -g in `run`\n")
    fprintf(stderr, "                   (default: pscript/runtime)\n")
    fprintf(stderr, "  -h, --help       this help\n")
    exit(2)

# creates every directory in the path of `p` (the file part is skipped)
private def mkdirs_for(p: const *char):
    buf: *char = malloc(strlen(p) + 1)   # (strdup is POSIX — hidden under -std=c11)
    strcpy(buf, p)
    i: usize = 1
    while buf[i] != '\0':
        if buf[i] == '/':
            buf[i] = '\0'
            mkdir(buf, 493)   # 0755; EEXIST: fine
            buf[i] = '/'
        i += 1
    free(buf)

# ---------- `plangc run x.psc [args...]` (6.3/15.3/16.2/50.3) ----------
# Decided in the sixth battery and never built: "compiled, plus a command that
# RUNS it" — the convenience of a script with the compilation still ahead of
# time. What makes it usable is the CACHE (15.3): the C is generated every time
# (tens of milliseconds) and hashed, and `cc` — which is the part that costs
# tenths of a second — runs only when that hash is new.
#
# The binary is keyed by the hash of the C, so two programs that generate the
# same C share it, and a program whose source changed gets a new one. Nothing
# is ever invalidated: an entry that stops being reachable is simply never
# looked up again, which is what a content-addressed cache is.
private def run_cache_dir(a: *Arena) -> const *char:
    e: const *char = getenv("PSCRIPT_CACHE")
    if e != None and e[0] != '\0':
        return e
    h: const *char = getenv("HOME")
    if h != None and h[0] != '\0':
        return a->printf("%s/.cache/pscript", h)
    return "/tmp/pscript-cache"

# The manifest that makes a cached `run` cheap (15.3). Keyed by the DIRECT
# source plus the compiler and the flags, it lists every file the last build
# read with the hash of its bytes. If they all still match, nothing has to be
# generated: the binary named in the first line is exec'd straight away.
#
# It has to be every file and not just the one named on the command line,
# because `import` pulls modules in — a cache that ignored them would run
# yesterday's binary after today's edit, which is the only failure mode of a
# build cache that actually matters.
private def hash_file(path: const *char, ref ok: bool) -> u64:
    n: usize = 0
    b: *char = read_entire_file_opt(path, out n)
    if b == None:
        ok = False
        return 0
    h: u64 = hash_bytes(b, n)
    free(b)
    return h

private def run_manifest_ok(a: *Arena, man: const *char, out binkey: u64) -> bool:
    n: usize = 0
    txt: *char = read_entire_file_opt(man, out n)
    if txt == None:
        return False
    defer free(txt)
    # first line: the binary's key; then one `<hash> <path>` per source
    p2: *char = txt
    key: u64 = strtoull(p2, &p2, 16)
    binkey = key
    while *p2 != '\0':
        while *p2 == '\n' or *p2 == ' ':
            p2 += 1
        if *p2 == '\0':
            break
        want: u64 = strtoull(p2, &p2, 16)
        while *p2 == ' ':
            p2 += 1
        start: *char = p2
        while *p2 != '\n' and *p2 != '\0':
            p2 += 1
        path: const *char = a->printf("%.*s", i32(p2 - start), start)
        ok: bool = True
        got: u64 = hash_file(path, ref ok)
        if not ok or got != want:
            return False
    return True

private def run_manifest_write(a: *Arena, man: const *char, binkey: u64, inputs: *Vec<*char>):
    mkdirs_for(man)
    f: *FILE = fopen(man, "wb")
    if f == None:
        return          # a cache that cannot be written is not an error
    fprintf(f, "%016llx\n", binkey)
    for i in range(inputs->len):
        ok: bool = True
        h: u64 = hash_file(inputs->get(usize(i)), ref ok)
        if ok:
            fprintf(f, "%016llx %s\n", h, inputs->get(usize(i)))
    fclose(f)

private def run_exec(binp: const *char, args: **char, nargs: i32) -> int:
    av: **char = malloc(usize(nargs + 2) * sizeof(*av))
    av[0] = (*char)(binp)
    for i in range(nargs):
        av[i + 1] = args[i]
    av[nargs + 1] = None
    execv(binp, av)
    fatal("could not run '%s'", binp)
    return 1

private def run_program(cc: *Cc, cfiles: *Vec<*char>, h: u64, cachedir: const *char, args: **char, nargs: i32, std_version: i32, debug: bool) -> int:
    binp: const *char = cc->arena.printf("%s/bin/%016llx", cachedir, h)
    mkdirs_for(binp)
    if access(binp, 0) != 0:
        # 16.3: the system's `cc` links it, as it does everywhere else here. The
        # POSIX defines are the ones the runtime needs — glibc hides socket and
        # getaddrinfo under a strict `-std=`.
        cmd: StrBuf = {0}
        defer cmd.deinit()
        ccname: const *char = getenv("CC")
        cmd.puts(ccname if ccname != None and ccname[0] != '\0' else "cc")
        cmd.puts(" -std=c89" if std_version == 89 else " -std=c11")
        # 100.1: the mode reaches the C compiler too — debug info and no
        # optimisation when it is asked for, optimisation when it is not
        cmd.puts(" -g -O0 -w" if debug else " -O2 -w")
        cmd.puts(" -D_POSIX_C_SOURCE=200112L -D_DEFAULT_SOURCE")
        for i in range(cfiles->len):
            cmd.puts(" \"")
            cmd.puts(cfiles->get(usize(i)))
            cmd.puts("\"")
        cmd.puts(" -o \"")
        cmd.puts(binp)
        cmd.puts("\" -lm -pthread")
        rc: int = system(cmd.data)
        if rc != 0:
            fatal("the C compiler failed while building '%s' (see the errors above)", binp)
    # exec, so the program's exit status IS this process's and no shell has to
    # be trusted with the arguments
    return run_exec(binp, args, nargs)

private def derive_output(a: *Arena, input: const *char, be: const *Backend) -> const *char:
    n: usize = strlen(input)
    if n > 3 and input + n - 3 == ".ph":
        if be->hdr_ext == None:
            fatal("backend '%s' does not generate headers (.ph)", be->name)
        return a->printf("%.*s.%s", i32(n - 3), input, be->hdr_ext)
    if n > 2 and input + n - 2 == ".p":
        return a->printf("%.*s.%s", i32(n - 2), input, be->out_ext)
    if n > 2 and input + n - 2 == ".c":
        return a->printf("%.*s.%s", i32(n - 2), input, be->out_ext)
    if n > 2 and input + n - 2 == ".i":
        return a->printf("%.*s.%s", i32(n - 2), input, be->out_ext)
    if n > 4 and input + n - 4 == ".psc":
        return a->printf("%.*s.%s", i32(n - 4), input, be->out_ext)
    fatal("'%s': unknown extension (expected .p, .ph, .psc, .c or .i)", input)
    return None

# onde a saída de um input vai parar, com os argumentos desta invocação. Extraída
# porque agora tem DOIS leitores: a emissão, que escreve ali, e a pergunta 3 do
# protocolo ("o que você vai emitir?"), que precisa da resposta sem compilar.
# A pergunta 1, do lado do P: os `import` de um módulo são seguidos pela SEMA, e
# a consulta não roda sema — então o caminhamento é aqui, no front end. É o que
# mantém a resposta barata (o front end sozinho custa 0,12 s no maior arquivo do
# compilador, contra os segundos de um `cc`), e `cc_load_module` guarda o que já
# leu, então reentrar num módulo já visto não relê nada.
private def deps_walk(cc: *Cc, path: const *char):
    m: *Module = cc_load_module(cc, path)   # lê o arquivo; o funil de util.p anota
    dir: const *char = path_dir(&cc->arena, path)
    for i in range(m->ndecls):
        d: *Decl = m->decls[i]
        if d->kind != DL_IMPORT or d->is_include or d->import_path == None:
            continue
        if not has_suffix(d->import_path, ".ph"):
            continue
        # `<pkg/mod.ph>` vem de uma raiz de pacote; `"x.ph"` vem do lado de quem
        # importa. As duas não se misturam — ver a nota do `pkgroots`.
        ip: const *char = pkg_resolve(cc, path, d) if d->import_system else path_join(&cc->arena, dir, d->import_path)
        seen: bool = False
        for j in range(deps_count()):
            if strcmp(deps_get(j), ip) == 0:
                seen = True
                break
        if not seen:
            deps_walk(cc, ip)

# 1.5(d): os módulos P que um programa em pscript puxa, no FECHAMENTO inteiro.
#
# `import "x.ph"` dentro de um módulo importado tem o mesmo peso do que está no
# arquivo de cima, e a resolução é relativa ao arquivo QUE O ESCREVEU — por isso
# a recursão carrega o caminho de cada módulo em vez de reusar o de cima. A sema
# do pscript resolve o mesmo grafo de imports (`ps_sema.p`), mas ela não roda
# quando a pergunta é `--outputs`, e a resposta 3 tem de valer sem compilar.
private def psc_pmods(cc: *Cc, path: const *char, m: *PsModule, inputs: *Vec<*char>,
                      pulled: *Vec<*char>, seen: *Vec<*char>):
    for i in range(seen->len):
        if strcmp(seen->get(i), path) == 0:
            return
    seen->push((*char)(path))
    dir: const *char = path_dir(&cc->arena, path)
    for j in range(m->ndecls):
        d: *PsDecl = m->decls[j]
        if d->kind == PD_INCLUDE and d->is_pmod:
            # `<pkg/mod.ph>` vem de uma raiz de pacote; `"x.ph"` vem do lado de
            # quem escreveu o import
            hp: const *char = ""
            if d->import_system:
                got: const *char = pkg_find(&cc->arena, cc->pkgroots, cc->npkgroots, d->path)
                if got == None:
                    fatal_at(path, d->pos, "import <%s>: not found in any package root (%s)",
                             d->path, pkg_where(&cc->arena, cc->pkgroots, cc->npkgroots))
                hp = got
            else:
                hp = path_join(&cc->arena, dir, d->path)
            add_input(inputs, pulled, hp)
            # o `.p` irmão do header, quando existe: o `.ph` sozinho é uma
            # declaração (o stl é assim), e nesse caso não há o que compilar
            sp: const *char = cc->arena.printf("%.*s", i32(strlen(hp) - 1), hp)
            slen: usize = 0
            sbytes: *char = read_entire_file_opt(sp, out slen)
            if sbytes != None:
                free(sbytes)
                add_input(inputs, pulled, sp)
            continue
        if d->kind != PD_IMPORT and d->kind != PD_FROM_IMPORT:
            continue
        if d->path == None:
            continue
        sub: const *char = path_join(&cc->arena, dir, cc->arena.printf("%s.psc", d->path))
        n2: usize = 0
        b2: *char = read_entire_file_opt(sub, out n2)
        if b2 == None:
            # `sys` e companhia não são arquivos (48.3), e um módulo que não
            # existe é erro da SEMA, com posição e mensagem — não daqui
            continue
        tl2: TokenList = ps_lex(sub, b2, n2, &cc->arena)
        sm: *PsModule = ps_parse(&cc->arena, sub, tl2)
        free(b2)
        psc_pmods(cc, sub, sm, inputs, pulled, seen)

private def dest_for(cc: *Cc, out_path: const *char, out_dir: const *char, path: const *char, be: const *Backend, pulled: *Vec<*char>) -> const *char:
    dest: const *char = out_path if out_path != None else derive_output(&cc->arena, path, be)
    if out_path != None and is_pulled(pulled, path):
        # `-o` nomeia UM arquivo, e este não foi pedido pelo nome: sai ao lado do
        # que foi, com o nome que o próprio fonte lhe dá
        dest = cc->arena.printf("%s/%s", path_dir(&cc->arena, out_path), path_base(derive_output(&cc->arena, path, be)))
    if out_dir != None:
        # a árvore de saída ESPELHA a de fontes sob --out-dir, para os includes
        # relativos do C emitido ("../stl/x.h") resolverem lá dentro
        dest = cc->arena.printf("%s/%s", out_dir, dest)
    return dest

private def dump_tokens(path: const *char, cc: *Cc):
    len: usize = 0
    bytes: *char = read_entire_file(path, out len)
    defer free(bytes)
    tl: TokenList = lex(path, bytes, len, &cc->arena)
    for i in range(tl.n):
        t: *Token = &tl.toks[i]
        printf("%4d:%-3d %-16s %s\n", t->pos.line, t->pos.col, tok_kind_name(t->kind), t->text if t->text != None else "")

# The QBE backend needs the LAYOUT of imported structs/unions/enums (for
# field offsets and enum values) — the C backend doesn't, since it uses the
# included headers. Structs/unions/enums don't emit code in QBE, so merging
# them into the top module is safe (it only populates the layout tables).
# Doing this in the C backend would duplicate typedefs.
private def qbe_merge_types(cc: *Cc, m: *Module):
    extra = 0
    for i in range(cc->nmods):
        md: *Module = cc->mods[i]
        if md == m:
            continue
        for j in range(md->ndecls):
            dd: *Decl = md->decls[j]
            dk: DeclKind = dd->kind
            if dk in {DL_STRUCT, DL_UNION, DL_ENUM}:
                extra += 1
            elif dk == DL_FUNC and (dd->func->body == None or ((dd->func->is_inline or dd->func->is_static) and has_suffix(md->path, ".ph"))):
                # prototype (registers signature) OR header-only free function
                # (static/inline with body, §8.5): essa é emitida por TU.
                #
                # 108: e só se ela vier de um `.ph`. Uma `static def` num `.p` é
                # privada DAQUELE TU: copiar o corpo dela para outro módulo
                # levava junto uma leitura de global que não foi copiada, e o
                # emissor morria com "unknown struct type field" numa linha que
                # nem era a certa. Apareceu ao dividir o runtime em camadas —
                # com um arquivo só, nunca havia um segundo módulo para onde
                # copiar.
                extra += 1
            elif dk == DL_VAR and dd->init != None and (dd->is_const or (dd->type != None and dd->type->is_const)) and has_suffix(md->path, ".ph"):
                # 108: só de header, pela mesma razão das `static def` acima — o
                # inicializador de uma const num `.p` pode nomear coisas
                # privadas daquele TU (um descritor cujo campo é um ponteiro
                # para função `static`), e aí o outro módulo não consegue dobrá-lo
                extra += 1
    if extra == 0:
        return
    total: i32 = extra + m->ndecls
    nd: **Decl = cc->arena.alloc(sizeof(*m->decls) * usize(total))
    p = 0
    for i in range(cc->nmods):
        md2: *Module = cc->mods[i]
        if md2 == m:
            continue
        for j2 in range(md2->ndecls):
            d: *Decl = md2->decls[j2]
            if d->kind == DL_STRUCT or d->kind == DL_UNION:
                # copy for layout (offsets) + method signatures: copies each
                # method with body=None (registers ret/params for coercion in
                # calls; emit_func skips body None — materialized via
                # `implement` on the owning object, without duplicating code)
                c: *Decl = cc->arena.alloc(sizeof(Decl))
                *c = *d
                if d->nmethods > 0:
                    mc: **Func = cc->arena.alloc(sizeof(*d->methods) * usize(d->nmethods))
                    for mk in range(d->nmethods):
                        fc: *Func = cc->arena.alloc(sizeof(Func))
                        *fc = *d->methods[mk]
                        # common methods are materialized via `implement` on
                        # the owning object (body=None here, signature only);
                        # static/inline methods are header-only (§8.5) — keeps
                        # the body to emit per-TU, as the C backend does in .h
                        if not (fc->is_inline or fc->is_static):
                            fc->body = None
                        mc[mk] = fc
                    c->methods = mc
                nd[p] = c
                p += 1
            elif d->kind == DL_ENUM:
                nd[p] = d
                p += 1
            elif d->kind == DL_FUNC and (d->func->body == None or ((d->func->is_inline or d->func->is_static) and has_suffix(md2->path, ".ph"))):
                # prototype (emit_func skips body==None) OR header-only free
                # function (static/inline): emitted per-TU, not exported
                # (local symbol, no link collision between TUs). A regra do
                # `.ph` é a da 108, acima.
                nd[p] = d
                p += 1
            elif d->kind == DL_VAR and d->init != None and (d->is_const or (d->type != None and d->type->is_const)) and has_suffix(md2->path, ".ph"):
                # a .ph const: TU-local data (the same rule the C backend
                # applies with `static const` in the .h) — no link collision.
                # Só de header (108): ver a nota na contagem.
                cv: *Decl = cc->arena.alloc(sizeof(Decl))
                *cv = *d
                cv->is_static = True
                nd[p] = cv
                p += 1
    for j3 in range(m->ndecls):
        nd[p] = m->decls[j3]
        p += 1
    m->decls = nd
    m->ndecls = total

def main(argc: int, argv: **char) -> int:
    out_path: const *char = None
    out_dir: const *char = None   # --out-dir: mirrors each input's path here
    backend_name: const *char = None
    tokens_only: bool = False
    parse_only: bool = False        # stop after the front end (a syntax check)
    # As perguntas do protocolo (o compilador RESPONDE; quem decide é o build).
    # As três rodam o front end e param antes da sema e da emissão: perguntar
    # custa 0,12 s no maior arquivo do compilador, contra os segundos de um `cc`.
    show_version: bool = False      # --version: a versão da linguagem + o hash dos bytes
    deps_mode: bool = False         # --deps: toda fonte que esta compilação leu
    outputs_mode: bool = False      # --outputs: o que ela emitiria, sem emitir
    api_mode: bool = False          # --api: a lista canónica da API + o hash dela
    # where the pscript runtime lives (16.4: it is P source compiled with the
    # program). The emitted import is made relative to the .psc, so this is
    # written the way the sources are laid out, not baked in absolute.
    ps_runtime: const *char = "pscript/runtime"
    std_version = 99      # target of the C backend (--std=c89 -> 89)
    pedantic_lvl = 0      # -pedantic = 1 (warn), -pedantic-errors = 2 (error)
    inline_runtime: bool = False   # --inline-runtime: no libc in injected helpers
    strip_asserts: bool = False    # --no-assert / -O: drop `assert` (46.4)
    full_trace: bool = False       # --trace: a frame for EVERY pscript function,
                                   #   so a stack trace can name all of them (34.2)
    werror: bool = False
    wall: bool = False
    wsuppress: bool = False
    i64_mode = 0          # under c89: 0=error, 1=downgrade 64->32, 2=long long
    # C compiler used to preprocess `include <h>`: --cpp > PLANGC_CPP env > "cc"
    cpp_cmd: const *char = getenv("PLANGC_CPP")
    if cpp_cmd == None:
        cpp_cmd = "cc"
    inputs: Vec<*char>
    inputs.init()
    pkg_roots: Vec<*char>       # --pkg-path, na ordem em que foram dadas
    pkg_roots.init()
    pulled: Vec<*char>      # inputs an `import "x.ph"` brought in (75.3)
    pulled.init()
    defines: Vec<*char>   # -D NAME=VALUE: comptime consts injected from outside
    defines.init()
    # `plangc run x.psc [args...]` (6.3): compile and run, with the cache of
    # 15.3 in between. Everything AFTER the file is the PROGRAM's, the way
    # `python -O x.py args` reads — so a flag for the compiler goes before it.
    run_mode: bool = False
    run_args: **char = None
    run_nargs: i32 = 0
    first: i32 = 1
    if argc > 1 and argv[1] == "run":
        run_mode = True
        first = 2
    # 50.3: `pscript` is the same binary under another name, and under that name
    # running is what it does — `pscript x.psc args` with no subcommand, the way
    # `python x.py args` reads. The compiler is still there: `plangc x.psc`
    # emits C and links nothing, exactly as before.
    elif has_suffix(argv[0], "pscript") or has_suffix(argv[0], "pscript.exe"):
        run_mode = True

    for i in range(first, argc):
        if run_mode and run_nargs == 0 and inputs.len == 1 and i < argc:
            # the file is in; from here on the arguments belong to the program
            run_args = &argv[i]
            run_nargs = argc - i
            break
        if strncmp(argv[i], "--std=", 6) == 0:
            std: const *char = argv[i] + 6
            if std in {"c89", "c90"}:
                std_version = 89
            elif std == "c99":
                std_version = 99
            else:
                fatal("unknown --std '%s' (supported: c89, c99)", std)
        elif argv[i] == "--i64-downgrade":
            i64_mode = 1
        elif argv[i] == "--i64-longlong":
            i64_mode = 2
        elif argv[i][0] == '-' and argv[i][1] == 'D':
            if argv[i][2] != '\0':
                defines.push(argv[i] + 2)     # -DNAME=VALUE (attached)
            else:
                i += 1
                if i >= argc:
                    usage()
                defines.push(argv[i])         # -D NAME=VALUE (separate)
        elif argv[i] == "-o":
            i += 1
            if i >= argc:
                usage()
            out_path = argv[i]
        elif argv[i] == "--out-dir":
            i += 1
            if i >= argc:
                usage()
            out_dir = argv[i]
        elif argv[i] == "--backend":
            i += 1
            if i >= argc:
                usage()
            backend_name = argv[i]
        elif argv[i] == "--cpp":
            i += 1
            if i >= argc:
                usage()
            cpp_cmd = argv[i]
        elif argv[i] == "--diag-json":
            # resposta 6: os MESMOS diagnósticos, como dado, num arquivo. O
            # texto no `stderr` continua igual — ele é a referência, e há 692
            # casos que o medem.
            i += 1
            if i >= argc:
                usage()
            diag_json_enable(argv[i])
        elif argv[i] == "--pkg-path":
            # uma RAIZ de pacote, repetível. Um `import <pkg/mod.ph>` é
            # procurado em cada uma, na ordem — a mesma regra do `-I` do C.
            i += 1
            if i >= argc:
                usage()
            pkg_roots.push((*char)(argv[i]))
        elif argv[i] == "--inline-runtime":
            inline_runtime = True
        elif argv[i] in {"-g", "--debug", "--trace"}:
            # 100.1: the debug half of the two modes. It gives EVERY pscript
            # function a frame, so a stack trace names them all (34.2), and in
            # `run` it also asks the C compiler for debug info instead of
            # optimisation — `-g` is the spelling everyone already knows, and
            # `--trace` stays as the name it was born with.
            full_trace = True
        elif argv[i] in {"--no-assert", "-O"}:
            # 46.4: strip `assert` from the build, the way Python's `-O` does.
            # `-O` is the spelling a Python reader reaches for; it says nothing
            # about optimisation here, and the C compiler is the one that
            # optimises anyway.
            strip_asserts = True
        elif argv[i] in {"-pedantic", "--pedantic", "-Wpedantic"}:
            pedantic_lvl = 1
        elif argv[i] in {"-pedantic-errors", "--pedantic-errors"}:
            pedantic_lvl = 2
        elif argv[i] == "-w":
            wsuppress = True
        elif argv[i] == "-Werror":
            werror = True
        elif strncmp(argv[i], "-Werror=", 8) == 0:
            diag_set(argv[i] + 8, 2)
        elif strncmp(argv[i], "-Wno-error=", 11) == 0:
            diag_set_no_error(argv[i] + 11)
        elif argv[i] == "-Wall":
            wall = True
        elif argv[i] == "-Wextra":
            wall = True   # accepted; the -Wextra set matches -Wall for now
        elif strncmp(argv[i], "-Wno-", 5) == 0:
            diag_set(argv[i] + 5, 0)
        elif argv[i][0] == '-' and argv[i][1] == 'W' and argv[i][2] != '\0':
            diag_set(argv[i] + 2, 1)   # -W<group>: enable as a warning
        elif argv[i] == "--version":
            show_version = True
        elif argv[i] == "--deps":
            deps_mode = True
        elif argv[i] == "--outputs":
            outputs_mode = True
        elif argv[i] == "--api":
            api_mode = True
        elif argv[i] == "--tokens":
            tokens_only = True
        elif argv[i] == "--parse-only":
            parse_only = True
        elif argv[i] == "--ps-runtime":
            i += 1
            if i >= argc:
                fatal("--ps-runtime needs a directory")
            ps_runtime = argv[i]
        elif argv[i] in {"-h", "--help"}:
            usage()
        elif argv[i][0] == '-' and argv[i] != "-":
            fprintf(stderr, "plangc: unknown option '%s'\n", argv[i])
            usage()
        else:
            inputs.push(argv[i])
    if show_version:
        okv: bool = True
        printf("plangc %s (%016llx)\n", PLANG_VERSION, hash_file(argv[0], ref okv))
        return 0
    if inputs.is_empty():
        usage()
    if run_mode and inputs.len != 1:
        fatal("`run` takes ONE file: `plangc run program.psc [args...]`")
    if out_path != None and inputs.len > 1:
        fatal("-o can only be used with a single input file")
    if out_path != None and out_dir != None:
        fatal("-o and --out-dir are mutually exclusive")

    be: const *Backend = backend_find(backend_name) if backend_name != None else backend_default()
    if be == None:
        fatal("unknown backend: '%s'", backend_name)

    if std_version == 89 and be->name != "c":
        fatal("--std=c89 only applies to the C backend")
    if i64_mode != 0 and std_version != 89:
        fatal("--i64-downgrade/--i64-longlong require --std=c89")
    backend_c_config(std_version == 89, i64_mode)

    cc: Cc = {0}
    cc.defines = defines.data
    cc.ndefines = defines.len
    cc.backend_name = be->name
    cc.std_version = std_version
    cc.cpp = cpp_cmd
    cc.inline_runtime = inline_runtime
    cc.pkgroots = pkg_roots.data
    cc.npkgroots = i32(pkg_roots.len)
    # 99.2: what a top-level `const if` may look at, before anything is parsed
    parser_config_predef(plang_host_os(), defines.data, defines.len)
    ps_lower_config(strip_asserts, full_trace)
    # `run` compiles the RUNTIME with the program (16.4): on the command line
    # that is the caller's job, and in `run` there is no command line left.
    cachedir: const *char = None
    cfiles: Vec<*char>      # what `run` will hand to `cc`
    cfiles.init()
    run_hash: u64 = 0xcbf29ce484222325
    manifest: const *char = None
    if run_mode:
        cachedir = run_cache_dir(&cc.arena)
        # The manifest's KEY: the file asked for, the compiler that would
        # compile it, and the flags that change what it emits. The compiler goes
        # in as its own bytes' size and time — a rebuilt plangc emits different
        # C, and a cache that survived that would be a liar.
        kb: StrBuf = {0}
        defer kb.deinit()
        kb.puts(inputs.get(0))
        kb.puts(argv[0])
        # The compiler's own BYTES, hashed. Not its size and modification time:
        # `st_mtime` is a macro on glibc and on macOS, so the member behind it
        # depends on which feature macros the header was read with — and this
        # file is read with different ones than it is compiled with. Reading a
        # megabyte costs a millisecond and cannot be wrong.
        ok0: bool = True
        kb.puts(cc.arena.printf("|%016llx", hash_file(argv[0], ref ok0)))
        kb.puts(cc.arena.printf("|%d|%d|%d|%s", std_version, 1 if strip_asserts else 0, 1 if full_trace else 0, backend_name if backend_name != None else "c"))
        mkey: u64 = hash_bytes(kb.data, kb.len)
        manifest = cc.arena.printf("%s/man/%016llx", cachedir, mkey)
        bkey: u64 = 0
        if run_manifest_ok(&cc.arena, manifest, out bkey):
            binp0: const *char = cc.arena.printf("%s/bin/%016llx", cachedir, bkey)
            if access(binp0, 0) == 0:
                return run_exec(binp0, run_args, run_nargs)
        if has_suffix(inputs.get(0), ".psc"):
            # 108/111: o runtime são SEIS módulos em camadas mais os headers; o
            # guarda-chuva `psrt.ph` entra primeiro porque é o que o programa
            # gerado inclui
            RT_SRCS: const *char[] = {"psrt.ph", "psrt_types.ph", "psrt_mem.ph",
                                      "psrt_val.ph", "psrt_rt.ph", "psrt_std.ph", "psrt_os.ph",
                                      "psrt_top.ph", "psrt_mem.p", "psrt_val.p",
                                      "psrt_rt.p", "psrt_std.p", "psrt_os.p", "psrt_top.p"}
            for ri in range(i32(sizeof(RT_SRCS) / sizeof(RT_SRCS[0]))):
                add_input(&inputs, &pulled, path_join(&cc.arena, ps_runtime, RT_SRCS[ri]))
        # the C goes to the cache too, so a `run` never writes next to the
        # source — a script that lives in a read-only directory still runs
        out_dir = cc.arena.printf("%s/obj", cachedir)
    diag_config(werror, wall, pedantic_lvl, wsuppress)
    # o modo CONSULTA: as três perguntas rodam o front end (é ele que descobre
    # os imports) e param antes da sema e da emissão. `--api` é a exceção — a
    # lista de um `.psc` só existe depois do lowering, que é onde os módulos dele
    # viram um módulo P.
    query_mode: bool = deps_mode or outputs_mode or api_mode
    if deps_mode:
        deps_enable()

    if tokens_only:
        for j in range(inputs.len):
            dump_tokens(inputs.get(j), &cc)
        return 0

    # a WHILE, not a `for`: compiling a pscript program that imports a P module
    # (75.3) appends that module to the list, and the loop has to see it
    k: i32 = -1
    while usize(k + 1) < inputs.len:
        # incremented HERE, at the top: the body has `continue`s, and a loop
        # whose step is at the bottom would spin on the first of them
        k += 1
        path: const *char = inputs.get(usize(k))
        # a `.ph` pulled in by `import "x.ph"` (75.3) exists to be READ; only a
        # back end with headers has anything to write for it, and QBE has none
        if is_pulled(&pulled, path) and has_suffix(path, ".ph") and be->hdr_ext == None:
            continue
        # o `.c` é lido pelo PRÉ-PROCESSADOR externo, não por nós, então ele não
        # passaria pelo funil de `read_entire_file` — anota-se aqui, onde se sabe
        # que ele entrou na compilação
        if deps_mode:
            deps_add(path)
        if outputs_mode:
            printf("%s\n", dest_for(&cc, out_path, out_dir, path, be, &pulled))
        m: *Module
        if has_suffix(path, ".psc"):
            # pscript front end (50.3: one binary, the extension picks the
            # language). Its own lexer spec, grammar, tree and sema, and then it
            # LOWERS to the P tree — so from here down the pipeline is the one P
            # uses, its sema included, which is what verifies the lowering (49.1).
            pslen: usize = 0
            psbytes: *char = read_entire_file(path, out pslen)
            defer free(psbytes)
            pstl: TokenList = ps_lex(path, psbytes, pslen, &cc.arena)
            psm: *PsModule = ps_parse(&cc.arena, path, pstl)
            # 75.3/2.4: `import "shim.ph"` pulls the P module into THIS build.
            # The header gives the declarations (45.5) and the `.p` beside it
            # gives the code; both are compiled into the same mirrored tree, so
            # one command covers what used to take two.
            #
            # 1.5(d): a varredura é do FECHAMENTO, não do arquivo nomeado. Um
            # `import "x.ph"` escrito dentro de um MÓDULO importado conta tanto
            # quanto um escrito no arquivo de cima — a alternativa era o que
            # havia: silêncio, um `#include` órfão no C gerado, e um arreio de
            # build compensando à mão (o `hl.p` do editor no `Makefile`).
            # A varredura mora aqui e não na sema porque `--outputs` não roda a
            # sema: a resposta 3 tem de saber o que vai ser emitido sem
            # compilar nada.
            psc_seen: Vec<*char>
            psc_seen.init()
            psc_pmods(&cc, path, psm, &inputs, &pulled, &psc_seen)
            # `--deps` e `--api` precisam do front end do pscript: é ELE que
            # resolve `import lib_core` e lê o módulo importado (ps_sema.p:3237).
            # `--outputs` sozinho não precisa de nada disso.
            if parse_only or (query_mode and not api_mode and not deps_mode):
                continue
            ps_sema_run(&cc.arena, psm, cc.cpp, cc.pkgroots, cc.npkgroots)
            m = ps_lower(&cc.arena, psm, ps_runtime)
            if not be->pre_sema and not query_mode:
                sema_run(&cc, m)
                # the runtime's types and signatures come from an imported
                # header, and QBE needs their LAYOUTS — without this the context
                # is a four-byte local and every runtime call returns a word
                if be->name == "qbe":
                    qbe_merge_types(&cc, m)
        elif has_suffix(path, ".c") or has_suffix(path, ".i"):
            # C frontend: produces the same AST and goes through the SAME sema
            # as P — that is what makes --std=c89 correct for C input too
            # (designated initializers lowered to positional, VLAs to
            # malloc/free). Sema is deliberately shallow (deep type checking is
            # the target compiler's job), so valid C is untouched.
            if query_mode and not api_mode:
                # nada a descobrir: o C não tem import que puxe outro input (o
                # pré-processador já resolveu os `#include`), e pré-processar
                # para nada custaria um processo por arquivo
                continue
            clen: usize = 0
            cbytes: *char
            if has_suffix(path, ".c"):
                # RAW C: run the configured preprocessor first, so #include
                # and #define resolve like in any production compiler driver.
                # .i input is already preprocessed and skips this.
                cbytes = preprocess_c(&cc, path, out clen)
            else:
                cbytes = read_entire_file(path, out clen)
            m = c_parse(&cc.arena, path, cbytes, clen, True)
            if not be->pre_sema and not query_mode:
                sema_run(&cc, m)
        else:
            m = cc_load_module(&cc, path)
            # `import <pkg/mod.ph>` PUXA o módulo do pacote, sempre — e não só
            # quando quem importa já foi puxado.
            #
            # É a regra 1.5(a) aplicada à forma com `<>`, e a diferença entre as
            # duas formas é o que a justifica: `"x.ph"` é um arquivo ao lado, e
            # quem compila diz o que compila (o contrato do `-o` e da linha de
            # comando); `<pkg/mod.ph>` é um PACOTE, e um pacote é uma unidade
            # que se usa inteira — importar a interface e ter de nomear a
            # implementação à mão seria pedir que quem usa o pacote soubesse
            # como ele é feito por dentro.
            for jp in range(m->ndecls):
                ip0: *Decl = m->decls[jp]
                if ip0->kind != DL_IMPORT or ip0->is_include or not ip0->import_system:
                    continue
                if ip0->import_path == None or not has_suffix(ip0->import_path, ".ph"):
                    continue
                pph: const *char = pkg_resolve(&cc, path, ip0)
                add_input(&inputs, &pulled, pph)
                ppp: const *char = cc.arena.printf("%.*s", i32(strlen(pph) - 1), pph)
                pl0: usize = 0
                pb0: *char = read_entire_file_opt(ppp, out pl0)
                if pb0 != None:
                    free(pb0)
                    add_input(&inputs, &pulled, ppp)
            if deps_mode:
                deps_walk(&cc, path)
            # 75.3, transitively: a module pulled into this build may import
            # others, and one command has to mean the whole graph. Only what a
            # PULLED file needs is pulled — a file the user named keeps the
            # build they asked for.
            if is_pulled(&pulled, path):
                for j in range(m->ndecls):
                    im: *Decl = m->decls[j]
                    if im->kind != DL_IMPORT or im->is_include or im->import_path == None:
                        continue
                    if not has_suffix(im->import_path, ".ph"):
                        continue
                    # a forma com `<>` vem de uma raiz de pacote, mesmo aqui —
                    # um módulo de pacote importa outro módulo de pacote pelo
                    # mesmo caminho por que quem o usa o importou
                    ip: const *char = pkg_resolve(&cc, path, im) if im->import_system else path_join(&cc.arena, path_dir(&cc.arena, path), im->import_path)
                    add_input(&inputs, &pulled, ip)
                    isp: const *char = cc.arena.printf("%.*s", i32(strlen(ip) - 1), ip)
                    sl2: usize = 0
                    sb2: *char = read_entire_file_opt(isp, out sl2)
                    if sb2 != None:
                        free(sb2)
                        add_input(&inputs, &pulled, isp)
            # a pre-sema backend wants the SURFACE tree: printing the source
            # language must not see the lowering (backend_p)
            if not be->pre_sema and not query_mode:
                sema_run(&cc, m)
                # QBE needs the LAYOUTS of imported types (offsets/enum). Imported
                # structs must not re-emit methods here (materialized via
                # `implement`); emit_func skips in_header methods.
                if be->name == "qbe":
                    qbe_merge_types(&cc, m)

        # a pergunta 2/5 do protocolo, num lugar só para as três linguagens: a
        # árvore de superfície de um `.p`/`.ph`, a do `.c` round-trip, e a que o
        # lowering do pscript produziu
        if api_mode:
            ab: StrBuf = {0}
            api_dump(m, &ab)
            fwrite(ab.data, 1, ab.len, stdout)
            ab.deinit()
        if query_mode:
            continue

        out: StrBuf = {0}
        defer out.deinit()
        backend_emit(be, m, &out)

        dest: const *char = dest_for(&cc, out_path, out_dir, path, be, &pulled)
        if out_dir != None:
            mkdirs_for(dest)
        if dest == "-":
            fwrite(out.data, 1, out.len, stdout)
        else:
            f: *FILE = fopen(dest, "wb")
            if f == None:
                fatal("could not write '%s'", dest)
            fwrite(out.data, 1, out.len, f)
            fclose(f)
        if run_mode:
            # the hash is over what will be COMPILED, in the order it will be
            # given to `cc`: same C, same binary, and nothing else can make two
            # runs disagree
            run_hash = run_hash * 0x100000001b3 ^ hash_bytes(out.data if out.data != None else "", out.len)
            if has_suffix(dest, ".c"):
                cfiles.push((*char)(dest))
    if deps_mode:
        # no fim, porque a lista só está completa quando o último import foi
        # seguido: o laço acima CRESCE enquanto descobre
        for di in range(deps_count()):
            printf("%s\n", deps_get(di))
        diag_json_flush()
        return 0
    if run_mode:
        run_manifest_write(&cc.arena, manifest, run_hash, &inputs)
        diag_json_flush()
        return run_program(&cc, &cfiles, run_hash, cachedir, run_args, run_nargs, std_version, full_trace)
    # a compilação acabou bem: os avisos que houve saem aqui, e o arquivo existe
    # mesmo quando não houve nenhum (uma lista vazia é uma resposta)
    diag_json_flush()
    return 0
