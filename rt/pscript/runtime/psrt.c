#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "psrt.h"

const int PS_BLOCK_BYTES = 1 << 20;

const int PS_GC_BYTES = 1 << 21;

const int PS_GC_OBJECTS = 200000;

static const int32_t PS_POISON = 0xDD;

static const int32_t PS_GRAVE_MAX = 16;

static int64_t ps_stress_n = -1;

static int64_t ps_stress_tick = 0;

static PsBlock *ps_graveyard = NULL;

static int32_t ps_grave_n = 0;

static int64_t ps_gc_stress(void) {
    if (ps_stress_n < 0) {
        const char *e = getenv("PSCRIPT_GC_STRESS");
        ps_stress_n = 0;
        if (e != NULL && e[0] != '\0') {
            int64_t v = (int64_t)atoll(e);
            ps_stress_n = (v > 0 ? v : 0);
        }
    }
    return ps_stress_n;
}

static int ps_stress_due(void) {
    int64_t n = ps_gc_stress();
    if (n == 0) {
        return 0;
    }
    ps_stress_tick += 1;
    if (ps_stress_tick < n) {
        return 0;
    }
    ps_stress_tick = 0;
    return 1;
}

static PsBlock *ps_new_block(size_t min) {
    size_t cap = (min < (size_t)PS_BLOCK_BYTES ? (size_t)PS_BLOCK_BYTES : min);
    PsBlock *b = malloc(sizeof(PsBlock));
    if (b == NULL) {
        fprintf(stderr, "pscript: out of memory\n");
        exit(1);
    }
    b->base = malloc(cap);
    if (b->base == NULL) {
        fprintf(stderr, "pscript: out of memory\n");
        exit(1);
    }
    b->next = NULL;
    b->used = 0;
    b->cap = cap;
    return b;
}

static void ps_free_blocks(PsBlock *b) {
    if (ps_gc_stress() != (int64_t)0) {
        while (b != NULL) {
            PsBlock *n = b->next;
            memset(b->base, PS_POISON, b->cap);
            b->next = ps_graveyard;
            ps_graveyard = b;
            ps_grave_n += 1;
            b = n;
        }
        while (ps_grave_n > PS_GRAVE_MAX) {
            PsBlock *prev = NULL;
            PsBlock *cur = ps_graveyard;
            while (cur != NULL && cur->next != NULL) {
                prev = cur;
                cur = cur->next;
            }
            if (cur == NULL) {
                break;
            }
            if (prev == NULL) {
                ps_graveyard = NULL;
            } else {
                prev->next = NULL;
            }
            free(cur->base);
            free(cur);
            ps_grave_n -= 1;
        }
        return;
    }
    while (b != NULL) {
        PsBlock *n = b->next;
        free(b->base);
        free(b);
        b = n;
    }
}

void ps_ctx_init(PsCtx *ctx) {
    ctx->blocks = ps_new_block(0);
    ctx->frames = NULL;
    ctx->roots = NULL;
    ctx->exc = NULL;
    ctx->live = 0;
    ctx->alloced = 0;
    ctx->nalloc = 0;
    ctx->ngc = 0;
    ctx->ready = NULL;
    ctx->ready_tail = NULL;
    ctx->globals = NULL;
    ctx->parent = NULL;
    ctx->workers = NULL;
    ctx->timers = NULL;
    ctx->waiters = NULL;
    ctx->io_r = -1;
    ctx->io_w = -1;
    ctx->nogc = 0;
    ctx->nogc_budget = (size_t)0;
    ctx->nogc_start = (size_t)0;
}

int ps_ctx_done(PsCtx *ctx) {
    ps_sched_drain(ctx);
    ps_join_all(ctx);
    int rc = 0;
    if (ctx->exc != NULL) {
        PsErr *e = ctx->exc;
        fflush(stdout);
        fprintf(stderr, "%s:%d: error: %s\n", (e->file != NULL ? e->file : "\?"), e->line, (e->msg != NULL ? e->msg->data : ""));
        rc = 1;
    }
    ps_free_blocks(ctx->blocks);
    ctx->blocks = NULL;
    PsRoot *r = ctx->roots;
    while (r != NULL) {
        PsRoot *nx = r->next;
        free(r);
        r = nx;
    }
    ctx->roots = NULL;
    return rc;
}

void *ps_alloc(PsCtx *ctx, size_t size, int32_t ty) {
    size_t n = (size + 15) & ~(size_t)15;
    PsBlock *b = ctx->blocks;
    if (b == NULL || b->used + n > b->cap) {
        PsBlock *nb = ps_new_block(n);
        nb->next = ctx->blocks;
        ctx->blocks = nb;
        b = nb;
    }
    char *p = b->base + b->used;
    b->used += n;
    ctx->alloced += n;
    ctx->nalloc += 1;
    PsObj *o = (PsObj *)p;
    o->ty = ty;
    o->size = (uint32_t)n;
    o->fwd = NULL;
    return p;
}

void *ps_new(PsCtx *ctx, const PsDesc *d, size_t size) {
    char *p = (char *)ps_alloc(ctx, size, PS_TY_USER);
    memset(p + sizeof(PsObj), 0, size - sizeof(PsObj));
    PsUser *u = (PsUser *)p;
    u->desc = d;
    return p;
}

static const const PsDesc PS_POD_DESC = {"message", NULL};

static void ps_gather_trace(void *o, PsBlock *to) {
    PsObj **p = (PsObj **)((char *)o + sizeof(PsUser));
    *p = ps_forward(to, *p);
}

static const const PsDesc PS_GATHER_DESC = {"gather", ps_gather_trace};

static const const PsDesc PS_REFMSG_DESC = {"message", ps_gather_trace};

static char *ps_dup(const char *s) {
    size_t n = strlen(s);
    char *p = (char *)malloc(n + 1);
    memcpy(p, s, n + 1);
    return p;
}

static void ps_msg_push(PsMsg **head, PsMsg **tail, const void *p, size_t size) {
    PsMsg *m = (PsMsg *)malloc(sizeof(PsMsg));
    m->next = NULL;
    m->size = size;
    m->data = (char *)malloc((size > 0 ? size : 1));
    if (size > 0) {
        memcpy(m->data, p, size);
    }
    if (*tail == NULL) {
        *head = m;
        *tail = m;
    } else {
        (*tail)->next = m;
        *tail = m;
    }
}

static PsMsg *ps_msg_pop(PsMsg **head, PsMsg **tail) {
    PsMsg *m = *head;
    if (m == NULL) {
        return NULL;
    }
    *head = m->next;
    if (*head == NULL) {
        *tail = NULL;
    }
    m->next = NULL;
    return m;
}

static void ps_pipe_open(int *rp, int *wp) {
    int fds[2];
    fds[0] = -1;
    fds[1] = -1;
    if (pipe(fds) != 0) {
        *rp = -1;
        *wp = -1;
        return;
    }
    fcntl(fds[0], 4, 2048);
    fcntl(fds[1], 4, 2048);
    *rp = fds[0];
    *wp = fds[1];
}

static void ps_pipe_wake(int fd) {
    if (fd < 0) {
        return;
    }
    char one = 'x';
    if (write(fd, &one, (size_t)1) < 0) {
        ;
    }
}

static void ps_pipe_drain(int fd) {
    if (fd < 0) {
        return;
    }
    char buf[64];
    while (read(fd, buf, sizeof(buf)) > 0) {
        ;
    }
}

static void ps_pipe_close(int fd) {
    if (fd >= 0) {
        close(fd);
    }
}

PsWorker *ps_worker_new(PsCtx *ctx, void *(*entry)(void *), void *args, size_t nargs) {
    PsWorkerBlk *blk = (PsWorkerBlk *)malloc(sizeof(PsWorkerBlk));
    memset(blk, 0, sizeof(PsWorkerBlk));
    pthread_mutex_init(&blk->mu, NULL);
    pthread_cond_init(&blk->cv, NULL);
    ps_pipe_open(&blk->up_r, &blk->up_w);
    ps_pipe_open(&blk->dn_r, &blk->dn_w);
    blk->nargs = nargs;
    blk->args = malloc((nargs > 0 ? nargs : 1));
    if (nargs > 0) {
        memcpy(blk->args, args, nargs);
    }
    blk->next = ctx->workers;
    ctx->workers = blk;
    PsWorker *w = (PsWorker *)ps_alloc(ctx, sizeof(PsWorker), PS_TY_WORKER);
    w->blk = blk;
    if (pthread_create(&blk->thread, NULL, entry, (void *)blk) != 0) {
        blk->done = 1;
        blk->failed = 1;
        blk->err = ps_dup("could not start the worker thread");
        return w;
    }
    blk->started = 1;
    return w;
}

char *ps_str_export(PsStr *s) {
    size_t n = (s != NULL ? (size_t)s->len : 0);
    char *p = (char *)malloc(n + 1);
    if (s != NULL && n > 0) {
        memcpy(p, s->data, n);
    }
    p[n] = '\0';
    return p;
}

PsStr *ps_str_import(PsCtx *ctx, char *p) {
    PsStr *out = ps_str_new(ctx, p, strlen(p));
    free(p);
    return out;
}

void *ps_list_export(PsList *l) {
    int64_t n = (l != NULL ? l->len : 0);
    int32_t es = (l != NULL ? l->esize : 1);
    size_t total = sizeof(int64_t) + sizeof(int32_t) + (size_t)n * (size_t)es;
    char *p = (char *)malloc(total);
    *(int64_t *)p = n;
    *(int32_t *)(p + sizeof(int64_t)) = es;
    if (n > 0) {
        memcpy(p + sizeof(int64_t) + sizeof(int32_t), (char *)l->data + sizeof(PsArr), (size_t)n * (size_t)es);
    }
    return (void *)p;
}

PsList *ps_list_import(PsCtx *ctx, void *p) {
    char *b = (char *)p;
    int64_t n = *(int64_t *)b;
    int32_t es = *(int32_t *)(b + sizeof(int64_t));
    PsList *l = ps_list_new(ctx, es, 0, n);
    char *src = b + sizeof(int64_t) + sizeof(int32_t);
    size_t i;
    for (i = 0; i < (int32_t)n; i += 1) {
        char *dst = ps_list_push(ctx, l);
        memcpy(dst, src + (size_t)i * (size_t)es, (size_t)es);
    }
    free(p);
    return l;
}

void *ps_worker_args(void *blk) {
    return ((PsWorkerBlk *)blk)->args;
}

void ps_worker_finish(PsCtx *ctx, void *blk) {
    PsWorkerBlk *b = (PsWorkerBlk *)blk;
    pthread_mutex_lock(&b->mu);
    if (ctx->exc != NULL) {
        b->failed = 1;
        b->err = ps_dup((ctx->exc->msg != NULL ? ctx->exc->msg->data : "\?"));
        b->err_cat = ctx->exc->cat;
        ctx->exc = NULL;
    }
    b->done = 1;
    pthread_cond_broadcast(&b->cv);
    ps_pipe_wake(b->up_w);
    pthread_mutex_unlock(&b->mu);
}

static PsTask *ps_msg_task(PsCtx *ctx, PsMsg *m, size_t size);

static PsTask *ps_obj_msg_task(PsCtx *ctx, PsMsg *m, const PsShape *sh, size_t size);

static void ps_des_run(PsCtx *ctx, PsMsg *m, const PsShape *sh, void *slot, size_t size);

static int32_t ps_sh_slot(const PsShape *sh);

static int ps_sh_isref(const PsShape *sh);

PsTask *ps_recv_task(PsCtx *ctx, PsWorkerBlk *b, int32_t dir, int32_t kind, const PsShape *sh, size_t size);

static void ps_task_clear_recv(PsTask *t);

static PsMsg *ps_recv_pop(PsWorkerBlk *b, int32_t dir, int *ended);

static PsTask *ps_recv_build(PsCtx *ctx, PsMsg *m, int32_t kind, const PsShape *sh, size_t size);

static void ps_recv_finish(PsCtx *ctx, PsTask *t, PsMsg *m);

static int ps_recvs_poll(PsCtx *ctx);

static int32_t ps_recv_fds(PsCtx *ctx, int *out_bad);

static void ps_io_run(PsWork *w);

static int ps_fd_try(PsCtx *ctx, PsTask *t);

static void ps_sigpipe_noop(int sig);

static void ps_sock_nonblock(int fd);

static PsConn *ps_conn_new(PsCtx *ctx, int fd, int32_t listening);

static int ps_conn_live(PsCtx *ctx, PsConn *c, const char *what);

static PsTask *ps_fd_task(PsCtx *ctx, PsWork *w, int isref, size_t size);

static PsTask *ps_send_task(PsCtx *ctx, PsConn *c, const char *bytes, size_t n);

static int ps_file_live(PsCtx *ctx, PsFile *f, const char *what);

int ps_utf8_valid(const char *b, size_t n);

static void ps_work_free(PsWork *w);

static void ps_pool_start(void);

static void ps_io_finish(PsCtx *ctx, PsTask *t);

static void *ps_pool_thread(void *arg);

static void ps_io_ready(PsCtx *ctx);

static char *ps_dupn(const char *p, size_t n);

static void ps_sched_push(PsCtx *ctx, PsTask *t);

static void ps_pipe_open(int *rp, int *wp);

static void ps_pipe_wake(int fd);

static void ps_pipe_drain(int fd);

static void ps_pipe_close(int fd);

static const const int32_t PS_POLL_MAX = 64;

static const const int32_t PS_RECV_RAW = 0;

static const const int32_t PS_RECV_OBJ = 1;

static void ps_ser_grow(PsSer *s, size_t n) {
    if (s->len + n <= s->cap) {
        return;
    }
    size_t cap = (s->cap > 0 ? s->cap * 2 : (size_t)256);
    while (cap < s->len + n) {
        cap *= 2;
    }
    s->buf = (char *)realloc(s->buf, cap);
    s->cap = cap;
}

static void ps_ser_bytes(PsSer *s, const void *p, size_t n) {
    if (n == 0) {
        return;
    }
    ps_ser_grow(s, n);
    memcpy(s->buf + s->len, p, n);
    s->len += n;
}

static void ps_ser_u8(PsSer *s, int32_t v) {
    char b = (char)v;
    ps_ser_bytes(s, &b, (size_t)1);
}

static void ps_ser_i32(PsSer *s, int32_t v) {
    ps_ser_bytes(s, &v, sizeof(int32_t));
}

static void ps_ser_i64(PsSer *s, int64_t v) {
    ps_ser_bytes(s, &v, sizeof(int64_t));
}

static size_t ps_ptr_hash(void *o) {
    size_t h = (size_t)o;
    h = h >> 4;
    h *= (size_t)2654435761;
    return h;
}

static void ps_ser_rehash(PsSer *s) {
    size_t ns = (s->nslots > 0 ? s->nslots * 2 : (size_t)64);
    void **nk = (void **)calloc(ns, sizeof(*nk));
    int32_t *nv = (int32_t *)calloc(ns, sizeof(*nv));
    size_t i = 0;
    while (i < s->nslots) {
        if (s->keys[i] != NULL) {
            size_t j = ps_ptr_hash(s->keys[i]) & (ns - 1);
            while (nk[j] != NULL) {
                j = (j + 1) & (ns - 1);
            }
            nk[j] = s->keys[i];
            nv[j] = s->vals[i];
        }
        i += 1;
    }
    free(s->keys);
    free(s->vals);
    s->keys = nk;
    s->vals = nv;
    s->nslots = ns;
}

static int ps_ser_seen(PsSer *s, void *o, int32_t *idx) {
    if (s->nslots == 0) {
        return 0;
    }
    size_t j = ps_ptr_hash(o) & (s->nslots - 1);
    while (s->keys[j] != NULL) {
        if (s->keys[j] == o) {
            *idx = s->vals[j];
            return 1;
        }
        j = (j + 1) & (s->nslots - 1);
    }
    return 0;
}

static int32_t ps_ser_add(PsSer *s, void *o) {
    if (s->nslots == 0 || (size_t)(s->used + 1) * 2 > s->nslots) {
        ps_ser_rehash(s);
    }
    size_t j = ps_ptr_hash(o) & (s->nslots - 1);
    while (s->keys[j] != NULL) {
        j = (j + 1) & (s->nslots - 1);
    }
    s->keys[j] = o;
    s->vals[j] = s->count;
    s->used += 1;
    s->count += 1;
    return s->count - 1;
}

static int32_t ps_sh_slot(const PsShape *sh) {
    return (sh->kind == PS_SH_POD ? (int32_t)sh->size : (int32_t)sizeof(PsStrPtr));
}

static int ps_sh_isref(const PsShape *sh) {
    return sh->kind != PS_SH_POD;
}

void ps_ser_value(PsSer *s, const PsShape *sh, const void *slot) {
    if (sh->kind == PS_SH_POD) {
        ps_ser_bytes(s, slot, (size_t)sh->size);
        return;
    }
    void *o = *(void **)slot;
    if (o == NULL) {
        ps_ser_u8(s, 0);
        return;
    }
    int32_t seen = 0;
    if (ps_ser_seen(s, o, &seen)) {
        ps_ser_u8(s, 2);
        ps_ser_i32(s, seen);
        return;
    }
    ps_ser_u8(s, 1);
    ps_ser_add(s, o);
    switch (sh->kind) {
        case PS_SH_STR: {
            PsStr *st = (PsStr *)o;
            ps_ser_i64(s, (int64_t)st->len);
            ps_ser_bytes(s, st->data, (size_t)st->len);
            break;
        }
        case PS_SH_LIST: {
            PsList *l = (PsList *)o;
            ps_ser_i64(s, l->len);
            int64_t i = 0;
            while (i < l->len) {
                ps_ser_value(s, sh->inner, ps_list_base(l) + (size_t)i * (size_t)l->esize);
                i += 1;
            }
            break;
        }
        case PS_SH_SET: {
            PsDict *d1 = (PsDict *)o;
            ps_ser_i64(s, ps_dict_len(d1));
            int64_t k1 = 0;
            while (k1 < ps_dict_cap(d1)) {
                if (ps_dict_live(d1, k1)) {
                    ps_ser_value(s, sh->inner, ps_dict_key_at(d1, k1));
                }
                k1 += 1;
            }
            break;
        }
        case PS_SH_DICT: {
            PsDict *d2 = (PsDict *)o;
            ps_ser_i64(s, ps_dict_len(d2));
            int64_t k2 = 0;
            while (k2 < ps_dict_cap(d2)) {
                if (ps_dict_live(d2, k2)) {
                    ps_ser_value(s, sh->key, ps_dict_key_at(d2, k2));
                    ps_ser_value(s, sh->inner, ps_dict_val_at(d2, k2));
                }
                k2 += 1;
            }
            break;
        }
        case PS_SH_STRUCT: {
            if (sh->ser != NULL) {
                sh->ser(s, o);
            }
            break;
        }
        default: {
            ;
            break;
        }
    }
}

static const char *ps_des_take(PsDes *d, size_t n) {
    if (d->pos + n > d->len) {
        d->bad = 1;
        return NULL;
    }
    const char *p = d->buf + d->pos;
    d->pos += n;
    return p;
}

static int32_t ps_des_u8(PsDes *d) {
    const char *p = ps_des_take(d, (size_t)1);
    return (p != NULL ? (int32_t)*p : 0);
}

static int32_t ps_des_i32(PsDes *d) {
    int32_t v = 0;
    const char *p = ps_des_take(d, sizeof(int32_t));
    if (p != NULL) {
        memcpy(&v, p, sizeof(int32_t));
    }
    return v;
}

static int64_t ps_des_i64(PsDes *d) {
    int64_t v = 0;
    const char *p = ps_des_take(d, sizeof(int64_t));
    if (p != NULL) {
        memcpy(&v, p, sizeof(int64_t));
    }
    return v;
}

static int32_t ps_des_reserve(PsDes *d) {
    if (d->nbuilt >= d->cbuilt) {
        d->cbuilt = (d->cbuilt > 0 ? d->cbuilt * 2 : 32);
        d->built = (void **)realloc(d->built, (size_t)d->cbuilt * sizeof(*d->built));
    }
    d->built[d->nbuilt] = NULL;
    d->nbuilt += 1;
    return d->nbuilt - 1;
}

