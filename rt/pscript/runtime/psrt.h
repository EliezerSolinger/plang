#pragma once

#include <stdint.h>
#include <stddef.h>

#include <stdio.h>
#include <stddef.h>
#include <math.h>
#include <pthread.h>
#include <time.h>
#include <regex.h>
#include <regex.h>
#include <regex.h>
#include <regex.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <signal.h>

typedef enum { PS_TY_MOVED = 0, PS_TY_STR = 1, PS_TY_ERR = 2, PS_TY_LIST = 3, PS_TY_ARR = 4, PS_TY_DICT = 5, PS_TY_DYN = 6, PS_TY_USER = 7, PS_TY_TASK = 8, PS_TY_WORKER = 9, PS_TY_FILE = 10, PS_TY_CLOSURE = 11, PS_TY_ANY = 12, PS_TY_BUFFER = 13, PS_TY_TIMER = 14, PS_TY_CONN = 15 } PsTyId;

typedef struct PsObj PsObj;
typedef struct PsStr PsStr;
typedef struct PsBlock PsBlock;
typedef struct PsDesc PsDesc;
typedef struct PsUser PsUser;
typedef struct PsTask PsTask;
typedef struct PsDyn PsDyn;
typedef struct PsStrPtr PsStrPtr;
typedef struct PsErr PsErr;
typedef struct PsArr PsArr;
typedef struct PsList PsList;
typedef struct PsDict PsDict;
typedef struct PsFrame PsFrame;
typedef struct PsRoot PsRoot;
typedef struct PsAny PsAny;
typedef struct PsClosure PsClosure;
typedef struct PsFile PsFile;
typedef struct PsMsg PsMsg;
typedef struct PsWorkerBlk PsWorkerBlk;
typedef struct PsConn PsConn;
typedef struct PsWorker PsWorker;
typedef struct PsSer PsSer;
typedef struct PsDes PsDes;
typedef struct PsShape PsShape;
typedef struct PsWork PsWork;
typedef struct PsCtx PsCtx;
typedef struct PsBuffer PsBuffer;
typedef struct PsSStr PsSStr;
typedef struct PsSDict PsSDict;
typedef struct PsTimer PsTimer;

struct PsObj {
    int32_t ty;
    uint32_t size;
    struct PsObj *fwd;
};

struct PsStr {
    PsObj obj;
    uint32_t len;
    uint32_t nchars;
    uint32_t hash;
    PsArr *offs;
    char data[1];
};

struct PsBlock {
    struct PsBlock *next;
    size_t used;
    size_t cap;
    char *base;
};

struct PsDesc {
    const char *name;
    void (*trace)(void *, PsBlock *);
};

struct PsUser {
    PsObj obj;
    const PsDesc *desc;
};

struct PsTask {
    PsObj obj;
    int32_t state;
    int (*step)(PsCtx *, PsTask *);
    PsObj *frame;
    PsErr *err;
    struct PsTask *waiting_on;
    struct PsTask *waiter;
    struct PsTask *next;
    int32_t cancelled;
    double deadline;
    int32_t is_timer;
    int32_t is_recv;
    int32_t is_io;
    PsWork *work;
    PsWorkerBlk *rblk;
    int32_t rdir;
    int32_t rkind;
    size_t rsize;
    const PsShape *rshape;
};

struct PsDyn {
    PsObj obj;
    const void *vt;
    uint32_t nbytes;
    uint32_t isref;
    char data[1];
};

typedef enum { PS_CAT_NONE = 0, PS_CAT_INDEX = 1, PS_CAT_KEY = 2, PS_CAT_TYPE = 3, PS_CAT_VALUE = 4, PS_CAT_ZERO = 5, PS_CAT_OVERFLOW = 6, PS_CAT_IO = 7 } PsCat;

struct PsStrPtr {
    PsStr *p;
};

struct PsErr {
    PsObj obj;
    PsStr *msg;
    int32_t cat;
    const char *file;
    int32_t line;
};

struct PsArr {
    PsObj obj;
    size_t nbytes;
};

