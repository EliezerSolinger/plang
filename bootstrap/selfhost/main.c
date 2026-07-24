#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include <stdio.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>
#include "backend.h"
#include "lexer.h"
#include "parser.h"
#include "sema.h"
#include "cfront.h"
#include "../stl/vec.h"
#include "vecs.h"

static FILE *popen(const char *cmd, const char *mode);

int32_t pclose(FILE *stream);

static char *preprocess_c(Cc *cc, const char *path, size_t *out_len) {
    const char *cpp = (cc->cpp != NULL ? cc->cpp : "cc");
    const char *cmd = arena_printf(&cc->arena, "%s -E -P -x c \"%s\"", cpp, path);
    FILE *f = popen(cmd, "r");
    if (f == NULL) {
        fatal("could not run the C preprocessor '%s' (see --cpp / PLANGC_CPP)", cpp);
    }
    StrBuf b = {0};
    char chunk[4097];
    while (1) {
        size_t n = fread(&chunk[0], 1, 4096, f);
        if (n == 0) {
            break;
        }
        chunk[n] = '\0';
        sb_puts(&b, &chunk[0]);
    }
    int32_t rc = pclose(f);
    if (rc != 0) {
        fatal("C preprocessing failed for '%s' ('%s -E'; fix the errors above or see --cpp / PLANGC_CPP)", path, cpp);
    }
    char *res = arena_strdup(&cc->arena, (b.data != NULL ? b.data : ""));
    *out_len = strlen(res);
    sb_free(&b);
    return res;
}

int has_suffix(const char *s, const char *suf) {
    size_t n = strlen(s);
    size_t m = strlen(suf);
    return n >= m && strcmp(s + n - m, suf) == 0;
}