void ps_des_value(PsCtx *ctx, PsDes *d, const PsShape *sh, void *slot) {
    if (sh->kind == PS_SH_POD) {
        const char *p = ps_des_take(d, (size_t)sh->size);
        if (p != NULL) {
            memcpy(slot, p, (size_t)sh->size);
        } else {
            memset(slot, 0, (size_t)sh->size);
        }
        return;
    }
    void **out = (void **)slot;
    int32_t tag = ps_des_u8(d);
    if (tag == 0 || d->bad != 0) {
        *out = NULL;
        return;
    }
    if (tag == 2) {
        int32_t i0 = ps_des_i32(d);
        *out = (i0 >= 0 && i0 < d->nbuilt ? d->built[i0] : NULL);
        return;
    }
    int32_t id = ps_des_reserve(d);
    switch (sh->kind) {
        case PS_SH_STR: {
            int64_t n1 = ps_des_i64(d);
            const char *b1 = ps_des_take(d, (size_t)n1);
            PsStr *v1 = ps_str_new(ctx, (b1 != NULL ? b1 : ""), (b1 != NULL ? (size_t)n1 : (size_t)0));
            d->built[id] = (void *)v1;
            *out = (void *)v1;
            break;
        }
        case PS_SH_LIST: {
            int64_t n2 = ps_des_i64(d);
            PsList *l2 = ps_list_new(ctx, ps_sh_slot(sh->inner), ps_sh_isref(sh->inner), n2);
            d->built[id] = (void *)l2;
            *out = (void *)l2;
            int64_t i2 = 0;
            while (i2 < n2 && d->bad == 0) {
                char *dst = ps_list_push(ctx, l2);
                ps_des_value(ctx, d, sh->inner, dst);
                i2 += 1;
            }
            break;
        }
        case PS_SH_SET: {
            int64_t n3 = ps_des_i64(d);
            int32_t ks3 = ps_sh_slot(sh->inner);
            PsDict *s3 = ps_dict_new(ctx, ks3, 0, sh->kkind, ps_sh_isref(sh->inner), 0);
            d->built[id] = (void *)s3;
            *out = (void *)s3;
            char *kb3 = (char *)malloc((size_t)ks3);
            int64_t i3 = 0;
            while (i3 < n3 && d->bad == 0) {
                ps_des_value(ctx, d, sh->inner, kb3);
                ps_dict_put(ctx, s3, kb3);
                i3 += 1;
            }
            free(kb3);
            break;
        }
        case PS_SH_DICT: {
            int64_t n4 = ps_des_i64(d);
            int32_t ks4 = ps_sh_slot(sh->key);
            int32_t vs4 = ps_sh_slot(sh->inner);
            PsDict *d4 = ps_dict_new(ctx, ks4, vs4, sh->kkind, ps_sh_isref(sh->key), ps_sh_isref(sh->inner));
            d->built[id] = (void *)d4;
            *out = (void *)d4;
            char *kb4 = (char *)malloc((size_t)ks4);
            char *vb4 = (char *)malloc((size_t)vs4);
            int64_t i4 = 0;
            while (i4 < n4 && d->bad == 0) {
                ps_des_value(ctx, d, sh->key, kb4);
                ps_des_value(ctx, d, sh->inner, vb4);
                memcpy(ps_dict_put(ctx, d4, kb4), vb4, (size_t)vs4);
                i4 += 1;
            }
            free(kb4);
            free(vb4);
            break;
        }
        case PS_SH_STRUCT: {
            void *o5 = ps_new(ctx, sh->desc, (size_t)sh->size);
            d->built[id] = o5;
            *out = o5;
            if (sh->des != NULL) {
                sh->des(ctx, d, o5);
            }
            break;
        }
        default: {
            *out = NULL;
            break;
        }
    }
}

static char *ps_ser_run(const PsShape *sh, const void *slot, size_t *out_n) {
    PsSer s = {NULL, 0, 0, NULL, NULL, 0, 0, 0};
    ps_ser_value(&s, sh, slot);
    free(s.keys);
    free(s.vals);
    *out_n = s.len;
    return s.buf;
}

int ps_send_obj_up(PsCtx *ctx, const PsShape *sh, const void *slot) {
    PsWorkerBlk *b = ctx->parent;
    if (b == NULL) {
        return 0;
    }
    size_t n = 0;
    char *buf = ps_ser_run(sh, slot, &n);
    pthread_mutex_lock(&b->mu);
    ps_msg_push(&b->up_head, &b->up_tail, buf, n);
    pthread_cond_broadcast(&b->cv);
    ps_pipe_wake(b->up_w);
    pthread_mutex_unlock(&b->mu);
    free(buf);
    return 1;
}

int ps_send_obj_down(PsWorker *w, const PsShape *sh, const void *slot) {
    if (w == NULL || w->blk == NULL) {
        return 0;
    }
    PsWorkerBlk *b = w->blk;
    if (b->done != 0) {
        return 0;
    }
    size_t n = 0;
    char *buf = ps_ser_run(sh, slot, &n);
    pthread_mutex_lock(&b->mu);
    ps_msg_push(&b->down_head, &b->down_tail, buf, n);
    pthread_cond_broadcast(&b->cv);
    ps_pipe_wake(b->dn_w);
    pthread_mutex_unlock(&b->mu);
    free(buf);
    return 1;
}

static void ps_des_run(PsCtx *ctx, PsMsg *m, const PsShape *sh, void *slot, size_t size) {
    memset(slot, 0, size);
    if (m == NULL) {
        return;
    }
    PsDes d = {m->data, m->size, 0, NULL, 0, 0, 0};
    ps_des_value(ctx, &d, sh, slot);
    free(d.built);
}

static PsTask *ps_obj_msg_task(PsCtx *ctx, PsMsg *m, const PsShape *sh, size_t size) {
    PsTask *t = ps_msg_task(ctx, NULL, size);
    ((PsUser *)t->frame)->desc = &PS_REFMSG_DESC;
    ps_des_run(ctx, m, sh, ps_task_ret(t), size);
    if (m != NULL) {
        free(m->data);
        free(m);
    }
    return t;
}

PsTask *ps_worker_recv_obj(PsCtx *ctx, PsWorker *w, const PsShape *sh, size_t size) {
    if (w == NULL || w->blk == NULL) {
        return ps_obj_msg_task(ctx, NULL, sh, size);
    }
    return ps_recv_task(ctx, w->blk, 0, PS_RECV_OBJ, sh, size);
}

PsTask *ps_parent_recv_obj(PsCtx *ctx, const PsShape *sh, size_t size) {
    if (ctx->parent == NULL) {
        return ps_obj_msg_task(ctx, NULL, sh, size);
    }
    return ps_recv_task(ctx, ctx->parent, 1, PS_RECV_OBJ, sh, size);
}

int ps_worker_send_up(PsCtx *ctx, const void *p, size_t size) {
    PsWorkerBlk *b = ctx->parent;
    if (b == NULL) {
        return 0;
    }
    pthread_mutex_lock(&b->mu);
    ps_msg_push(&b->up_head, &b->up_tail, p, size);
    pthread_cond_broadcast(&b->cv);
    ps_pipe_wake(b->up_w);
    pthread_mutex_unlock(&b->mu);
    return 1;
}

int ps_worker_send_down(PsWorker *w, const void *p, size_t size) {
    if (w == NULL || w->blk == NULL) {
        return 0;
    }
    PsWorkerBlk *b = w->blk;
    pthread_mutex_lock(&b->mu);
    if (b->done != 0) {
        pthread_mutex_unlock(&b->mu);
        return 0;
    }
    ps_msg_push(&b->down_head, &b->down_tail, p, size);
    pthread_cond_broadcast(&b->cv);
    ps_pipe_wake(b->dn_w);
    pthread_mutex_unlock(&b->mu);
    return 1;
}

static PsTask *ps_msg_task(PsCtx *ctx, PsMsg *m, size_t size) {
    char *fr = (char *)ps_alloc(ctx, sizeof(PsUser) + size, PS_TY_USER);
    PsUser *u = (PsUser *)fr;
    u->desc = &PS_POD_DESC;
    memset(fr + sizeof(PsUser), 0, size);
    if (m != NULL) {
        memcpy(fr + sizeof(PsUser), m->data, (m->size < size ? m->size : size));
        free(m->data);
        free(m);
    }
    PsTask *t = (PsTask *)ps_alloc(ctx, sizeof(PsTask), PS_TY_TASK);
    t->state = -1;
    t->step = NULL;
    t->frame = (PsObj *)fr;
    t->err = NULL;
    t->waiting_on = NULL;
    t->waiter = NULL;
    t->cancelled = 0;
    t->deadline = 0.0;
    t->is_timer = 0;
    t->next = NULL;
    ps_task_clear_recv(t);
    return t;
}

static const const int32_t PS_POOL_MAX = 8;

typedef struct PsPool PsPool;
typedef struct PsJson PsJson;

struct PsPool {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    PsWork *head;
    PsWork *tail;
    int32_t n;
    int32_t started;
};

static PsPool g_pool = {0};

static void *ps_pool_thread(void *arg) {
    while (1) {
        pthread_mutex_lock(&g_pool.mu);
        while (g_pool.head == NULL) {
            pthread_cond_wait(&g_pool.cv, &g_pool.mu);
        }
        PsWork *w = g_pool.head;
        g_pool.head = w->next;
        if (g_pool.head == NULL) {
            g_pool.tail = NULL;
        }
        w->next = NULL;
        pthread_mutex_unlock(&g_pool.mu);
        ps_io_run(w);
        pthread_mutex_lock(&g_pool.mu);
        if (w->orphan != 0) {
            pthread_mutex_unlock(&g_pool.mu);
            ps_work_free(w);
            continue;
        }
        w->done = 1;
        int fd = w->wake;
        pthread_mutex_unlock(&g_pool.mu);
        ps_pipe_wake(fd);
    }
    return NULL;
}

static void ps_pool_start(void) {
    if (g_pool.started != 0) {
        return;
    }
    pthread_mutex_init(&g_pool.mu, NULL);
    pthread_cond_init(&g_pool.cv, NULL);
    int32_t n = (int32_t)sysconf(_SC_NPROCESSORS_ONLN);
    if (n < 1) {
        n = 1;
    }
    if (n > PS_POOL_MAX) {
        n = PS_POOL_MAX;
    }
    const char *env = getenv("PSCRIPT_POOL");
    if (env != NULL) {
        int64_t v = strtoll(env, NULL, 10);
        if (v >= 1 && v <= 64) {
            n = (int32_t)v;
        }
    }
    g_pool.n = n;
    g_pool.started = 1;
    size_t i;
    for (i = 0; i < n; i += 1) {
        pthread_t th;
        pthread_create(&th, NULL, ps_pool_thread, NULL);
        pthread_detach(th);
    }
}

static void ps_work_free(PsWork *w) {
    if (w == NULL) {
        return;
    }
    if (w->path != NULL) {
        free(w->path);
    }
    if (w->mode != NULL) {
        free(w->mode);
    }
    if (w->buf != NULL) {
        free(w->buf);
    }
    free(w);
}

static char *ps_dupn(const char *p, size_t n) {
    char *q = (char *)malloc(n + 1);
    if (n > 0) {
        memcpy(q, p, n);
    }
    q[n] = '\0';
    return q;
}

static void ps_io_run(PsWork *w) {
    w->err = 0;
    switch (w->op) {
        case PS_IO_OPEN: {
            FILE *f = fopen(w->path, w->mode);
            if (f == NULL) {
                w->err = 1;
                w->rc = 0;
            } else {
                w->fp = f;
                w->rc = 1;
            }
            break;
        }
        case PS_IO_READ: {
            char *b = (char *)malloc((w->n > 0 ? w->n : (size_t)1));
            size_t got = fread(b, 1, w->n, w->fp);
            w->buf = b;
            w->n = got;
            w->rc = (int64_t)got;
            if (got == 0 && ferror(w->fp) != 0) {
                w->err = 1;
            }
            break;
        }
        case PS_IO_READALL: {
            size_t cap = 8192;
            char *acc = (char *)malloc(cap);
            size_t len = 0;
            while (1) {
                if (len == cap) {
                    cap *= 2;
                    acc = (char *)realloc(acc, cap);
                }
                size_t k = fread(acc + len, 1, cap - len, w->fp);
                len += k;
                if (k == 0) {
                    break;
                }
            }
            if (ferror(w->fp) != 0) {
                w->err = 1;
            }
            w->buf = acc;
            w->n = len;
            w->rc = (int64_t)len;
            break;
        }
        case PS_IO_WRITE: {
            size_t put = fwrite(w->buf, 1, w->n, w->fp);
            w->rc = (int64_t)put;
            if (put != w->n) {
                w->err = 1;
            }
            break;
        }
        case PS_IO_CLOSE: {
            if (w->fp != NULL) {
                if (fclose(w->fp) != 0) {
                    w->err = 1;
                }
                w->fp = NULL;
            }
            w->rc = 0;
            break;
        }
        case PS_IO_LOOKUP: {
            struct addrinfo hints;
            memset(&hints, 0, sizeof(hints));
            hints.ai_family = 2;
            hints.ai_socktype = SOCK_STREAM;
            struct addrinfo *res = NULL;
            if (getaddrinfo(w->path, NULL, &hints, &res) != 0 || res == NULL) {
                w->err = 1;
            } else {
                struct sockaddr_in *sa = (struct sockaddr_in *)res->ai_addr;
                const char *txt = inet_ntoa(sa->sin_addr);
                w->buf = ps_dupn(txt, strlen(txt));
                w->n = strlen(txt);
                freeaddrinfo(res);
            }
            break;
        }
        case PS_IO_CONNECT: {
            struct addrinfo hints2;
            memset(&hints2, 0, sizeof(hints2));
            hints2.ai_family = 2;
            hints2.ai_socktype = SOCK_STREAM;
            struct addrinfo *res2 = NULL;
            char port[16];
            snprintf(port, 16, "%d", w->port);
            if (getaddrinfo(w->path, port, &hints2, &res2) != 0 || res2 == NULL) {
                w->err = 1;
            } else {
                int fd = socket(res2->ai_family, res2->ai_socktype, res2->ai_protocol);
                if (fd < 0 || connect(fd, res2->ai_addr, res2->ai_addrlen) != 0) {
                    if (fd >= 0) {
                        close(fd);
                    }
                    w->err = 1;
                } else {
                    w->rc = (int64_t)fd;
                }
                freeaddrinfo(res2);
            }
            break;
        }
        default: {
            w->rc = 0;
            break;
        }
    }
}

static void ps_io_ready(PsCtx *ctx) {
    ps_pool_start();
    if (ctx->io_r < 0 || (ctx->io_r == 0 && ctx->io_w == 0)) {
        ps_pipe_open(&ctx->io_r, &ctx->io_w);
    }
}

void ps_pool_submit(PsCtx *ctx, PsWork *w) {
    ps_io_ready(ctx);
    w->wake = ctx->io_w;
    w->next = NULL;
    pthread_mutex_lock(&g_pool.mu);
    if (g_pool.tail == NULL) {
        g_pool.head = w;
        g_pool.tail = w;
    } else {
        g_pool.tail->next = w;
        g_pool.tail = w;
    }
    pthread_cond_signal(&g_pool.cv);
    pthread_mutex_unlock(&g_pool.mu);
}

PsWork *ps_work_new(int32_t op) {
    PsWork *w = (PsWork *)malloc(sizeof(PsWork));
    memset(w, 0, sizeof(PsWork));
    w->op = op;
    w->fd = -1;
    return w;
}

PsTask *ps_io_task(PsCtx *ctx, PsWork *w, int isref, size_t size) {
    char *fr = (char *)ps_alloc(ctx, sizeof(PsUser) + size, PS_TY_USER);
    PsUser *u = (PsUser *)fr;
    u->desc = (isref ? &PS_REFMSG_DESC : &PS_POD_DESC);
    memset(fr + sizeof(PsUser), 0, size);
    PsTask *t = (PsTask *)ps_alloc(ctx, sizeof(PsTask), PS_TY_TASK);
    t->state = 0;
    t->step = NULL;
    t->frame = (PsObj *)fr;
    t->err = NULL;
    t->waiting_on = NULL;
    t->waiter = NULL;
    t->cancelled = 0;
    t->deadline = 0.0;
    t->is_timer = 0;
    t->next = NULL;
    ps_task_clear_recv(t);
    t->is_io = 1;
    t->work = w;
    t->rsize = size;
    ps_pool_submit(ctx, w);
    t->next = ctx->waiters;
    ctx->waiters = t;
    return t;
}

static void ps_sigpipe_noop(int sig) {
    ;
}

static int32_t g_sigpipe_done = 0;

static void ps_sock_nonblock(int fd) {
    if (g_sigpipe_done == 0) {
        g_sigpipe_done = 1;
        signal(13, ps_sigpipe_noop);
    }
    fcntl(fd, 4, 2048);
}

static PsTask *ps_fd_task(PsCtx *ctx, PsWork *w, int isref, size_t size) {
    char *fr = (char *)ps_alloc(ctx, sizeof(PsUser) + size, PS_TY_USER);
    PsUser *u = (PsUser *)fr;
    u->desc = (isref ? &PS_REFMSG_DESC : &PS_POD_DESC);
    memset(fr + sizeof(PsUser), 0, size);
    PsTask *t = (PsTask *)ps_alloc(ctx, sizeof(PsTask), PS_TY_TASK);
    t->state = 0;
    t->step = NULL;
    t->frame = (PsObj *)fr;
    t->err = NULL;
    t->waiting_on = NULL;
    t->waiter = NULL;
    t->cancelled = 0;
    t->deadline = 0.0;
    t->is_timer = 0;
    t->next = NULL;
    ps_task_clear_recv(t);
    t->is_io = 1;
    t->work = w;
    t->rsize = size;
    t->next = ctx->waiters;
    ctx->waiters = t;
    return t;
}

static PsConn *ps_conn_new(PsCtx *ctx, int fd, int32_t listening) {
    PsConn *c = (PsConn *)ps_alloc(ctx, sizeof(PsConn), PS_TY_CONN);
    c->fd = fd;
    c->is_open = (fd >= 0 ? 1 : 0);
    c->listening = listening;
    return c;
}

PsConn *ps_net_listen(PsCtx *ctx, int64_t port) {
    int fd = socket(2, SOCK_STREAM, 0);
    if (fd < 0) {
        ps_raise(ctx, "could not make a socket", PS_CAT_IO, "<net>", 0);
        return ps_conn_new(ctx, -1, 1);
    }
    int one = 1;
    setsockopt(fd, 1, 2, &one, (uint32_t)sizeof(int));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = (uint16_t)2;
    a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = htonl((uint32_t)0);
    if (bind(fd, (struct sockaddr *)&a, (uint32_t)sizeof(a)) != 0) {
        close(fd);
        char msg[128];
        snprintf(msg, 128, "could not bind port %ld", port);
        ps_raise(ctx, msg, PS_CAT_IO, "<net>", 0);
        return ps_conn_new(ctx, -1, 1);
    }
    if (listen(fd, 128) != 0) {
        close(fd);
        ps_raise(ctx, "could not listen", PS_CAT_IO, "<net>", 0);
        return ps_conn_new(ctx, -1, 1);
    }
    ps_sock_nonblock(fd);
    return ps_conn_new(ctx, fd, 1);
}

int64_t ps_conn_port(PsConn *c) {
    if (c == NULL || c->is_open == 0) {
        return 0;
    }
    struct sockaddr_in a;
    uint32_t n = (uint32_t)sizeof(a);
    memset(&a, 0, sizeof(a));
    if (getsockname(c->fd, (struct sockaddr *)&a, &n) != 0) {
        return 0;
    }
    return (int64_t)ntohs(a.sin_port);
}

static int ps_conn_live(PsCtx *ctx, PsConn *c, const char *what) {
    if (c == NULL || c->is_open == 0) {
        char msg[128];
        snprintf(msg, 128, "%s on a socket that is not open", what);
        ps_raise(ctx, msg, PS_CAT_IO, "<net>", 0);
        return 0;
    }
    return 1;
}

PsTask *ps_net_accept(PsCtx *ctx, PsConn *srv) {
    if (!ps_conn_live(ctx, srv, "accept")) {
        return ps_msg_task(ctx, NULL, sizeof(PsStrPtr));
    }
    PsWork *w = ps_work_new(PS_IO_ACCEPT);
    w->want = PS_W_CONN;
    w->fd = srv->fd;
    w->events = (int16_t)1;
    return ps_fd_task(ctx, w, 1, sizeof(PsStrPtr));
}

PsTask *ps_conn_read(PsCtx *ctx, PsConn *c, int64_t n) {
    if (!ps_conn_live(ctx, c, "read")) {
        return ps_msg_task(ctx, NULL, sizeof(PsStrPtr));
    }
    PsWork *w = ps_work_new(PS_IO_RECV);
    w->want = PS_W_BYTES;
    w->fd = c->fd;
    w->events = (int16_t)1;
    w->n = (size_t)(n > 0 ? n : 0);
    w->buf = (char *)malloc((w->n > 0 ? w->n : (size_t)1));
    return ps_fd_task(ctx, w, 1, sizeof(PsStrPtr));
}

static PsTask *ps_send_task(PsCtx *ctx, PsConn *c, const char *bytes, size_t n) {
    PsWork *w = ps_work_new(PS_IO_SEND);
    w->want = PS_W_INT;
    w->fd = c->fd;
    w->events = (int16_t)4;
    w->n = n;
    w->off = 0;
    w->buf = (char *)malloc(n + 1);
    if (n > 0) {
        memcpy(w->buf, bytes, n);
    }
    return ps_fd_task(ctx, w, 0, sizeof(int64_t));
}

PsTask *ps_conn_write(PsCtx *ctx, PsConn *c, PsStr *s) {
    if (!ps_conn_live(ctx, c, "write")) {
        return ps_msg_task(ctx, NULL, sizeof(int64_t));
    }
    return ps_send_task(ctx, c, (s != NULL ? s->data : ""), (s != NULL ? (size_t)s->len : (size_t)0));
}

PsTask *ps_conn_write_bytes(PsCtx *ctx, PsConn *c, PsList *l) {
    if (!ps_conn_live(ctx, c, "write")) {
        return ps_msg_task(ctx, NULL, sizeof(int64_t));
    }
    size_t n = (l != NULL ? (size_t)l->len : (size_t)0);
    return ps_send_task(ctx, c, (n > 0 ? ps_list_base(l) : ""), n);
}

void ps_conn_close(PsCtx *ctx, PsConn *c) {
    if (c != NULL && c->is_open != 0) {
        close(c->fd);
        c->is_open = 0;
        c->fd = -1;
    }
}

PsTask *ps_net_connect(PsCtx *ctx, PsStr *host, int64_t port) {
    PsWork *w = ps_work_new(PS_IO_CONNECT);
    w->want = PS_W_CONN;
    w->path = ps_dupn(host->data, (size_t)host->len);
    w->port = (int32_t)port;
    w->fd = -1;
    return ps_io_task(ctx, w, 1, sizeof(PsStrPtr));
}

PsTask *ps_net_lookup(PsCtx *ctx, PsStr *host) {
    PsWork *w = ps_work_new(PS_IO_LOOKUP);
    w->want = PS_W_STR;
    w->path = ps_dupn(host->data, (size_t)host->len);
    w->fd = -1;
    return ps_io_task(ctx, w, 1, sizeof(PsStrPtr));
}

PsTask *ps_aio_open(PsCtx *ctx, PsStr *path, PsStr *mode) {
    PsWork *w = ps_work_new(PS_IO_OPEN);
    w->want = PS_W_FILE;
    w->path = ps_dupn(path->data, (size_t)path->len);
    w->mode = ps_dupn(mode->data, (size_t)mode->len);
    return ps_io_task(ctx, w, 1, sizeof(PsStrPtr));
}

