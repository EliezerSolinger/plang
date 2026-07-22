# main.p — driver: orchestrates the pipeline (port of src/main.c)
#   file -> utf8 -> lexer -> parser -> sema -> backend -> output
include <stdio.h>
include <stdlib.h>
include <string.h>
import "backend.ph"
import "lexer.ph"
import "parser.ph"
import "sema.ph"
import "cfront.ph"
import "../stl/vec.ph"
import "vecs.ph"


static def has_suffix(s: const *char, suf: const *char) -> bool:
    n: usize = strlen(s)
    m: usize = strlen(suf)
    return n >= m and strcmp(s + n - m, suf) == 0

static def usage():
    fprintf(stderr, "usage: plangc [options] file.p [file2.ph ...]\n")
    fprintf(stderr, "\n")
    fprintf(stderr, "options:\n")
    fprintf(stderr, "  -o <file>        output (single input only; '-' = stdout)\n")
    fprintf(stderr, "  -D NAME[=VAL]    define a compile-time const (int/float/\"str\")\n")
    fprintf(stderr, "  --std=c89        emit strict C89 (C backend; default: c99)\n")
    fprintf(stderr, "  --i64-downgrade  under c89: map 64-bit ints to 32-bit\n")
    fprintf(stderr, "  --i64-longlong   under c89: use the long long extension\n")
    fprintf(stderr, "  --backend <b>    codegen target (default: c)\n")
    fprintf(stderr, "  --cpp <cc>       C compiler used to preprocess `include <h>` headers\n")
    fprintf(stderr, "                   (default: PLANGC_CPP env, else \"cc\")\n")
    fprintf(stderr, "  --tokens         dump tokens and exit\n")
    fprintf(stderr, "  -h, --help       this help\n")
    exit(2)

static def derive_output(a: *Arena, input: const *char, be: const *Backend) -> const *char:
    n: usize = strlen(input)
    if n > 3 and strcmp(input + n - 3, ".ph") == 0:
        if be->hdr_ext == None:
            fatal("backend '%s' does not generate headers (.ph)", be->name)
        return arena_printf(a, "%.*s.%s", i32(n - 3), input, be->hdr_ext)
    if n > 2 and strcmp(input + n - 2, ".p") == 0:
        return arena_printf(a, "%.*s.%s", i32(n - 2), input, be->out_ext)
    if n > 2 and strcmp(input + n - 2, ".c") == 0:
        return arena_printf(a, "%.*s.%s", i32(n - 2), input, be->out_ext)
    if n > 2 and strcmp(input + n - 2, ".i") == 0:
        return arena_printf(a, "%.*s.%s", i32(n - 2), input, be->out_ext)
    fatal("'%s': unknown extension (expected .p, .ph, .c or .i)", input)
    return None

static def dump_tokens(path: const *char, cc: *Cc):
    len: usize = 0
    bytes: *char = read_entire_file(path, &len)
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
static def qbe_merge_types(cc: *Cc, m: *Module):
    extra = 0
    for i in range(cc->nmods):
        md: *Module = cc->mods[i]
        if md == m:
            continue
        for j in range(md->ndecls):
            dd: *Decl = md->decls[j]
            dk: DeclKind = dd->kind
            if dk == DL_STRUCT or dk == DL_UNION or dk == DL_ENUM:
                extra += 1
            elif dk == DL_FUNC and (dd->func->body == None or dd->func->is_inline or dd->func->is_static):
                # prototype (registers signature) OR header-only free function
                # (static/inline with body, §8.5): this one is emitted per-TU
                extra += 1
    if extra == 0:
        return
    total: i32 = extra + m->ndecls
    nd: **Decl = arena_alloc(&cc->arena, sizeof(*m->decls) * usize(total))
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
                c: *Decl = arena_alloc(&cc->arena, sizeof(Decl))
                *c = *d
                if d->nmethods > 0:
                    mc: **Func = arena_alloc(&cc->arena, sizeof(*d->methods) * usize(d->nmethods))
                    for mk in range(d->nmethods):
                        fc: *Func = arena_alloc(&cc->arena, sizeof(Func))
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
            elif d->kind == DL_FUNC and (d->func->body == None or d->func->is_inline or d->func->is_static):
                # prototype (emit_func skips body==None) OR header-only free
                # function (static/inline): emitted per-TU, not exported
                # (local symbol, no link collision between TUs)
                nd[p] = d
                p += 1
    for j3 in range(m->ndecls):
        nd[p] = m->decls[j3]
        p += 1
    m->decls = nd
    m->ndecls = total