static void usage(void) {
    fprintf(stderr, "usage: plangc [options] file.p [file2.ph ...]\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "options:\n");
    fprintf(stderr, "  -o <file>        output (single input only; '-' = stdout)\n");
    fprintf(stderr, "  --out-dir <dir>  mirror each input's path under <dir> (out/stl/x.h,\n");
    fprintf(stderr, "                   out/selfhost/x.c ...): builds never touch the sources\n");
    fprintf(stderr, "  -D NAME[=VAL]    define a compile-time const (int/float/\"str\")\n");
    fprintf(stderr, "  --std=c89        emit strict C89 (C backend; default: c99)\n");
    fprintf(stderr, "  --i64-downgrade  under c89: map 64-bit ints to 32-bit\n");
    fprintf(stderr, "  --i64-longlong   under c89: use the long long extension\n");
    fprintf(stderr, "  --backend <b>    codegen target (default: c)\n");
    fprintf(stderr, "  --cpp <cc>       C compiler used to preprocess `include <h>` headers\n");
    fprintf(stderr, "                   (default: PLANGC_CPP env, else \"cc\")\n");
    fprintf(stderr, "  -W<group>        clang-style warning control: -W<g>, -Wno-<g>,\n");
    fprintf(stderr, "                   -Werror, -Werror=<g>, -Wno-error=<g>, -Wall, -w\n");
    fprintf(stderr, "  --inline-runtime helpers injected by the compiler (e.g. the 'in'\n");
    fprintf(stderr, "                   operator's strcmp) become self-contained inline\n");
    fprintf(stderr, "                   functions - the output has no libc dependency for them\n");
    fprintf(stderr, "  -pedantic        warn on GNU/C23 extensions in C input\n");
    fprintf(stderr, "  -pedantic-errors reject GNU/C23 extensions in C input\n");
    fprintf(stderr, "  --tokens         dump tokens and exit\n");
    fprintf(stderr, "  -h, --help       this help\n");
    exit(2);
}

static void mkdirs_for(const char *p) {
    char *buf = malloc(strlen(p) + 1);
    strcpy(buf, p);
    size_t i = 1;
    while (buf[i] != '\0') {
        if (buf[i] == '/') {
            buf[i] = '\0';
            mkdir(buf, 493);
            buf[i] = '/';
        }
        i += 1;
    }
    free(buf);
}

static const char *derive_output(Arena *a, const char *input, const Backend *be) {
    size_t n = strlen(input);
    if (n > 3 && strcmp(input + n - 3, ".ph") == 0) {
        if (be->hdr_ext == NULL) {
            fatal("backend '%s' does not generate headers (.ph)", be->name);
        }
        return arena_printf(a, "%.*s.%s", (int32_t)(n - 3), input, be->hdr_ext);
    }
    if (n > 2 && strcmp(input + n - 2, ".p") == 0) {
        return arena_printf(a, "%.*s.%s", (int32_t)(n - 2), input, be->out_ext);
    }
    if (n > 2 && strcmp(input + n - 2, ".c") == 0) {
        return arena_printf(a, "%.*s.%s", (int32_t)(n - 2), input, be->out_ext);
    }
    if (n > 2 && strcmp(input + n - 2, ".i") == 0) {
        return arena_printf(a, "%.*s.%s", (int32_t)(n - 2), input, be->out_ext);
    }
    fatal("'%s': unknown extension (expected .p, .ph, .c or .i)", input);
    return NULL;
}

static void dump_tokens(const char *path, Cc *cc) {
    size_t len = 0;
    char *bytes = read_entire_file(path, &len);
    TokenList tl = lex(path, bytes, len, &cc->arena);
    size_t i;
    for (i = 0; i < tl.n; i += 1) {
        Token *t = &tl.toks[i];
        printf("%4d:%-3d %-16s %s\n", t->pos.line, t->pos.col, tok_kind_name(t->kind), (t->text != NULL ? t->text : ""));
    }
    {
        free(bytes);
    }
}

static void qbe_merge_types(Cc *cc, Module *m) {
    int extra = 0;
    size_t i;
    for (i = 0; i < cc->nmods; i += 1) {
        Module *md = cc->mods[i];
        if (md == m) {
            continue;
        }
        size_t j;
        for (j = 0; j < md->ndecls; j += 1) {
            Decl *dd = md->decls[j];
            DeclKind dk = dd->kind;
            if (dk == DL_STRUCT || dk == DL_UNION || dk == DL_ENUM) {
                extra += 1;
            } else if (dk == DL_FUNC && (dd->func->body == NULL || dd->func->is_inline || dd->func->is_static)) {
                extra += 1;
            }
        }
    }
    if (extra == 0) {
        return;
    }
    int32_t total = extra + m->ndecls;
    Decl **nd = arena_alloc(&cc->arena, sizeof(*m->decls) * (size_t)total);
    int p = 0;
    for (i = 0; i < cc->nmods; i += 1) {
        Module *md2 = cc->mods[i];
        if (md2 == m) {
            continue;
        }
        size_t j2;
        for (j2 = 0; j2 < md2->ndecls; j2 += 1) {
            Decl *d = md2->decls[j2];
            if (d->kind == DL_STRUCT || d->kind == DL_UNION) {
                Decl *c = arena_alloc(&cc->arena, sizeof(Decl));
                *c = *d;
                if (d->nmethods > 0) {
                    Func **mc = arena_alloc(&cc->arena, sizeof(*d->methods) * (size_t)d->nmethods);
                    size_t mk;
                    for (mk = 0; mk < d->nmethods; mk += 1) {
                        Func *fc = arena_alloc(&cc->arena, sizeof(Func));
                        *fc = *d->methods[mk];
                        if (!(fc->is_inline || fc->is_static)) {
                            fc->body = NULL;
                        }
                        mc[mk] = fc;
                    }
                    c->methods = mc;
                }
                nd[p] = c;
                p += 1;
            } else if (d->kind == DL_ENUM) {
                nd[p] = d;
                p += 1;
            } else if (d->kind == DL_FUNC && (d->func->body == NULL || d->func->is_inline || d->func->is_static)) {
                nd[p] = d;
                p += 1;
            }
        }
    }
    size_t j3;
    for (j3 = 0; j3 < m->ndecls; j3 += 1) {
        nd[p] = m->decls[j3];
        p += 1;
    }
    m->decls = nd;
    m->ndecls = total;
}

int main(int argc, char **argv) {
    const char *out_path = NULL;
    const char *out_dir = NULL;
    const char *backend_name = NULL;
    int tokens_only = 0;
    int std_version = 99;
    int pedantic_lvl = 0;
    int inline_runtime = 0;
    int werror = 0;
    int wall = 0;
    int wsuppress = 0;
    int i64_mode = 0;
    const char *cpp_cmd = getenv("PLANGC_CPP");
    if (cpp_cmd == NULL) {
        cpp_cmd = "cc";
    }
    Vec_pchar inputs;
    Vec_pchar_init(&inputs);
    Vec_pchar defines;
    Vec_pchar_init(&defines);
    size_t i;
    for (i = 1; i < argc; i += 1) {
        if (strncmp(argv[i], "--std=", 6) == 0) {
            const char *std = argv[i] + 6;
            if (strcmp(std, "c89") == 0 || strcmp(std, "c90") == 0) {
                std_version = 89;
            } else if (strcmp(std, "c99") == 0) {
                std_version = 99;
            } else {
                fatal("unknown --std '%s' (supported: c89, c99)", std);
            }
        } else if (strcmp(argv[i], "--i64-downgrade") == 0) {
            i64_mode = 1;
        } else if (strcmp(argv[i], "--i64-longlong") == 0) {
            i64_mode = 2;
        } else if (argv[i][0] == '-' && argv[i][1] == 'D') {
            if (argv[i][2] != '\0') {
                Vec_pchar_push(&defines, argv[i] + 2);
            } else {
                i += 1;
                if (i >= argc) {
                    usage();
                }
                Vec_pchar_push(&defines, argv[i]);
            }
        } else if (strcmp(argv[i], "-o") == 0) {
            i += 1;
            if (i >= argc) {
                usage();
            }
            out_path = argv[i];
        } else if (strcmp(argv[i], "--out-dir") == 0) {
            i += 1;
            if (i >= argc) {
                usage();
            }
            out_dir = argv[i];
        } else if (strcmp(argv[i], "--backend") == 0) {
            i += 1;
            if (i >= argc) {
                usage();
            }
            backend_name = argv[i];
        } else if (strcmp(argv[i], "--cpp") == 0) {
            i += 1;
            if (i >= argc) {
                usage();
            }
            cpp_cmd = argv[i];
        } else if (strcmp(argv[i], "--inline-runtime") == 0) {
            inline_runtime = 1;
        } else if (strcmp(argv[i], "-pedantic") == 0 || strcmp(argv[i], "--pedantic") == 0 || strcmp(argv[i], "-Wpedantic") == 0) {
            pedantic_lvl = 1;
        } else if (strcmp(argv[i], "-pedantic-errors") == 0 || strcmp(argv[i], "--pedantic-errors") == 0) {
            pedantic_lvl = 2;
        } else if (strcmp(argv[i], "-w") == 0) {
            wsuppress = 1;
        } else if (strcmp(argv[i], "-Werror") == 0) {
            werror = 1;
        } else if (strncmp(argv[i], "-Werror=", 8) == 0) {
            diag_set(argv[i] + 8, 2);
        } else if (strncmp(argv[i], "-Wno-error=", 11) == 0) {
            diag_set_no_error(argv[i] + 11);
        } else if (strcmp(argv[i], "-Wall") == 0) {
            wall = 1;
        } else if (strcmp(argv[i], "-Wextra") == 0) {
            wall = 1;
        } else if (strncmp(argv[i], "-Wno-", 5) == 0) {
            diag_set(argv[i] + 5, 0);
        } else if (argv[i][0] == '-' && argv[i][1] == 'W' && argv[i][2] != '\0') {
            diag_set(argv[i] + 2, 1);
        } else if (strcmp(argv[i], "--tokens") == 0) {
            tokens_only = 1;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage();
        } else if (argv[i][0] == '-' && strcmp(argv[i], "-") != 0) {
            fprintf(stderr, "plangc: unknown option '%s'\n", argv[i]);
            usage();
        } else {
            Vec_pchar_push(&inputs, argv[i]);
        }
    }
    if (Vec_pchar_is_empty(&inputs)) {
        usage();
    }
    if (out_path != NULL && inputs.len > 1) {
        fatal("-o can only be used with a single input file");
    }
    if (out_path != NULL && out_dir != NULL) {
        fatal("-o and --out-dir are mutually exclusive");
    }
    const Backend *be = (backend_name != NULL ? backend_find(backend_name) : backend_default());
    if (be == NULL) {
        fatal("unknown backend: '%s'", backend_name);
    }
    if (std_version == 89 && strcmp(be->name, "c") != 0) {
        fatal("--std=c89 only applies to the C backend");
    }
    if (i64_mode != 0 && std_version != 89) {
        fatal("--i64-downgrade/--i64-longlong require --std=c89");
    }
    backend_c_config(std_version == 89, i64_mode);
    Cc cc = {0};
    cc.defines = defines.data;
    cc.ndefines = defines.len;
    cc.backend_name = be->name;
    cc.std_version = std_version;
    cc.cpp = cpp_cmd;
    cc.inline_runtime = inline_runtime;
    diag_config(werror, wall, pedantic_lvl, wsuppress);
    if (tokens_only) {
        size_t j;
        for (j = 0; j < inputs.len; j += 1) {
            dump_tokens(Vec_pchar_get(&inputs, j), &cc);
        }
        return 0;
    }
    size_t k;
    for (k = 0; k < inputs.len; k += 1) {
        const char *path = Vec_pchar_get(&inputs, k);
        Module *m;
        if (has_suffix(path, ".c") || has_suffix(path, ".i")) {
            size_t clen = 0;
            char *cbytes;
            if (has_suffix(path, ".c")) {
                cbytes = preprocess_c(&cc, path, &clen);
            } else {
                cbytes = read_entire_file(path, &clen);
            }
            m = c_parse(&cc.arena, path, cbytes, clen, 1);
            sema_run(&cc, m);
        } else {
            m = cc_load_module(&cc, path);
            sema_run(&cc, m);
            if (strcmp(be->name, "qbe") == 0) {
                qbe_merge_types(&cc, m);
            }
        }
        StrBuf out = {0};
        backend_emit(be, m, &out);
        const char *dest = (out_path != NULL ? out_path : derive_output(&cc.arena, Vec_pchar_get(&inputs, k), be));
        if (out_dir != NULL) {
            dest = arena_printf(&cc.arena, "%s/%s", out_dir, dest);
            mkdirs_for(dest);
        }
        if (strcmp(dest, "-") == 0) {
            fwrite(out.data, 1, out.len, stdout);
        } else {
            FILE *f = fopen(dest, "wb");
            if (f == NULL) {
                fatal("could not write '%s'", dest);
            }
            fwrite(out.data, 1, out.len, f);
            fclose(f);
        }
        {
            sb_free(&out);
        }
    }
    return 0;
}