static int ps_file_live(PsCtx *ctx, PsFile *f, const char *what) {
    if (f == NULL || f->is_open == 0) {
        char msg[128];
        snprintf(msg, 128, "%s on a file that is not open", what);
        ps_raise(ctx, msg, PS_CAT_IO, "<io>", 0);
        return 0;
    }
    return 1;
}

PsTask *ps_aio_read(PsCtx *ctx, PsFile *f, int64_t n) {
    if (!ps_file_live(ctx, f, "read")) {
        return ps_msg_task(ctx, NULL, sizeof(PsStrPtr));
    }
    PsWork *w = ps_work_new(PS_IO_READ);
    w->want = PS_W_BYTES;
    w->fp = f->fp;
    w->n = (size_t)(n > 0 ? n : 0);
    return ps_io_task(ctx, w, 1, sizeof(PsStrPtr));
}

PsTask *ps_aio_readall(PsCtx *ctx, PsFile *f, int32_t want) {
    if (!ps_file_live(ctx, f, "read")) {
        return ps_msg_task(ctx, NULL, sizeof(PsStrPtr));
    }
    PsWork *w = ps_work_new(PS_IO_READALL);
    w->want = want;
    w->fp = f->fp;
    return ps_io_task(ctx, w, 1, sizeof(PsStrPtr));
}

PsTask *ps_aio_write(PsCtx *ctx, PsFile *f, PsStr *s) {
    if (!ps_file_live(ctx, f, "write")) {
        return ps_msg_task(ctx, NULL, sizeof(int64_t));
    }
    PsWork *w = ps_work_new(PS_IO_WRITE);
    w->want = PS_W_INT;
    w->fp = f->fp;
    w->n = (size_t)s->len;
    w->buf = ps_dupn(s->data, (size_t)s->len);
    return ps_io_task(ctx, w, 0, sizeof(int64_t));
}

PsTask *ps_aio_write_bytes(PsCtx *ctx, PsFile *f, PsList *l) {
    if (!ps_file_live(ctx, f, "write")) {
        return ps_msg_task(ctx, NULL, sizeof(int64_t));
    }
    size_t n = (l != NULL ? (size_t)l->len : (size_t)0);
    PsWork *w = ps_work_new(PS_IO_WRITE);
    w->want = PS_W_INT;
    w->fp = f->fp;
    w->n = n;
    w->buf = (char *)malloc(n + 1);
    size_t i = 0;
    while (i < n) {
        w->buf[i] = *(ps_list_base(l) + i);
        i += 1;
    }
    return ps_io_task(ctx, w, 0, sizeof(int64_t));
}

PsTask *ps_aio_close(PsCtx *ctx, PsFile *f) {
    PsWork *w = ps_work_new(PS_IO_CLOSE);
    w->want = PS_W_NONE;
    if (f != NULL && f->is_std != 0) {
        return ps_io_task(ctx, w, 0, sizeof(int64_t));
    }
    if (f != NULL && f->is_open != 0) {
        w->fp = f->fp;
        f->is_open = 0;
        f->fp = NULL;
    }
    return ps_io_task(ctx, w, 0, sizeof(int64_t));
}

static void ps_task_clear_recv(PsTask *t) {
    t->is_recv = 0;
    t->rblk = NULL;
    t->rdir = 0;
    t->rkind = 0;
    t->rsize = 0;
    t->rshape = NULL;
}

static PsMsg *ps_recv_pop(PsWorkerBlk *b, int32_t dir, int *ended) {
    PsMsg *m = NULL;
    *ended = 0;
    pthread_mutex_lock(&b->mu);
    if (dir == 0) {
        m = ps_msg_pop(&b->up_head, &b->up_tail);
        if (m == NULL && b->done != 0) {
            *ended = 1;
        }
    } else {
        m = ps_msg_pop(&b->down_head, &b->down_tail);
    }
    pthread_mutex_unlock(&b->mu);
    return m;
}

static PsTask *ps_recv_build(PsCtx *ctx, PsMsg *m, int32_t kind, const PsShape *sh, size_t size) {
    if (kind == PS_RECV_OBJ) {
        return ps_obj_msg_task(ctx, m, sh, size);
    }
    return ps_msg_task(ctx, m, size);
}

PsTask *ps_recv_task(PsCtx *ctx, PsWorkerBlk *b, int32_t dir, int32_t kind, const PsShape *sh, size_t size) {
    int ended = 0;
    PsMsg *m = ps_recv_pop(b, dir, &ended);
    if (m != NULL || ended) {
        return ps_recv_build(ctx, m, kind, sh, size);
    }
    char *fr = (char *)ps_alloc(ctx, sizeof(PsUser) + size, PS_TY_USER);
    PsUser *u = (PsUser *)fr;
    u->desc = (kind == PS_RECV_RAW ? &PS_POD_DESC : &PS_REFMSG_DESC);
    memset(fr + sizeof(PsUser), 0, size);
    PsTask *t = (PsTask *)ps_alloc(ctx, sizeof(PsTask), PS_TY_TASK);
    t->state = 0;
    t->step = NULL;
    t->frame = (PsObj *)fr;
    t->err = NULL;
    t->waiting_on = NULL;
    t->waiter = NULL;
    t->cancelled = 0;
    t->deadline = 0.0;
    t->is_timer = 0;
    t->next = NULL;
    ps_task_clear_recv(t);
    t->is_recv = 1;
    t->rblk = b;
    t->rdir = dir;
    t->rkind = kind;
    t->rsize = size;
    t->rshape = sh;
    t->next = ctx->waiters;
    ctx->waiters = t;
    return t;
}

static void ps_recv_finish(PsCtx *ctx, PsTask *t, PsMsg *m) {
    if (t->rkind == PS_RECV_OBJ) {
        ps_des_run(ctx, m, t->rshape, ps_task_ret(t), t->rsize);
    } else if (m != NULL) {
        memcpy((char *)t->frame + sizeof(PsUser), m->data, (m->size < t->rsize ? m->size : t->rsize));
    }
    if (m != NULL) {
        free(m->data);
        free(m);
    }
    t->state = -1;
    PsTask *w = t->waiter;
    t->waiter = NULL;
    if (w != NULL) {
        w->waiting_on = NULL;
        ps_sched_push(ctx, w);
    }
}

static void ps_io_finish(PsCtx *ctx, PsTask *t) {
    PsWork *w = t->work;
    if (w->err != 0) {
        char msg[512];
        switch (w->op) {
            case PS_IO_OPEN: {
                snprintf(msg, 512, "cannot open '%s'", (w->path != NULL ? w->path : "\?"));
                break;
            }
            case PS_IO_READ:
            case PS_IO_READALL: {
                snprintf(msg, 512, "read failed");
                break;
            }
            case PS_IO_WRITE: {
                snprintf(msg, 512, "could not write the whole buffer");
                break;
            }
            case PS_IO_CLOSE: {
                snprintf(msg, 512, "close failed");
                break;
            }
            default: {
                snprintf(msg, 512, "the operation failed");
                break;
            }
        }
        ps_raise(ctx, msg, PS_CAT_IO, "<io>", 0);
        ps_task_fail(ctx, t);
        ps_work_free(w);
        t->work = NULL;
        return;
    }
    switch (w->want) {
        case PS_W_FILE: {
            PsFile *f = (PsFile *)ps_alloc(ctx, sizeof(PsFile), PS_TY_FILE);
            f->fp = w->fp;
            f->is_open = 1;
            *(PsFile **)ps_task_ret(t) = f;
            break;
        }
        case PS_W_BYTES: {
            PsList *l = ps_list_new(ctx, 1, 0, (int64_t)w->n);
            size_t i = 0;
            while (i < w->n) {
                char *dst = ps_list_push(ctx, l);
                *dst = w->buf[i];
                i += 1;
            }
            *(PsList **)ps_task_ret(t) = l;
            break;
        }
        case PS_W_STR: {
            if (!ps_utf8_valid(w->buf, w->n)) {
                ps_raise(ctx, "these bytes are not valid UTF-8: read them as bytes, or decode them yourself", PS_CAT_VALUE, "<io>", 0);
                ps_task_fail(ctx, t);
                ps_work_free(w);
                t->work = NULL;
                return;
            }
            *(PsStr **)ps_task_ret(t) = ps_str_new(ctx, w->buf, w->n);
            break;
        }
        case PS_W_LINES: {
            if (!ps_utf8_valid(w->buf, w->n)) {
                ps_raise(ctx, "these bytes are not valid UTF-8: read them as bytes, or decode them yourself", PS_CAT_VALUE, "<io>", 0);
                ps_task_fail(ctx, t);
                ps_work_free(w);
                t->work = NULL;
                return;
            }
            PsStr *whole = ps_str_new(ctx, w->buf, w->n);
            PsStr *nl = ps_str_new(ctx, "\n", 1);
            *(PsList **)ps_task_ret(t) = ps_str_split(ctx, whole, nl);
            break;
        }
        case PS_W_CONN: {
            PsConn *c = (PsConn *)ps_alloc(ctx, sizeof(PsConn), PS_TY_CONN);
            c->fd = (int)w->rc;
            c->is_open = 1;
            c->listening = 0;
            ps_sock_nonblock(c->fd);
            *(PsConn **)ps_task_ret(t) = c;
            break;
        }
        case PS_W_INT: {
            *(int64_t *)ps_task_ret(t) = w->rc;
            break;
        }
        default: {
            ;
            break;
        }
    }
    ps_work_free(w);
    t->work = NULL;
    if (t->state != -2) {
        t->state = -1;
    }
}

static int ps_fd_try(PsCtx *ctx, PsTask *t) {
    PsWork *w = t->work;
    struct pollfd pf[1];
    pf[0].fd = w->fd;
    pf[0].events = w->events;
    pf[0].revents = 0;
    if (poll(pf, (uint64_t)1, 0) <= 0) {
        return 0;
    }
    switch (w->op) {
        case PS_IO_ACCEPT: {
            int fd2 = accept(w->fd, NULL, NULL);
            if (fd2 < 0) {
                return 0;
            }
            w->rc = (int64_t)fd2;
            return 1;
        }
        case PS_IO_RECV: {
            int64_t got = (int64_t)recv(w->fd, w->buf, w->n, 0);
            if (got < 0) {
                w->err = 1;
                w->n = 0;
            } else {
                w->n = (size_t)got;
            }
            return 1;
        }
        case PS_IO_SEND: {
            int64_t put = (int64_t)send(w->fd, w->buf + w->off, w->n - w->off, 0);
            if (put < 0) {
                w->err = 1;
                return 1;
            }
            w->off += (size_t)put;
            if (w->off < w->n) {
                return 0;
            }
            w->rc = (int64_t)w->n;
            return 1;
        }
        default: {
            return 1;
        }
    }
}

static int ps_recvs_poll(PsCtx *ctx) {
    int any = 0;
    PsTask *t = ctx->waiters;
    while (t != NULL) {
        PsTask *n = t->next;
        if (t->state == 0 && t->is_io != 0) {
            if (t->cancelled != 0) {
                if (t->work->fd >= 0) {
                    ps_work_free(t->work);
                } else {
                    pthread_mutex_lock(&g_pool.mu);
                    if (t->work->done != 0) {
                        pthread_mutex_unlock(&g_pool.mu);
                        ps_work_free(t->work);
                    } else {
                        t->work->orphan = 1;
                        pthread_mutex_unlock(&g_pool.mu);
                    }
                }
                t->work = NULL;
                t->state = -1;
                PsTask *iw = t->waiter;
                t->waiter = NULL;
                if (iw != NULL) {
                    iw->waiting_on = NULL;
                    ps_sched_push(ctx, iw);
                }
                any = 1;
            } else if (t->work->fd >= 0) {
                if (ps_fd_try(ctx, t)) {
                    ps_io_finish(ctx, t);
                    PsTask *fw = t->waiter;
                    t->waiter = NULL;
                    if (fw != NULL) {
                        fw->waiting_on = NULL;
                        ps_sched_push(ctx, fw);
                    }
                    any = 1;
                }
            } else {
                pthread_mutex_lock(&g_pool.mu);
                int fin = t->work->done != 0;
                pthread_mutex_unlock(&g_pool.mu);
                if (fin) {
                    ps_io_finish(ctx, t);
                    PsTask *dw = t->waiter;
                    t->waiter = NULL;
                    if (dw != NULL) {
                        dw->waiting_on = NULL;
                        ps_sched_push(ctx, dw);
                    }
                    any = 1;
                }
            }
        } else if (t->state == 0) {
            if (t->cancelled != 0) {
                t->state = -1;
                PsTask *cw = t->waiter;
                t->waiter = NULL;
                if (cw != NULL) {
                    cw->waiting_on = NULL;
                    ps_sched_push(ctx, cw);
                }
                any = 1;
            } else {
                int ended = 0;
                PsMsg *m = ps_recv_pop(t->rblk, t->rdir, &ended);
                if (m != NULL || ended) {
                    ps_recv_finish(ctx, t, m);
                    any = 1;
                }
            }
        }
        t = n;
    }
    PsTask **prev = &ctx->waiters;
    PsTask *cur = ctx->waiters;
    while (cur != NULL) {
        PsTask *nx = cur->next;
        if (cur->state != 0) {
            *prev = nx;
            cur->next = NULL;
        } else {
            prev = &cur->next;
        }
        cur = nx;
    }
    return any;
}

static int32_t ps_recv_fds(PsCtx *ctx, int *out_bad) {
    int32_t cnt = 0;
    int io = 0;
    *out_bad = 0;
    PsTask *t = ctx->waiters;
    while (t != NULL) {
        if (t->state == 0) {
            if (t->is_io != 0 && t->work != NULL && t->work->fd >= 0) {
                cnt += 1;
            } else if (t->is_io != 0) {
                io = 1;
            } else {
                int fd = (t->rdir == 0 ? t->rblk->up_r : t->rblk->dn_r);
                if (fd < 0) {
                    *out_bad = 1;
                } else {
                    cnt += 1;
                }
            }
        }
        t = t->next;
    }
    if (io) {
        if (ctx->io_r < 0) {
            *out_bad = 1;
        } else {
            cnt += 1;
        }
    }
    return cnt;
}

PsTask *ps_worker_recv(PsCtx *ctx, PsWorker *w, size_t size) {
    if (w == NULL || w->blk == NULL) {
        return ps_msg_task(ctx, NULL, size);
    }
    return ps_recv_task(ctx, w->blk, 0, PS_RECV_RAW, NULL, size);
}

PsTask *ps_parent_recv(PsCtx *ctx, size_t size) {
    if (ctx->parent == NULL) {
        return ps_msg_task(ctx, NULL, size);
    }
    return ps_recv_task(ctx, ctx->parent, 1, PS_RECV_RAW, NULL, size);
}

PsErr *ps_worker_error(PsCtx *ctx, PsWorker *w) {
    if (w == NULL || w->blk == NULL) {
        return NULL;
    }
    PsWorkerBlk *b = w->blk;
    pthread_mutex_lock(&b->mu);
    if (b->done == 0 || b->failed == 0) {
        pthread_mutex_unlock(&b->mu);
        return NULL;
    }
    b->collected = 1;
    char *msg = ps_dup((b->err != NULL ? b->err : "\?"));
    int32_t cat = b->err_cat;
    pthread_mutex_unlock(&b->mu);
    PsErr *e = (PsErr *)ps_alloc(ctx, sizeof(PsErr), PS_TY_ERR);
    e->msg = ps_str_new(ctx, msg, strlen(msg));
    e->cat = cat;
    e->file = NULL;
    e->line = 0;
    free(msg);
    return e;
}

void ps_join_all(PsCtx *ctx) {
    PsWorkerBlk *b = ctx->workers;
    while (b != NULL) {
        if (b->started != 0 && b->joined == 0 && b->detached == 0) {
            pthread_join(b->thread, NULL);
            b->joined = 1;
            ps_pipe_close(b->up_r);
            ps_pipe_close(b->up_w);
            ps_pipe_close(b->dn_r);
            ps_pipe_close(b->dn_w);
            b->up_r = -1;
            b->up_w = -1;
            b->dn_r = -1;
            b->dn_w = -1;
        }
        if (b->failed != 0 && b->collected == 0 && b->err != NULL) {
            fprintf(stderr, "worker error: %s\n", b->err);
        }
        b = b->next;
    }
}

PsList *ps_list_slice(PsCtx *ctx, PsList *l, int64_t a, int64_t b, int has_a, int has_b) {
    int64_t n = l->len;
    int64_t i = (has_a ? a : 0);
    int64_t j = (has_b ? b : n);
    if (i < 0) {
        i += n;
    }
    if (j < 0) {
        j += n;
    }
    if (i < 0) {
        i = 0;
    }
    if (j > n) {
        j = n;
    }
    PsList *out = ps_list_new(ctx, l->esize, l->eref, (j > i ? j - i : 0));
    int64_t k = i;
    while (k < j) {
        char *src = (char *)l->data + sizeof(PsArr) + (size_t)k * (size_t)l->esize;
        char *dst = ps_list_push(ctx, out);
        memcpy(dst, src, (size_t)l->esize);
        k += 1;
    }
    return out;
}

char *ps_list_insert(PsCtx *ctx, PsList *l, int64_t i, const char *file, int32_t line) {
    int64_t k = (i < 0 ? i + l->len : i);
    if (k < 0 || k > l->len) {
        ps_raise(ctx, "insert position out of range", PS_CAT_INDEX, file, line);
        return ps_list_push(ctx, l);
    }
    ps_list_push(ctx, l);
    char *base = (char *)l->data + sizeof(PsArr);
    size_t es = (size_t)l->esize;
    int64_t m = l->len - 1;
    while (m > k) {
        memcpy(base + (size_t)m * es, base + (size_t)(m - 1) * es, es);
        m -= 1;
    }
    return base + (size_t)k * es;
}

void ps_list_remove_at(PsCtx *ctx, PsList *l, int64_t i, const char *file, int32_t line) {
    int64_t k = (i < 0 ? i + l->len : i);
    if (k < 0 || k >= l->len) {
        ps_raise(ctx, "list index out of range", PS_CAT_INDEX, file, line);
        return;
    }
    char *base = (char *)l->data + sizeof(PsArr);
    size_t es = (size_t)l->esize;
    int64_t m = k;
    while (m + 1 < l->len) {
        memcpy(base + (size_t)m * es, base + (size_t)(m + 1) * es, es);
        m += 1;
    }
    l->len -= 1;
}

void ps_list_reverse(PsList *l) {
    char *base = (char *)l->data + sizeof(PsArr);
    size_t es = (size_t)l->esize;
    char tmp[64];
    int64_t i = 0;
    int64_t j = l->len - 1;
    while (i < j && es <= 64) {
        memcpy(tmp, base + (size_t)i * es, es);
        memcpy(base + (size_t)i * es, base + (size_t)j * es, es);
        memcpy(base + (size_t)j * es, tmp, es);
        i += 1;
        j -= 1;
    }
}

static int ps_cmp_int(const void *a, const void *b) {
    int64_t x = *(int64_t *)a;
    int64_t y = *(int64_t *)b;
    return (x < y ? -1 : (x > y ? 1 : 0));
}

static int ps_cmp_float(const void *a, const void *b) {
    double x = *(double *)a;
    double y = *(double *)b;
    return (x < y ? -1 : (x > y ? 1 : 0));
}

static int ps_cmp_str(const void *a, const void *b) {
    PsStr *x = *(PsStr **)a;
    PsStr *y = *(PsStr **)b;
    return strcmp(x->data, y->data);
}

PsList *ps_list_sorted(PsCtx *ctx, PsList *l, int32_t kind) {
    PsList *out = ps_list_slice(ctx, l, 0, 0, 0, 0);
    if (out->len < 2) {
        return out;
    }
    void *base = (void *)((char *)out->data + sizeof(PsArr));
    if (kind == 0) {
        qsort(base, (size_t)out->len, (size_t)out->esize, ps_cmp_int);
    } else if (kind == 1) {
        qsort(base, (size_t)out->len, (size_t)out->esize, ps_cmp_float);
    } else {
        qsort(base, (size_t)out->len, (size_t)out->esize, ps_cmp_str);
    }
    return out;
}

PsBuffer *ps_buffer_new(PsCtx *ctx, int64_t nbytes, const char *file, int32_t line) {
    PsBuffer *b = (PsBuffer *)calloc(1, sizeof(PsBuffer));
    b->obj.ty = PS_TY_BUFFER;
    b->obj.size = (uint32_t)sizeof(PsBuffer);
    b->gone_from = NULL;
    b->data = NULL;
    b->nbytes = 0;
    b->open = 0;
    if (nbytes < 0) {
        ps_raise(ctx, "a buffer cannot have a negative size", PS_CAT_VALUE, file, line);
        return b;
    }
    b->data = (char *)calloc((nbytes > 0 ? (size_t)nbytes : 1), 1);
    if (b->data == NULL) {
        ps_raise(ctx, "out of memory for the buffer", PS_CAT_VALUE, file, line);
        return b;
    }
    b->nbytes = (size_t)nbytes;
    b->open = 1;
    return b;
}

void ps_buffer_close(PsCtx *ctx, PsBuffer *b) {
    if (b != NULL && b->open != 0) {
        free(b->data);
        b->data = NULL;
        b->open = 0;
    }
}

int64_t ps_buffer_size(PsBuffer *b) {
    return (b != NULL ? (int64_t)b->nbytes : 0);
}

static int ps_buffer_gone(PsCtx *ctx, PsBuffer *b);

