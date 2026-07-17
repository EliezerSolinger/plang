#include <stdint.h>
#include <stddef.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "backend.h"
#include "lexer.h"
#include "parser.h"
#include "sema.h"
#include "cfront.h"
#include "../stl/vec.h"
#include "vecs.h"

static int has_suffix(const char *s, const char *suf) {
    size_t n = strlen(s);
    size_t m = strlen(suf);
    return n >= m && strcmp(s + n - m, suf) == 0;
}

static void usage(void) {
    fprintf(stderr, "usage: plangc [options] file.p [file2.ph ...]\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "options:\n");
    fprintf(stderr, "  -o <file>        output (single input only; '-' = stdout)\n");
    fprintf(stderr, "  -D NAME[=VAL]    define a compile-time const (int/float/\"str\")\n");
    fprintf(stderr, "  --std=c89        emit strict C89 (C backend; default: c99)\n");
    fprintf(stderr, "  --i64-downgrade  under c89: map 64-bit ints to 32-bit\n");
    fprintf(stderr, "  --i64-longlong   under c89: use the long long extension\n");
    fprintf(stderr, "  --backend <b>    codegen target (default: c)\n");
    fprintf(stderr, "  --tokens         dump tokens and exit\n");
    fprintf(stderr, "  -h, --help       this help\n");
    exit(2);
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
    int32_t i;
    for (i = 0; i < cc->nmods; i += 1) {
        Module *md = cc->mods[i];
        if (md == m) {
            continue;
        }
        int32_t j;
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
        int32_t j2;
        for (j2 = 0; j2 < md2->ndecls; j2 += 1) {
            Decl *d = md2->decls[j2];
            if (d->kind == DL_STRUCT || d->kind == DL_UNION) {
                Decl *c = arena_alloc(&cc->arena, sizeof(Decl));
                *c = *d;
                if (d->nmethods > 0) {
                    Func **mc = arena_alloc(&cc->arena, sizeof(*d->methods) * (size_t)d->nmethods);
                    int32_t mk;
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
    int32_t j3;
    for (j3 = 0; j3 < m->ndecls; j3 += 1) {
        nd[p] = m->decls[j3];
        p += 1;
    }
    m->decls = nd;
    m->ndecls = total;
}

int main(int argc, char **argv) {
    const char *out_path = NULL;
    const char *backend_name = NULL;
    int tokens_only = 0;
    int std_version = 99;
    int i64_mode = 0;
    Vec_pchar inputs;
    Vec_pchar_init(&inputs);
    Vec_pchar defines;
    Vec_pchar_init(&defines);
    int32_t i;
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
        } else if (strcmp(argv[i], "--backend") == 0) {
            i += 1;
            if (i >= argc) {
                usage();
            }
            backend_name = argv[i];
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
    if (tokens_only) {
        int32_t j;
        for (j = 0; j < inputs.len; j += 1) {
            dump_tokens(Vec_pchar_get(&inputs, j), &cc);
        }
        return 0;
    }
    int32_t k;
    for (k = 0; k < inputs.len; k += 1) {
        const char *path = Vec_pchar_get(&inputs, k);
        Module *m;
        if (has_suffix(path, ".c") || has_suffix(path, ".i")) {
            size_t clen = 0;
            char *cbytes = read_entire_file(path, &clen);
            m = c_parse(&cc.arena, path, cbytes, clen);
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
