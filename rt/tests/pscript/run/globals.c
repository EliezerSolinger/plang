#include <stdint.h>

#include "../../../pscript/runtime/psrt.h"

typedef enum { NONE, INDEX, KEY, TYPE, VALUE, ZERO, OVERFLOW, IO } Category;

typedef enum { RUNNING, DONE, ERROR, GONE } Status;

typedef enum { LE, BE } Endian;

int64_t bump(PsCtx *__ctx, int64_t by);

int64_t next_rand(PsCtx *__ctx);

static int64_t LIMIT = 10;

typedef struct __PsGlobals __PsGlobals;

struct __PsGlobals {
    int64_t counter;
    int64_t rng_state;
    PsList *history;
};

static void __ps_globals_init(PsCtx *__ctx);

int64_t bump(PsCtx *__ctx, int64_t by) {
    if (ps_has_exc(__ctx)) {
        return 0;
    }
    int64_t __ret = ps_add(__ctx, by, 1, "tests/pscript/run/globals.psc", 13);
    if (ps_has_exc(__ctx)) {
        return 0;
    }
    return __ret;
}

int64_t next_rand(PsCtx *__ctx) {
    if (ps_has_exc(__ctx)) {
        return 0;
    }
    ((__PsGlobals *)__ctx->globals)->rng_state = ps_mod(__ctx, ps_add(__ctx, ps_mul(__ctx, ((__PsGlobals *)__ctx->globals)->rng_state, 31, "tests/pscript/run/globals.psc", 38), 17, "tests/pscript/run/globals.psc", 38), 1000, "tests/pscript/run/globals.psc", 38);
    if (ps_has_exc(__ctx)) {
        return 0;
    }
    *(int64_t *)ps_list_push(__ctx, ((__PsGlobals *)__ctx->globals)->history) = ((__PsGlobals *)__ctx->globals)->rng_state;
    ps_gc_poll(__ctx);
    return ((__PsGlobals *)__ctx->globals)->rng_state;
}

static void __ps_globals_init(PsCtx *__ctx) {
    __PsGlobals *__g = (__PsGlobals *)calloc(1, sizeof(__PsGlobals));
    __ctx->globals = (void *)__g;
    ps_add_root(__ctx, (PsObj **)&__g->history);
}