static double *ps_buffer_slot(PsCtx *ctx, PsBuffer *b, int64_t i, const char *file, int32_t line) {
    if (ps_buffer_gone(ctx, b)) {
        ps_raise(ctx, "this buffer was transferred: it belongs to whoever received it (18.2)", PS_CAT_VALUE, file, line);
        return NULL;
    }
    if (b == NULL || b->open == 0) {
        ps_raise(ctx, "this buffer is closed", PS_CAT_VALUE, file, line);
        return NULL;
    }
    int64_t n = (int64_t)(b->nbytes / 8);
    int64_t k = (i < 0 ? i + n : i);
    if (k < 0 || k >= n) {
        ps_raise(ctx, "buffer index out of range", PS_CAT_INDEX, file, line);
        return NULL;
    }
    return (double *)(b->data + (size_t)k * 8);
}

double ps_buffer_get_f64(PsCtx *ctx, PsBuffer *b, int64_t i, const char *file, int32_t line) {
    double *p = ps_buffer_slot(ctx, b, i, file, line);
    return (p != NULL ? *p : 0.0);
}

void ps_buffer_set_f64(PsCtx *ctx, PsBuffer *b, int64_t i, double v, const char *file, int32_t line) {
    double *p = ps_buffer_slot(ctx, b, i, file, line);
    if (p != NULL) {
        *p = v;
    }
}

const int32_t PS_JSON_MAX_DEPTH = 1000;

struct PsJson {
    PsCtx *ctx;
    const char *s;
    size_t n;
    size_t i;
    int32_t bad;
    int32_t depth;
    const char *file;
    int32_t line;
};

static void js_fail(PsJson *j, const char *what) {
    if (j->bad != 0) {
        return;
    }
    j->bad = 1;
    char msg[160];
    snprintf(msg, 160, "invalid JSON: %s at byte %d", what, (int)j->i);
    ps_raise(j->ctx, msg, PS_CAT_VALUE, j->file, j->line);
}

static void js_space(PsJson *j) {
    while (j->i < j->n && (j->s[j->i] == ' ' || j->s[j->i] == '\t' || j->s[j->i] == '\n' || j->s[j->i] == '\r')) {
        j->i += 1;
    }
}

static PsObj *js_value(PsJson *j);

static int32_t js_hex4(PsJson *j) {
    if (j->i + (size_t)4 > j->n) {
        return -1;
    }
    int32_t v = 0;
    size_t k = 0;
    while (k < (size_t)4) {
        char c = j->s[j->i + k];
        int32_t d = -1;
        if (c >= '0' && c <= '9') {
            d = (int32_t)c - 48;
        } else if (c >= 'a' && c <= 'f') {
            d = (int32_t)c - 87;
        } else if (c >= 'A' && c <= 'F') {
            d = (int32_t)c - 55;
        }
        if (d < 0) {
            return -1;
        }
        v = v * 16 + d;
        k += 1;
    }
    j->i += (size_t)4;
    return v;
}

static size_t js_utf8(char *buf, size_t k, int32_t cp) {
    uint32_t v = (uint32_t)cp;
    if (v < 0x80) {
        buf[k] = (char)v;
        return k + (size_t)1;
    }
    if (v < 0x800) {
        buf[k] = (char)(0xC0 | (v >> 6));
        buf[k + (size_t)1] = (char)(0x80 | (v & 0x3F));
        return k + (size_t)2;
    }
    if (v < 0x10000) {
        buf[k] = (char)(0xE0 | (v >> 12));
        buf[k + (size_t)1] = (char)(0x80 | ((v >> 6) & 0x3F));
        buf[k + (size_t)2] = (char)(0x80 | (v & 0x3F));
        return k + (size_t)3;
    }
    buf[k] = (char)(0xF0 | (v >> 18));
    buf[k + (size_t)1] = (char)(0x80 | ((v >> 12) & 0x3F));
    buf[k + (size_t)2] = (char)(0x80 | ((v >> 6) & 0x3F));
    buf[k + (size_t)3] = (char)(0x80 | (v & 0x3F));
    return k + (size_t)4;
}

static PsStr *js_string(PsJson *j) {
    j->i += 1;
    char *buf = (char *)malloc(j->n - j->i + (size_t)8);
    size_t k = 0;
    while (1) {
        if (j->i >= j->n) {
            js_fail(j, "a string that never ends");
            free(buf);
            return ps_str_new(j->ctx, "", 0);
        }
        char c = j->s[j->i];
        if (c == '"') {
            j->i += 1;
            break;
        }
        if ((uint8_t)c < 0x20) {
            js_fail(j, "a control character has to be escaped inside a string");
            free(buf);
            return ps_str_new(j->ctx, "", 0);
        }
        if (c != '\\') {
            buf[k] = c;
            k += 1;
            j->i += 1;
            continue;
        }
        j->i += 1;
        if (j->i >= j->n) {
            js_fail(j, "a string that never ends");
            free(buf);
            return ps_str_new(j->ctx, "", 0);
        }
        char e = j->s[j->i];
        j->i += 1;
        if (e == 'n') {
            buf[k] = '\n';
            k += 1;
        } else if (e == 't') {
            buf[k] = '\t';
            k += 1;
        } else if (e == 'r') {
            buf[k] = '\r';
            k += 1;
        } else if (e == 'b') {
            buf[k] = (char)8;
            k += 1;
        } else if (e == 'f') {
            buf[k] = (char)12;
            k += 1;
        } else if (e == '"' || e == '\\' || e == '/') {
            buf[k] = e;
            k += 1;
        } else if (e == 'u') {
            int32_t cp = js_hex4(j);
            if (cp < 0) {
                js_fail(j, "a \\u escape needs four hexadecimal digits");
                free(buf);
                return ps_str_new(j->ctx, "", 0);
            }
            if (cp >= 0xD800 && cp <= 0xDBFF) {
                if (j->i + (size_t)1 < j->n && j->s[j->i] == '\\' && j->s[j->i + (size_t)1] == 'u') {
                    j->i += (size_t)2;
                    int32_t lo = js_hex4(j);
                    if (lo < 0) {
                        js_fail(j, "a \\u escape needs four hexadecimal digits");
                        free(buf);
                        return ps_str_new(j->ctx, "", 0);
                    }
                    if (lo >= 0xDC00 && lo <= 0xDFFF) {
                        cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00);
                    } else {
                        k = js_utf8(buf, k, 0xFFFD);
                        cp = (lo >= 0xD800 && lo <= 0xDFFF ? 0xFFFD : lo);
                    }
                } else {
                    cp = 0xFFFD;
                }
            } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                cp = 0xFFFD;
            }
            k = js_utf8(buf, k, cp);
        } else {
            char m[64];
            if ((uint8_t)e >= 0x20 && (uint8_t)e < 0x7F) {
                snprintf(m, 64, "'\\%c' is not a JSON escape", e);
            } else {
                snprintf(m, 64, "byte 0x%02X is not a JSON escape", (int32_t)(uint8_t)e);
            }
            js_fail(j, m);
            free(buf);
            return ps_str_new(j->ctx, "", 0);
        }
    }
    PsStr *out = ps_str_new(j->ctx, buf, k);
    free(buf);
    return out;
}

static PsObj *js_array(PsJson *j) {
    j->i += 1;
    PsList *l = ps_list_new(j->ctx, (int32_t)sizeof(PsStrPtr), 1, 0);
    js_space(j);
    if (j->i < j->n && j->s[j->i] == ']') {
        j->i += 1;
        return (PsObj *)l;
    }
    while (j->bad == 0) {
        if (j->i >= j->n) {
            js_fail(j, "an array that never ends");
            return (PsObj *)l;
        }
        PsObj *v = js_value(j);
        if (j->bad != 0) {
            return (PsObj *)l;
        }
        char *slot = ps_list_push(j->ctx, l);
        PsObj **p = (PsObj **)slot;
        *p = v;
        js_space(j);
        if (j->i < j->n && j->s[j->i] == ',') {
            j->i += 1;
            js_space(j);
            continue;
        }
        if (j->i < j->n && j->s[j->i] == ']') {
            j->i += 1;
            return (PsObj *)l;
        }
        js_fail(j, "a ',' or a ']' was expected");
        return (PsObj *)l;
    }
    return (PsObj *)l;
}

static PsObj *js_object(PsJson *j) {
    j->i += 1;
    PsDict *d = ps_dict_new(j->ctx, (int32_t)sizeof(PsStrPtr), (int32_t)sizeof(PsStrPtr), PS_K_STR, 1, 1);
    js_space(j);
    if (j->i < j->n && j->s[j->i] == '}') {
        j->i += 1;
        return (PsObj *)d;
    }
    while (j->bad == 0) {
        js_space(j);
        if (j->i >= j->n || j->s[j->i] != '"') {
            js_fail(j, "a key has to be a string");
            return (PsObj *)d;
        }
        PsStr *k = js_string(j);
        if (j->bad != 0) {
            return (PsObj *)d;
        }
        js_space(j);
        if (j->i >= j->n || j->s[j->i] != ':') {
            js_fail(j, "a ':' was expected");
            return (PsObj *)d;
        }
        j->i += 1;
        js_space(j);
        PsObj *v = js_value(j);
        if (j->bad != 0) {
            return (PsObj *)d;
        }
        char *slot = ps_dict_put(j->ctx, d, (char *)&k);
        PsObj **vp = (PsObj **)slot;
        *vp = v;
        js_space(j);
        if (j->i < j->n && j->s[j->i] == ',') {
            j->i += 1;
            continue;
        }
        if (j->i < j->n && j->s[j->i] == '}') {
            j->i += 1;
            return (PsObj *)d;
        }
        js_fail(j, "a ',' or a '}' was expected");
        return (PsObj *)d;
    }
    return (PsObj *)d;
}

static PsObj *js_number(PsJson *j) {
    size_t start = j->i;
    int neg = 0;
    if (j->s[j->i] == '-') {
        neg = 1;
        j->i += 1;
    }
    if (j->i >= j->n || j->s[j->i] < '0' || j->s[j->i] > '9') {
        js_fail(j, "a number needs a digit");
        return ps_any_none(j->ctx);
    }
    size_t dstart = j->i;
    if (j->s[j->i] == '0') {
        j->i += 1;
        if (j->i < j->n && j->s[j->i] >= '0' && j->s[j->i] <= '9') {
            js_fail(j, "a number may not have a leading zero");
            return ps_any_none(j->ctx);
        }
    } else {
        while (j->i < j->n && j->s[j->i] >= '0' && j->s[j->i] <= '9') {
            j->i += 1;
        }
    }
    size_t dend = j->i;
    int integral = 1;
    if (j->i < j->n && j->s[j->i] == '.') {
        integral = 0;
        j->i += 1;
        if (j->i >= j->n || j->s[j->i] < '0' || j->s[j->i] > '9') {
            js_fail(j, "a fraction needs a digit after the point");
            return ps_any_none(j->ctx);
        }
        while (j->i < j->n && j->s[j->i] >= '0' && j->s[j->i] <= '9') {
            j->i += 1;
        }
    }
    if (j->i < j->n && (j->s[j->i] == 'e' || j->s[j->i] == 'E')) {
        integral = 0;
        j->i += 1;
        if (j->i < j->n && (j->s[j->i] == '+' || j->s[j->i] == '-')) {
            j->i += 1;
        }
        if (j->i >= j->n || j->s[j->i] < '0' || j->s[j->i] > '9') {
            js_fail(j, "an exponent needs a digit");
            return ps_any_none(j->ctx);
        }
        while (j->i < j->n && j->s[j->i] >= '0' && j->s[j->i] <= '9') {
            j->i += 1;
        }
    }
    if (!integral) {
        return ps_any_float(j->ctx, strtod(j->s + start, NULL));
    }
    uint64_t lim = (uint64_t)9223372036854775807;
    if (neg) {
        lim = (uint64_t)9223372036854775807 + (uint64_t)1;
    }
    uint64_t acc = 0;
    size_t p = dstart;
    while (p < dend) {
        uint64_t dv = (uint64_t)((int32_t)j->s[p] - 48);
        if (acc > (lim - dv) / (uint64_t)10) {
            js_fail(j, "this integer does not fit in an int");
            return ps_any_none(j->ctx);
        }
        acc = acc * (uint64_t)10 + dv;
        p += 1;
    }
    if (neg) {
        if (acc == (uint64_t)9223372036854775807 + (uint64_t)1) {
            return ps_any_int(j->ctx, -9223372036854775807 - 1);
        }
        return ps_any_int(j->ctx, -(int64_t)acc);
    }
    return ps_any_int(j->ctx, (int64_t)acc);
}

static PsObj *js_value(PsJson *j) {
    js_space(j);
    if (j->i >= j->n) {
        js_fail(j, "the text ended");
        return ps_any_none(j->ctx);
    }
    char c = j->s[j->i];
    if (c == '{' || c == '[') {
        j->depth += 1;
        if (j->depth > PS_JSON_MAX_DEPTH) {
            js_fail(j, "this JSON nests deeper than the limit");
            j->depth -= 1;
            return ps_any_none(j->ctx);
        }
        PsObj *agg = (c == '{' ? js_object(j) : js_array(j));
        j->depth -= 1;
        return agg;
    }
    if (c == '"') {
        return (PsObj *)js_string(j);
    }
    if (strncmp(j->s + j->i, "true", 4) == 0) {
        j->i += 4;
        return ps_any_bool(j->ctx, 1);
    }
    if (strncmp(j->s + j->i, "false", 5) == 0) {
        j->i += 5;
        return ps_any_bool(j->ctx, 0);
    }
    if (strncmp(j->s + j->i, "null", 4) == 0) {
        j->i += 4;
        return ps_any_none(j->ctx);
    }
    if (c == '-' || (c >= '0' && c <= '9')) {
        return js_number(j);
    }
    js_fail(j, "a value was expected");
    return ps_any_none(j->ctx);
}

void ps_buffer_transfer(PsCtx *ctx, PsBuffer *b) {
    if (b != NULL) {
        b->gone_from = (void *)ctx;
    }
}

static int ps_buffer_gone(PsCtx *ctx, PsBuffer *b) {
    return b != NULL && b->gone_from != NULL && b->gone_from == (void *)ctx;
}

PsList *ps_buffer_view(PsCtx *ctx, PsBuffer *b, int32_t esize, const char *file, int32_t line) {
    if (ps_buffer_gone(ctx, b)) {
        ps_raise(ctx, "this buffer was transferred: it belongs to whoever received it (18.2)", PS_CAT_VALUE, file, line);
        return NULL;
    }
    if (b == NULL || b->open == 0) {
        ps_raise(ctx, "this buffer is closed", PS_CAT_VALUE, file, line);
        return NULL;
    }
    if (b->nbytes % (size_t)esize != (size_t)0) {
        ps_raise(ctx, "the buffer does not divide into elements of this size", PS_CAT_VALUE, file, line);
        return NULL;
    }
    PsList *l = ps_alloc(ctx, sizeof(PsList), PS_TY_LIST);
    l->len = (int64_t)(b->nbytes / (size_t)esize);
    l->cap = l->len;
    l->esize = esize;
    l->eref = 0;
    l->data = NULL;
    l->raw = b->data;
    l->owner = b;
    return l;
}

PsObj *ps_json_parse(PsCtx *ctx, PsStr *text, const char *file, int32_t line) {
    PsJson j;
    j.ctx = ctx;
    j.s = text->data;
    j.n = (size_t)text->len;
    j.i = 0;
    j.bad = 0;
    j.depth = 0;
    j.file = file;
    j.line = line;
    PsObj *v = js_value(&j);
    js_space(&j);
    if (j.bad == 0 && j.i < j.n) {
        js_fail(&j, "there is text after the value");
    }
    return v;
}

const int32_t PS_RE_MAX_GROUPS = 16;

PsList *ps_re_match(PsCtx *ctx, PsStr *pattern, PsStr *text, const char *file, int32_t line) {
    regex_t rx;
    int rc = regcomp(&rx, pattern->data, 1);
    if (rc != 0) {
        char buf[256];
        regerror(rc, &rx, buf, 256);
        ps_raise(ctx, buf, PS_CAT_VALUE, file, line);
        return NULL;
    }
    regmatch_t m[16];
    int got = regexec(&rx, text->data, (size_t)PS_RE_MAX_GROUPS, m, 0);
    if (got != 0) {
        regfree(&rx);
        return NULL;
    }
    int32_t n = 0;
    while (n < PS_RE_MAX_GROUPS && m[n].rm_so >= 0) {
        n += 1;
    }
    PsList *out = ps_list_new(ctx, (int32_t)sizeof(PsStrPtr), 1, (int64_t)n);
    size_t i;
    for (i = 0; i < n; i += 1) {
        char *st = text->data + m[i].rm_so;
        size_t ln = (size_t)(m[i].rm_eo - m[i].rm_so);
        char *slot = ps_list_push(ctx, out);
        PsStr **sp = (PsStr **)slot;
        *sp = ps_str_new(ctx, st, ln);
    }
    regfree(&rx);
    return out;
}

PsList *ps_list_sorted_by(PsCtx *ctx, PsList *l, double (*keyfn)(void *, PsCtx *, const void *), void *env) {
    int64_t n = l->len;
    PsList *out = ps_list_slice(ctx, l, 0, 0, 0, 0);
    if (n < 2) {
        return out;
    }
    double *keys = (double *)malloc((size_t)n * sizeof(double));
    int64_t *idx = (int64_t *)malloc((size_t)n * sizeof(int64_t));
    char *base = (char *)out->data + sizeof(PsArr);
    size_t es = (size_t)out->esize;
    size_t i;
    for (i = 0; i < (int32_t)n; i += 1) {
        keys[i] = keyfn(env, ctx, (void *)(base + (size_t)i * es));
        idx[i] = (int64_t)i;
        if (ctx->exc != NULL) {
            free(keys);
            free(idx);
            return out;
        }
    }
    int64_t k = 1;
    while (k < n) {
        int64_t j = k;
        while (j > 0 && keys[idx[j - 1]] > keys[idx[j]]) {
            int64_t t = idx[j - 1];
            idx[j - 1] = idx[j];
            idx[j] = t;
            j -= 1;
        }
        k += 1;
    }
    char *src = (char *)malloc((size_t)n * es);
    memcpy(src, base, (size_t)n * es);
    size_t i2;
    for (i2 = 0; i2 < (int32_t)n; i2 += 1) {
        memcpy(base + (size_t)i2 * es, src + (size_t)idx[i2] * es, es);
    }
    free(src);
    free(keys);
    free(idx);
    return out;
}

static int PS_ARGC = 0;

static char **PS_ARGV = NULL;

void ps_sys_args(int argc, char **argv) {
    PS_ARGC = argc;
    PS_ARGV = argv;
}

PsList *ps_sys_argv(PsCtx *ctx) {
    PsList *l = ps_list_new(ctx, (int32_t)sizeof(PsStrPtr), 1, (int64_t)PS_ARGC);
    size_t i;
    for (i = 0; i < PS_ARGC; i += 1) {
        char *slot = ps_list_push(ctx, l);
        PsStr **p = (PsStr **)slot;
        *p = ps_str_new(ctx, PS_ARGV[i], strlen(PS_ARGV[i]));
    }
    return l;
}

extern char **environ;

PsDict *ps_sys_env(PsCtx *ctx) {
    PsDict *d = ps_dict_new(ctx, (int32_t)sizeof(PsStrPtr), (int32_t)sizeof(PsStrPtr), PS_K_STR, 1, 1);
    char **e = environ;
    while (e != NULL && *e != NULL) {
        const char *line = *e;
        const char *eq = strchr(line, '=');
        if (eq != NULL) {
            PsStr *k = ps_str_new(ctx, line, (size_t)(eq - line));
            PsStr *v = ps_str_new(ctx, eq + 1, strlen(eq + 1));
            char *slot = ps_dict_put(ctx, d, (char *)&k);
            PsStr **vp = (PsStr **)slot;
            *vp = v;
        }
        e += 1;
    }
    return d;
}

void ps_sys_exit(PsCtx *ctx, int64_t code) {
    exit((int)code);
}

void ps_worker_detach(PsWorker *w) {
    if (w != NULL && w->blk != NULL) {
        ((PsWorkerBlk *)w->blk)->detached = 1;
    }
}

int64_t ps_worker_status(PsWorker *w) {
    if (w == NULL || w->blk == NULL) {
        return 3;
    }
    PsWorkerBlk *b = w->blk;
    if (b->done == 0) {
        return 0;
    }
    return (b->failed != 0 ? 2 : 1);
}

PsTask *ps_sleep(PsCtx *ctx, double seconds) {
    return ps_timer_task(ctx, ps_sys_time() + (seconds > 0.0 ? seconds : 0.0));
}

