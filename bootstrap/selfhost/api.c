#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include <string.h>
#include "plang.h"
#include "ast.h"
#include "api.h"
#include "ps_ast.h"
#include "../packages/stl/hash.h"

static void a_type(StrBuf *b, Type *t, int no_const);

static void a_doc(StrBuf *b, const char *owner, const char *name, const char *doc);

static void a_expr(StrBuf *b, Expr *e);

static const char *a_op(int32_t op) {
    switch ((TokKind)op) {
        case TK_PLUS: {
            return "+";
        }
        case TK_MINUS: {
            return "-";
        }
        case TK_STAR: {
            return "*";
        }
        case TK_SLASH: {
            return "/";
        }
        case TK_PERCENT: {
            return "%";
        }
        case TK_AMP: {
            return "&";
        }
        case TK_PIPE: {
            return "|";
        }
        case TK_CARET: {
            return "^";
        }
        case TK_TILDE: {
            return "~";
        }
        case TK_SHL: {
            return "<<";
        }
        case TK_SHR: {
            return ">>";
        }
        case TK_LT: {
            return "<";
        }
        case TK_LE: {
            return "<=";
        }
        case TK_GT: {
            return ">";
        }
        case TK_GE: {
            return ">=";
        }
        case TK_EQ: {
            return "==";
        }
        case TK_NE: {
            return "!=";
        }
        case TK_AND: {
            return " and ";
        }
        case TK_OR: {
            return " or ";
        }
        case TK_NOT: {
            return "not ";
        }
        case TK_IS: {
            return " is ";
        }
        case TK_ISNOT: {
            return " is not ";
        }
        case TK_DOT: {
            return ".";
        }
        case TK_ARROW: {
            return "->";
        }
        default: {
            return "\?";
        }
    }
}

static void a_type(StrBuf *b, Type *t, int no_const) {
    if (t == NULL) {
        StrBuf_puts(b, "void");
        return;
    }
    switch (t->kind) {
        case TY_PTR: {
            if (t->is_ref) {
                StrBuf_puts(b, "ref ");
                a_type(b, t->inner, 0);
                return;
            }
            if (t->inner != NULL && t->inner->kind == TY_FUNC) {
                a_type(b, t->inner, 0);
                return;
            }
            if (t->inner != NULL && t->inner->kind == TY_ARRAY) {
                StrBuf_puts(b, "*(");
                a_type(b, t->inner, 0);
                StrBuf_putc(b, ')');
                return;
            }
            int hoist = 0;
            if (!no_const) {
                Type *base2 = t;
                while (base2 != NULL && base2->kind == TY_PTR) {
                    base2 = base2->inner;
                }
                if (base2 != NULL && base2->kind == TY_NAME && base2->is_const) {
                    hoist = 1;
                }
            }
            if (hoist) {
                StrBuf_puts(b, "const ");
            }
            if (t->is_restrict) {
                StrBuf_puts(b, "restrict ");
            }
            StrBuf_putc(b, '*');
            if (t->is_const) {
                StrBuf_puts(b, "const ");
            }
            a_type(b, t->inner, hoist || no_const);
            break;
        }
        case TY_ARRAY: {
            Type *base = t;
            while (base != NULL && base->kind == TY_ARRAY) {
                base = base->inner;
            }
            a_type(b, base, 0);
            Type *dim = t;
            while (dim != NULL && dim->kind == TY_ARRAY) {
                StrBuf_putc(b, '[');
                if (dim->arr_len != NULL) {
                    a_expr(b, dim->arr_len);
                }
                StrBuf_putc(b, ']');
                dim = dim->inner;
            }
            break;
        }
        case TY_FUNC: {
            StrBuf_puts(b, "def(");
            size_t i;
            for (i = 0; i < t->ntargs; i += 1) {
                if (i != 0) {
                    StrBuf_puts(b, ", ");
                }
                a_type(b, t->targs[i], 0);
            }
            StrBuf_putc(b, ')');
            if (!(t->inner == NULL || (t->inner->kind == TY_NAME && strcmp(t->inner->name, "void") == 0))) {
                StrBuf_puts(b, " -> ");
                a_type(b, t->inner, 0);
            }
            break;
        }
        default: {
            if (t->is_const && !no_const) {
                StrBuf_puts(b, "const ");
            }
            if (t->is_volatile) {
                StrBuf_puts(b, "volatile ");
            }
            switch (t->tag_kind) {
                case TAG_STRUCT: {
                    StrBuf_puts(b, "struct ");
                    break;
                }
                case TAG_UNION: {
                    StrBuf_puts(b, "union ");
                    break;
                }
                case TAG_ENUM: {
                    StrBuf_puts(b, "enum ");
                    break;
                }
                default: {
                    ;
                    break;
                }
            }
            StrBuf_puts(b, (t->name != NULL ? t->name : "void"));
            if (t->ntargs > 0) {
                StrBuf_putc(b, '<');
                size_t j;
                for (j = 0; j < t->ntargs; j += 1) {
                    if (j != 0) {
                        StrBuf_puts(b, ", ");
                    }
                    a_type(b, t->targs[j], 0);
                }
                StrBuf_putc(b, '>');
            }
            break;
        }
    }
}