struct PsList {
    PsObj obj;
    int64_t len;
    int64_t cap;
    int32_t esize;
    int eref;
    PsArr *data;
    char *raw;
    PsBuffer *owner;
};

typedef enum { PS_K_BITS = 0, PS_K_STR = 1 } PsKeyKind;

struct PsDict {
    PsObj obj;
    int64_t n;
    int64_t used;
    int64_t cap;
    int32_t ksize;
    int32_t vsize;
    int32_t kkind;
    int kref;
    int vref;
    PsArr *keys;
    PsArr *vals;
    PsArr *state;
};

struct PsFrame {
    struct PsFrame *prev;
    int32_t nslots;
    PsObj ***slots;
};

struct PsRoot {
    PsObj **slot;
    struct PsRoot *next;
};

typedef enum { PS_ANY_NONE = 0, PS_ANY_INT = 1, PS_ANY_FLOAT = 2, PS_ANY_BOOL = 3 } PsAnyKind;

struct PsAny {
    PsObj obj;
    int32_t kind;
    int64_t i;
    double f;
};

struct PsClosure {
    PsObj obj;
    void *fn;
    PsObj *env;
    const char *sig;
};

struct PsFile {
    PsObj obj;
    FILE *fp;
    int32_t is_open;
    int32_t is_std;
};

struct PsMsg {
    struct PsMsg *next;
    size_t size;
    char *data;
};

struct PsWorkerBlk {
    pthread_t thread;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    PsMsg *up_head;
    PsMsg *up_tail;
    PsMsg *down_head;
    PsMsg *down_tail;
    void *args;
    size_t nargs;
    int32_t started;
    int32_t done;
    int32_t joined;
    int32_t failed;
    char *err;
    int32_t err_cat;
    int32_t collected;
    int32_t detached;
    int up_r;
    int up_w;
    int dn_r;
    int dn_w;
    struct PsWorkerBlk *next;
};

struct PsConn {
    PsObj obj;
    int fd;
    int32_t is_open;
    int32_t listening;
};

struct PsWorker {
    PsObj obj;
    PsWorkerBlk *blk;
};

typedef enum { PS_SH_POD = 0, PS_SH_STR = 1, PS_SH_LIST = 2, PS_SH_SET = 3, PS_SH_DICT = 4, PS_SH_STRUCT = 5 } PsShKind;

struct PsSer {
    char *buf;
    size_t len;
    size_t cap;
    void **keys;
    int32_t *vals;
    size_t nslots;
    int32_t used;
    int32_t count;
};

struct PsDes {
    const char *buf;
    size_t len;
    size_t pos;
    void **built;
    int32_t nbuilt;
    int32_t cbuilt;
    int32_t bad;
};

struct PsShape {
    int32_t kind;
    uint32_t size;
    const struct PsShape *inner;
    const struct PsShape *key;
    int32_t kkind;
    void (*ser)(PsSer *, void *);
    void (*des)(PsCtx *, PsDes *, void *);
    const PsDesc *desc;
};

typedef enum { PS_W_NONE = 0, PS_W_FILE, PS_W_BYTES, PS_W_STR, PS_W_LINES, PS_W_INT, PS_W_CONN } PsIoWant;

typedef enum { PS_IO_OPEN = 0, PS_IO_READ, PS_IO_READALL, PS_IO_WRITE, PS_IO_CLOSE, PS_IO_ACCEPT, PS_IO_RECV, PS_IO_SEND, PS_IO_CONNECT, PS_IO_LOOKUP } PsIoOp;

struct PsWork {
    struct PsWork *next;
    int32_t op;
    FILE *fp;
    char *path;
    char *mode;
    char *buf;
    size_t n;
    int32_t want;
    int64_t rc;
    int32_t err;
    int32_t done;
    int32_t orphan;
    int wake;
    int fd;
    int16_t events;
    size_t off;
    int32_t port;
};