int main(int argc, char **argv) {
    PsStr *label;
    PsCtx __ctx;
    ps_sys_args(argc, argv);
    ps_ctx_init(&__ctx);
    __ps_globals_init(&__ctx);
    PsList *__lst3 = NULL;
    PsList *__st4 = NULL;
    PsStr *__ord5 = NULL;
    PsStr *__ord6 = NULL;
    PsStr *__ord7 = NULL;
    PsStr *__ord8 = NULL;
    PsObj **__sl1[6];
    __sl1[0] = (PsObj **)&__lst3;
    __sl1[1] = (PsObj **)&__st4;
    __sl1[2] = (PsObj **)&__ord5;
    __sl1[3] = (PsObj **)&__ord6;
    __sl1[4] = (PsObj **)&__ord7;
    __sl1[5] = (PsObj **)&__ord8;
    PsFrame __fr1;
    ps_push_frame(&__ctx, &__fr1, __sl1, 6);
    ((__PsGlobals *)(&__ctx)->globals)->counter = 0;
    int64_t __st0 = bump(&__ctx, ((__PsGlobals *)(&__ctx)->globals)->counter);
    ((__PsGlobals *)(&__ctx)->globals)->counter = __st0;
    if (ps_has_exc(&__ctx)) {
        int __defer_ret0 = ps_ctx_done(&__ctx);
        {
            ps_pop_frame(&__ctx, &__fr1);
        }
        return __defer_ret0;
    }
    ps_gc_poll(&__ctx);
    int64_t __st1 = bump(&__ctx, ((__PsGlobals *)(&__ctx)->globals)->counter);
    ((__PsGlobals *)(&__ctx)->globals)->counter = __st1;
    if (ps_has_exc(&__ctx)) {
        int __defer_ret1 = ps_ctx_done(&__ctx);
        {
            ps_pop_frame(&__ctx, &__fr1);
        }
        return __defer_ret1;
    }
    ps_gc_poll(&__ctx);
    ps_print(&__ctx, ps_str_concat(&__ctx, ps_str_new(&__ctx, "counter ", 8), ps_str_from_int(&__ctx, ((__PsGlobals *)(&__ctx)->globals)->counter)));
    ps_gc_poll(&__ctx);
    ps_print(&__ctx, ps_str_concat(&__ctx, ps_str_new(&__ctx, "limit ", 6), ps_str_from_int(&__ctx, LIMIT)));
    ps_gc_poll(&__ctx);
    int64_t __ord2 = 0;
    if (__ord2 = ((__PsGlobals *)(&__ctx)->globals)->counter, __ord2 < LIMIT) {
        label = NULL;
        PsObj **__sl0[1];
        __sl0[0] = (PsObj **)&label;
        PsFrame __fr0;
        ps_push_frame(&__ctx, &__fr0, __sl0, 1);
        label = ps_str_new(&__ctx, "small", 5);
        ps_gc_poll(&__ctx);
        {
            ps_pop_frame(&__ctx, &__fr0);
        }
    } else {
        label = ps_str_new(&__ctx, "big", 3);
        ps_gc_poll(&__ctx);
    }
    ps_gc_poll(&__ctx);
    ps_print(&__ctx, label);
    ps_gc_poll(&__ctx);
    ((__PsGlobals *)(&__ctx)->globals)->rng_state = 7;
    __lst3 = NULL;
    __st4 = (__lst3 = ps_list_new(&__ctx, (int32_t)sizeof(int64_t), 0, 0), __lst3);
    ((__PsGlobals *)(&__ctx)->globals)->history = __st4;
    ps_gc_poll(&__ctx);
    __ord5 = NULL;
    __ord6 = NULL;
    ps_print(&__ctx, (__ord5 = ps_str_concat(&__ctx, (__ord6 = ps_str_concat(&__ctx, ps_str_concat(&__ctx, ps_str_new(&__ctx, "rand ", 5), ps_fmt_int(&__ctx, next_rand(&__ctx), 0, (char)0, 0, 0)), ps_str_new(&__ctx, " ", 1)), ps_str_concat(&__ctx, __ord6, ps_fmt_int(&__ctx, next_rand(&__ctx), 0, (char)0, 0, 0))), ps_str_new(&__ctx, " ", 1)), ps_str_concat(&__ctx, __ord5, ps_fmt_int(&__ctx, next_rand(&__ctx), 0, (char)0, 0, 0))));
    if (ps_has_exc(&__ctx)) {
        int __defer_ret2 = ps_ctx_done(&__ctx);
        {
            ps_pop_frame(&__ctx, &__fr1);
        }
        return __defer_ret2;
    }
    ps_gc_poll(&__ctx);
    __ord7 = NULL;
    __ord8 = NULL;
    ps_print(&__ctx, (__ord7 = ps_str_concat(&__ctx, (__ord8 = ps_str_concat(&__ctx, ps_str_concat(&__ctx, ps_str_new(&__ctx, "state ", 6), ps_fmt_int(&__ctx, ((__PsGlobals *)(&__ctx)->globals)->rng_state, 0, (char)0, 0, 0)), ps_str_new(&__ctx, " history ", 9)), ps_str_concat(&__ctx, __ord8, ps_fmt_int(&__ctx, ps_list_len(((__PsGlobals *)(&__ctx)->globals)->history), 0, (char)0, 0, 0))), ps_str_new(&__ctx, " ", 1)), ps_str_concat(&__ctx, __ord7, ps_fmt_int(&__ctx, ((int64_t *)ps_list_base(((__PsGlobals *)(&__ctx)->globals)->history))[ps_list_at(&__ctx, ((__PsGlobals *)(&__ctx)->globals)->history, 0, "tests/pscript/run/globals.psc", 44)], 0, (char)0, 0, 0))));
    if (ps_has_exc(&__ctx)) {
        int __defer_ret3 = ps_ctx_done(&__ctx);
        {
            ps_pop_frame(&__ctx, &__fr1);
        }
        return __defer_ret3;
    }
    ps_gc_poll(&__ctx);
    int __defer_ret4 = ps_ctx_done(&__ctx);
    {
        ps_pop_frame(&__ctx, &__fr1);
    }
    return __defer_ret4;
}