static void a_expr(StrBuf *b, Expr *e) {
    if (e == NULL) {
        StrBuf_puts(b, "()");
        return;
    }
    switch (e->kind) {
        case EX_IDENT:
        case EX_NUMBER:
        case EX_STRING:
        case EX_CHARLIT: {
            StrBuf_puts(b, (e->text != NULL ? e->text : "\?"));
            break;
        }
        case EX_TRUE: {
            StrBuf_puts(b, "True");
            break;
        }
        case EX_FALSE: {
            StrBuf_puts(b, "False");
            break;
        }
        case EX_NONE: {
            StrBuf_puts(b, "None");
            break;
        }
        case EX_UNARY: {
            StrBuf_puts(b, a_op(e->op));
            a_expr(b, e->lhs);
            break;
        }
        case EX_BINARY: {
            StrBuf_putc(b, '(');
            a_expr(b, e->lhs);
            StrBuf_puts(b, a_op(e->op));
            a_expr(b, e->rhs);
            StrBuf_putc(b, ')');
            break;
        }
        case EX_TERNARY: {
            StrBuf_putc(b, '(');
            a_expr(b, e->lhs);
            StrBuf_puts(b, " if ");
            a_expr(b, e->cond);
            StrBuf_puts(b, " else ");
            a_expr(b, e->rhs);
            StrBuf_putc(b, ')');
            break;
        }
        case EX_CALL: {
            a_expr(b, e->lhs);
            StrBuf_putc(b, '(');
            size_t i;
            for (i = 0; i < e->nargs; i += 1) {
                if (i != 0) {
                    StrBuf_puts(b, ", ");
                }
                a_expr(b, e->args[i]);
            }
            StrBuf_putc(b, ')');
            break;
        }
        case EX_INDEX: {
            a_expr(b, e->lhs);
            StrBuf_putc(b, '[');
            a_expr(b, e->rhs);
            StrBuf_putc(b, ']');
            break;
        }
        case EX_FIELD: {
            a_expr(b, e->lhs);
            StrBuf_puts(b, a_op(e->op));
            StrBuf_puts(b, (e->field != NULL ? e->field : "\?"));
            break;
        }
        case EX_CAST: {
            a_type(b, e->cast_type, 0);
            StrBuf_putc(b, '(');
            a_expr(b, e->lhs);
            StrBuf_putc(b, ')');
            break;
        }
        case EX_TYPEREF: {
            a_type(b, e->cast_type, 0);
            break;
        }
        case EX_INITLIST: {
            StrBuf_putc(b, '{');
            size_t j;
            for (j = 0; j < e->nargs; j += 1) {
                if (j != 0) {
                    StrBuf_puts(b, ", ");
                }
                a_expr(b, e->args[j]);
            }
            StrBuf_putc(b, '}');
            break;
        }
        case EX_DESIG: {
            if (e->field != NULL) {
                StrBuf_putc(b, '.');
                StrBuf_puts(b, e->field);
            } else {
                StrBuf_putc(b, '[');
                a_expr(b, e->rhs);
                StrBuf_putc(b, ']');
            }
            StrBuf_puts(b, " = ");
            a_expr(b, e->lhs);
            break;
        }
        default: {
            StrBuf_printf(b, "(k%d", (int32_t)e->kind);
            if (e->lhs != NULL) {
                StrBuf_putc(b, ' ');
                a_expr(b, e->lhs);
            }
            if (e->rhs != NULL) {
                StrBuf_putc(b, ' ');
                a_expr(b, e->rhs);
            }
            size_t k;
            for (k = 0; k < e->nargs; k += 1) {
                StrBuf_putc(b, ' ');
                a_expr(b, e->args[k]);
            }
            StrBuf_putc(b, ')');
            break;
        }
    }
}