def main(argc: int, argv: **char) -> int:
    out_path: const *char = None
    backend_name: const *char = None
    tokens_only: bool = False
    std_version = 99      # target of the C backend (--std=c89 -> 89)
    i64_mode = 0          # under c89: 0=error, 1=downgrade 64->32, 2=long long
    # C compiler used to preprocess `include <h>`: --cpp > PLANGC_CPP env > "cc"
    cpp_cmd: const *char = getenv("PLANGC_CPP")
    if cpp_cmd == None:
        cpp_cmd = "cc"
    inputs: Vec<*char>
    inputs.init()
    defines: Vec<*char>   # -D NAME=VALUE: comptime consts injected from outside
    defines.init()

    for i in range(1, argc):
        if strncmp(argv[i], "--std=", 6) == 0:
            std: const *char = argv[i] + 6
            if strcmp(std, "c89") == 0 or strcmp(std, "c90") == 0:
                std_version = 89
            elif strcmp(std, "c99") == 0:
                std_version = 99
            else:
                fatal("unknown --std '%s' (supported: c89, c99)", std)
        elif strcmp(argv[i], "--i64-downgrade") == 0:
            i64_mode = 1
        elif strcmp(argv[i], "--i64-longlong") == 0:
            i64_mode = 2
        elif argv[i][0] == '-' and argv[i][1] == 'D':
            if argv[i][2] != '\0':
                defines.push(argv[i] + 2)     # -DNAME=VALUE (attached)
            else:
                i += 1
                if i >= argc:
                    usage()
                defines.push(argv[i])         # -D NAME=VALUE (separate)
        elif strcmp(argv[i], "-o") == 0:
            i += 1
            if i >= argc:
                usage()
            out_path = argv[i]
        elif strcmp(argv[i], "--backend") == 0:
            i += 1
            if i >= argc:
                usage()
            backend_name = argv[i]
        elif strcmp(argv[i], "--cpp") == 0:
            i += 1
            if i >= argc:
                usage()
            cpp_cmd = argv[i]
        elif strcmp(argv[i], "--tokens") == 0:
            tokens_only = True
        elif strcmp(argv[i], "-h") == 0 or strcmp(argv[i], "--help") == 0:
            usage()
        elif argv[i][0] == '-' and strcmp(argv[i], "-") != 0:
            fprintf(stderr, "plangc: unknown option '%s'\n", argv[i])
            usage()
        else:
            inputs.push(argv[i])
    if inputs.is_empty():
        usage()
    if out_path != None and inputs.len > 1:
        fatal("-o can only be used with a single input file")

    be: const *Backend = backend_find(backend_name) if backend_name != None else backend_default()
    if be == None:
        fatal("unknown backend: '%s'", backend_name)

    if std_version == 89 and strcmp(be->name, "c") != 0:
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

    if tokens_only:
        for j in range(inputs.len):
            dump_tokens(inputs.get(j), &cc)
        return 0

    for k in range(inputs.len):
        path: const *char = inputs.get(k)
        m: *Module
        if has_suffix(path, ".c") or has_suffix(path, ".i"):
            # C frontend: produces the same AST; the backend infers types (F1),
            # so we don't go through P's sema
            clen: usize = 0
            cbytes: *char = read_entire_file(path, &clen)
            m = c_parse(&cc.arena, path, cbytes, clen)
        else:
            m = cc_load_module(&cc, path)
            sema_run(&cc, m)
            # QBE needs the LAYOUTS of imported types (offsets/enum). Imported
            # structs must not re-emit methods here (materialized via
            # `implement`); emit_func skips in_header methods.
            if strcmp(be->name, "qbe") == 0:
                qbe_merge_types(&cc, m)

        out: StrBuf = {0}
        defer sb_free(&out)
        backend_emit(be, m, &out)

        dest: const *char = out_path if out_path != None else derive_output(&cc.arena, inputs.get(k), be)
        if strcmp(dest, "-") == 0:
            fwrite(out.data, 1, out.len, stdout)
        else:
            f: *FILE = fopen(dest, "wb")
            if f == None:
                fatal("could not write '%s'", dest)
            fwrite(out.data, 1, out.len, f)
            fclose(f)
    return 0