struct PsCtx {
    PsBlock *blocks;
    PsFrame *frames;
    PsRoot *roots;
    PsErr *exc;
    size_t live;
    size_t alloced;
    int64_t nalloc;
    int64_t ngc;
    PsTask *ready;
    PsTask *ready_tail;
    void *globals;
    PsWorkerBlk *parent;
    PsWorkerBlk *workers;
    PsTask *timers;
    int io_r;
    int io_w;
    PsTask *waiters;
    int64_t nogc;
    size_t nogc_budget;
    size_t nogc_start;
};

void ps_ctx_init(PsCtx *ctx);

int ps_ctx_done(PsCtx *ctx);

void *ps_alloc(PsCtx *ctx, size_t size, int32_t ty);

void ps_gc_suspend(PsCtx *ctx, int64_t budget, const char *file, int32_t line);

void ps_gc_resume(PsCtx *ctx);

void *ps_new(PsCtx *ctx, const PsDesc *d, size_t size);

PsObj *ps_forward(PsBlock *to, PsObj *p);

PsTask *ps_task_new(PsCtx *ctx, int (*step)(PsCtx *, PsTask *), PsObj *frame);

int ps_task_done(PsTask *t);

void ps_task_step(PsCtx *ctx, PsTask *t);

void ps_task_park(PsCtx *ctx, PsTask *waiter, PsTask *on);

PsList *ps_gather_settled(PsCtx *ctx, PsList *ts);

PsTask *ps_gather_settled_task(PsCtx *ctx, PsList *ts);

int64_t ps_first_ok(PsCtx *ctx, PsList *ts);

PsTask *ps_first_ok_task(PsCtx *ctx, PsList *ts);

PsList *ps_gather_map(PsCtx *ctx, PsList *items, PsTask *(*mk)(void *, PsCtx *, const void *), void *env, int32_t esize, int eref, int64_t at_most);

PsTask *ps_gather_map_task(PsCtx *ctx, PsList *items, PsTask *(*mk)(void *, PsCtx *, const void *), void *env, int32_t esize, int eref, int64_t at_most);

void ps_task_wait(PsCtx *ctx, PsTask *t);

void ps_task_yield(PsCtx *ctx, PsTask *t);

int ps_sched_yield(PsCtx *ctx);

void ps_sched_drain(PsCtx *ctx);

void ps_task_fail(PsCtx *ctx, PsTask *t);

void ps_task_take_err(PsCtx *ctx, PsTask *t);

void *ps_task_ret(PsTask *t);

void ps_task_cancel(PsCtx *ctx, PsTask *t);

int ps_task_cancelled(PsTask *t);

PsTask *ps_timer_task(PsCtx *ctx, double at);

int ps_sched_progress(PsCtx *ctx);

PsTask *ps_task_of_int(PsCtx *ctx, int64_t v);

int64_t ps_race(PsCtx *ctx, PsList *ts);

int ps_timeout(PsCtx *ctx, PsTask *t, double seconds);

PsWorker *ps_worker_new(PsCtx *ctx, void *(*entry)(void *), void *args, size_t nargs);

void *ps_worker_args(void *blk);

char *ps_str_export(PsStr *s);

PsStr *ps_str_import(PsCtx *ctx, char *p);

void *ps_list_export(PsList *l);

PsList *ps_list_import(PsCtx *ctx, void *p);

void ps_worker_finish(PsCtx *ctx, void *blk);

int ps_worker_send_up(PsCtx *ctx, const void *p, size_t size);

int ps_send_obj_up(PsCtx *ctx, const PsShape *sh, const void *slot);

int ps_send_obj_down(PsWorker *w, const PsShape *sh, const void *slot);

PsTask *ps_worker_recv_obj(PsCtx *ctx, PsWorker *w, const PsShape *sh, size_t size);

PsTask *ps_parent_recv_obj(PsCtx *ctx, const PsShape *sh, size_t size);

void ps_ser_value(PsSer *s, const PsShape *sh, const void *slot);

void ps_des_value(PsCtx *ctx, PsDes *d, const PsShape *sh, void *slot);