static void a_tparams(StrBuf *b, char **names, char **bounds, int32_t n) {
    if (n <= 0) {
        return;
    }
    StrBuf_putc(b, '<');
    size_t i;
    for (i = 0; i < n; i += 1) {
        if (i != 0) {
            StrBuf_puts(b, ", ");
        }
        StrBuf_puts(b, names[i]);
        if (bounds != NULL && bounds[i] != NULL) {
            StrBuf_puts(b, ": ");
            StrBuf_puts(b, bounds[i]);
        }
    }
    StrBuf_putc(b, '>');
}

static void a_func(StrBuf *b, Func *f, const char *owner) {
    StrBuf_puts(b, "def ");
    if (owner != NULL) {
        StrBuf_puts(b, owner);
        StrBuf_putc(b, '.');
    }
    StrBuf_puts(b, (f->name != NULL ? f->name : "\?"));
    a_tparams(b, f->tparams, f->tbounds, f->ntparams);
    StrBuf_putc(b, '(');
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        if (i != 0) {
            StrBuf_puts(b, ", ");
        }
        Param *p = &f->params[i];
        switch (p->byref) {
            case 1: {
                StrBuf_puts(b, "out ");
                break;
            }
            case 2: {
                StrBuf_puts(b, "ref ");
                break;
            }
            case 3: {
                StrBuf_puts(b, "in ");
                break;
            }
            default: {
                ;
                break;
            }
        }
        a_type(b, p->type, 0);
        if (p->dflt != NULL) {
            StrBuf_puts(b, " = ");
            a_expr(b, p->dflt);
        }
    }
    if (f->is_varargs) {
        if (f->nparams > 0) {
            StrBuf_puts(b, ", ");
        }
        StrBuf_puts(b, "...");
    }
    StrBuf_putc(b, ')');
    if (!(f->ret == NULL || (f->ret->kind == TY_NAME && strcmp(f->ret->name, "void") == 0))) {
        StrBuf_puts(b, " -> ");
        a_type(b, f->ret, 0);
    }
    StrBuf_putc(b, '\n');
}

static void a_agg(StrBuf *b, Decl *d, const char *word) {
    StrBuf_puts(b, word);
    StrBuf_putc(b, ' ');
    StrBuf_puts(b, (d->name != NULL ? d->name : "\?"));
    a_tparams(b, d->tparams, d->tbounds, d->ntparams);
    if (d->is_fwd) {
        StrBuf_puts(b, " (fwd)\n");
        return;
    }
    StrBuf_puts(b, " {");
    size_t i;
    for (i = 0; i < d->nfields; i += 1) {
        if (i != 0) {
            StrBuf_puts(b, ", ");
        }
        Field *fl = &d->fields[i];
        StrBuf_puts(b, (fl->name != NULL ? fl->name : "_"));
        StrBuf_puts(b, ": ");
        a_type(b, fl->type, 0);
        if (fl->bit_width >= 0) {
            StrBuf_printf(b, ":%d", fl->bit_width);
        }
    }
    StrBuf_puts(b, "}\n");
    size_t j;
    for (j = 0; j < d->nmethods; j += 1) {
        a_func(b, d->methods[j], d->name);
    }
}

static int a_is_public(Decl *d, int is_header) {
    if (is_header) {
        return 1;
    }
    switch (d->kind) {
        case DL_FUNC: {
            return d->func != NULL && !d->func->is_static;
        }
        case DL_VAR: {
            return !d->is_static;
        }
        default: {
            return 1;
        }
    }
}

static void a_doc(StrBuf *b, const char *owner, const char *name, const char *doc) {
    if (doc == NULL || doc[0] == '\0') {
        return;
    }
    size_t n0 = strlen(doc);
    if (n0 >= 6 && doc[0] == '"' && doc[1] == '"' && doc[2] == '"') {
        doc = doc + 3;
        n0 -= 6;
    } else if (n0 >= 2 && doc[0] == '"') {
        doc = doc + 1;
        n0 -= 2;
    } else {
        n0 = strlen(doc);
    }
    if (owner != NULL) {
        StrBuf_printf(b, "#doc %s.%s ", owner, name);
    } else {
        StrBuf_printf(b, "#doc %s ", name);
    }
    size_t i = 0;
    size_t n = n0;
    while (i < n) {
        char c = doc[i];
        if (c == '\n') {
            StrBuf_puts(b, "\\n");
        } else if (c == '\\') {
            StrBuf_puts(b, "\\\\");
        } else {
            StrBuf_putc(b, c);
        }
        i += 1;
    }
    StrBuf_putc(b, '\n');
}