double ps_sys_time(void) {
    struct timespec ts;
    clock_gettime(1, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

PsClosure *ps_closure_new(PsCtx *ctx, void *fn, PsObj *env, const char *sig) {
    PsClosure *c = (PsClosure *)ps_alloc(ctx, sizeof(PsClosure), PS_TY_CLOSURE);
    c->fn = fn;
    c->env = env;
    c->sig = sig;
    return c;
}

PsClosure *ps_closure_narrow(PsCtx *ctx, PsClosure *c, const char *want, const char *file, int32_t line) {
    if (c == NULL) {
        ps_raise(ctx, "there is no function here to narrow", PS_CAT_VALUE, file, line);
        return NULL;
    }
    if (c->sig == NULL || strcmp(c->sig, want) != 0) {
        ps_raise_str(ctx, ps_str_concat(ctx, ps_str_new(ctx, "this function is ", 17), ps_str_concat(ctx, ps_str_new(ctx, (c->sig != NULL ? c->sig : "of unknown shape"), (c->sig != NULL ? strlen(c->sig) : (size_t)16)), ps_str_concat(ctx, ps_str_new(ctx, ", not ", 6), ps_str_new(ctx, want, strlen(want))))), (int64_t)PS_CAT_TYPE, file, line);
        return NULL;
    }
    return c;
}

static PsAny *ps_any_new(PsCtx *ctx, int32_t kind) {
    PsAny *a = (PsAny *)ps_alloc(ctx, sizeof(PsAny), PS_TY_ANY);
    a->kind = kind;
    a->i = 0;
    a->f = 0.0;
    return a;
}

PsObj *ps_any_int(PsCtx *ctx, int64_t v) {
    PsAny *a = ps_any_new(ctx, PS_ANY_INT);
    a->i = v;
    return (PsObj *)a;
}

PsObj *ps_any_float(PsCtx *ctx, double v) {
    PsAny *a = ps_any_new(ctx, PS_ANY_FLOAT);
    a->f = v;
    return (PsObj *)a;
}

PsObj *ps_any_bool(PsCtx *ctx, int v) {
    PsAny *a = ps_any_new(ctx, PS_ANY_BOOL);
    a->i = (v ? 1 : 0);
    return (PsObj *)a;
}

PsObj *ps_any_none(PsCtx *ctx) {
    return (PsObj *)ps_any_new(ctx, PS_ANY_NONE);
}

static const char *ps_any_what(PsObj *v) {
    if (v == NULL) {
        return "nothing";
    }
    switch (v->ty) {
        case PS_TY_STR: {
            return "str";
        }
        case PS_TY_LIST: {
            return "list";
        }
        case PS_TY_DICT: {
            return "dict";
        }
        case PS_TY_ANY: {
            PsAny *a = (PsAny *)v;
            if (a->kind == PS_ANY_INT) {
                return "int";
            }
            if (a->kind == PS_ANY_FLOAT) {
                return "float";
            }
            if (a->kind == PS_ANY_BOOL) {
                return "bool";
            }
            return "None";
        }
        default: {
            return "a value of another type";
        }
    }
}

static void ps_as_fail(PsCtx *ctx, PsObj *v, const char *want, const char *file, int32_t line) {
    char msg[160];
    snprintf(msg, 160, "this `any` holds %s, not %s", ps_any_what(v), want);
    ps_raise(ctx, msg, PS_CAT_TYPE, file, line);
}

int64_t ps_as_int(PsCtx *ctx, PsObj *v, const char *file, int32_t line) {
    if (v == NULL || v->ty != PS_TY_ANY || ((PsAny *)v)->kind != PS_ANY_INT) {
        ps_as_fail(ctx, v, "int", file, line);
        return 0;
    }
    return ((PsAny *)v)->i;
}

double ps_as_float(PsCtx *ctx, PsObj *v, const char *file, int32_t line) {
    if (v != NULL && v->ty == PS_TY_ANY) {
        PsAny *a = (PsAny *)v;
        if (a->kind == PS_ANY_FLOAT) {
            return a->f;
        }
        if (a->kind == PS_ANY_INT) {
            return (double)a->i;
        }
    }
    ps_as_fail(ctx, v, "float", file, line);
    return 0.0;
}

int ps_as_bool(PsCtx *ctx, PsObj *v, const char *file, int32_t line) {
    if (v == NULL || v->ty != PS_TY_ANY || ((PsAny *)v)->kind != PS_ANY_BOOL) {
        ps_as_fail(ctx, v, "bool", file, line);
        return 0;
    }
    return ((PsAny *)v)->i != 0;
}

PsObj *ps_as_ref(PsCtx *ctx, PsObj *v, int32_t want, const char *what, const char *file, int32_t line) {
    if (v == NULL || v->ty != want) {
        ps_as_fail(ctx, v, what, file, line);
        return NULL;
    }
    return v;
}

int ps_is_kind(PsObj *v, int32_t ty, int32_t kind) {
    if (v == NULL) {
        return 0;
    }
    if (ty != PS_TY_ANY) {
        return v->ty == ty;
    }
    return v->ty == PS_TY_ANY && ((PsAny *)v)->kind == kind;
}

PsErr *ps_exc_take(PsCtx *ctx) {
    PsErr *e = ctx->exc;
    ctx->exc = NULL;
    return e;
}

void ps_exc_put(PsCtx *ctx, PsErr *e) {
    if (e != NULL) {
        ctx->exc = e;
    }
}

PsFile *ps_file_open(PsCtx *ctx, PsStr *path, PsStr *mode, const char *file, int32_t line) {
    PsFile *f = (PsFile *)ps_alloc(ctx, sizeof(PsFile), PS_TY_FILE);
    f->fp = NULL;
    f->is_open = 0;
    FILE *fp = fopen(path->data, mode->data);
    if (fp == NULL) {
        char msg[512];
        snprintf(msg, 512, "cannot open '%s'", path->data);
        ps_raise(ctx, msg, PS_CAT_IO, file, line);
        return f;
    }
    f->fp = fp;
    f->is_open = 1;
    return f;
}

int64_t ps_file_write(PsCtx *ctx, PsFile *f, PsStr *s, const char *file, int32_t line) {
    if (f == NULL || f->is_open == 0) {
        ps_raise(ctx, "write to a file that is not open", PS_CAT_IO, file, line);
        return 0;
    }
    size_t n = fwrite(s->data, 1, (size_t)s->len, f->fp);
    if (n != (size_t)s->len) {
        ps_raise(ctx, "could not write the whole string", PS_CAT_IO, file, line);
    }
    return (int64_t)n;
}

PsStr *ps_file_read(PsCtx *ctx, PsFile *f, const char *file, int32_t line) {
    if (f == NULL || f->is_open == 0) {
        ps_raise(ctx, "read from a file that is not open", PS_CAT_IO, file, line);
        return ps_str_new(ctx, "", 0);
    }
    size_t cap = 4096;
    size_t len = 0;
    char *buf = (char *)malloc(cap);
    while (1) {
        if (len == cap) {
            cap *= 2;
            buf = (char *)realloc(buf, cap);
        }
        size_t got = fread(buf + len, 1, cap - len, f->fp);
        len += got;
        if (got == 0) {
            break;
        }
    }
    PsStr *out = ps_str_new(ctx, buf, len);
    free(buf);
    return out;
}

PsList *ps_file_readlines(PsCtx *ctx, PsFile *f, const char *file, int32_t line) {
    PsStr *whole = ps_file_read(ctx, f, file, line);
    PsStr *nl = ps_str_new(ctx, "\n", 1);
    return ps_str_split(ctx, whole, nl);
}

void ps_file_close(PsCtx *ctx, PsFile *f) {
    if (f != NULL && f->is_std != 0) {
        return;
    }
    if (f != NULL && f->is_open != 0) {
        fclose(f->fp);
        f->is_open = 0;
        f->fp = NULL;
    }
}

static void ps_sstr_set(PsSStr *dst, PsStr *s);

void ps_shared_str_init(PsSStr *slot, const char *bytes, int64_t n) {
    if (slot->p != NULL) {
        free(slot->p);
    }
    slot->p = (char *)malloc((size_t)n + 1);
    memcpy(slot->p, bytes, (size_t)n);
    slot->p[n] = '\0';
    slot->n = (size_t)n;
}

PsStr *ps_shared_str_get(PsCtx *ctx, void *mu, PsSStr *slot) {
    ps_lock(mu);
    PsStr *r = ps_str_new(ctx, (slot->p != NULL ? slot->p : ""), (slot->p != NULL ? slot->n : (size_t)0));
    ps_unlock(mu);
    return r;
}

void ps_shared_str_put(void *mu, PsSStr *slot, PsStr *v) {
    ps_lock(mu);
    ps_sstr_set(slot, v);
    ps_unlock(mu);
}

void *ps_lock_new(void) {
    pthread_mutex_t *mu = (pthread_mutex_t *)malloc(sizeof(pthread_mutex_t));
    pthread_mutex_init(mu, NULL);
    return (void *)mu;
}

void ps_lock(void *mu) {
    pthread_mutex_lock((pthread_mutex_t *)mu);
}

void ps_unlock(void *mu) {
    pthread_mutex_unlock((pthread_mutex_t *)mu);
}

static uint64_t ps_hash_bytes(const char *b, size_t n);

static void ps_sdict_grow(PsSDict *d, int64_t ncap);

static int64_t ps_sdict_slot(PsSDict *d, const void *key);

PsTimer *ps_interval_new(PsCtx *ctx, double seconds, const char *file, int32_t line) {
    if (seconds <= 0.0) {
        ps_raise(ctx, "an interval needs a positive period", PS_CAT_VALUE, file, line);
        return NULL;
    }
    PsTimer *t = (PsTimer *)ps_alloc(ctx, sizeof(PsTimer), PS_TY_TIMER);
    t->period = seconds;
    t->next = ps_sys_time() + seconds;
    return t;
}

PsTask *ps_timer_tick(PsCtx *ctx, PsTimer *t) {
    double now = ps_sys_time();
    double at = t->next;
    if (now < t->next) {
        t->next = t->next + t->period;
    } else {
        at = now;
        t->next = now + t->period;
    }
    return ps_timer_task(ctx, at);
}

void ps_pack_int(PsCtx *ctx, PsList *l, uint64_t v, int32_t nbytes, int32_t be) {
    size_t i;
    for (i = 0; i < nbytes; i += 1) {
        int32_t k = (be != 0 ? nbytes - 1 - i : i);
        char *p = ps_list_push(ctx, l);
        *(uint8_t *)p = (uint8_t)((v >> (uint64_t)(k * 8)) & (uint64_t)255);
    }
}

uint64_t ps_unpack_int(PsList *l, int64_t off, int32_t nbytes, int32_t be) {
    uint64_t v = 0;
    uint8_t *base = (uint8_t *)ps_list_base(l);
    size_t i;
    for (i = 0; i < nbytes; i += 1) {
        int32_t k = (be != 0 ? nbytes - 1 - i : i);
        v = v | ((uint64_t)base[off + (int64_t)i] << (uint64_t)(k * 8));
    }
    return v;
}

void ps_pack_f64(PsCtx *ctx, PsList *l, double v, int32_t be) {
    uint64_t b = 0;
    memcpy(&b, &v, sizeof(b));
    ps_pack_int(ctx, l, b, 8, be);
}

double ps_unpack_f64(PsList *l, int64_t off, int32_t be) {
    uint64_t b = ps_unpack_int(l, off, 8, be);
    double v = 0.0;
    memcpy(&v, &b, sizeof(v));
    return v;
}

void ps_pack_f32(PsCtx *ctx, PsList *l, float v, int32_t be) {
    uint32_t b = 0;
    memcpy(&b, &v, sizeof(b));
    ps_pack_int(ctx, l, (uint64_t)b, 4, be);
}

float ps_unpack_f32(PsList *l, int64_t off, int32_t be) {
    uint32_t b = (uint32_t)ps_unpack_int(l, off, 4, be);
    float v = 0.0;
    memcpy(&v, &b, sizeof(v));
    return v;
}

void ps_unpack_check(PsCtx *ctx, PsList *l, int64_t want, const char *file, int32_t line) {
    if (l == NULL || l->len != want) {
        ps_raise(ctx, "these bytes are not the right length for this record", PS_CAT_VALUE, file, line);
    }
}

static void ps_sstr_set(PsSStr *dst, PsStr *s) {
    if (dst->p != NULL) {
        free(dst->p);
    }
    size_t n = (size_t)s->len;
    dst->p = (char *)malloc(n + 1);
    memcpy(dst->p, s->data, n);
    dst->p[n] = '\0';
    dst->n = n;
}

static uint64_t ps_skey_hash(PsSDict *d, const void *key) {
    if (d->kstr) {
        PsStr *ks = (PsStr *)key;
        return ps_hash_bytes(ks->data, (size_t)ks->len);
    }
    return ps_hash_bytes((char *)key, d->ksize);
}

static int ps_skey_eq(PsSDict *d, const char *slot, const void *key) {
    if (d->kstr) {
        PsSStr *st = (PsSStr *)slot;
        PsStr *ks = (PsStr *)key;
        if (st->n != (size_t)ks->len) {
            return 0;
        }
        return memcmp(st->p, ks->data, st->n) == 0;
    }
    return memcmp(slot, (char *)key, d->ksize) == 0;
}

static void ps_sdict_grow(PsSDict *d, int64_t ncap) {
    char *okeys = d->keys;
    char *ovals = d->vals;
    char *ostate = d->state;
    int64_t ocap = d->cap;
    d->keys = (char *)calloc((size_t)ncap, d->ksize);
    d->vals = (char *)calloc((size_t)ncap, d->vsize);
    d->state = (char *)calloc((size_t)ncap, 1);
    d->cap = ncap;
    d->len = 0;
    size_t i;
    for (i = 0; i < ocap; i += 1) {
        if (ostate == NULL || ostate[i] == 0) {
            continue;
        }
        char *ksrc = okeys + (size_t)i * d->ksize;
        uint64_t h = 0;
        if (d->kstr) {
            PsSStr *ss = (PsSStr *)ksrc;
            h = ps_hash_bytes(ss->p, ss->n);
        } else {
            h = ps_hash_bytes(ksrc, d->ksize);
        }
        int64_t j = (int64_t)(h % (uint64_t)ncap);
        while (d->state[j] != 0) {
            j = (j + 1) % ncap;
        }
        memcpy(d->keys + (size_t)j * d->ksize, ksrc, d->ksize);
        memcpy(d->vals + (size_t)j * d->vsize, ovals + (size_t)i * d->vsize, d->vsize);
        d->state[j] = 1;
        d->len += 1;
    }
    free(okeys);
    free(ovals);
    free(ostate);
}

PsSDict *ps_sdict_new(int64_t ksize, int64_t vsize, int kstr, int vstr) {
    PsSDict *d = (PsSDict *)calloc(1, sizeof(PsSDict));
    d->mu = ps_lock_new();
    d->ksize = (size_t)ksize;
    d->vsize = (size_t)vsize;
    d->kstr = kstr;
    d->vstr = vstr;
    ps_sdict_grow(d, 16);
    return d;
}

int64_t ps_sdict_len(PsSDict *d) {
    ps_lock(d->mu);
    int64_t n = d->len;
    ps_unlock(d->mu);
    return n;
}

static int64_t ps_sdict_slot(PsSDict *d, const void *key) {
    int64_t j = (int64_t)(ps_skey_hash(d, key) % (uint64_t)d->cap);
    while (d->state[j] != 0) {
        if (ps_skey_eq(d, d->keys + (size_t)j * d->ksize, key)) {
            return j;
        }
        j = (j + 1) % d->cap;
    }
    return j;
}

void ps_sdict_put(PsCtx *ctx, PsSDict *d, const void *key, const void *val) {
    ps_lock(d->mu);
    if ((d->len + 1) * 4 > d->cap * 3) {
        ps_sdict_grow(d, d->cap * 2);
    }
    int64_t j = ps_sdict_slot(d, key);
    if (d->state[j] == 0) {
        if (d->kstr) {
            PsSStr *ks = (PsSStr *)(d->keys + (size_t)j * d->ksize);
            ks->p = NULL;
            ps_sstr_set(ks, (PsStr *)key);
        } else {
            memcpy(d->keys + (size_t)j * d->ksize, (char *)key, d->ksize);
        }
        d->state[j] = 1;
        d->len += 1;
        if (d->vstr) {
            PsSStr *vs0 = (PsSStr *)(d->vals + (size_t)j * d->vsize);
            vs0->p = NULL;
        }
    }
    if (d->vstr) {
        ps_sstr_set((PsSStr *)(d->vals + (size_t)j * d->vsize), (PsStr *)val);
    } else {
        memcpy(d->vals + (size_t)j * d->vsize, (char *)val, d->vsize);
    }
    ps_unlock(d->mu);
}

int ps_sdict_has(PsSDict *d, const void *key) {
    ps_lock(d->mu);
    int64_t j = ps_sdict_slot(d, key);
    int r = d->state[j] != 0;
    ps_unlock(d->mu);
    return r;
}

void ps_sdict_get(PsCtx *ctx, PsSDict *d, const void *key, void *out, const char *file, int32_t line) {
    ps_lock(d->mu);
    int64_t j = ps_sdict_slot(d, key);
    if (d->state[j] == 0) {
        ps_unlock(d->mu);
        ps_raise(ctx, "key not in the shared dict", PS_CAT_KEY, file, line);
        return;
    }
    if (d->vstr) {
        PsSStr *vs = (PsSStr *)(d->vals + (size_t)j * d->vsize);
        PsStr *cp = ps_str_new(ctx, vs->p, vs->n);
        memcpy(out, &cp, sizeof(cp));
    } else {
        memcpy(out, d->vals + (size_t)j * d->vsize, d->vsize);
    }
    ps_unlock(d->mu);
}

int ps_sdict_del(PsSDict *d, const void *key) {
    ps_lock(d->mu);
    int64_t j = ps_sdict_slot(d, key);
    if (d->state[j] == 0) {
        ps_unlock(d->mu);
        return 0;
    }
    if (d->kstr) {
        PsSStr *ks = (PsSStr *)(d->keys + (size_t)j * d->ksize);
        free(ks->p);
        ks->p = NULL;
    }
    if (d->vstr) {
        PsSStr *vs = (PsSStr *)(d->vals + (size_t)j * d->vsize);
        free(vs->p);
        vs->p = NULL;
    }
    d->state[j] = 0;
    d->len -= 1;
    int64_t k = (j + 1) % d->cap;
    while (d->state[k] != 0) {
        char *kb = d->keys + (size_t)k * d->ksize;
        uint64_t h = (d->kstr ? ps_hash_bytes(((PsSStr *)kb)->p, ((PsSStr *)kb)->n) : ps_hash_bytes(kb, d->ksize));
        int64_t want = (int64_t)(h % (uint64_t)d->cap);
        if (want != k) {
            char *tk = (char *)malloc(d->ksize);
            char *tv = (char *)malloc(d->vsize);
            memcpy(tk, kb, d->ksize);
            memcpy(tv, d->vals + (size_t)k * d->vsize, d->vsize);
            d->state[k] = 0;
            d->len -= 1;
            int64_t j2 = (int64_t)(h % (uint64_t)d->cap);
            while (d->state[j2] != 0) {
                j2 = (j2 + 1) % d->cap;
            }
            memcpy(d->keys + (size_t)j2 * d->ksize, tk, d->ksize);
            memcpy(d->vals + (size_t)j2 * d->vsize, tv, d->vsize);
            d->state[j2] = 1;
            d->len += 1;
            free(tk);
            free(tv);
        }
        k = (k + 1) % d->cap;
    }
    ps_unlock(d->mu);
    return 1;
}

static void ps_sched_push(PsCtx *ctx, PsTask *t) {
    t->next = NULL;
    if (ctx->ready_tail == NULL) {
        ctx->ready = t;
        ctx->ready_tail = t;
    } else {
        ctx->ready_tail->next = t;
        ctx->ready_tail = t;
    }
}

static PsTask *ps_sched_pop(PsCtx *ctx) {
    PsTask *t = ctx->ready;
    if (t == NULL) {
        return NULL;
    }
    ctx->ready = t->next;
    if (ctx->ready == NULL) {
        ctx->ready_tail = NULL;
    }
    t->next = NULL;
    return t;
}

PsTask *ps_task_new(PsCtx *ctx, int (*step)(PsCtx *, PsTask *), PsObj *frame) {
    PsTask *t = (PsTask *)ps_alloc(ctx, sizeof(PsTask), PS_TY_TASK);
    t->state = 0;
    t->step = step;
    t->frame = frame;
    t->err = NULL;
    t->waiting_on = NULL;
    t->waiter = NULL;
    t->cancelled = 0;
    t->deadline = 0.0;
    t->is_timer = 0;
    t->next = NULL;
    ps_task_clear_recv(t);
    PsObj **slots[1];
    slots[0] = (PsObj **)&t;
    PsFrame f;
    ps_push_frame(ctx, &f, slots, 1);
    ps_task_step(ctx, t);
    ps_pop_frame(ctx, &f);
    return t;
}

int ps_task_done(PsTask *t) {
    return t != NULL && (t->state == -1 || t->state == -2);
}

void ps_task_step(PsCtx *ctx, PsTask *t) {
    if (ps_task_done(t)) {
        return;
    }
    if (t->cancelled != 0 && ctx->exc == NULL) {
        ps_raise(ctx, "task cancelled", PS_CAT_VALUE, "<cancel>", 0);
    }
    PsObj **slots[1];
    slots[0] = (PsObj **)&t;
    PsFrame f;
    ps_push_frame(ctx, &f, slots, 1);
    int done = t->step(ctx, t);
    ps_pop_frame(ctx, &f);
    if (!done) {
        return;
    }
    if (t->state != -2) {
        t->state = -1;
    }
    PsTask *w = t->waiter;
    t->waiter = NULL;
    if (w != NULL) {
        w->waiting_on = NULL;
        ps_sched_push(ctx, w);
    }
}

PsList *ps_gather(PsCtx *ctx, PsList *ts, int32_t esize, int eref) {
    PsList *out = ps_list_new(ctx, esize, eref, ts->len);
    int64_t i = 0;
    while (i < ts->len) {
        PsTask **base = (PsTask **)((char *)ts->data + sizeof(PsArr) + (size_t)i * (size_t)ts->esize);
        PsTask *t = *base;
        ps_task_wait(ctx, t);
        if (ctx->exc != NULL) {
            return out;
        }
        char *dst = ps_list_push(ctx, out);
        base = (PsTask **)((char *)ts->data + sizeof(PsArr) + (size_t)i * (size_t)ts->esize);
        memcpy(dst, ps_task_ret(*base), (size_t)esize);
        i += 1;
    }
    return out;
}

static void ps_sched_push(PsCtx *ctx, PsTask *t);

static PsTask *ps_sched_pop(PsCtx *ctx);

PsTask *ps_timer_task(PsCtx *ctx, double at) {
    char *fr = (char *)ps_alloc(ctx, sizeof(PsUser) + sizeof(PsStrPtr), PS_TY_USER);
    PsUser *u = (PsUser *)fr;
    u->desc = &PS_POD_DESC;
    memset(fr + sizeof(PsUser), 0, sizeof(PsStrPtr));
    PsTask *t = (PsTask *)ps_alloc(ctx, sizeof(PsTask), PS_TY_TASK);
    t->state = 0;
    t->step = NULL;
    t->frame = (PsObj *)fr;
    t->err = NULL;
    t->waiting_on = NULL;
    t->waiter = NULL;
    t->next = NULL;
    t->cancelled = 0;
    t->is_timer = 1;
    t->deadline = at;
    ps_task_clear_recv(t);
    t->next = ctx->timers;
    ctx->timers = t;
    return t;
}

static double ps_timer_soonest(PsCtx *ctx) {
    double best = -1.0;
    PsTask *t = ctx->timers;
    while (t != NULL) {
        if (t->state == 0 && (best < 0.0 || t->deadline < best)) {
            best = t->deadline;
        }
        t = t->next;
    }
    return best;
}

static int ps_timers_fire(PsCtx *ctx, double now) {
    int any = 0;
    PsTask *t = ctx->timers;
    while (t != NULL) {
        PsTask *n = t->next;
        if (t->state == 0 && t->deadline <= now) {
            t->state = -1;
            PsTask *w = t->waiter;
            t->waiter = NULL;
            if (w != NULL) {
                w->waiting_on = NULL;
                ps_sched_push(ctx, w);
            }
            any = 1;
        }
        t = n;
    }
    PsTask **prev = &ctx->timers;
    PsTask *cur = ctx->timers;
    while (cur != NULL) {
        PsTask *nx = cur->next;
        if (cur->state != 0) {
            *prev = nx;
            cur->next = NULL;
        } else {
            prev = &cur->next;
        }
        cur = nx;
    }
    return any;
}

int ps_sched_progress(PsCtx *ctx) {
    PsTask *n = ps_sched_pop(ctx);
    if (n != NULL) {
        ps_task_step(ctx, n);
        return 1;
    }
    if (ps_timers_fire(ctx, ps_sys_time())) {
        return 1;
    }
    if (ps_recvs_poll(ctx)) {
        return 1;
    }
    double soon = ps_timer_soonest(ctx);
    int bad = 0;
    int32_t nfd = ps_recv_fds(ctx, &bad);
    if (nfd == 0 && !bad) {
        if (soon < 0.0) {
            return 0;
        }
        double wait = soon - ps_sys_time();
        if (wait > 0.0) {
            struct timespec ts;
            ts.tv_sec = (int64_t)wait;
            ts.tv_nsec = (int64_t)((wait - (double)(int64_t)wait) * 1000000000.0);
            nanosleep(&ts, NULL);
        }
        return ps_timers_fire(ctx, ps_sys_time());
    }
    int ms = -1;
    if (soon >= 0.0) {
        double w2 = (soon - ps_sys_time()) * 1000.0;
        ms = (w2 > 0.0 ? (int)w2 + 1 : 0);
    }
    if (bad && (ms < 0 || ms > 2)) {
        ms = 2;
    }
    if (nfd > 0) {
        struct pollfd fds[64];
        int32_t k = 0;
        int anyio = 0;
        PsTask *t2 = ctx->waiters;
        while (t2 != NULL && k < PS_POLL_MAX) {
            if (t2->state == 0) {
                if (t2->is_io != 0 && t2->work != NULL && t2->work->fd >= 0) {
                    fds[k].fd = t2->work->fd;
                    fds[k].events = t2->work->events;
                    fds[k].revents = 0;
                    k += 1;
                } else if (t2->is_io != 0) {
                    anyio = 1;
                } else {
                    int fd = (t2->rdir == 0 ? t2->rblk->up_r : t2->rblk->dn_r);
                    if (fd >= 0) {
                        fds[k].fd = fd;
                        fds[k].events = 1;
                        fds[k].revents = 0;
                        k += 1;
                    }
                }
            }
            t2 = t2->next;
        }
        if (anyio && ctx->io_r >= 0 && k < PS_POLL_MAX) {
            fds[k].fd = ctx->io_r;
            fds[k].events = 1;
            fds[k].revents = 0;
            k += 1;
        }
        if (nfd > PS_POLL_MAX && (ms < 0 || ms > 2)) {
            ms = 2;
        }
        poll(fds, (uint64_t)k, ms);
        size_t i;
        for (i = 0; i < k; i += 1) {
            if (fds[i].revents != 0) {
                ps_pipe_drain(fds[i].fd);
            }
        }
    } else if (ms > 0) {
        struct timespec ts2;
        ts2.tv_sec = 0;
        ts2.tv_nsec = (int64_t)ms * 1000000;
        nanosleep(&ts2, NULL);
    }
    if (ps_recvs_poll(ctx)) {
        return 1;
    }
    ps_timers_fire(ctx, ps_sys_time());
    return 1;
}

void ps_task_yield(PsCtx *ctx, PsTask *t) {
    ps_sched_push(ctx, t);
}

int ps_sched_yield(PsCtx *ctx) {
    PsTask *n = ps_sched_pop(ctx);
    if (n == NULL) {
        return 0;
    }
    ps_task_step(ctx, n);
    return 1;
}

void ps_sched_drain(PsCtx *ctx) {
    while (ps_sched_progress(ctx)) {
        if (ctx->exc != NULL) {
            return;
        }
    }
}

PsTask *ps_task_of_int(PsCtx *ctx, int64_t v) {
    PsTask *t = ps_msg_task(ctx, NULL, sizeof(int64_t));
    *(int64_t *)ps_task_ret(t) = v;
    return t;
}

void ps_task_cancel(PsCtx *ctx, PsTask *t) {
    if (t == NULL || ps_task_done(t)) {
        return;
    }
    t->cancelled = 1;
    if (t->waiting_on != NULL) {
        t->waiting_on = NULL;
        ps_sched_push(ctx, t);
    }
}

int ps_task_cancelled(PsTask *t) {
    return t != NULL && t->cancelled != 0;
}

int64_t ps_race(PsCtx *ctx, PsList *ts) {
    if (ts == NULL || ts->len == 0) {
        ps_raise(ctx, "race() needs at least one task", PS_CAT_VALUE, "<race>", 0);
        return -1;
    }
    int64_t win = -1;
    while (win < 0) {
        int64_t i = 0;
        while (i < ts->len) {
            PsTask **base = (PsTask **)(ps_list_base(ts) + (size_t)i * (size_t)ts->esize);
            if (ps_task_done(*base)) {
                win = i;
                i = ts->len;
            } else {
                i += 1;
            }
        }
        if (win >= 0) {
            break;
        }
        if (!ps_sched_progress(ctx)) {
            ps_raise(ctx, "deadlock: racing tasks that nothing can finish", PS_CAT_VALUE, "<race>", 0);
            return -1;
        }
        if (ctx->exc != NULL) {
            return -1;
        }
    }
    int64_t i2 = 0;
    while (i2 < ts->len) {
        if (i2 != win) {
            PsTask **lose = (PsTask **)(ps_list_base(ts) + (size_t)i2 * (size_t)ts->esize);
            ps_task_cancel(ctx, *lose);
        }
        i2 += 1;
    }
    PsTask **wb = (PsTask **)(ps_list_base(ts) + (size_t)win * (size_t)ts->esize);
    if ((*wb)->err != NULL && ctx->exc == NULL) {
        ctx->exc = (*wb)->err;
    }
    return win;
}

int ps_timeout(PsCtx *ctx, PsTask *t, double seconds) {
    double deadline = ps_sys_time() + seconds;
    ps_timer_task(ctx, deadline);
    PsObj **slots[1];
    slots[0] = (PsObj **)&t;
    PsFrame f;
    ps_push_frame(ctx, &f, slots, 1);
    while (!ps_task_done(t)) {
        if (ps_sys_time() >= deadline) {
            ps_pop_frame(ctx, &f);
            ps_task_cancel(ctx, t);
            return 0;
        }
        if (!ps_sched_progress(ctx)) {
            ps_pop_frame(ctx, &f);
            ps_task_cancel(ctx, t);
            return 0;
        }
        if (ctx->exc != NULL) {
            ps_pop_frame(ctx, &f);
            return 1;
        }
    }
    ps_pop_frame(ctx, &f);
    if (t->err != NULL && ctx->exc == NULL) {
        ctx->exc = t->err;
    }
    return 1;
}

PsTask *ps_gather_task(PsCtx *ctx, PsList *ts, int32_t esize, int eref) {
    PsList *out = ps_gather(ctx, ts, esize, eref);
    char *fr = (char *)ps_alloc(ctx, sizeof(PsUser) + sizeof(PsStrPtr), PS_TY_USER);
    PsUser *u = (PsUser *)fr;
    u->desc = &PS_GATHER_DESC;
    PsList **p = (PsList **)(fr + sizeof(PsUser));
    *p = out;
    PsTask *t = (PsTask *)ps_alloc(ctx, sizeof(PsTask), PS_TY_TASK);
    t->state = -1;
    t->step = NULL;
    t->frame = (PsObj *)fr;
    t->err = NULL;
    t->waiting_on = NULL;
    t->waiter = NULL;
    t->cancelled = 0;
    t->deadline = 0.0;
    t->is_timer = 0;
    t->next = NULL;
    ps_task_clear_recv(t);
    return t;
}

PsList *ps_gather_settled(PsCtx *ctx, PsList *ts) {
    PsList *out = ps_list_new(ctx, (int32_t)sizeof(PsStrPtr), 1, (ts != NULL ? ts->len : 0));
    int64_t i = 0;
    while (ts != NULL && i < ts->len) {
        PsTask **base = (PsTask **)(ps_list_base(ts) + (size_t)i * (size_t)ts->esize);
        PsTask *t = *base;
        while (!ps_task_done(t)) {
            if (!ps_sched_progress(ctx)) {
                break;
            }
            if (ctx->exc != NULL) {
                ps_exc_take(ctx);
            }
        }
        base = (PsTask **)(ps_list_base(ts) + (size_t)i * (size_t)ts->esize);
        char *dst = ps_list_push(ctx, out);
        *(PsErr **)dst = (*base)->err;
        i += 1;
    }
    return out;
}

PsTask *ps_gather_settled_task(PsCtx *ctx, PsList *ts) {
    PsList *out = ps_gather_settled(ctx, ts);
    PsTask *t = ps_msg_task(ctx, NULL, sizeof(PsStrPtr));
    ((PsUser *)t->frame)->desc = &PS_REFMSG_DESC;
    *(PsList **)ps_task_ret(t) = out;
    return t;
}

int64_t ps_first_ok(PsCtx *ctx, PsList *ts) {
    if (ts == NULL || ts->len == 0) {
        ps_raise(ctx, "first_ok() needs at least one task", PS_CAT_VALUE, "<first_ok>", 0);
        return -1;
    }
    while (1) {
        int alldone = 1;
        int64_t i = 0;
        while (i < ts->len) {
            PsTask **base = (PsTask **)(ps_list_base(ts) + (size_t)i * (size_t)ts->esize);
            PsTask *t = *base;
            if (ps_task_done(t)) {
                if (t->state != -2 && t->err == NULL) {
                    int64_t j = 0;
                    while (j < ts->len) {
                        if (j != i) {
                            PsTask **lose = (PsTask **)(ps_list_base(ts) + (size_t)j * (size_t)ts->esize);
                            ps_task_cancel(ctx, *lose);
                        }
                        j += 1;
                    }
                    return i;
                }
            } else {
                alldone = 0;
            }
            i += 1;
        }
        if (alldone) {
            ps_raise(ctx, "first_ok(): every task failed", PS_CAT_VALUE, "<first_ok>", 0);
            return -1;
        }
        if (!ps_sched_progress(ctx)) {
            ps_raise(ctx, "deadlock: nothing can finish these tasks", PS_CAT_VALUE, "<first_ok>", 0);
            return -1;
        }
        if (ctx->exc != NULL) {
            ps_exc_take(ctx);
        }
    }
    return -1;
}

PsList *ps_gather_map(PsCtx *ctx, PsList *items, PsTask *(*mk)(void *, PsCtx *, const void *), void *env, int32_t esize, int eref, int64_t at_most) {
    int64_t n = (items != NULL ? items->len : 0);
    PsList *out = ps_list_new(ctx, esize, eref, n);
    if (n == 0) {
        return out;
    }
    int64_t win = (at_most > 0 ? at_most : 1);
    PsList *pend = ps_list_new(ctx, (int32_t)sizeof(PsStrPtr), 1, n);
    int64_t made = 0;
    int64_t taken = 0;
    while (taken < n) {
        while (made < n && made - taken < win) {
            void *item = (void *)(ps_list_base(items) + (size_t)made * (size_t)items->esize);
            PsTask *t = mk(env, ctx, item);
            char *slot = ps_list_push(ctx, pend);
            *(PsTask **)slot = t;
            made += 1;
            if (ctx->exc != NULL) {
                return out;
            }
        }
        PsTask **base = (PsTask **)(ps_list_base(pend) + (size_t)taken * (size_t)pend->esize);
        ps_task_wait(ctx, *base);
        if (ctx->exc != NULL) {
            return out;
        }
        base = (PsTask **)(ps_list_base(pend) + (size_t)taken * (size_t)pend->esize);
        char *dst = ps_list_push(ctx, out);
        memcpy(dst, ps_task_ret(*base), (size_t)esize);
        taken += 1;
    }
    return out;
}

PsTask *ps_gather_map_task(PsCtx *ctx, PsList *items, PsTask *(*mk)(void *, PsCtx *, const void *), void *env, int32_t esize, int eref, int64_t at_most) {
    PsList *out = ps_gather_map(ctx, items, mk, env, esize, eref, at_most);
    PsTask *t = ps_msg_task(ctx, NULL, sizeof(PsStrPtr));
    ((PsUser *)t->frame)->desc = &PS_REFMSG_DESC;
    *(PsList **)ps_task_ret(t) = out;
    return t;
}

PsTask *ps_first_ok_task(PsCtx *ctx, PsList *ts) {
    int64_t v = ps_first_ok(ctx, ts);
    return ps_task_of_int(ctx, v);
}

void ps_task_park(PsCtx *ctx, PsTask *waiter, PsTask *on) {
    waiter->waiting_on = on;
    on->waiter = waiter;
}

void ps_task_fail(PsCtx *ctx, PsTask *t) {
    t->err = ctx->exc;
    ctx->exc = NULL;
    t->state = -2;
}

void ps_task_take_err(PsCtx *ctx, PsTask *t) {
    if (t != NULL && t->err != NULL && ctx->exc == NULL) {
        ctx->exc = t->err;
    }
}

void *ps_task_ret(PsTask *t) {
    return (char *)t->frame + sizeof(PsUser);
}

void ps_task_wait(PsCtx *ctx, PsTask *t) {
    PsTask *n = NULL;
    PsObj **slots[2];
    slots[0] = (PsObj **)&t;
    slots[1] = (PsObj **)&n;
    PsFrame f;
    ps_push_frame(ctx, &f, slots, 2);
    ps_sched_yield(ctx);
    while (!ps_task_done(t)) {
        if (!ps_sched_progress(ctx)) {
            ps_raise(ctx, "deadlock: awaiting a task that nothing can finish", PS_CAT_VALUE, "<runtime>", 0);
            ps_pop_frame(ctx, &f);
            return;
        }
        n = NULL;
        if (ctx->exc != NULL) {
            ps_pop_frame(ctx, &f);
            return;
        }
    }
    ps_pop_frame(ctx, &f);
    if (t->err != NULL && ctx->exc == NULL) {
        ctx->exc = t->err;
    }
}

PsDyn *ps_box(PsCtx *ctx, const void *src, size_t nbytes, const void *vt, int isref) {
    PsDyn *d = (PsDyn *)ps_alloc(ctx, sizeof(PsDyn) + nbytes, PS_TY_DYN);
    d->vt = vt;
    d->nbytes = (uint32_t)nbytes;
    d->isref = (isref ? 1 : 0);
    memcpy(&d->data[0], src, nbytes);
    return d;
}

void *ps_dyn_data(PsCtx *ctx, PsDyn *d) {
    if (d == NULL) {
        ps_raise(ctx, "a method was called on a `dyn` that holds nothing", PS_CAT_TYPE, "<runtime>", 0);
        return NULL;
    }
    return &d->data[0];
}

void ps_push_frame(PsCtx *ctx, PsFrame *f, PsObj ***slots, int32_t n) {
    f->prev = ctx->frames;
    f->nslots = n;
    f->slots = slots;
    ctx->frames = f;
}

void ps_pop_frame(PsCtx *ctx, PsFrame *f) {
    ctx->frames = f->prev;
}

void ps_add_root(PsCtx *ctx, PsObj **slot) {
    PsRoot *r = malloc(sizeof(PsRoot));
    if (r == NULL) {
        fprintf(stderr, "pscript: out of memory\n");
        exit(1);
    }
    r->slot = slot;
    r->next = ctx->roots;
    ctx->roots = r;
}

PsObj *ps_forward(PsBlock *to, PsObj *p) {
    if (p == NULL) {
        return NULL;
    }
    if (p->ty == PS_TY_MOVED) {
        return p->fwd;
    }
    if ((char *)p >= to->base && (char *)p < to->base + to->used) {
        return p;
    }
    size_t n = (size_t)p->size;
    char *d = to->base + to->used;
    to->used += n;
    memcpy(d, p, n);
    p->ty = PS_TY_MOVED;
    p->fwd = (PsObj *)d;
    return (PsObj *)d;
}

static void ps_scan_object(PsBlock *to, PsObj *o) {
    switch (o->ty) {
        case PS_TY_STR: {
            PsStr *st9 = (PsStr *)o;
            if (st9->offs != NULL) {
                st9->offs = (PsArr *)ps_forward(to, (PsObj *)st9->offs);
            }
            break;
        }
        case PS_TY_ERR: {
            PsErr *e = (PsErr *)o;
            e->msg = (PsStr *)ps_forward(to, (PsObj *)e->msg);
            break;
        }
        case PS_TY_LIST: {
            PsList *l = (PsList *)o;
            if (l->raw != NULL) {
                l->owner = (PsBuffer *)ps_forward(to, (PsObj *)l->owner);
                return;
            }
            l->data = (PsArr *)ps_forward(to, (PsObj *)l->data);
            if (l->eref && l->data != NULL) {
                PsObj **base = (PsObj **)((char *)l->data + sizeof(PsArr));
                size_t i;
                for (i = 0; i < (int32_t)l->len; i += 1) {
                    base[i] = ps_forward(to, base[i]);
                }
            }
            break;
        }
        case PS_TY_DICT: {
            PsDict *d = (PsDict *)o;
            d->keys = (PsArr *)ps_forward(to, (PsObj *)d->keys);
            d->vals = (PsArr *)ps_forward(to, (PsObj *)d->vals);
            d->state = (PsArr *)ps_forward(to, (PsObj *)d->state);
            if ((d->kref || d->vref) && d->state != NULL) {
                char *stb = (char *)d->state + sizeof(PsArr);
                size_t i;
                for (i = 0; i < (int32_t)d->cap; i += 1) {
                    if (stb[i] != 1) {
                        continue;
                    }
                    if (d->kref) {
                        PsObj **kp = (PsObj **)((char *)d->keys + sizeof(PsArr) + (size_t)i * (size_t)d->ksize);
                        *kp = ps_forward(to, *kp);
                    }
                    if (d->vref) {
                        PsObj **vp = (PsObj **)((char *)d->vals + sizeof(PsArr) + (size_t)i * (size_t)d->vsize);
                        *vp = ps_forward(to, *vp);
                    }
                }
            }
            break;
        }
        case PS_TY_ARR: {
            ;
            break;
        }
        case PS_TY_DYN: {
            PsDyn *dy = (PsDyn *)o;
            if (dy->isref != 0) {
                PsObj **dp = (PsObj **)&dy->data[0];
                *dp = ps_forward(to, *dp);
            }
            break;
        }
        case PS_TY_TASK: {
            PsTask *tk = (PsTask *)o;
            tk->frame = ps_forward(to, tk->frame);
            if (tk->err != NULL) {
                tk->err = (PsErr *)ps_forward(to, (PsObj *)tk->err);
            }
            if (tk->waiting_on != NULL) {
                tk->waiting_on = (PsTask *)ps_forward(to, (PsObj *)tk->waiting_on);
            }
            if (tk->waiter != NULL) {
                tk->waiter = (PsTask *)ps_forward(to, (PsObj *)tk->waiter);
            }
            if (tk->next != NULL) {
                tk->next = (PsTask *)ps_forward(to, (PsObj *)tk->next);
            }
            break;
        }
        case PS_TY_WORKER:
        case PS_TY_CONN: {
            ;
            break;
        }
        case PS_TY_FILE: {
            ;
            break;
        }
        case PS_TY_ANY: {
            ;
            break;
        }
        case PS_TY_BUFFER: {
            ;
            break;
        }
        case PS_TY_TIMER: {
            ;
            break;
        }
        case PS_TY_CLOSURE: {
            PsClosure *cl = (PsClosure *)o;
            if (cl->env != NULL) {
                cl->env = ps_forward(to, cl->env);
            }
            break;
        }
        case PS_TY_USER: {
            PsUser *u = (PsUser *)o;
            if (u->desc->trace != NULL) {
                u->desc->trace((void *)o, to);
            }
            break;
        }
        default: {
            ;
            break;
        }
    }
}

void ps_gc(PsCtx *ctx) {
    size_t total = 0;
    PsBlock *b = ctx->blocks;
    while (b != NULL) {
        total += b->used;
        b = b->next;
    }
    PsBlock *to = ps_new_block(total + (size_t)PS_BLOCK_BYTES);
    PsFrame *f = ctx->frames;
    while (f != NULL) {
        size_t i;
        for (i = 0; i < f->nslots; i += 1) {
            PsObj **slot = f->slots[i];
            if (slot != NULL) {
                *slot = ps_forward(to, *slot);
            }
        }
        f = f->prev;
    }
    PsRoot *r = ctx->roots;
    while (r != NULL) {
        *r->slot = ps_forward(to, *r->slot);
        r = r->next;
    }
    if (ctx->exc != NULL) {
        ctx->exc = (PsErr *)ps_forward(to, (PsObj *)ctx->exc);
    }
    if (ctx->ready != NULL) {
        ctx->ready = (PsTask *)ps_forward(to, (PsObj *)ctx->ready);
    }
    if (ctx->ready_tail != NULL) {
        ctx->ready_tail = (PsTask *)ps_forward(to, (PsObj *)ctx->ready_tail);
    }
    if (ctx->timers != NULL) {
        ctx->timers = (PsTask *)ps_forward(to, (PsObj *)ctx->timers);
    }
    if (ctx->waiters != NULL) {
        ctx->waiters = (PsTask *)ps_forward(to, (PsObj *)ctx->waiters);
    }
    size_t scan = 0;
    while (scan < to->used) {
        PsObj *o = (PsObj *)(to->base + scan);
        ps_scan_object(to, o);
        scan += (size_t)o->size;
    }
    ps_free_blocks(ctx->blocks);
    ctx->blocks = to;
    ctx->live = to->used;
    ctx->alloced = 0;
    ctx->nalloc = 0;
    ctx->ngc += 1;
}

void ps_gc_poll(PsCtx *ctx) {
    if (ctx->nogc > 0) {
        if (ctx->nogc_budget != (size_t)0 && ctx->alloced - ctx->nogc_start > ctx->nogc_budget) {
            ps_raise(ctx, "nogc budget exceeded", PS_CAT_VALUE, "<nogc>", 0);
        }
        return;
    }
    if (ps_stress_due()) {
        ps_gc(ctx);
        return;
    }
    if (ctx->alloced < (size_t)PS_GC_BYTES && ctx->nalloc < PS_GC_OBJECTS) {
        return;
    }
    ps_gc(ctx);
}

void ps_gc_suspend(PsCtx *ctx, int64_t budget, const char *file, int32_t line) {
    if (ctx->nogc == 0 && budget > 0) {
        ps_gc(ctx);
        ctx->nogc_budget = (size_t)budget;
        ctx->nogc_start = ctx->alloced;
    } else if (ctx->nogc == 0) {
        ctx->nogc_budget = (size_t)0;
        ctx->nogc_start = ctx->alloced;
    }
    ctx->nogc += 1;
}

void ps_gc_resume(PsCtx *ctx) {
    if (ctx->nogc > 0) {
        ctx->nogc -= 1;
    }
    if (ctx->nogc == 0) {
        ctx->nogc_budget = (size_t)0;
        ps_gc_poll(ctx);
    }
}

static void ps_list_grow(PsCtx *ctx, PsList *l, int64_t need);

PsList *ps_list_new(PsCtx *ctx, int32_t esize, int eref, int64_t cap) {
    PsList *l = ps_alloc(ctx, sizeof(PsList), PS_TY_LIST);
    l->len = 0;
    l->cap = 0;
    l->esize = esize;
    l->eref = eref;
    l->data = NULL;
    l->raw = NULL;
    l->owner = NULL;
    if (cap > 0) {
        ps_list_grow(ctx, l, cap);
    }
    return l;
}

static void ps_list_grow(PsCtx *ctx, PsList *l, int64_t need) {
    if (need <= l->cap) {
        return;
    }
    int64_t ncap = (l->cap == 0 ? 8 : l->cap * 2);
    while (ncap < need) {
        ncap *= 2;
    }
    size_t nb = (size_t)ncap * (size_t)l->esize;
    PsArr *a = ps_alloc(ctx, sizeof(PsArr) + nb, PS_TY_ARR);
    a->nbytes = nb;
    if (l->data != NULL && l->len > 0) {
        memcpy((char *)a + sizeof(PsArr), (char *)l->data + sizeof(PsArr), (size_t)l->len * (size_t)l->esize);
    }
    l->data = a;
    l->cap = ncap;
}

int64_t ps_list_len(PsList *l) {
    return l->len;
}

static char PS_SCRATCH[64];

char *ps_list_base(PsList *l) {
    if (l->raw != NULL) {
        return l->raw;
    }
    if (l->data == NULL) {
        return PS_SCRATCH;
    }
    return (char *)l->data + sizeof(PsArr);
}

int64_t ps_arr_at(PsCtx *ctx, int64_t i, int64_t n, const char *file, int32_t line) {
    int64_t k = (i < 0 ? i + n : i);
    if (k < 0 || k >= n) {
        ps_raise(ctx, "array index out of range", PS_CAT_INDEX, file, line);
        return 0;
    }
    return k;
}

int64_t ps_list_at(PsCtx *ctx, PsList *l, int64_t i, const char *file, int32_t line) {
    int64_t k = (i < 0 ? i + l->len : i);
    if (k < 0 || k >= l->len) {
        ps_raise(ctx, "list index out of range", PS_CAT_INDEX, file, line);
        return 0;
    }
    return k;
}

char *ps_list_push(PsCtx *ctx, PsList *l) {
    if (l->raw != NULL) {
        ps_raise(ctx, "a view over a buffer has a fixed size", PS_CAT_VALUE, "<view>", 0);
        return PS_SCRATCH;
    }
    ps_list_grow(ctx, l, l->len + 1);
    char *p = ps_list_base(l) + (size_t)l->len * (size_t)l->esize;
    l->len += 1;
    memset(p, 0, (size_t)l->esize);
    return p;
}

static void ps_dict_rehash(PsCtx *ctx, PsDict *d, int64_t ncap);

static uint64_t ps_hash_bytes(const char *b, size_t n) {
    uint64_t h = 1469598103934665603;
    size_t i;
    for (i = 0; i < n; i += 1) {
        h ^= (uint64_t)(uint8_t)b[i];
        h *= 1099511628211;
    }
    return h;
}

static uint64_t ps_key_hash(PsDict *d, const char *k) {
    if (d->kkind == PS_K_STR) {
        PsStr *s = *(PsStr **)k;
        return ps_hash_bytes(s->data, (size_t)s->len);
    }
    return ps_hash_bytes(k, (size_t)d->ksize);
}

static int ps_key_eq(PsDict *d, const char *a, const char *b) {
    if (d->kkind == PS_K_STR) {
        return ps_str_eq(*(PsStr **)a, *(PsStr **)b);
    }
    return memcmp(a, b, (size_t)d->ksize) == 0;
}

PsDict *ps_dict_new(PsCtx *ctx, int32_t ksize, int32_t vsize, int32_t kkind, int kref, int vref) {
    PsDict *d = ps_alloc(ctx, sizeof(PsDict), PS_TY_DICT);
    d->n = 0;
    d->used = 0;
    d->cap = 0;
    d->ksize = ksize;
    d->vsize = vsize;
    d->kkind = kkind;
    d->kref = kref;
    d->vref = vref;
    d->keys = NULL;
    d->vals = NULL;
    d->state = NULL;
    ps_dict_rehash(ctx, d, 8);
    return d;
}

static PsArr *ps_arr_new(PsCtx *ctx, size_t nbytes) {
    PsArr *a = ps_alloc(ctx, sizeof(PsArr) + nbytes, PS_TY_ARR);
    a->nbytes = nbytes;
    memset((char *)a + sizeof(PsArr), 0, nbytes);
    return a;
}

static char *ps_arr_data(PsArr *a) {
    return (char *)a + sizeof(PsArr);
}

static void ps_dict_rehash(PsCtx *ctx, PsDict *d, int64_t ncap) {
    PsArr *ok = d->keys;
    PsArr *ov = d->vals;
    PsArr *ost = d->state;
    int64_t ocap = d->cap;
    d->keys = ps_arr_new(ctx, (size_t)ncap * (size_t)d->ksize);
    d->vals = ps_arr_new(ctx, (size_t)ncap * (size_t)(d->vsize > 0 ? d->vsize : 1));
    d->state = ps_arr_new(ctx, (size_t)ncap);
    d->cap = ncap;
    d->n = 0;
    d->used = 0;
    if (ost == NULL) {
        return;
    }
    char *ostate = ps_arr_data(ost);
    char *okeys = ps_arr_data(ok);
    char *ovals = ps_arr_data(ov);
    size_t i;
    for (i = 0; i < (int32_t)ocap; i += 1) {
        if (ostate[i] != 1) {
            continue;
        }
        char *kp = okeys + (size_t)i * (size_t)d->ksize;
        char *slot = ps_dict_put(ctx, d, kp);
        if (d->vsize > 0) {
            memcpy(slot, ovals + (size_t)i * (size_t)d->vsize, (size_t)d->vsize);
        }
    }
}

int64_t ps_dict_len(PsDict *d) {
    return d->n;
}

static int64_t ps_dict_slot(PsDict *d, const char *key, int *found) {
    char *st = ps_arr_data(d->state);
    char *keys = ps_arr_data(d->keys);
    uint64_t mask = (uint64_t)d->cap - 1;
    uint64_t i = ps_key_hash(d, key) & mask;
    int64_t first_free = -1;
    while (1) {
        char s = st[i];
        if (s == 0) {
            *found = 0;
            return (first_free < 0 ? (int64_t)i : first_free);
        }
        if (s == 2) {
            if (first_free < 0) {
                first_free = (int64_t)i;
            }
        } else if (ps_key_eq(d, keys + (size_t)i * (size_t)d->ksize, key)) {
            *found = 1;
            return (int64_t)i;
        }
        i = (i + 1) & mask;
    }
}

char *ps_dict_put(PsCtx *ctx, PsDict *d, const char *key) {
    if ((d->used + 1) * 4 >= d->cap * 3) {
        ps_dict_rehash(ctx, d, d->cap * 2);
    }
    int found = 0;
    int64_t i = ps_dict_slot(d, key, &found);
    char *st = ps_arr_data(d->state);
    if (!found) {
        memcpy(ps_arr_data(d->keys) + (size_t)i * (size_t)d->ksize, key, (size_t)d->ksize);
        if (st[i] == 0) {
            d->used += 1;
        }
        st[i] = 1;
        d->n += 1;
    }
    if (d->vsize == 0) {
        return NULL;
    }
    return ps_arr_data(d->vals) + (size_t)i * (size_t)d->vsize;
}

char *ps_dict_get(PsCtx *ctx, PsDict *d, const char *key, const char *file, int32_t line) {
    int found = 0;
    int64_t i = ps_dict_slot(d, key, &found);
    if (!found) {
        ps_raise(ctx, "key not found", PS_CAT_KEY, file, line);
        return ps_arr_data(d->vals);
    }
    return ps_arr_data(d->vals) + (size_t)i * (size_t)d->vsize;
}

int ps_dict_has(PsDict *d, const char *key) {
    int found = 0;
    ps_dict_slot(d, key, &found);
    return found;
}

int ps_dict_del(PsDict *d, const char *key) {
    int found = 0;
    int64_t i = ps_dict_slot(d, key, &found);
    if (!found) {
        return 0;
    }
    ps_arr_data(d->state)[i] = 2;
    d->n -= 1;
    return 1;
}

int64_t ps_dict_cap(PsDict *d) {
    return d->cap;
}

int ps_dict_live(PsDict *d, int64_t i) {
    return ps_arr_data(d->state)[i] == 1;
}

char *ps_dict_key_at(PsDict *d, int64_t i) {
    return ps_arr_data(d->keys) + (size_t)i * (size_t)d->ksize;
}

char *ps_dict_val_at(PsDict *d, int64_t i) {
    return ps_arr_data(d->vals) + (size_t)i * (size_t)d->vsize;
}

static uint32_t ps_utf8_count(const char *b, size_t n) {
    uint32_t c = 0;
    size_t i;
    for (i = 0; i < n; i += 1) {
        if (((uint8_t)b[i] & 0xC0) != 0x80) {
            c += 1;
        }
    }
    return c;
}

int ps_utf8_valid(const char *b, size_t n) {
    size_t i = 0;
    while (i < n) {
        uint8_t c = (uint8_t)b[i];
        int32_t need = 0;
        uint32_t lo = 0;
        uint32_t cp = 0;
        if (c < 0x80) {
            i += 1;
            continue;
        } else if ((c & 0xE0) == 0xC0) {
            need = 1;
            cp = (uint32_t)(c & 0x1F);
            lo = 0x80;
        } else if ((c & 0xF0) == 0xE0) {
            need = 2;
            cp = (uint32_t)(c & 0x0F);
            lo = 0x800;
        } else if ((c & 0xF8) == 0xF0) {
            need = 3;
            cp = (uint32_t)(c & 0x07);
            lo = 0x10000;
        } else {
            return 0;
        }
        if (i + (size_t)need >= n + (size_t)0 && i + (size_t)need > n - 1) {
            return 0;
        }
        size_t k;
        for (k = 0; k < need; k += 1) {
            uint8_t cc = (uint8_t)b[i + (size_t)k + 1];
            if ((cc & 0xC0) != 0x80) {
                return 0;
            }
            cp = (cp << 6) | (uint32_t)(cc & 0x3F);
        }
        if (cp < lo || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
            return 0;
        }
        i += (size_t)need + 1;
    }
    return 1;
}

static int ps_str_ascii(PsStr *s) {
    return s->nchars == s->len;
}

static PsArr *ps_str_index(PsCtx *ctx, PsStr *s) {
    if (s->offs != NULL) {
        return s->offs;
    }
    size_t n = (size_t)s->len;
    size_t cnt = (size_t)s->nchars;
    PsArr *a = (PsArr *)ps_alloc(ctx, sizeof(PsArr) + (cnt + 1) * sizeof(uint32_t), PS_TY_ARR);
    a->nbytes = (cnt + 1) * sizeof(uint32_t);
    uint32_t *off = (uint32_t *)((char *)a + sizeof(PsArr));
    size_t k = 0;
    size_t i = 0;
    while (i < n) {
        if (((uint8_t)s->data[i] & 0xC0) != 0x80) {
            off[k] = (uint32_t)i;
            k += 1;
        }
        i += 1;
    }
    off[cnt] = (uint32_t)n;
    s->offs = a;
    return a;
}

static size_t ps_utf8_off(const char *b, size_t n, int64_t k) {
    int64_t seen = 0;
    size_t i;
    for (i = 0; i < n; i += 1) {
        if (((uint8_t)b[i] & 0xC0) != 0x80) {
            if (seen == k) {
                return (size_t)i;
            }
            seen += 1;
        }
    }
    return n;
}

PsStr *ps_str_new(PsCtx *ctx, const char *bytes, size_t len) {
    PsStr *s = ps_alloc(ctx, sizeof(PsStr) + len + 1, PS_TY_STR);
    s->len = (uint32_t)len;
    s->hash = 0;
    if (len > 0) {
        memcpy(s->data, bytes, len);
    }
    s->data[len] = '\0';
    s->nchars = ps_utf8_count(s->data, len);
    s->offs = NULL;
    return s;
}

PsStr *ps_str_from_bytes(PsCtx *ctx, PsList *l, const char *file, int32_t line) {
    size_t n = (l != NULL ? (size_t)l->len : (size_t)0);
    const char *p = (n > 0 ? ps_list_base(l) : "");
    if (!ps_utf8_valid(p, n)) {
        ps_raise(ctx, "these bytes are not valid UTF-8: keep them as bytes, or decode them yourself", PS_CAT_VALUE, file, line);
        return ps_str_new(ctx, "", 0);
    }
    return ps_str_new(ctx, p, n);
}

PsStr *ps_str_checked(PsCtx *ctx, const char *p, size_t n, const char *file, int32_t line) {
    if (p == NULL) {
        return ps_str_new(ctx, "", 0);
    }
    if (!ps_utf8_valid(p, n)) {
        ps_raise(ctx, "this text is not valid UTF-8 (it came from the other side of the boundary)", PS_CAT_VALUE, file, line);
        return ps_str_new(ctx, "", 0);
    }
    return ps_str_new(ctx, p, n);
}

PsList *ps_bytes_new(PsCtx *ctx, const uint8_t *p, size_t n) {
    PsList *l = ps_list_new(ctx, 1, 0, (int64_t)n);
    size_t i = 0;
    while (i < n) {
        char *dst = ps_list_push(ctx, l);
        *dst = (char)p[i];
        i += 1;
    }
    return l;
}

PsStr *ps_str_concat(PsCtx *ctx, PsStr *a, PsStr *b) {
    size_t n = (size_t)a->len + (size_t)b->len;
    PsStr *s = ps_alloc(ctx, sizeof(PsStr) + n + 1, PS_TY_STR);
    s->len = (uint32_t)n;
    s->nchars = a->nchars + b->nchars;
    s->hash = 0;
    memcpy(s->data, a->data, (size_t)a->len);
    memcpy(s->data + a->len, b->data, (size_t)b->len);
    s->data[n] = '\0';
    s->offs = NULL;
    return s;
}

PsStr *ps_str_from_int(PsCtx *ctx, int64_t v) {
    char buf[24];
    int32_t i = 24;
    int neg = v < 0;
    int64_t n = (neg ? v : -v);
    do {
        i -= 1;
        buf[i] = (char)((int32_t)'0' - (int32_t)(n % 10));
        n /= 10;
    } while (n != 0);
    if (neg) {
        i -= 1;
        buf[i] = '-';
    }
    return ps_str_new(ctx, buf + i, (size_t)(24 - i));
}

PsStr *ps_str_from_float(PsCtx *ctx, double v) {
    char buf[64];
    int32_t n = 0;
    int32_t prec = 15;
    while (prec <= 17) {
        n = snprintf(buf, 64, "%.*g", prec, v);
        if (strtod(buf, NULL) == v) {
            break;
        }
        prec += 1;
    }
    if (strpbrk(buf, ".eEni") == NULL) {
        buf[n] = '.';
        buf[n + 1] = '0';
        n += 2;
        buf[n] = '\0';
    }
    return ps_str_new(ctx, buf, (size_t)n);
}

PsStr *ps_str_from_bool(PsCtx *ctx, int v) {
    return ps_str_new(ctx, (v ? "True" : "False"), (size_t)(v ? 4 : 5));
}

int64_t ps_str_nbytes(PsStr *s) {
    return (s != NULL ? (int64_t)s->len : 0);
}

PsStr *ps_str_step(PsCtx *ctx, PsStr *s, int64_t *off) {
    if (s == NULL || *off >= (int64_t)s->len) {
        return ps_str_new(ctx, "", 0);
    }
    size_t a = (size_t)*off;
    size_t n = 1;
    uint8_t c = (uint8_t)s->data[a];
    if ((c & 0xF8) == 0xF0) {
        n = 4;
    } else if ((c & 0xF0) == 0xE0) {
        n = 3;
    } else if ((c & 0xE0) == 0xC0) {
        n = 2;
    }
    if (a + n > (size_t)s->len) {
        n = (size_t)s->len - a;
    }
    *off = (int64_t)(a + n);
    return ps_str_new(ctx, s->data + a, n);
}

int ps_str_has(PsStr *hay, PsStr *needle) {
    if (hay == NULL || needle == NULL) {
        return 0;
    }
    size_t n = (size_t)needle->len;
    if (n == (size_t)0) {
        return 1;
    }
    if (n > (size_t)hay->len) {
        return 0;
    }
    size_t limit = (size_t)hay->len - n;
    size_t i = 0;
    while (i <= limit) {
        if (memcmp(hay->data + i, needle->data, n) == 0) {
            return 1;
        }
        i += 1;
    }
    return 0;
}

int32_t ps_str_lt(PsStr *a, PsStr *b) {
    if (a == NULL || b == NULL) {
        return 0;
    }
    size_t na = (size_t)a->len;
    size_t nb = (size_t)b->len;
    size_t n = (na < nb ? na : nb);
    int r = memcmp(a->data, b->data, n);
    if (r != 0) {
        return (r < 0 ? -1 : 1);
    }
    if (na == nb) {
        return 0;
    }
    return (na < nb ? -1 : 1);
}

int ps_str_eq(PsStr *a, PsStr *b) {
    if (a == b) {
        return 1;
    }
    if (a->len != b->len) {
        return 0;
    }
    return memcmp(a->data, b->data, (size_t)a->len) == 0;
}

const char *ps_str_cstr(PsStr *s) {
    return (s != NULL ? s->data : "");
}

int64_t ps_str_len(PsCtx *ctx, PsStr *s) {
    return (int64_t)s->nchars;
}

PsStr *ps_str_at(PsCtx *ctx, PsStr *s, int64_t i, const char *file, int32_t line) {
    int64_t k = (i < 0 ? i + (int64_t)s->nchars : i);
    if (k < 0 || k >= (int64_t)s->nchars) {
        ps_raise(ctx, "string index out of range", PS_CAT_INDEX, file, line);
        return ps_str_new(ctx, "", 0);
    }
    if (ps_str_ascii(s)) {
        return ps_str_new(ctx, s->data + (size_t)k, (size_t)1);
    }
    PsArr *idx = ps_str_index(ctx, s);
    uint32_t *off = (uint32_t *)((char *)idx + sizeof(PsArr));
    size_t a = (size_t)off[k];
    size_t b = (size_t)off[k + 1];
    return ps_str_new(ctx, s->data + a, b - a);
}

int64_t ps_str_ord(PsCtx *ctx, PsStr *s, const char *file, int32_t line) {
    if (s == NULL || s->nchars != 1) {
        ps_raise(ctx, "ord() takes a string of exactly one character", PS_CAT_VALUE, file, line);
        return 0;
    }
    uint8_t *b = (uint8_t *)s->data;
    uint32_t c = (uint32_t)b[0];
    if (c < 0x80) {
        return (int64_t)c;
    }
    if ((c & 0xE0) == 0xC0) {
        return (int64_t)(((c & 0x1F) << 6) | ((uint32_t)b[1] & 0x3F));
    }
    if ((c & 0xF0) == 0xE0) {
        return (int64_t)(((c & 0x0F) << 12) | (((uint32_t)b[1] & 0x3F) << 6) | ((uint32_t)b[2] & 0x3F));
    }
    return (int64_t)(((c & 0x07) << 18) | (((uint32_t)b[1] & 0x3F) << 12) | (((uint32_t)b[2] & 0x3F) << 6) | ((uint32_t)b[3] & 0x3F));
}

PsStr *ps_str_chr(PsCtx *ctx, int64_t cp, const char *file, int32_t line) {
    if (cp < 0 || cp > 1114111) {
        ps_raise(ctx, "chr() takes a codepoint between 0 and 0x10FFFF", PS_CAT_VALUE, file, line);
        return ps_str_new(ctx, "", 0);
    }
    char b[5];
    size_t n = 0;
    uint32_t v = (uint32_t)cp;
    if (v < 0x80) {
        b[0] = (char)v;
        n = 1;
    } else if (v < 0x800) {
        b[0] = (char)(0xC0 | (v >> 6));
        b[1] = (char)(0x80 | (v & 0x3F));
        n = 2;
    } else if (v < 0x10000) {
        b[0] = (char)(0xE0 | (v >> 12));
        b[1] = (char)(0x80 | ((v >> 6) & 0x3F));
        b[2] = (char)(0x80 | (v & 0x3F));
        n = 3;
    } else {
        b[0] = (char)(0xF0 | (v >> 18));
        b[1] = (char)(0x80 | ((v >> 12) & 0x3F));
        b[2] = (char)(0x80 | ((v >> 6) & 0x3F));
        b[3] = (char)(0x80 | (v & 0x3F));
        n = 4;
    }
    return ps_str_new(ctx, &b[0], n);
}

PsStr *ps_str_slice(PsCtx *ctx, PsStr *s, int64_t a, int64_t b, int has_a, int has_b) {
    int64_t n = (int64_t)s->nchars;
    int64_t lo = (has_a ? a : 0);
    int64_t hi = (has_b ? b : n);
    if (lo < 0) {
        lo += n;
    }
    if (hi < 0) {
        hi += n;
    }
    if (lo < 0) {
        lo = 0;
    }
    if (hi > n) {
        hi = n;
    }
    if (lo >= hi) {
        return ps_str_new(ctx, "", 0);
    }
    if (ps_str_ascii(s)) {
        return ps_str_new(ctx, s->data + (size_t)lo, (size_t)(hi - lo));
    }
    PsArr *idx = ps_str_index(ctx, s);
    uint32_t *off = (uint32_t *)((char *)idx + sizeof(PsArr));
    size_t ba = (size_t)off[lo];
    size_t bb = (size_t)off[hi];
    return ps_str_new(ctx, s->data + ba, bb - ba);
}

int64_t ps_str_find(PsCtx *ctx, PsStr *s, PsStr *needle) {
    if (needle->len == 0) {
        return 0;
    }
    if (needle->len > s->len) {
        return -1;
    }
    int64_t chars = 0;
    size_t i;
    for (i = 0; i < (size_t)s->len - (size_t)needle->len + 1; i += 1) {
        if (((uint8_t)s->data[i] & 0xC0) != 0x80) {
            if (memcmp(s->data + i, needle->data, (size_t)needle->len) == 0) {
                return chars;
            }
            chars += 1;
        }
    }
    return -1;
}

int ps_str_contains(PsStr *s, PsStr *needle) {
    if (needle->len == 0) {
        return 1;
    }
    if (needle->len > s->len) {
        return 0;
    }
    size_t i;
    for (i = 0; i < (size_t)s->len - (size_t)needle->len + 1; i += 1) {
        if (memcmp(s->data + i, needle->data, (size_t)needle->len) == 0) {
            return 1;
        }
    }
    return 0;
}

PsStr *ps_str_lower(PsCtx *ctx, PsStr *s) {
    size_t n = (size_t)s->len;
    PsStr *out = ps_str_new(ctx, s->data, n);
    size_t i = 0;
    while (i < n) {
        char c = out->data[i];
        if (c >= 'A' && c <= 'Z') {
            out->data[i] = (char)((int32_t)c + 32);
        }
        i += 1;
    }
    out->hash = 0;
    return out;
}

PsStr *ps_str_upper(PsCtx *ctx, PsStr *s) {
    size_t n = (size_t)s->len;
    PsStr *out = ps_str_new(ctx, s->data, n);
    size_t i = 0;
    while (i < n) {
        char c = out->data[i];
        if (c >= 'a' && c <= 'z') {
            out->data[i] = (char)((int32_t)c - 32);
        }
        i += 1;
    }
    out->hash = 0;
    return out;
}

int ps_str_startswith(PsStr *s, PsStr *p) {
    if (p->len > s->len) {
        return 0;
    }
    return memcmp(s->data, p->data, (size_t)p->len) == 0;
}

int ps_str_endswith(PsStr *s, PsStr *p) {
    if (p->len > s->len) {
        return 0;
    }
    return memcmp(s->data + ((size_t)s->len - (size_t)p->len), p->data, (size_t)p->len) == 0;
}

PsStr *ps_str_strip(PsCtx *ctx, PsStr *s) {
    size_t a = 0;
    size_t b = (size_t)s->len;
    while (a < b && (s->data[a] == ' ' || s->data[a] == '\t' || s->data[a] == '\n' || s->data[a] == '\r')) {
        a += 1;
    }
    while (b > a && (s->data[b - 1] == ' ' || s->data[b - 1] == '\t' || s->data[b - 1] == '\n' || s->data[b - 1] == '\r')) {
        b -= 1;
    }
    return ps_str_new(ctx, s->data + a, b - a);
}

PsList *ps_str_split(PsCtx *ctx, PsStr *s, PsStr *sep) {
    PsList *out = ps_list_new(ctx, (int32_t)sizeof(PsStrPtr), 1, 4);
    if (sep->len == 0) {
        ps_raise(ctx, "split() needs a non-empty separator", PS_CAT_VALUE, "<split>", 0);
        return out;
    }
    size_t start = 0;
    size_t i = 0;
    size_t n = (size_t)s->len;
    size_t m = (size_t)sep->len;
    while (i + m <= n) {
        if (memcmp(s->data + i, sep->data, m) == 0) {
            PsStr *piece = ps_str_new(ctx, s->data + start, i - start);
            PsStr **slot = (PsStr **)ps_list_push(ctx, out);
            *slot = piece;
            i += m;
            start = i;
        } else {
            i += 1;
        }
    }
    PsStr *last = ps_str_new(ctx, s->data + start, n - start);
    PsStr **slot2 = (PsStr **)ps_list_push(ctx, out);
    *slot2 = last;
    return out;
}

int64_t ps_str_to_int(PsCtx *ctx, PsStr *s) {
    char *end = NULL;
    int64_t v = strtoll(s->data, &end, 10);
    if (end == s->data || *end != '\0') {
        ps_raise(ctx, "int(): the string is not a number", PS_CAT_VALUE, "<int>", 0);
        return 0;
    }
    return v;
}

double ps_str_to_float(PsCtx *ctx, PsStr *s) {
    char *end = NULL;
    double v = strtod(s->data, &end);
    if (end == s->data || *end != '\0') {
        ps_raise(ctx, "float(): the string is not a number", PS_CAT_VALUE, "<float>", 0);
        return 0.0;
    }
    return v;
}

void ps_raise(PsCtx *ctx, const char *msg, int32_t cat, const char *file, int32_t line) {
    if (ctx->exc != NULL) {
        return;
    }
    PsErr *e = ps_alloc(ctx, sizeof(PsErr), PS_TY_ERR);
    e->msg = ps_str_new(ctx, msg, strlen(msg));
    e->cat = cat;
    e->file = file;
    e->line = line;
    ctx->exc = e;
}

void ps_raise_str(PsCtx *ctx, PsStr *msg, int64_t cat, const char *file, int32_t line) {
    if (ctx->exc != NULL) {
        return;
    }
    PsErr *e = ps_alloc(ctx, sizeof(PsErr), PS_TY_ERR);
    e->msg = msg;
    e->cat = (int32_t)cat;
    e->file = file;
    e->line = line;
    ctx->exc = e;
}

PsErr *ps_err_new(PsCtx *ctx, PsStr *msg, int64_t cat) {
    PsErr *e = ps_alloc(ctx, sizeof(PsErr), PS_TY_ERR);
    e->msg = msg;
    e->cat = (int32_t)cat;
    e->file = NULL;
    e->line = 0;
    return e;
}

void ps_reraise(PsCtx *ctx, PsErr *e) {
    if (ctx->exc != NULL || e == NULL) {
        return;
    }
    ctx->exc = e;
}

int ps_has_exc(PsCtx *ctx) {
    return ctx->exc != NULL;
}

PsErr *ps_take_exc(PsCtx *ctx) {
    PsErr *e = ctx->exc;
    ctx->exc = NULL;
    return e;
}

PsStr *ps_err_message(PsErr *e) {
    return e->msg;
}

int64_t ps_err_category(PsErr *e) {
    return (int64_t)e->cat;
}

static PsStr *ps_pad(PsCtx *ctx, const char *src, size_t n, int32_t width, char align, int zero) {
    if (width <= 0 || (size_t)width <= n) {
        return ps_str_new(ctx, src, n);
    }
    size_t total = (size_t)width;
    size_t pad = total - n;
    PsStr *out = ps_alloc(ctx, sizeof(PsStr) + total + 1, PS_TY_STR);
    out->len = (uint32_t)total;
    out->hash = 0;
    out->offs = NULL;
    out->nchars = (uint32_t)pad + ps_utf8_count(src, n);
    char *d = out->data;
    if (zero && align != '^') {
        size_t lead = (n > 0 && (src[0] == '-' || src[0] == '+') ? 1 : 0);
        memcpy(d, src, lead);
        memset(d + lead, '0', pad);
        memcpy(d + lead + pad, src + lead, n - lead);
    } else if (align == '<') {
        memcpy(d, src, n);
        memset(d + n, ' ', pad);
    } else if (align == '^') {
        size_t left = pad / 2;
        memset(d, ' ', left);
        memcpy(d + left, src, n);
        memset(d + left + n, ' ', pad - left);
    } else {
        memset(d, ' ', pad);
        memcpy(d + pad, src, n);
    }
    d[total] = '\0';
    return out;
}

PsStr *ps_fmt_int(PsCtx *ctx, int64_t v, int32_t width, char align, int zero, char ty) {
    char buf[32];
    size_t n = 0;
    if (ty == 'x' || ty == 'X' || ty == 'b' || ty == 'o') {
        int64_t base = (ty == 'x' || ty == 'X' ? 16 : (ty == 'b' ? 2 : 8));
        const char *digits = (ty != 'X' ? "0123456789abcdef" : "0123456789ABCDEF");
        int32_t i = 32;
        uint64_t u = (uint64_t)v;
        do {
            i -= 1;
            buf[i] = digits[(size_t)(u % (uint64_t)base)];
            u /= (uint64_t)base;
        } while (u != 0);
        n = (size_t)(32 - i);
        return ps_pad(ctx, buf + i, n, width, align, zero);
    }
    PsStr *t = ps_str_from_int(ctx, v);
    return ps_pad(ctx, t->data, (size_t)t->len, width, align, zero);
}

PsStr *ps_fmt_float(PsCtx *ctx, double v, int32_t width, int32_t prec, char align, int zero) {
    if (prec < 0) {
        PsStr *t = ps_str_from_float(ctx, v);
        return ps_pad(ctx, t->data, (size_t)t->len, width, align, zero);
    }
    char buf[64];
    int32_t n = snprintf(buf, 64, "%.*f", prec, v);
    return ps_pad(ctx, buf, (size_t)n, width, align, zero);
}

PsStr *ps_fmt_str(PsCtx *ctx, PsStr *s, int32_t width, char align) {
    return ps_pad(ctx, s->data, (size_t)s->len, width, align, 0);
}

PsFile *ps_std_file(PsCtx *ctx, int32_t which) {
    PsFile *f = (PsFile *)ps_alloc(ctx, sizeof(PsFile), PS_TY_FILE);
    f->fp = (which == 0 ? stdout : stderr);
    f->is_open = 1;
    f->is_std = 1;
    return f;
}

PsTask *ps_aprint(PsCtx *ctx, PsStr *s) {
    if (ctx->exc != NULL) {
        return ps_task_of_int(ctx, 0);
    }
    PsWork *w = ps_work_new(PS_IO_WRITE);
    w->want = PS_W_INT;
    w->fp = stdout;
    w->n = (size_t)s->len + 1;
    w->buf = (char *)malloc(w->n + 1);
    if (s->len > 0) {
        memcpy(w->buf, s->data, (size_t)s->len);
    }
    w->buf[s->len] = '\n';
    return ps_io_task(ctx, w, 0, sizeof(int64_t));
}

void ps_print(PsCtx *ctx, PsStr *s) {
    if (ctx->exc != NULL) {
        return;
    }
    fwrite(s->data, 1, (size_t)s->len, stdout);
    fputc('\n', stdout);
}

int64_t ps_add(PsCtx *ctx, int64_t a, int64_t b, const char *file, int32_t line) {
    if (b > 0 && a > 9223372036854775807 - b) {
        ps_raise(ctx, "integer overflow in +", PS_CAT_OVERFLOW, file, line);
        return 0;
    }
    if (b < 0 && a < -9223372036854775807 - 1 - b) {
        ps_raise(ctx, "integer overflow in +", PS_CAT_OVERFLOW, file, line);
        return 0;
    }
    return a + b;
}

int64_t ps_sub(PsCtx *ctx, int64_t a, int64_t b, const char *file, int32_t line) {
    if (b < 0 && a > 9223372036854775807 + b) {
        ps_raise(ctx, "integer overflow in -", PS_CAT_OVERFLOW, file, line);
        return 0;
    }
    if (b > 0 && a < -9223372036854775807 - 1 + b) {
        ps_raise(ctx, "integer overflow in -", PS_CAT_OVERFLOW, file, line);
        return 0;
    }
    return a - b;
}

int64_t ps_mul(PsCtx *ctx, int64_t a, int64_t b, const char *file, int32_t line) {
    if (a != 0) {
        int64_t r = a * b;
        if (b != 0 && (r / a != b || (a == -1 && b == -9223372036854775807 - 1))) {
            ps_raise(ctx, "integer overflow in *", PS_CAT_OVERFLOW, file, line);
            return 0;
        }
        return r;
    }
    return 0;
}

int64_t ps_neg(PsCtx *ctx, int64_t a, const char *file, int32_t line) {
    if (a == -9223372036854775807 - 1) {
        ps_raise(ctx, "integer overflow in unary -", PS_CAT_OVERFLOW, file, line);
        return 0;
    }
    return -a;
}

double ps_div(PsCtx *ctx, double a, double b, const char *file, int32_t line) {
    if (b == 0.0) {
        ps_raise(ctx, "division by zero", PS_CAT_ZERO, file, line);
        return 0.0;
    }
    return a / b;
}

int64_t ps_floordiv(PsCtx *ctx, int64_t a, int64_t b, const char *file, int32_t line) {
    if (b == 0) {
        ps_raise(ctx, "integer division by zero", PS_CAT_ZERO, file, line);
        return 0;
    }
    if (a == -9223372036854775807 - 1 && b == -1) {
        ps_raise(ctx, "integer overflow in //", PS_CAT_OVERFLOW, file, line);
        return 0;
    }
    int64_t q = a / b;
    if (a % b != 0 && (a < 0) != (b < 0)) {
        q -= 1;
    }
    return q;
}

int64_t ps_mod(PsCtx *ctx, int64_t a, int64_t b, const char *file, int32_t line) {
    if (b == 0) {
        ps_raise(ctx, "integer modulo by zero", PS_CAT_ZERO, file, line);
        return 0;
    }
    if (a == -9223372036854775807 - 1 && b == -1) {
        return 0;
    }
    int64_t r = a % b;
    if (r != 0 && (r < 0) != (b < 0)) {
        r += b;
    }
    return r;
}

double ps_fpow(double a, double b) {
    return pow(a, b);
}

double ps_ffloordiv(PsCtx *ctx, double a, double b, const char *file, int32_t line) {
    if (b == 0.0) {
        ps_raise(ctx, "float division by zero", PS_CAT_ZERO, file, line);
        return 0.0;
    }
    return floor(a / b);
}

double ps_fmod(PsCtx *ctx, double a, double b, const char *file, int32_t line) {
    if (b == 0.0) {
        ps_raise(ctx, "float modulo by zero", PS_CAT_ZERO, file, line);
        return 0.0;
    }
    return a - floor(a / b) * b;
}

int64_t ps_fitw(PsCtx *ctx, int64_t v, int64_t lo, int64_t hi, const char *what, const char *file, int32_t line) {
    if (v < lo || v > hi) {
        char msg[96];
        snprintf(msg, 96, "overflow of %s", what);
        ps_raise(ctx, msg, PS_CAT_OVERFLOW, file, line);
        return 0;
    }
    return v;
}

int64_t ps_f_to_iw(PsCtx *ctx, double v, int64_t lo, int64_t hi, const char *what, const char *file, int32_t line) {
    if (v != v || v < (double)lo || v > (double)hi) {
        char msg[96];
        snprintf(msg, 96, "%f does not fit %s", v, what);
        ps_raise(ctx, msg, PS_CAT_OVERFLOW, file, line);
        return 0;
    }
    return (int64_t)v;
}

uint64_t ps_uadd(PsCtx *ctx, uint64_t a, uint64_t b, const char *file, int32_t line) {
    if (a > ~(uint64_t)0 - b) {
        ps_raise(ctx, "overflow of u64 in +", PS_CAT_OVERFLOW, file, line);
        return 0;
    }
    return a + b;
}

uint64_t ps_usub(PsCtx *ctx, uint64_t a, uint64_t b, const char *file, int32_t line) {
    if (b > a) {
        ps_raise(ctx, "overflow of u64 in - (the result would be negative)", PS_CAT_OVERFLOW, file, line);
        return 0;
    }
    return a - b;
}

uint64_t ps_umul(PsCtx *ctx, uint64_t a, uint64_t b, const char *file, int32_t line) {
    if (a != 0 && b > ~(uint64_t)0 / a) {
        ps_raise(ctx, "overflow of u64 in *", PS_CAT_OVERFLOW, file, line);
        return 0;
    }
    return a * b;
}

uint64_t ps_udiv(PsCtx *ctx, uint64_t a, uint64_t b, const char *file, int32_t line) {
    if (b == 0) {
        ps_raise(ctx, "integer division by zero", PS_CAT_ZERO, file, line);
        return 0;
    }
    return a / b;
}

uint64_t ps_umod(PsCtx *ctx, uint64_t a, uint64_t b, const char *file, int32_t line) {
    if (b == 0) {
        ps_raise(ctx, "integer modulo by zero", PS_CAT_ZERO, file, line);
        return 0;
    }
    return a % b;
}

uint64_t ps_upow(PsCtx *ctx, uint64_t a, uint64_t b, const char *file, int32_t line) {
    uint64_t r = 1;
    uint64_t base = a;
    uint64_t e = b;
    while (e > 0) {
        if (e & (1 == 1)) {
            r = ps_umul(ctx, r, base, file, line);
            if (ctx->exc != NULL) {
                return 0;
            }
        }
        e >>= 1;
        if (e > 0) {
            base = ps_umul(ctx, base, base, file, line);
            if (ctx->exc != NULL) {
                return 0;
            }
        }
    }
    return r;
}

int64_t ps_u_to_i(PsCtx *ctx, uint64_t v, const char *file, int32_t line) {
    if (v > (uint64_t)9223372036854775807) {
        ps_raise(ctx, "this u64 does not fit int", PS_CAT_OVERFLOW, file, line);
        return 0;
    }
    return (int64_t)v;
}

uint64_t ps_i_to_u64(PsCtx *ctx, int64_t v, const char *file, int32_t line) {
    if (v < 0) {
        ps_raise(ctx, "a negative int does not fit u64", PS_CAT_OVERFLOW, file, line);
        return 0;
    }
    return (uint64_t)v;
}

uint64_t ps_f_to_u64(PsCtx *ctx, double v, const char *file, int32_t line) {
    if (v != v || v < 0.0 || v >= 18446744073709551616.0) {
        ps_raise(ctx, "this float does not fit u64", PS_CAT_OVERFLOW, file, line);
        return 0;
    }
    return (uint64_t)v;
}

int64_t ps_wrapw(int64_t v, int32_t bits, int uns) {
    uint64_t u = (uint64_t)v;
    if (bits < 64) {
        u &= ((uint64_t)1 << (uint64_t)bits) - 1;
    }
    if (!uns && bits < 64 && (u & ((uint64_t)1 << (uint64_t)(bits - 1))) != 0) {
        u |= ~(((uint64_t)1 << (uint64_t)bits) - 1);
    }
    return (int64_t)u;
}

PsStr *ps_str_from_uint(PsCtx *ctx, uint64_t v) {
    char buf[24];
    int32_t i = 24;
    uint64_t n = v;
    do {
        i -= 1;
        buf[i] = (char)('0' + (int)(n % 10));
        n /= 10;
    } while (n != 0);
    return ps_str_new(ctx, buf + i, (size_t)(24 - i));
}

PsStr *ps_fmt_uint(PsCtx *ctx, uint64_t v, int32_t width, char align, int zero, char ty) {
    PsStr *s = ps_str_from_uint(ctx, v);
    return ps_pad(ctx, s->data, (size_t)s->len, width, align, zero);
}

int64_t ps_pow(PsCtx *ctx, int64_t a, int64_t b, const char *file, int32_t line) {
    if (b < 0) {
        ps_raise(ctx, "negative exponent on integers (write a float base for that)", PS_CAT_VALUE, file, line);
        return 0;
    }
    int64_t r = 1;
    int64_t base = a;
    int64_t e = b;
    while (e > 0) {
        if (e & (1 == 1)) {
            r = ps_mul(ctx, r, base, file, line);
            if (ctx->exc != NULL) {
                return 0;
            }
        }
        e >>= 1;
        if (e > 0) {
            base = ps_mul(ctx, base, base, file, line);
            if (ctx->exc != NULL) {
                return 0;
            }
        }
    }
    return r;
}