int ps_worker_send_down(PsWorker *w, const void *p, size_t size);

PsTask *ps_worker_recv(PsCtx *ctx, PsWorker *w, size_t size);

PsTask *ps_parent_recv(PsCtx *ctx, size_t size);

PsErr *ps_worker_error(PsCtx *ctx, PsWorker *w);

void ps_join_all(PsCtx *ctx);

PsList *ps_gather(PsCtx *ctx, PsList *ts, int32_t esize, int eref);

PsTask *ps_gather_task(PsCtx *ctx, PsList *ts, int32_t esize, int eref);

struct PsBuffer {
    PsObj obj;
    char *data;
    size_t nbytes;
    int32_t open;
    void *gone_from;
};

PsBuffer *ps_buffer_new(PsCtx *ctx, int64_t nbytes, const char *file, int32_t line);

void ps_buffer_close(PsCtx *ctx, PsBuffer *b);

int64_t ps_buffer_size(PsBuffer *b);

void ps_buffer_transfer(PsCtx *ctx, PsBuffer *b);

double ps_buffer_get_f64(PsCtx *ctx, PsBuffer *b, int64_t i, const char *file, int32_t line);

void ps_buffer_set_f64(PsCtx *ctx, PsBuffer *b, int64_t i, double v, const char *file, int32_t line);

PsList *ps_buffer_view(PsCtx *ctx, PsBuffer *b, int32_t esize, const char *file, int32_t line);

PsObj *ps_json_parse(PsCtx *ctx, PsStr *text, const char *file, int32_t line);

PsList *ps_re_match(PsCtx *ctx, PsStr *pattern, PsStr *text, const char *file, int32_t line);

void ps_sys_args(int argc, char **argv);

PsList *ps_sys_argv(PsCtx *ctx);

PsDict *ps_sys_env(PsCtx *ctx);

void ps_sys_exit(PsCtx *ctx, int64_t code);

double ps_sys_time(void);

PsTask *ps_sleep(PsCtx *ctx, double seconds);

int64_t ps_worker_status(PsWorker *w);

void ps_worker_detach(PsWorker *w);

PsClosure *ps_closure_new(PsCtx *ctx, void *fn, PsObj *env, const char *sig);

PsObj *ps_any_int(PsCtx *ctx, int64_t v);

PsObj *ps_any_float(PsCtx *ctx, double v);

PsObj *ps_any_bool(PsCtx *ctx, int v);

PsObj *ps_any_none(PsCtx *ctx);

int64_t ps_as_int(PsCtx *ctx, PsObj *v, const char *file, int32_t line);

double ps_as_float(PsCtx *ctx, PsObj *v, const char *file, int32_t line);

int ps_as_bool(PsCtx *ctx, PsObj *v, const char *file, int32_t line);

PsObj *ps_as_ref(PsCtx *ctx, PsObj *v, int32_t want, const char *what, const char *file, int32_t line);

int ps_is_kind(PsObj *v, int32_t ty, int32_t kind);

PsFile *ps_file_open(PsCtx *ctx, PsStr *path, PsStr *mode, const char *file, int32_t line);

PsTask *ps_aio_open(PsCtx *ctx, PsStr *path, PsStr *mode);

PsTask *ps_aio_read(PsCtx *ctx, PsFile *f, int64_t n);

PsTask *ps_aio_readall(PsCtx *ctx, PsFile *f, int32_t want);

PsTask *ps_aio_write(PsCtx *ctx, PsFile *f, PsStr *s);

PsTask *ps_aio_write_bytes(PsCtx *ctx, PsFile *f, PsList *l);

PsTask *ps_aio_close(PsCtx *ctx, PsFile *f);

PsWork *ps_work_new(int32_t op);

void ps_pool_submit(PsCtx *ctx, PsWork *w);

PsTask *ps_io_task(PsCtx *ctx, PsWork *w, int isref, size_t size);

int ps_utf8_valid(const char *b, size_t n);

PsStr *ps_str_from_bytes(PsCtx *ctx, PsList *l, const char *file, int32_t line);