static void p_type(StrBuf *b, PsType *t);

static void p_func(StrBuf *b, PsFunc *f, const char *owner);

static void p_type(StrBuf *b, PsType *t) {
    if (t == NULL) {
        StrBuf_puts(b, "void");
        return;
    }
    switch (t->kind) {
        case PT_INT: {
            if (t->width == 0) {
                StrBuf_puts(b, "int");
            } else {
                StrBuf_printf(b, "%c%d", (t->uns ? 'u' : 'i'), t->width);
            }
            break;
        }
        case PT_FLOAT: {
            StrBuf_puts(b, (t->width == 0 ? "float" : "f32"));
            break;
        }
        case PT_BOOL: {
            StrBuf_puts(b, "bool");
            break;
        }
        case PT_STR: {
            StrBuf_puts(b, "str");
            break;
        }
        case PT_ANY: {
            StrBuf_puts(b, "any");
            break;
        }
        case PT_VOID: {
            StrBuf_puts(b, "void");
            break;
        }
        case PT_NAME: {
            if (t->qual != NULL) {
                StrBuf_printf(b, "%s.", t->qual);
            }
            StrBuf_puts(b, (t->name != NULL ? t->name : "\?"));
            break;
        }
        case PT_LIST: {
            StrBuf_puts(b, "List<");
            p_type(b, t->inner);
            StrBuf_putc(b, '>');
            break;
        }
        case PT_SET: {
            StrBuf_puts(b, "Set<");
            p_type(b, t->inner);
            StrBuf_putc(b, '>');
            break;
        }
        case PT_DICT: {
            StrBuf_puts(b, "Dict<");
            p_type(b, t->key);
            StrBuf_puts(b, ", ");
            p_type(b, t->inner);
            StrBuf_putc(b, '>');
            break;
        }
        case PT_OPT: {
            p_type(b, t->inner);
            StrBuf_putc(b, '\?');
            break;
        }
        case PT_ARRAY: {
            p_type(b, t->inner);
            StrBuf_puts(b, "[]");
            break;
        }
        case PT_TUPLE: {
            StrBuf_putc(b, '(');
            size_t i;
            for (i = 0; i < t->nparams; i += 1) {
                if (i > 0) {
                    StrBuf_puts(b, ", ");
                }
                p_type(b, t->params[i]);
            }
            StrBuf_putc(b, ')');
            break;
        }
        case PT_FUNC: {
            StrBuf_puts(b, "def(");
            size_t i;
            for (i = 0; i < t->nparams; i += 1) {
                if (i > 0) {
                    StrBuf_puts(b, ", ");
                }
                p_type(b, t->params[i]);
            }
            StrBuf_puts(b, ") -> ");
            p_type(b, t->inner);
            break;
        }
        case PT_TASK: {
            StrBuf_puts(b, "Task<");
            p_type(b, t->inner);
            StrBuf_putc(b, '>');
            break;
        }
        case PT_WORKER: {
            StrBuf_puts(b, "Worker<");
            p_type(b, t->inner);
            StrBuf_putc(b, '>');
            break;
        }
        case PT_BYTES: {
            StrBuf_puts(b, "bytes");
            break;
        }
        case PT_VIEW: {
            StrBuf_puts(b, "View<");
            p_type(b, t->inner);
            StrBuf_putc(b, '>');
            break;
        }
        case PT_FILE: {
            StrBuf_puts(b, "File");
            break;
        }
        case PT_BUFFER: {
            StrBuf_puts(b, "Buffer");
            break;
        }
        case PT_CONN: {
            StrBuf_puts(b, "Socket");
            break;
        }
        case PT_PROC: {
            StrBuf_puts(b, "proc");
            break;
        }
        case PT_TIMER: {
            StrBuf_puts(b, "Timer");
            break;
        }
        case PT_DYN: {
            StrBuf_puts(b, "dyn ");
            StrBuf_puts(b, (t->name != NULL ? t->name : "\?"));
            break;
        }
        default: {
            StrBuf_puts(b, "\?");
            break;
        }
    }
}

static void p_func(StrBuf *b, PsFunc *f, const char *owner) {
    StrBuf_puts(b, (f->is_async ? "async def " : "def "));
    if (owner != NULL) {
        StrBuf_printf(b, "%s.", owner);
    }
    StrBuf_puts(b, (f->name != NULL ? f->name : "\?"));
    StrBuf_putc(b, '(');
    int first = 1;
    size_t i;
    for (i = 0; i < f->nparams; i += 1) {
        if (owner != NULL && i == 0 && f->params[i].name != NULL && strcmp(f->params[i].name, "self") == 0) {
            continue;
        }
        if (!first) {
            StrBuf_puts(b, ", ");
        }
        first = 0;
        p_type(b, f->params[i].type);
    }
    StrBuf_puts(b, ") -> ");
    p_type(b, f->ret);
    StrBuf_putc(b, '\n');
}

static int ps_public(PsDecl *d) {
    if (d->kind == PD_FUNC && d->func != NULL) {
        return !d->func->is_private;
    }
    return !d->is_private;
}

void ps_api_dump(PsModule *m, StrBuf *b) {
    StrBuf_printf(b, "== %s\n", m->path);
    size_t start = b->len;
    size_t i;
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d = m->decls[i];
        if (!ps_public(d)) {
            continue;
        }
        switch (d->kind) {
            case PD_IMPORT: {
                StrBuf_printf(b, "import %s\n", (d->path != NULL ? d->path : "\?"));
                break;
            }
            case PD_INCLUDE: {
                if (d->is_pmod) {
                    StrBuf_printf(b, "import \"%s\"\n", (d->path != NULL ? d->path : "\?"));
                } else {
                    StrBuf_printf(b, "include <%s>\n", (d->path != NULL ? d->path : "\?"));
                }
                break;
            }
            case PD_ENUM: {
                StrBuf_printf(b, "enum %s {", d->name);
                size_t j;
                for (j = 0; j < d->nitems; j += 1) {
                    if (j > 0) {
                        StrBuf_puts(b, ", ");
                    }
                    StrBuf_puts(b, d->items[j].name);
                }
                StrBuf_puts(b, "}\n");
                break;
            }
            case PD_RECORD:
            case PD_STRUCT: {
                StrBuf_printf(b, "%s %s {", (d->kind == PD_RECORD ? "record" : "struct"), d->name);
                size_t j;
                for (j = 0; j < d->nfields; j += 1) {
                    if (j > 0) {
                        StrBuf_puts(b, ", ");
                    }
                    StrBuf_printf(b, "%s: ", d->fields[j].name);
                    p_type(b, d->fields[j].type);
                }
                StrBuf_puts(b, "}\n");
                for (j = 0; j < d->nmethods; j += 1) {
                    if (!d->methods[j]->is_private) {
                        p_func(b, d->methods[j], d->name);
                    }
                }
                break;
            }
            case PD_TRAIT: {
                StrBuf_printf(b, "trait %s\n", d->name);
                size_t j;
                for (j = 0; j < d->nmethods; j += 1) {
                    p_func(b, d->methods[j], d->name);
                }
                break;
            }
            case PD_FUNC: {
                if (d->func != NULL) {
                    p_func(b, d->func, NULL);
                }
                break;
            }
            case PD_VAR: {
                StrBuf_printf(b, "%s %s: ", (d->is_const ? "const" : "var"), d->name);
                p_type(b, d->type);
                StrBuf_putc(b, '\n');
                break;
            }
            default: {
                ;
                break;
            }
        }
    }
    uint64_t h = hash_bytes(b->data + start, b->len - start);
    StrBuf_printf(b, "#hash %016llx\n", h);
    a_doc(b, NULL, ".", m->doc);
    for (i = 0; i < m->ndecls; i += 1) {
        PsDecl *d2 = m->decls[i];
        if (!ps_public(d2)) {
            continue;
        }
        if (d2->kind == PD_FUNC && d2->func != NULL) {
            a_doc(b, NULL, d2->func->name, d2->func->doc);
            continue;
        }
        if (d2->name == NULL) {
            continue;
        }
        a_doc(b, NULL, d2->name, d2->doc);
        size_t j;
        for (j = 0; j < d2->nmethods; j += 1) {
            a_doc(b, d2->name, d2->methods[j]->name, d2->methods[j]->doc);
        }
    }
}