PsStr *ps_str_checked(PsCtx *ctx, const char *p, size_t n, const char *file, int32_t line);

PsList *ps_bytes_new(PsCtx *ctx, const uint8_t *p, size_t n);

PsTask *ps_aprint(PsCtx *ctx, PsStr *s);

PsFile *ps_std_file(PsCtx *ctx, int32_t which);

PsConn *ps_net_listen(PsCtx *ctx, int64_t port);

PsTask *ps_net_accept(PsCtx *ctx, PsConn *srv);

PsTask *ps_net_connect(PsCtx *ctx, PsStr *host, int64_t port);

PsTask *ps_net_lookup(PsCtx *ctx, PsStr *host);

PsTask *ps_conn_read(PsCtx *ctx, PsConn *c, int64_t n);

PsTask *ps_conn_write(PsCtx *ctx, PsConn *c, PsStr *s);

PsTask *ps_conn_write_bytes(PsCtx *ctx, PsConn *c, PsList *l);

void ps_conn_close(PsCtx *ctx, PsConn *c);

int64_t ps_conn_port(PsConn *c);

int64_t ps_file_write(PsCtx *ctx, PsFile *f, PsStr *s, const char *file, int32_t line);

PsStr *ps_file_read(PsCtx *ctx, PsFile *f, const char *file, int32_t line);

PsList *ps_file_readlines(PsCtx *ctx, PsFile *f, const char *file, int32_t line);

void ps_file_close(PsCtx *ctx, PsFile *f);

void ps_shared_str_init(PsSStr *slot, const char *bytes, int64_t n);

PsStr *ps_shared_str_get(PsCtx *ctx, void *mu, PsSStr *slot);

void ps_shared_str_put(void *mu, PsSStr *slot, PsStr *v);

void *ps_lock_new(void);

void ps_lock(void *mu);

void ps_unlock(void *mu);

struct PsSStr {
    char *p;
    size_t n;
};

struct PsSDict {
    void *mu;
    char *keys;
    char *vals;
    char *state;
    size_t ksize;
    size_t vsize;
    int kstr;
    int vstr;
    int64_t len;
    int64_t cap;
};

PsSDict *ps_sdict_new(int64_t ksize, int64_t vsize, int kstr, int vstr);

int64_t ps_sdict_len(PsSDict *d);

void ps_sdict_put(PsCtx *ctx, PsSDict *d, const void *key, const void *val);

int ps_sdict_has(PsSDict *d, const void *key);

void ps_sdict_get(PsCtx *ctx, PsSDict *d, const void *key, void *out, const char *file, int32_t line);

int ps_sdict_del(PsSDict *d, const void *key);

struct PsTimer {
    PsObj obj;
    double period;
    double next;
};

PsTimer *ps_interval_new(PsCtx *ctx, double seconds, const char *file, int32_t line);

PsTask *ps_timer_tick(PsCtx *ctx, PsTimer *t);

void ps_pack_int(PsCtx *ctx, PsList *l, uint64_t v, int32_t nbytes, int32_t be);

uint64_t ps_unpack_int(PsList *l, int64_t off, int32_t nbytes, int32_t be);

void ps_pack_f64(PsCtx *ctx, PsList *l, double v, int32_t be);

double ps_unpack_f64(PsList *l, int64_t off, int32_t be);

void ps_pack_f32(PsCtx *ctx, PsList *l, float v, int32_t be);

float ps_unpack_f32(PsList *l, int64_t off, int32_t be);

void ps_unpack_check(PsCtx *ctx, PsList *l, int64_t want, const char *file, int32_t line);

PsClosure *ps_closure_narrow(PsCtx *ctx, PsClosure *c, const char *want, const char *file, int32_t line);

PsDyn *ps_box(PsCtx *ctx, const void *src, size_t nbytes, const void *vt, int isref);

void *ps_dyn_data(PsCtx *ctx, PsDyn *d);

void ps_gc_poll(PsCtx *ctx);

void ps_gc(PsCtx *ctx);