void api_dump(Module *m, StrBuf *b) {
    StrBuf_printf(b, "== %s\n", m->path);
    size_t start = b->len;
    size_t i;
    for (i = 0; i < m->ndecls; i += 1) {
        Decl *d = m->decls[i];
        if (!a_is_public(d, m->is_header)) {
            continue;
        }
        switch (d->kind) {
            case DL_IMPORT: {
                if (d->is_include) {
                    StrBuf_printf(b, "include <%s>\n", d->import_path);
                } else if (d->import_system) {
                    StrBuf_printf(b, "import <%s>\n", d->import_path);
                } else {
                    StrBuf_printf(b, "import \"%s\"", d->import_path);
                    if (d->import_alias != NULL) {
                        StrBuf_printf(b, " as %s", d->import_alias);
                    }
                    StrBuf_putc(b, '\n');
                }
                break;
            }
            case DL_FUNC: {
                if (d->func != NULL && !d->func->is_comptime) {
                    int dup = 0;
                    size_t pj;
                    for (pj = 0; pj < i; pj += 1) {
                        Decl *pd = m->decls[pj];
                        if (pd->kind == DL_FUNC && pd->func != NULL && pd->func->name != NULL && d->func->name != NULL) {
                            if (strcmp(pd->func->name, d->func->name) == 0) {
                                dup = 1;
                                break;
                            }
                        }
                    }
                    if (!dup) {
                        a_func(b, d->func, NULL);
                    }
                }
                break;
            }
            case DL_STRUCT: {
                a_agg(b, d, (d->is_record ? "record" : "struct"));
                break;
            }
            case DL_UNION: {
                a_agg(b, d, "union");
                break;
            }
            case DL_TRAIT: {
                StrBuf_printf(b, "trait %s", (d->name != NULL ? d->name : "\?"));
                if (d->assoc != NULL) {
                    StrBuf_printf(b, " (type %s)", d->assoc);
                }
                StrBuf_puts(b, " {");
                size_t j;
                for (j = 0; j < d->nmethods; j += 1) {
                    StrBuf_putc(b, ' ');
                    a_func(b, d->methods[j], NULL);
                }
                StrBuf_puts(b, "}\n");
                break;
            }
            case DL_ENUM: {
                StrBuf_printf(b, "enum %s {", (d->name != NULL ? d->name : "\?"));
                size_t k;
                for (k = 0; k < d->nitems; k += 1) {
                    if (k != 0) {
                        StrBuf_puts(b, ", ");
                    }
                    StrBuf_puts(b, d->items[k].name);
                    if (d->items[k].value != NULL) {
                        StrBuf_puts(b, " = ");
                        a_expr(b, d->items[k].value);
                    }
                }
                StrBuf_puts(b, "}\n");
                break;
            }
            case DL_VAR: {
                StrBuf_puts(b, (d->is_const ? "const " : "var "));
                StrBuf_puts(b, (d->name != NULL ? d->name : "\?"));
                StrBuf_puts(b, ": ");
                a_type(b, d->type, 0);
                if (d->is_const && d->init != NULL) {
                    StrBuf_puts(b, " = ");
                    a_expr(b, d->init);
                }
                StrBuf_putc(b, '\n');
                break;
            }
            case DL_DECLARE: {
                StrBuf_printf(b, "declare %s\n", (d->name != NULL ? d->name : "\?"));
                break;
            }
            case DL_IMPLEMENT: {
                StrBuf_printf(b, "implement %s", (d->name != NULL ? d->name : "\?"));
                if (d->trait_for != NULL) {
                    StrBuf_printf(b, " for %s", d->trait_for);
                }
                StrBuf_putc(b, '\n');
                break;
            }
            default: {
                ;
                break;
            }
        }
    }
    uint64_t h = hash_bytes(b->data + start, b->len - start);
    StrBuf_printf(b, "#hash %016llx\n", h);
    a_doc(b, NULL, ".", m->doc);
    for (i = 0; i < m->ndecls; i += 1) {
        Decl *d = m->decls[i];
        if (!a_is_public(d, m->is_header)) {
            continue;
        }
        if (d->kind == DL_FUNC && d->func != NULL) {
            if (d->func->body == NULL && !m->is_header) {
                continue;
            }
            a_doc(b, NULL, d->func->name, d->func->doc);
            continue;
        }
        if (d->name == NULL) {
            continue;
        }
        a_doc(b, NULL, d->name, d->doc);
        size_t j;
        for (j = 0; j < d->nmethods; j += 1) {
            a_doc(b, d->name, d->methods[j]->name, d->methods[j]->doc);
        }
    }
}