void ps_add_root(PsCtx *ctx, PsObj **slot);

void ps_push_frame(PsCtx *ctx, PsFrame *f, PsObj ***slots, int32_t n);

void ps_pop_frame(PsCtx *ctx, PsFrame *f);

PsStr *ps_str_new(PsCtx *ctx, const char *bytes, size_t len);

PsStr *ps_str_concat(PsCtx *ctx, PsStr *a, PsStr *b);

PsStr *ps_str_from_int(PsCtx *ctx, int64_t v);

PsStr *ps_str_from_float(PsCtx *ctx, double v);

PsStr *ps_str_from_bool(PsCtx *ctx, int v);

int ps_str_eq(PsStr *a, PsStr *b);

int32_t ps_str_lt(PsStr *a, PsStr *b);

int ps_str_has(PsStr *hay, PsStr *needle);

int64_t ps_str_nbytes(PsStr *s);

PsStr *ps_str_step(PsCtx *ctx, PsStr *s, int64_t *off);

int64_t ps_str_len(PsCtx *ctx, PsStr *s);

const char *ps_str_cstr(PsStr *s);

int64_t ps_str_to_int(PsCtx *ctx, PsStr *s);

double ps_str_to_float(PsCtx *ctx, PsStr *s);

PsStr *ps_str_at(PsCtx *ctx, PsStr *s, int64_t i, const char *file, int32_t line);

int64_t ps_str_ord(PsCtx *ctx, PsStr *s, const char *file, int32_t line);

PsStr *ps_str_chr(PsCtx *ctx, int64_t cp, const char *file, int32_t line);

PsStr *ps_str_slice(PsCtx *ctx, PsStr *s, int64_t a, int64_t b, int has_a, int has_b);

PsList *ps_str_split(PsCtx *ctx, PsStr *s, PsStr *sep);

int64_t ps_str_find(PsCtx *ctx, PsStr *s, PsStr *needle);

int ps_str_contains(PsStr *s, PsStr *needle);

PsStr *ps_str_lower(PsCtx *ctx, PsStr *s);

PsStr *ps_str_upper(PsCtx *ctx, PsStr *s);

int ps_str_startswith(PsStr *s, PsStr *p);

int ps_str_endswith(PsStr *s, PsStr *p);

PsStr *ps_str_strip(PsCtx *ctx, PsStr *s);

PsList *ps_list_new(PsCtx *ctx, int32_t esize, int eref, int64_t cap);

int64_t ps_list_len(PsList *l);

char *ps_list_base(PsList *l);

int64_t ps_list_at(PsCtx *ctx, PsList *l, int64_t i, const char *file, int32_t line);

int64_t ps_arr_at(PsCtx *ctx, int64_t i, int64_t n, const char *file, int32_t line);

char *ps_list_push(PsCtx *ctx, PsList *l);

PsList *ps_list_slice(PsCtx *ctx, PsList *l, int64_t a, int64_t b, int has_a, int has_b);

char *ps_list_insert(PsCtx *ctx, PsList *l, int64_t i, const char *file, int32_t line);

void ps_list_remove_at(PsCtx *ctx, PsList *l, int64_t i, const char *file, int32_t line);

void ps_list_reverse(PsList *l);

PsList *ps_list_sorted(PsCtx *ctx, PsList *l, int32_t kind);

PsList *ps_list_sorted_by(PsCtx *ctx, PsList *l, double (*keyfn)(void *, PsCtx *, const void *), void *env);

PsDict *ps_dict_new(PsCtx *ctx, int32_t ksize, int32_t vsize, int32_t kkind, int kref, int vref);

int64_t ps_dict_len(PsDict *d);

char *ps_dict_put(PsCtx *ctx, PsDict *d, const char *key);

char *ps_dict_get(PsCtx *ctx, PsDict *d, const char *key, const char *file, int32_t line);

int ps_dict_has(PsDict *d, const char *key);

int ps_dict_del(PsDict *d, const char *key);

int64_t ps_dict_cap(PsDict *d);

int ps_dict_live(PsDict *d, int64_t i);

char *ps_dict_key_at(PsDict *d, int64_t i);

char *ps_dict_val_at(PsDict *d, int64_t i);

void ps_raise(PsCtx *ctx, const char *msg, int32_t cat, const char *file, int32_t line);

PsErr *ps_exc_take(PsCtx *ctx);

void ps_exc_put(PsCtx *ctx, PsErr *e);

void ps_raise_str(PsCtx *ctx, PsStr *msg, int64_t cat, const char *file, int32_t line);

PsErr *ps_err_new(PsCtx *ctx, PsStr *msg, int64_t cat);

void ps_reraise(PsCtx *ctx, PsErr *e);

int ps_has_exc(PsCtx *ctx);

PsErr *ps_take_exc(PsCtx *ctx);

PsStr *ps_err_message(PsErr *e);

int64_t ps_err_category(PsErr *e);

PsStr *ps_fmt_int(PsCtx *ctx, int64_t v, int32_t width, char align, int zero, char ty);

PsStr *ps_fmt_float(PsCtx *ctx, double v, int32_t width, int32_t prec, char align, int zero);

PsStr *ps_fmt_str(PsCtx *ctx, PsStr *s, int32_t width, char align);

void ps_print(PsCtx *ctx, PsStr *s);

int64_t ps_add(PsCtx *ctx, int64_t a, int64_t b, const char *file, int32_t line);

int64_t ps_sub(PsCtx *ctx, int64_t a, int64_t b, const char *file, int32_t line);

int64_t ps_mul(PsCtx *ctx, int64_t a, int64_t b, const char *file, int32_t line);

int64_t ps_neg(PsCtx *ctx, int64_t a, const char *file, int32_t line);

double ps_div(PsCtx *ctx, double a, double b, const char *file, int32_t line);

int64_t ps_floordiv(PsCtx *ctx, int64_t a, int64_t b, const char *file, int32_t line);

int64_t ps_mod(PsCtx *ctx, int64_t a, int64_t b, const char *file, int32_t line);

int64_t ps_pow(PsCtx *ctx, int64_t a, int64_t b, const char *file, int32_t line);

int64_t ps_fitw(PsCtx *ctx, int64_t v, int64_t lo, int64_t hi, const char *what, const char *file, int32_t line);

int64_t ps_f_to_iw(PsCtx *ctx, double v, int64_t lo, int64_t hi, const char *what, const char *file, int32_t line);

uint64_t ps_uadd(PsCtx *ctx, uint64_t a, uint64_t b, const char *file, int32_t line);

uint64_t ps_usub(PsCtx *ctx, uint64_t a, uint64_t b, const char *file, int32_t line);

uint64_t ps_umul(PsCtx *ctx, uint64_t a, uint64_t b, const char *file, int32_t line);

uint64_t ps_udiv(PsCtx *ctx, uint64_t a, uint64_t b, const char *file, int32_t line);

uint64_t ps_umod(PsCtx *ctx, uint64_t a, uint64_t b, const char *file, int32_t line);

uint64_t ps_upow(PsCtx *ctx, uint64_t a, uint64_t b, const char *file, int32_t line);

int64_t ps_u_to_i(PsCtx *ctx, uint64_t v, const char *file, int32_t line);

uint64_t ps_i_to_u64(PsCtx *ctx, int64_t v, const char *file, int32_t line);

uint64_t ps_f_to_u64(PsCtx *ctx, double v, const char *file, int32_t line);

int64_t ps_wrapw(int64_t v, int32_t bits, int uns);

PsStr *ps_str_from_uint(PsCtx *ctx, uint64_t v);

PsStr *ps_fmt_uint(PsCtx *ctx, uint64_t v, int32_t width, char align, int zero, char ty);

double ps_fpow(double a, double b);

double ps_ffloordiv(PsCtx *ctx, double a, double b, const char *file, int32_t line);

double ps_fmod(PsCtx *ctx, double a, double b, const char *file, int32_t line);
