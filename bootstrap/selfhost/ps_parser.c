#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include <string.h>
#include <stdlib.h>
#include "ps_parser.h"
#include "parser.h"
#include "vecs.h"
#include "../packages/stl/vec.h"

typedef struct Vec_pPsExpr Vec_pPsExpr;
typedef struct Vec_pPsStmt Vec_pPsStmt;
typedef struct Vec_pPsDecl Vec_pPsDecl;
typedef struct Vec_pPsType Vec_pPsType;
typedef struct Vec_pPsFunc Vec_pPsFunc;
typedef struct Vec_pPsCase Vec_pPsCase;
typedef struct Vec_pPsBlock Vec_pPsBlock;
typedef struct Vec_PsParam Vec_PsParam;
typedef struct Vec_PsTParam Vec_PsTParam;
typedef struct Vec_PsField Vec_PsField;
typedef struct Vec_PsEnumItem Vec_PsEnumItem;
typedef struct PsP PsP;

struct Vec_pPsExpr {
    PsExpr **data;
    int32_t len;
    int32_t cap;
};

void Vec_pPsExpr_init(Vec_pPsExpr *self);

void Vec_pPsExpr_reserve(Vec_pPsExpr *self, int32_t n);

void Vec_pPsExpr_push(Vec_pPsExpr *self, PsExpr *item);

PsExpr *Vec_pPsExpr_pop(Vec_pPsExpr *self);

PsExpr *Vec_pPsExpr_get(const Vec_pPsExpr *self, int32_t i);

void Vec_pPsExpr_set(Vec_pPsExpr *self, int32_t i, PsExpr *item);

PsExpr *Vec_pPsExpr_last(const Vec_pPsExpr *self);

int Vec_pPsExpr_is_empty(const Vec_pPsExpr *self);

void Vec_pPsExpr_insert_gap(Vec_pPsExpr *self, int32_t i, int32_t n);

void Vec_pPsExpr_insert_at(Vec_pPsExpr *self, int32_t i, PsExpr *item);

void Vec_pPsExpr_remove_range(Vec_pPsExpr *self, int32_t i, int32_t n);

void Vec_pPsExpr_remove_at(Vec_pPsExpr *self, int32_t i);

void Vec_pPsExpr_swap_remove(Vec_pPsExpr *self, int32_t i);

void Vec_pPsExpr_clear(Vec_pPsExpr *self);

void Vec_pPsExpr_deinit(Vec_pPsExpr *self);


void Vec_pPsExpr_init(Vec_pPsExpr *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pPsExpr_reserve(Vec_pPsExpr *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(PsExpr *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pPsExpr_push(Vec_pPsExpr *self, PsExpr *item) {
    Vec_pPsExpr_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

PsExpr *Vec_pPsExpr_pop(Vec_pPsExpr *self) {
    self->len -= 1;
    return self->data[self->len];
}

PsExpr *Vec_pPsExpr_get(const Vec_pPsExpr *self, int32_t i) {
    return self->data[i];
}

void Vec_pPsExpr_set(Vec_pPsExpr *self, int32_t i, PsExpr *item) {
    self->data[i] = item;
}

PsExpr *Vec_pPsExpr_last(const Vec_pPsExpr *self) {
    return self->data[self->len - 1];
}

int Vec_pPsExpr_is_empty(const Vec_pPsExpr *self) {
    return self->len == 0;
}

void Vec_pPsExpr_insert_gap(Vec_pPsExpr *self, int32_t i, int32_t n) {
    Vec_pPsExpr_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(PsExpr *) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_pPsExpr_insert_at(Vec_pPsExpr *self, int32_t i, PsExpr *item) {
    Vec_pPsExpr_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_pPsExpr_remove_range(Vec_pPsExpr *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(PsExpr *) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_pPsExpr_remove_at(Vec_pPsExpr *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(PsExpr *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pPsExpr_swap_remove(Vec_pPsExpr *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pPsExpr_clear(Vec_pPsExpr *self) {
    self->len = 0;
}

void Vec_pPsExpr_deinit(Vec_pPsExpr *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

struct Vec_pPsStmt {
    PsStmt **data;
    int32_t len;
    int32_t cap;
};

void Vec_pPsStmt_init(Vec_pPsStmt *self);

void Vec_pPsStmt_reserve(Vec_pPsStmt *self, int32_t n);

void Vec_pPsStmt_push(Vec_pPsStmt *self, PsStmt *item);

PsStmt *Vec_pPsStmt_pop(Vec_pPsStmt *self);

PsStmt *Vec_pPsStmt_get(const Vec_pPsStmt *self, int32_t i);

void Vec_pPsStmt_set(Vec_pPsStmt *self, int32_t i, PsStmt *item);

PsStmt *Vec_pPsStmt_last(const Vec_pPsStmt *self);

int Vec_pPsStmt_is_empty(const Vec_pPsStmt *self);

void Vec_pPsStmt_insert_gap(Vec_pPsStmt *self, int32_t i, int32_t n);

void Vec_pPsStmt_insert_at(Vec_pPsStmt *self, int32_t i, PsStmt *item);

void Vec_pPsStmt_remove_range(Vec_pPsStmt *self, int32_t i, int32_t n);

void Vec_pPsStmt_remove_at(Vec_pPsStmt *self, int32_t i);

void Vec_pPsStmt_swap_remove(Vec_pPsStmt *self, int32_t i);

void Vec_pPsStmt_clear(Vec_pPsStmt *self);

void Vec_pPsStmt_deinit(Vec_pPsStmt *self);


void Vec_pPsStmt_init(Vec_pPsStmt *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pPsStmt_reserve(Vec_pPsStmt *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(PsStmt *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pPsStmt_push(Vec_pPsStmt *self, PsStmt *item) {
    Vec_pPsStmt_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

PsStmt *Vec_pPsStmt_pop(Vec_pPsStmt *self) {
    self->len -= 1;
    return self->data[self->len];
}

PsStmt *Vec_pPsStmt_get(const Vec_pPsStmt *self, int32_t i) {
    return self->data[i];
}

void Vec_pPsStmt_set(Vec_pPsStmt *self, int32_t i, PsStmt *item) {
    self->data[i] = item;
}

PsStmt *Vec_pPsStmt_last(const Vec_pPsStmt *self) {
    return self->data[self->len - 1];
}

int Vec_pPsStmt_is_empty(const Vec_pPsStmt *self) {
    return self->len == 0;
}

void Vec_pPsStmt_insert_gap(Vec_pPsStmt *self, int32_t i, int32_t n) {
    Vec_pPsStmt_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(PsStmt *) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_pPsStmt_insert_at(Vec_pPsStmt *self, int32_t i, PsStmt *item) {
    Vec_pPsStmt_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_pPsStmt_remove_range(Vec_pPsStmt *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(PsStmt *) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_pPsStmt_remove_at(Vec_pPsStmt *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(PsStmt *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pPsStmt_swap_remove(Vec_pPsStmt *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pPsStmt_clear(Vec_pPsStmt *self) {
    self->len = 0;
}

void Vec_pPsStmt_deinit(Vec_pPsStmt *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

struct Vec_pPsDecl {
    PsDecl **data;
    int32_t len;
    int32_t cap;
};

void Vec_pPsDecl_init(Vec_pPsDecl *self);

void Vec_pPsDecl_reserve(Vec_pPsDecl *self, int32_t n);

void Vec_pPsDecl_push(Vec_pPsDecl *self, PsDecl *item);

PsDecl *Vec_pPsDecl_pop(Vec_pPsDecl *self);

PsDecl *Vec_pPsDecl_get(const Vec_pPsDecl *self, int32_t i);

void Vec_pPsDecl_set(Vec_pPsDecl *self, int32_t i, PsDecl *item);

PsDecl *Vec_pPsDecl_last(const Vec_pPsDecl *self);

int Vec_pPsDecl_is_empty(const Vec_pPsDecl *self);

void Vec_pPsDecl_insert_gap(Vec_pPsDecl *self, int32_t i, int32_t n);

void Vec_pPsDecl_insert_at(Vec_pPsDecl *self, int32_t i, PsDecl *item);

void Vec_pPsDecl_remove_range(Vec_pPsDecl *self, int32_t i, int32_t n);

void Vec_pPsDecl_remove_at(Vec_pPsDecl *self, int32_t i);

void Vec_pPsDecl_swap_remove(Vec_pPsDecl *self, int32_t i);

void Vec_pPsDecl_clear(Vec_pPsDecl *self);

void Vec_pPsDecl_deinit(Vec_pPsDecl *self);


void Vec_pPsDecl_init(Vec_pPsDecl *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pPsDecl_reserve(Vec_pPsDecl *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(PsDecl *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pPsDecl_push(Vec_pPsDecl *self, PsDecl *item) {
    Vec_pPsDecl_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

PsDecl *Vec_pPsDecl_pop(Vec_pPsDecl *self) {
    self->len -= 1;
    return self->data[self->len];
}

PsDecl *Vec_pPsDecl_get(const Vec_pPsDecl *self, int32_t i) {
    return self->data[i];
}

void Vec_pPsDecl_set(Vec_pPsDecl *self, int32_t i, PsDecl *item) {
    self->data[i] = item;
}

PsDecl *Vec_pPsDecl_last(const Vec_pPsDecl *self) {
    return self->data[self->len - 1];
}

int Vec_pPsDecl_is_empty(const Vec_pPsDecl *self) {
    return self->len == 0;
}

void Vec_pPsDecl_insert_gap(Vec_pPsDecl *self, int32_t i, int32_t n) {
    Vec_pPsDecl_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(PsDecl *) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_pPsDecl_insert_at(Vec_pPsDecl *self, int32_t i, PsDecl *item) {
    Vec_pPsDecl_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_pPsDecl_remove_range(Vec_pPsDecl *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(PsDecl *) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_pPsDecl_remove_at(Vec_pPsDecl *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(PsDecl *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pPsDecl_swap_remove(Vec_pPsDecl *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pPsDecl_clear(Vec_pPsDecl *self) {
    self->len = 0;
}

void Vec_pPsDecl_deinit(Vec_pPsDecl *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

struct Vec_pPsType {
    PsType **data;
    int32_t len;
    int32_t cap;
};

void Vec_pPsType_init(Vec_pPsType *self);

void Vec_pPsType_reserve(Vec_pPsType *self, int32_t n);

void Vec_pPsType_push(Vec_pPsType *self, PsType *item);

PsType *Vec_pPsType_pop(Vec_pPsType *self);

PsType *Vec_pPsType_get(const Vec_pPsType *self, int32_t i);

void Vec_pPsType_set(Vec_pPsType *self, int32_t i, PsType *item);

PsType *Vec_pPsType_last(const Vec_pPsType *self);

int Vec_pPsType_is_empty(const Vec_pPsType *self);

void Vec_pPsType_insert_gap(Vec_pPsType *self, int32_t i, int32_t n);

void Vec_pPsType_insert_at(Vec_pPsType *self, int32_t i, PsType *item);

void Vec_pPsType_remove_range(Vec_pPsType *self, int32_t i, int32_t n);

void Vec_pPsType_remove_at(Vec_pPsType *self, int32_t i);

void Vec_pPsType_swap_remove(Vec_pPsType *self, int32_t i);

void Vec_pPsType_clear(Vec_pPsType *self);

void Vec_pPsType_deinit(Vec_pPsType *self);


void Vec_pPsType_init(Vec_pPsType *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pPsType_reserve(Vec_pPsType *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(PsType *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pPsType_push(Vec_pPsType *self, PsType *item) {
    Vec_pPsType_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

PsType *Vec_pPsType_pop(Vec_pPsType *self) {
    self->len -= 1;
    return self->data[self->len];
}

PsType *Vec_pPsType_get(const Vec_pPsType *self, int32_t i) {
    return self->data[i];
}

void Vec_pPsType_set(Vec_pPsType *self, int32_t i, PsType *item) {
    self->data[i] = item;
}

PsType *Vec_pPsType_last(const Vec_pPsType *self) {
    return self->data[self->len - 1];
}

int Vec_pPsType_is_empty(const Vec_pPsType *self) {
    return self->len == 0;
}

void Vec_pPsType_insert_gap(Vec_pPsType *self, int32_t i, int32_t n) {
    Vec_pPsType_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(PsType *) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_pPsType_insert_at(Vec_pPsType *self, int32_t i, PsType *item) {
    Vec_pPsType_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_pPsType_remove_range(Vec_pPsType *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(PsType *) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_pPsType_remove_at(Vec_pPsType *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(PsType *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pPsType_swap_remove(Vec_pPsType *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pPsType_clear(Vec_pPsType *self) {
    self->len = 0;
}

void Vec_pPsType_deinit(Vec_pPsType *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

struct Vec_pPsFunc {
    PsFunc **data;
    int32_t len;
    int32_t cap;
};

void Vec_pPsFunc_init(Vec_pPsFunc *self);

void Vec_pPsFunc_reserve(Vec_pPsFunc *self, int32_t n);

void Vec_pPsFunc_push(Vec_pPsFunc *self, PsFunc *item);

PsFunc *Vec_pPsFunc_pop(Vec_pPsFunc *self);

PsFunc *Vec_pPsFunc_get(const Vec_pPsFunc *self, int32_t i);

void Vec_pPsFunc_set(Vec_pPsFunc *self, int32_t i, PsFunc *item);

PsFunc *Vec_pPsFunc_last(const Vec_pPsFunc *self);

int Vec_pPsFunc_is_empty(const Vec_pPsFunc *self);

void Vec_pPsFunc_insert_gap(Vec_pPsFunc *self, int32_t i, int32_t n);

void Vec_pPsFunc_insert_at(Vec_pPsFunc *self, int32_t i, PsFunc *item);

void Vec_pPsFunc_remove_range(Vec_pPsFunc *self, int32_t i, int32_t n);

void Vec_pPsFunc_remove_at(Vec_pPsFunc *self, int32_t i);

void Vec_pPsFunc_swap_remove(Vec_pPsFunc *self, int32_t i);

void Vec_pPsFunc_clear(Vec_pPsFunc *self);

void Vec_pPsFunc_deinit(Vec_pPsFunc *self);


void Vec_pPsFunc_init(Vec_pPsFunc *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pPsFunc_reserve(Vec_pPsFunc *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(PsFunc *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pPsFunc_push(Vec_pPsFunc *self, PsFunc *item) {
    Vec_pPsFunc_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

PsFunc *Vec_pPsFunc_pop(Vec_pPsFunc *self) {
    self->len -= 1;
    return self->data[self->len];
}

PsFunc *Vec_pPsFunc_get(const Vec_pPsFunc *self, int32_t i) {
    return self->data[i];
}

void Vec_pPsFunc_set(Vec_pPsFunc *self, int32_t i, PsFunc *item) {
    self->data[i] = item;
}

PsFunc *Vec_pPsFunc_last(const Vec_pPsFunc *self) {
    return self->data[self->len - 1];
}

int Vec_pPsFunc_is_empty(const Vec_pPsFunc *self) {
    return self->len == 0;
}

void Vec_pPsFunc_insert_gap(Vec_pPsFunc *self, int32_t i, int32_t n) {
    Vec_pPsFunc_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(PsFunc *) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_pPsFunc_insert_at(Vec_pPsFunc *self, int32_t i, PsFunc *item) {
    Vec_pPsFunc_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_pPsFunc_remove_range(Vec_pPsFunc *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(PsFunc *) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_pPsFunc_remove_at(Vec_pPsFunc *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(PsFunc *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pPsFunc_swap_remove(Vec_pPsFunc *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pPsFunc_clear(Vec_pPsFunc *self) {
    self->len = 0;
}

void Vec_pPsFunc_deinit(Vec_pPsFunc *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

struct Vec_pPsCase {
    PsCase **data;
    int32_t len;
    int32_t cap;
};

void Vec_pPsCase_init(Vec_pPsCase *self);

void Vec_pPsCase_reserve(Vec_pPsCase *self, int32_t n);

void Vec_pPsCase_push(Vec_pPsCase *self, PsCase *item);

PsCase *Vec_pPsCase_pop(Vec_pPsCase *self);

PsCase *Vec_pPsCase_get(const Vec_pPsCase *self, int32_t i);

void Vec_pPsCase_set(Vec_pPsCase *self, int32_t i, PsCase *item);

PsCase *Vec_pPsCase_last(const Vec_pPsCase *self);

int Vec_pPsCase_is_empty(const Vec_pPsCase *self);

void Vec_pPsCase_insert_gap(Vec_pPsCase *self, int32_t i, int32_t n);

void Vec_pPsCase_insert_at(Vec_pPsCase *self, int32_t i, PsCase *item);

void Vec_pPsCase_remove_range(Vec_pPsCase *self, int32_t i, int32_t n);

void Vec_pPsCase_remove_at(Vec_pPsCase *self, int32_t i);

void Vec_pPsCase_swap_remove(Vec_pPsCase *self, int32_t i);

void Vec_pPsCase_clear(Vec_pPsCase *self);

void Vec_pPsCase_deinit(Vec_pPsCase *self);


void Vec_pPsCase_init(Vec_pPsCase *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pPsCase_reserve(Vec_pPsCase *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(PsCase *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pPsCase_push(Vec_pPsCase *self, PsCase *item) {
    Vec_pPsCase_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

PsCase *Vec_pPsCase_pop(Vec_pPsCase *self) {
    self->len -= 1;
    return self->data[self->len];
}

PsCase *Vec_pPsCase_get(const Vec_pPsCase *self, int32_t i) {
    return self->data[i];
}

void Vec_pPsCase_set(Vec_pPsCase *self, int32_t i, PsCase *item) {
    self->data[i] = item;
}

PsCase *Vec_pPsCase_last(const Vec_pPsCase *self) {
    return self->data[self->len - 1];
}

int Vec_pPsCase_is_empty(const Vec_pPsCase *self) {
    return self->len == 0;
}

void Vec_pPsCase_insert_gap(Vec_pPsCase *self, int32_t i, int32_t n) {
    Vec_pPsCase_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(PsCase *) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_pPsCase_insert_at(Vec_pPsCase *self, int32_t i, PsCase *item) {
    Vec_pPsCase_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_pPsCase_remove_range(Vec_pPsCase *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(PsCase *) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_pPsCase_remove_at(Vec_pPsCase *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(PsCase *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pPsCase_swap_remove(Vec_pPsCase *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pPsCase_clear(Vec_pPsCase *self) {
    self->len = 0;
}

void Vec_pPsCase_deinit(Vec_pPsCase *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

struct Vec_pPsBlock {
    PsBlock **data;
    int32_t len;
    int32_t cap;
};

void Vec_pPsBlock_init(Vec_pPsBlock *self);

void Vec_pPsBlock_reserve(Vec_pPsBlock *self, int32_t n);

void Vec_pPsBlock_push(Vec_pPsBlock *self, PsBlock *item);

PsBlock *Vec_pPsBlock_pop(Vec_pPsBlock *self);

PsBlock *Vec_pPsBlock_get(const Vec_pPsBlock *self, int32_t i);

void Vec_pPsBlock_set(Vec_pPsBlock *self, int32_t i, PsBlock *item);

PsBlock *Vec_pPsBlock_last(const Vec_pPsBlock *self);

int Vec_pPsBlock_is_empty(const Vec_pPsBlock *self);

void Vec_pPsBlock_insert_gap(Vec_pPsBlock *self, int32_t i, int32_t n);

void Vec_pPsBlock_insert_at(Vec_pPsBlock *self, int32_t i, PsBlock *item);

void Vec_pPsBlock_remove_range(Vec_pPsBlock *self, int32_t i, int32_t n);

void Vec_pPsBlock_remove_at(Vec_pPsBlock *self, int32_t i);

void Vec_pPsBlock_swap_remove(Vec_pPsBlock *self, int32_t i);

void Vec_pPsBlock_clear(Vec_pPsBlock *self);

void Vec_pPsBlock_deinit(Vec_pPsBlock *self);


void Vec_pPsBlock_init(Vec_pPsBlock *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pPsBlock_reserve(Vec_pPsBlock *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(PsBlock *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pPsBlock_push(Vec_pPsBlock *self, PsBlock *item) {
    Vec_pPsBlock_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

PsBlock *Vec_pPsBlock_pop(Vec_pPsBlock *self) {
    self->len -= 1;
    return self->data[self->len];
}

PsBlock *Vec_pPsBlock_get(const Vec_pPsBlock *self, int32_t i) {
    return self->data[i];
}

void Vec_pPsBlock_set(Vec_pPsBlock *self, int32_t i, PsBlock *item) {
    self->data[i] = item;
}

PsBlock *Vec_pPsBlock_last(const Vec_pPsBlock *self) {
    return self->data[self->len - 1];
}

int Vec_pPsBlock_is_empty(const Vec_pPsBlock *self) {
    return self->len == 0;
}

void Vec_pPsBlock_insert_gap(Vec_pPsBlock *self, int32_t i, int32_t n) {
    Vec_pPsBlock_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(PsBlock *) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_pPsBlock_insert_at(Vec_pPsBlock *self, int32_t i, PsBlock *item) {
    Vec_pPsBlock_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_pPsBlock_remove_range(Vec_pPsBlock *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(PsBlock *) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_pPsBlock_remove_at(Vec_pPsBlock *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(PsBlock *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pPsBlock_swap_remove(Vec_pPsBlock *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pPsBlock_clear(Vec_pPsBlock *self) {
    self->len = 0;
}

void Vec_pPsBlock_deinit(Vec_pPsBlock *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

struct Vec_PsParam {
    PsParam *data;
    int32_t len;
    int32_t cap;
};

void Vec_PsParam_init(Vec_PsParam *self);

void Vec_PsParam_reserve(Vec_PsParam *self, int32_t n);

void Vec_PsParam_push(Vec_PsParam *self, PsParam item);

PsParam Vec_PsParam_pop(Vec_PsParam *self);

PsParam Vec_PsParam_get(const Vec_PsParam *self, int32_t i);

void Vec_PsParam_set(Vec_PsParam *self, int32_t i, PsParam item);

PsParam Vec_PsParam_last(const Vec_PsParam *self);

int Vec_PsParam_is_empty(const Vec_PsParam *self);

void Vec_PsParam_insert_gap(Vec_PsParam *self, int32_t i, int32_t n);

void Vec_PsParam_insert_at(Vec_PsParam *self, int32_t i, PsParam item);

void Vec_PsParam_remove_range(Vec_PsParam *self, int32_t i, int32_t n);

void Vec_PsParam_remove_at(Vec_PsParam *self, int32_t i);

void Vec_PsParam_swap_remove(Vec_PsParam *self, int32_t i);

void Vec_PsParam_clear(Vec_PsParam *self);

void Vec_PsParam_deinit(Vec_PsParam *self);

struct Vec_PsTParam {
    PsTParam *data;
    int32_t len;
    int32_t cap;
};

void Vec_PsTParam_init(Vec_PsTParam *self);

void Vec_PsTParam_reserve(Vec_PsTParam *self, int32_t n);

void Vec_PsTParam_push(Vec_PsTParam *self, PsTParam item);

PsTParam Vec_PsTParam_pop(Vec_PsTParam *self);

PsTParam Vec_PsTParam_get(const Vec_PsTParam *self, int32_t i);

void Vec_PsTParam_set(Vec_PsTParam *self, int32_t i, PsTParam item);

PsTParam Vec_PsTParam_last(const Vec_PsTParam *self);

int Vec_PsTParam_is_empty(const Vec_PsTParam *self);

void Vec_PsTParam_insert_gap(Vec_PsTParam *self, int32_t i, int32_t n);

void Vec_PsTParam_insert_at(Vec_PsTParam *self, int32_t i, PsTParam item);

void Vec_PsTParam_remove_range(Vec_PsTParam *self, int32_t i, int32_t n);

void Vec_PsTParam_remove_at(Vec_PsTParam *self, int32_t i);

void Vec_PsTParam_swap_remove(Vec_PsTParam *self, int32_t i);

void Vec_PsTParam_clear(Vec_PsTParam *self);

void Vec_PsTParam_deinit(Vec_PsTParam *self);


void Vec_PsTParam_init(Vec_PsTParam *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_PsTParam_reserve(Vec_PsTParam *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(PsTParam) * (size_t)nc);
    self->cap = nc;
}

void Vec_PsTParam_push(Vec_PsTParam *self, PsTParam item) {
    Vec_PsTParam_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

PsTParam Vec_PsTParam_pop(Vec_PsTParam *self) {
    self->len -= 1;
    return self->data[self->len];
}

PsTParam Vec_PsTParam_get(const Vec_PsTParam *self, int32_t i) {
    return self->data[i];
}

void Vec_PsTParam_set(Vec_PsTParam *self, int32_t i, PsTParam item) {
    self->data[i] = item;
}

PsTParam Vec_PsTParam_last(const Vec_PsTParam *self) {
    return self->data[self->len - 1];
}

int Vec_PsTParam_is_empty(const Vec_PsTParam *self) {
    return self->len == 0;
}

void Vec_PsTParam_insert_gap(Vec_PsTParam *self, int32_t i, int32_t n) {
    Vec_PsTParam_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(PsTParam) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_PsTParam_insert_at(Vec_PsTParam *self, int32_t i, PsTParam item) {
    Vec_PsTParam_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_PsTParam_remove_range(Vec_PsTParam *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(PsTParam) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_PsTParam_remove_at(Vec_PsTParam *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(PsTParam) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_PsTParam_swap_remove(Vec_PsTParam *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_PsTParam_clear(Vec_PsTParam *self) {
    self->len = 0;
}

void Vec_PsTParam_deinit(Vec_PsTParam *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_PsParam_init(Vec_PsParam *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_PsParam_reserve(Vec_PsParam *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(PsParam) * (size_t)nc);
    self->cap = nc;
}

void Vec_PsParam_push(Vec_PsParam *self, PsParam item) {
    Vec_PsParam_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

PsParam Vec_PsParam_pop(Vec_PsParam *self) {
    self->len -= 1;
    return self->data[self->len];
}

PsParam Vec_PsParam_get(const Vec_PsParam *self, int32_t i) {
    return self->data[i];
}

void Vec_PsParam_set(Vec_PsParam *self, int32_t i, PsParam item) {
    self->data[i] = item;
}

PsParam Vec_PsParam_last(const Vec_PsParam *self) {
    return self->data[self->len - 1];
}

int Vec_PsParam_is_empty(const Vec_PsParam *self) {
    return self->len == 0;
}

void Vec_PsParam_insert_gap(Vec_PsParam *self, int32_t i, int32_t n) {
    Vec_PsParam_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(PsParam) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_PsParam_insert_at(Vec_PsParam *self, int32_t i, PsParam item) {
    Vec_PsParam_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_PsParam_remove_range(Vec_PsParam *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(PsParam) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_PsParam_remove_at(Vec_PsParam *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(PsParam) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_PsParam_swap_remove(Vec_PsParam *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_PsParam_clear(Vec_PsParam *self) {
    self->len = 0;
}

void Vec_PsParam_deinit(Vec_PsParam *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

struct Vec_PsField {
    PsField *data;
    int32_t len;
    int32_t cap;
};

void Vec_PsField_init(Vec_PsField *self);

void Vec_PsField_reserve(Vec_PsField *self, int32_t n);

void Vec_PsField_push(Vec_PsField *self, PsField item);

PsField Vec_PsField_pop(Vec_PsField *self);

PsField Vec_PsField_get(const Vec_PsField *self, int32_t i);

void Vec_PsField_set(Vec_PsField *self, int32_t i, PsField item);

PsField Vec_PsField_last(const Vec_PsField *self);

int Vec_PsField_is_empty(const Vec_PsField *self);

void Vec_PsField_insert_gap(Vec_PsField *self, int32_t i, int32_t n);

void Vec_PsField_insert_at(Vec_PsField *self, int32_t i, PsField item);

void Vec_PsField_remove_range(Vec_PsField *self, int32_t i, int32_t n);

void Vec_PsField_remove_at(Vec_PsField *self, int32_t i);

void Vec_PsField_swap_remove(Vec_PsField *self, int32_t i);

void Vec_PsField_clear(Vec_PsField *self);

void Vec_PsField_deinit(Vec_PsField *self);


void Vec_PsField_init(Vec_PsField *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_PsField_reserve(Vec_PsField *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(PsField) * (size_t)nc);
    self->cap = nc;
}

void Vec_PsField_push(Vec_PsField *self, PsField item) {
    Vec_PsField_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

PsField Vec_PsField_pop(Vec_PsField *self) {
    self->len -= 1;
    return self->data[self->len];
}

PsField Vec_PsField_get(const Vec_PsField *self, int32_t i) {
    return self->data[i];
}

void Vec_PsField_set(Vec_PsField *self, int32_t i, PsField item) {
    self->data[i] = item;
}

PsField Vec_PsField_last(const Vec_PsField *self) {
    return self->data[self->len - 1];
}

int Vec_PsField_is_empty(const Vec_PsField *self) {
    return self->len == 0;
}

void Vec_PsField_insert_gap(Vec_PsField *self, int32_t i, int32_t n) {
    Vec_PsField_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(PsField) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_PsField_insert_at(Vec_PsField *self, int32_t i, PsField item) {
    Vec_PsField_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_PsField_remove_range(Vec_PsField *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(PsField) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_PsField_remove_at(Vec_PsField *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(PsField) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_PsField_swap_remove(Vec_PsField *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_PsField_clear(Vec_PsField *self) {
    self->len = 0;
}

void Vec_PsField_deinit(Vec_PsField *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

struct Vec_PsEnumItem {
    PsEnumItem *data;
    int32_t len;
    int32_t cap;
};

void Vec_PsEnumItem_init(Vec_PsEnumItem *self);

void Vec_PsEnumItem_reserve(Vec_PsEnumItem *self, int32_t n);

void Vec_PsEnumItem_push(Vec_PsEnumItem *self, PsEnumItem item);

PsEnumItem Vec_PsEnumItem_pop(Vec_PsEnumItem *self);

PsEnumItem Vec_PsEnumItem_get(const Vec_PsEnumItem *self, int32_t i);

void Vec_PsEnumItem_set(Vec_PsEnumItem *self, int32_t i, PsEnumItem item);

PsEnumItem Vec_PsEnumItem_last(const Vec_PsEnumItem *self);

int Vec_PsEnumItem_is_empty(const Vec_PsEnumItem *self);

void Vec_PsEnumItem_insert_gap(Vec_PsEnumItem *self, int32_t i, int32_t n);

void Vec_PsEnumItem_insert_at(Vec_PsEnumItem *self, int32_t i, PsEnumItem item);

void Vec_PsEnumItem_remove_range(Vec_PsEnumItem *self, int32_t i, int32_t n);

void Vec_PsEnumItem_remove_at(Vec_PsEnumItem *self, int32_t i);

void Vec_PsEnumItem_swap_remove(Vec_PsEnumItem *self, int32_t i);

void Vec_PsEnumItem_clear(Vec_PsEnumItem *self);

void Vec_PsEnumItem_deinit(Vec_PsEnumItem *self);

static void ps_const_if_top(PsP *p, Vec_pPsDecl *decls, Vec_pPsStmt *top, Arena *a);

static void ps_const_if_block(PsP *p, Vec_pPsDecl *decls, Vec_pPsStmt *top, Arena *a, int keep);


void Vec_PsEnumItem_init(Vec_PsEnumItem *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_PsEnumItem_reserve(Vec_PsEnumItem *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(PsEnumItem) * (size_t)nc);
    self->cap = nc;
}

void Vec_PsEnumItem_push(Vec_PsEnumItem *self, PsEnumItem item) {
    Vec_PsEnumItem_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

PsEnumItem Vec_PsEnumItem_pop(Vec_PsEnumItem *self) {
    self->len -= 1;
    return self->data[self->len];
}

PsEnumItem Vec_PsEnumItem_get(const Vec_PsEnumItem *self, int32_t i) {
    return self->data[i];
}

void Vec_PsEnumItem_set(Vec_PsEnumItem *self, int32_t i, PsEnumItem item) {
    self->data[i] = item;
}

PsEnumItem Vec_PsEnumItem_last(const Vec_PsEnumItem *self) {
    return self->data[self->len - 1];
}

int Vec_PsEnumItem_is_empty(const Vec_PsEnumItem *self) {
    return self->len == 0;
}

void Vec_PsEnumItem_insert_gap(Vec_PsEnumItem *self, int32_t i, int32_t n) {
    Vec_PsEnumItem_reserve(self, self->len + n);
    memmove(&self->data[i + n], &self->data[i], sizeof(PsEnumItem) * (size_t)(self->len - i));
    self->len += n;
}

void Vec_PsEnumItem_insert_at(Vec_PsEnumItem *self, int32_t i, PsEnumItem item) {
    Vec_PsEnumItem_insert_gap(self, i, 1);
    self->data[i] = item;
}

void Vec_PsEnumItem_remove_range(Vec_PsEnumItem *self, int32_t i, int32_t n) {
    memmove(&self->data[i], &self->data[i + n], sizeof(PsEnumItem) * (size_t)(self->len - i - n));
    self->len -= n;
}

void Vec_PsEnumItem_remove_at(Vec_PsEnumItem *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(PsEnumItem) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_PsEnumItem_swap_remove(Vec_PsEnumItem *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_PsEnumItem_clear(Vec_PsEnumItem *self) {
    self->len = 0;
}

void Vec_PsEnumItem_deinit(Vec_PsEnumItem *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

static int is_float_lexeme(const char *t);

static int is_ps_assign_op(TokKind k);

static int has_suffix_ps(const char *s, const char *suf);

static void ps_retag(PsExpr *e, Pos pos);

static PsExpr *ps_clone_expr(Arena *a, PsExpr *e, const char *file);

static const char *ps_module_name(Arena *a, const char *path);

struct PsP {
    Token *t;
    size_t n;
    size_t i;
    const char *file;
    Arena *a;
    int blocked;
    int sub;
    char **sk;
    PsExpr **sv;
    int *su;
    int32_t sn;
};

static Token *PsP_pk(PsP *self);

static Token *PsP_pk1(PsP *self);

static int PsP_at(PsP *self, TokKind k);

static Token *PsP_adv(PsP *self);

static int PsP_accept(PsP *self, TokKind k);

static Token *PsP_expect(PsP *self, TokKind k, const char *ctx);

static PsType *PsP_parse_type(PsP *self);

static void PsP_expect_gt(PsP *self, const char *what);

static PsExpr *PsP_parse_expr(PsP *self);

static PsExpr *PsP_parse_ternary(PsP *self);

static PsExpr *PsP_parse_as_chain(PsP *self, PsExpr *e);

static PsExpr *PsP_parse_or(PsP *self);

static PsExpr *PsP_parse_and(PsP *self);

static PsExpr *PsP_parse_not(PsP *self);

static PsExpr *PsP_parse_cmp(PsP *self);

static PsExpr *PsP_parse_coalesce(PsP *self);

static PsExpr *PsP_parse_bitor(PsP *self);

static PsExpr *PsP_parse_bitxor(PsP *self);

static PsExpr *PsP_parse_bitand(PsP *self);

static PsExpr *PsP_parse_shift(PsP *self);

static PsExpr *PsP_parse_add(PsP *self);

static PsExpr *PsP_parse_mul(PsP *self);

static PsExpr *PsP_parse_unary(PsP *self);

static PsExpr *PsP_parse_pow(PsP *self);

static PsExpr *PsP_parse_postfix(PsP *self);

static PsExpr *PsP_parse_primary(PsP *self);

static PsBlock *PsP_parse_block(PsP *self);

static void PsP_refuse_python(PsP *self);

static PsStmt *PsP_parse_stmt(PsP *self);

static PsStmt *PsP_parse_simple_stmt(PsP *self);

static PsStmt *PsP_parse_if(PsP *self);

static int PsP_const_cond(PsP *self, PsExpr *e);

static PsStmt *PsP_parse_for(PsP *self);

static PsStmt *PsP_parse_match(PsP *self);

static PsStmt *PsP_parse_try(PsP *self);

static PsFunc *PsP_parse_func(PsP *self, int no_recv, int is_async, const char *owner);

static PsFunc *PsP_parse_func_head(PsP *self, int no_recv, int is_async, const char *owner);

static PsDecl *PsP_parse_trait(PsP *self);

static PsDecl *PsP_parse_impl(PsP *self);

static PsDecl *PsP_parse_aggregate(PsP *self, int is_record);

static void PsP_parse_decorators(PsP *self, Vec_pPsExpr *into);

static PsDecl *PsP_parse_enum(PsP *self);

static PsDecl *PsP_parse_import(PsP *self);

static PsDecl *PsP_parse_from(PsP *self);

static PsDecl *PsP_parse_include(PsP *self);

static PsExpr *PsP_parse_lambda(PsP *self);

static PsExpr *PsP_parse_list_or_comprehension(PsP *self);

static PsExpr *PsP_parse_dict_or_set(PsP *self);

static PsExpr *PsP_finish_comprehension(PsP *self, Pos pos, PsExpr *elem, TokKind close);

static const char *PsP_docstring(PsP *self);

static const char *PsP_member_name(PsP *self);

static PsExpr *PsP_fstring(PsP *self, const char *lex, Pos pos);

static PsExpr *PsP_fs_lit(PsP *self, const char *bytes, size_t n, Pos pos);

static PsExpr *PsP_fs_join(PsP *self, PsExpr *acc, PsExpr *one, Pos pos);

static PsExpr *PsP_fs_hole(PsP *self, const char *etext, const char *spec, Pos pos);

static PsExpr *PsP_fs_key(PsP *self, const char *etext, Pos pos);

static PsExpr *PsP_fs_num(PsP *self, int32_t v, Pos pos);

static Token *PsP_pk(PsP *self) {
    return &self->t[self->i];
}

static Token *PsP_pk1(PsP *self) {
    return (self->i + 1 < self->n ? &self->t[self->i + 1] : &self->t[self->n - 1]);
}

static int PsP_at(PsP *self, TokKind k) {
    return PsP_pk(self)->kind == k;
}

static Token *PsP_adv(PsP *self) {
    Token *t = &self->t[self->i];
    if (t->kind != TK_EOF) {
        self->i += 1;
    }
    return t;
}

static int PsP_accept(PsP *self, TokKind k) {
    if (PsP_at(self, k)) {
        PsP_adv(self);
        return 1;
    }
    return 0;
}

static Token *PsP_expect(PsP *self, TokKind k, const char *ctx) {
    if (!PsP_at(self, k)) {
        fatal_at(self->file, PsP_pk(self)->pos, "expected %s in %s, found %s", tok_kind_name(k), ctx, tok_kind_name(PsP_pk(self)->kind));
    }
    return PsP_adv(self);
}

static const char *PsP_member_name(PsP *self) {
    Token *t = PsP_pk(self);
    char c = (t->text != NULL ? t->text[0] : '\0');
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_') {
        PsP_adv(self);
        return t->text;
    }
    fatal_at(self->file, t->pos, "expected a field name after '.', found %s", tok_kind_name(t->kind));
    return NULL;
}

static const char *PsP_docstring(PsP *self) {
    if (PsP_at(self, TK_STRING) && PsP_pk1(self)->kind == TK_NEWLINE) {
        const char *d = PsP_adv(self)->text;
        PsP_adv(self);
        return d;
    }
    return NULL;
}

static void PsP_expect_gt(PsP *self, const char *what) {
    Token *t = PsP_pk(self);
    if (t->kind == TK_SHR) {
        t->kind = TK_GT;
        return;
    }
    PsP_expect(self, TK_GT, what);
}

static PsType *PsP_parse_type(PsP *self) {
    Pos pos = PsP_pk(self)->pos;
    PsType *t;
    if (PsP_at(self, TK_LPAREN)) {
        PsP_adv(self);
        Vec_pPsType ms;
        Vec_pPsType_init(&ms);
        do {
            Vec_pPsType_push(&ms, PsP_parse_type(self));
        } while (PsP_accept(self, TK_COMMA));
        PsP_expect(self, TK_RPAREN, "tuple type");
        if (ms.len == 1) {
            t = ms.data[0];
        } else {
            t = ps_type(self->a, PT_TUPLE, pos);
            t->params = ms.data;
            t->nparams = ms.len;
        }
    } else if (PsP_at(self, TK_DEF)) {
        PsP_adv(self);
        t = ps_type(self->a, PT_FUNC, pos);
        t->wide = 1;
        if (PsP_accept(self, TK_LPAREN)) {
            t->wide = 0;
            Vec_pPsType ps;
            Vec_pPsType_init(&ps);
            if (!PsP_at(self, TK_RPAREN)) {
                do {
                    Vec_pPsType_push(&ps, PsP_parse_type(self));
                } while (PsP_accept(self, TK_COMMA));
            }
            PsP_expect(self, TK_RPAREN, "def(...) type");
            t->params = ps.data;
            t->nparams = ps.len;
            if (PsP_accept(self, TK_ARROW)) {
                t->inner = PsP_parse_type(self);
            }
        }
    } else {
        Token *id = PsP_expect(self, TK_IDENT, "type name");
        const char *name = id->text;
        if (strcmp(name, "int") == 0 || strcmp(name, "i64") == 0) {
            t = ps_type(self->a, PT_INT, pos);
        } else if (strcmp(name, "float") == 0 || strcmp(name, "f64") == 0) {
            t = ps_type(self->a, PT_FLOAT, pos);
        } else if (ps_width_name(name) != 0) {
            int32_t w9 = ps_width_name(name);
            t = ps_type(self->a, (name[0] == 'f' ? PT_FLOAT : PT_INT), pos);
            t->width = w9;
            t->uns = name[0] == 'u';
        } else if (strcmp(name, "bool") == 0) {
            t = ps_type(self->a, PT_BOOL, pos);
        } else if (strcmp(name, "str") == 0) {
            t = ps_type(self->a, PT_STR, pos);
        } else if (strcmp(name, "any") == 0) {
            t = ps_type(self->a, PT_ANY, pos);
        } else if (strcmp(name, "file") == 0) {
            t = ps_type(self->a, PT_FILE, pos);
        } else if (strcmp(name, "buffer") == 0) {
            t = ps_type(self->a, PT_BUFFER, pos);
        } else if (strcmp(name, "socket") == 0) {
            t = ps_type(self->a, PT_CONN, pos);
        } else if (strcmp(name, "proc") == 0) {
            t = ps_type(self->a, PT_PROC, pos);
        } else if (strcmp(name, "list") == 0) {
            t = ps_type(self->a, PT_LIST, pos);
            PsP_expect(self, TK_LT, "list<T>");
            t->inner = PsP_parse_type(self);
            PsP_expect_gt(self, "list<T>");
        } else if (strcmp(name, "set") == 0) {
            t = ps_type(self->a, PT_SET, pos);
            PsP_expect(self, TK_LT, "set<T>");
            t->inner = PsP_parse_type(self);
            PsP_expect_gt(self, "set<T>");
        } else if (strcmp(name, "dict") == 0) {
            t = ps_type(self->a, PT_DICT, pos);
            PsP_expect(self, TK_LT, "dict<K, V>");
            t->key = PsP_parse_type(self);
            PsP_expect(self, TK_COMMA, "dict<K, V>");
            t->inner = PsP_parse_type(self);
            PsP_expect_gt(self, "dict<K, V>");
        } else if (strcmp(name, "Task") == 0 || strcmp(name, "Worker") == 0) {
            t = ps_type(self->a, (strcmp(name, "Task") == 0 ? PT_TASK : PT_WORKER), pos);
            PsP_expect(self, TK_LT, "Task<T>");
            t->inner = PsP_parse_type(self);
            PsP_expect_gt(self, "Task<T>");
        } else if (strcmp(name, "dyn") == 0 && PsP_at(self, TK_IDENT)) {
            t = ps_type(self->a, PT_DYN, pos);
            t->name = PsP_expect(self, TK_IDENT, "trait name after 'dyn'")->text;
            if (PsP_at(self, TK_DOT)) {
                PsP_adv(self);
                t->qual = t->name;
                t->name = PsP_expect(self, TK_IDENT, "trait name after '.'")->text;
            }
        } else {
            t = ps_type(self->a, PT_NAME, pos);
            t->name = name;
            if (PsP_at(self, TK_DOT)) {
                PsP_adv(self);
                t->qual = name;
                t->name = PsP_expect(self, TK_IDENT, "type name after '.'")->text;
            }
        }
    }
    while (1) {
        if (PsP_at(self, TK_LBRACKET)) {
            PsP_adv(self);
            PsType *at2 = ps_type(self->a, PT_ARRAY, pos);
            at2->inner = t;
            if (!PsP_at(self, TK_RBRACKET)) {
                at2->count = PsP_parse_expr(self);
            }
            PsP_expect(self, TK_RBRACKET, "T[N]");
            t = at2;
        } else if (PsP_at(self, TK_COALESCE)) {
            Pos qp2 = PsP_adv(self)->pos;
            PsType *o1 = ps_type(self->a, PT_OPT, qp2);
            o1->inner = t;
            PsType *o2 = ps_type(self->a, PT_OPT, qp2);
            o2->inner = o1;
            t = o2;
        } else if (PsP_at(self, TK_QUESTION) || PsP_at(self, TK_OPTINDEX)) {
            int arr = PsP_at(self, TK_OPTINDEX);
            Pos qp = PsP_adv(self)->pos;
            PsType *ot = ps_type(self->a, PT_OPT, qp);
            ot->inner = t;
            t = ot;
            if (arr) {
                PsType *at3 = ps_type(self->a, PT_ARRAY, qp);
                at3->inner = t;
                if (!PsP_at(self, TK_RBRACKET)) {
                    at3->count = PsP_parse_expr(self);
                }
                PsP_expect(self, TK_RBRACKET, "T\?[N]");
                t = at3;
            }
        } else {
            break;
        }
    }
    return t;
}

static PsExpr *PsP_parse_primary(PsP *self) {
    Token *tk = PsP_pk(self);
    Pos pos = tk->pos;
    switch (tk->kind) {
        case TK_NUMBER: {
            PsP_adv(self);
            PsExpr *e = ps_expr(self->a, (is_float_lexeme(tk->text) ? PE_FLOAT : PE_INT), pos);
            e->text = tk->text;
            return e;
        }
        case TK_STRING:
        case TK_CHARLIT: {
            PsP_adv(self);
            PsExpr *e2 = ps_expr(self->a, PE_STR, pos);
            e2->text = tk->text;
            return e2;
        }
        case TK_FSTRING: {
            PsP_adv(self);
            return PsP_fstring(self, tk->text, pos);
        }
        case TK_TRUE:
        case TK_FALSE: {
            PsP_adv(self);
            PsExpr *e4 = ps_expr(self->a, PE_BOOL, pos);
            e4->text = (tk->kind == TK_TRUE ? "True" : "False");
            return e4;
        }
        case TK_NONE: {
            PsP_adv(self);
            return ps_expr(self->a, PE_NONE, pos);
        }
        case TK_IDENT: {
            PsP_adv(self);
            if (strcmp(tk->text, "set") == 0 && PsP_at(self, TK_LT)) {
                PsP_adv(self);
                PsType *st9 = ps_type(self->a, PT_SET, pos);
                st9->inner = PsP_parse_type(self);
                PsP_expect_gt(self, "set<T>()");
                PsP_expect(self, TK_LPAREN, "set<T>()");
                PsP_expect(self, TK_RPAREN, "set<T>()");
                PsExpr *es9 = ps_expr(self->a, PE_SET, pos);
                es9->type = st9;
                return es9;
            }
            if (PsP_at(self, TK_WALRUS)) {
                PsP_adv(self);
                PsExpr *w = ps_expr(self->a, PE_WALRUS, pos);
                w->var = tk->text;
                w->lhs = PsP_parse_expr(self);
                return w;
            }
            PsExpr *e5 = ps_expr(self->a, PE_NAME, pos);
            e5->text = tk->text;
            return e5;
        }
        case TK_LPAREN: {
            PsP_adv(self);
            if (PsP_at(self, TK_RPAREN)) {
                PsP_adv(self);
                return ps_expr(self->a, PE_TUPLE, pos);
            }
            PsExpr *inner = PsP_parse_expr(self);
            if (PsP_at(self, TK_FOR)) {
                fatal_at(self->file, PsP_pk(self)->pos, "there is no generator expression, because there are no generators: write the comprehension in brackets, `[x for x in xs]`, which builds the list in one go");
            }
            if (PsP_at(self, TK_COMMA)) {
                Vec_pPsExpr items;
                Vec_pPsExpr_init(&items);
                Vec_pPsExpr_push(&items, inner);
                while (PsP_accept(self, TK_COMMA)) {
                    if (PsP_at(self, TK_RPAREN)) {
                        break;
                    }
                    Vec_pPsExpr_push(&items, PsP_parse_expr(self));
                }
                PsP_expect(self, TK_RPAREN, "tuple");
                PsExpr *tp = ps_expr(self->a, PE_TUPLE, pos);
                tp->args = items.data;
                tp->nargs = items.len;
                return tp;
            }
            PsP_expect(self, TK_RPAREN, "parenthesized expression");
            inner->parened = 1;
            return inner;
        }
        case TK_LBRACKET: {
            return PsP_parse_list_or_comprehension(self);
        }
        case TK_LBRACE: {
            return PsP_parse_dict_or_set(self);
        }
        case TK_LAMBDA: {
            return PsP_parse_lambda(self);
        }
        case TK_ASYNC: {
            if (PsP_pk1(self)->kind == TK_LAMBDA) {
                PsP_adv(self);
                PsExpr *al = PsP_parse_lambda(self);
                al->is_async_lam = 1;
                return al;
            }
            if (PsP_pk1(self)->kind != TK_COLON) {
                fatal_at(self->file, PsP_pk(self)->pos, "`async` here opens a block: write `async:` and indent what the task does (78.3)");
            }
            Pos ap = PsP_adv(self)->pos;
            PsExpr *ab = ps_expr(self->a, PE_ASYNCBLK, ap);
            ab->body = PsP_parse_block(self);
            self->blocked = 1;
            return ab;
        }
        case TK_AWAIT: {
            PsP_adv(self);
            PsExpr *aw = ps_expr(self->a, PE_AWAIT, pos);
            aw->lhs = PsP_parse_unary(self);
            return aw;
        }
        case TK_SPAWN: {
            PsP_adv(self);
            PsExpr *sp = ps_expr(self->a, PE_SPAWN, pos);
            sp->lhs = PsP_parse_unary(self);
            return sp;
        }
        default: {
            fatal_at(self->file, pos, "expected an expression, found %s", tok_kind_name(tk->kind));
            break;
        }
    }
    return NULL;
}

static PsExpr *PsP_parse_postfix(PsP *self) {
    PsExpr *e = PsP_parse_primary(self);
    while (1) {
        Pos pos = PsP_pk(self)->pos;
        if (e != NULL && e->kind == PE_NAME && e->text != NULL && strcmp(e->text, "unpack") == 0 && PsP_at(self, TK_LT)) {
            PsP_adv(self);
            PsType *ut = PsP_parse_type(self);
            PsP_expect_gt(self, "unpack<T>");
            PsP_expect(self, TK_LPAREN, "unpack<T>(bytes)");
            PsExpr *uc = ps_expr(self->a, PE_CALL, pos);
            uc->lhs = e;
            uc->type = ut;
            Vec_pPsExpr uargs;
            Vec_pPsExpr_init(&uargs);
            do {
                Vec_pPsExpr_push(&uargs, PsP_parse_expr(self));
            } while (PsP_accept(self, TK_COMMA));
            uc->args = uargs.data;
            uc->nargs = uargs.len;
            PsP_expect(self, TK_RPAREN, "unpack<T>(bytes)");
            e = uc;
            continue;
        }
        if (PsP_at(self, TK_LPAREN)) {
            PsP_adv(self);
            PsExpr *c = ps_expr(self->a, PE_CALL, pos);
            c->lhs = e;
            Vec_pPsExpr args;
            Vec_pPsExpr_init(&args);
            if (!PsP_at(self, TK_RPAREN)) {
                do {
                    if (PsP_at(self, TK_IDENT) && PsP_pk1(self)->kind == TK_ASSIGN) {
                        Token *nt = PsP_adv(self);
                        PsP_adv(self);
                        PsExpr *d = ps_expr(self->a, PE_DESIG, nt->pos);
                        d->text = nt->text;
                        d->lhs = PsP_parse_expr(self);
                        Vec_pPsExpr_push(&args, d);
                    } else if (PsP_at(self, TK_IN)) {
                        Pos ip = PsP_adv(self)->pos;
                        PsExpr *ia = PsP_parse_expr(self);
                        ia->is_in = 1;
                        ia->pos = ip;
                        Vec_pPsExpr_push(&args, ia);
                    } else if (PsP_at(self, TK_IDENT) && PsP_pk1(self)->kind == TK_IDENT && (strcmp(PsP_pk(self)->text, "out") == 0 || strcmp(PsP_pk(self)->text, "ref") == 0)) {
                        int wasout = strcmp(PsP_pk(self)->text, "out") == 0;
                        Pos op9 = PsP_adv(self)->pos;
                        PsExpr *oa = PsP_parse_expr(self);
                        oa->is_out = wasout;
                        oa->is_ref = !wasout;
                        oa->pos = op9;
                        Vec_pPsExpr_push(&args, oa);
                    } else if (PsP_at(self, TK_STAR)) {
                        Pos sp = PsP_adv(self)->pos;
                        PsExpr *sa = PsP_parse_expr(self);
                        sa->is_splat = 1;
                        sa->pos = sp;
                        Vec_pPsExpr_push(&args, sa);
                    } else {
                        Vec_pPsExpr_push(&args, PsP_parse_expr(self));
                    }
                } while (PsP_accept(self, TK_COMMA));
            }
            PsP_expect(self, TK_RPAREN, "call");
            c->args = args.data;
            c->nargs = args.len;
            e = c;
        } else if (PsP_at(self, TK_LBRACKET) || PsP_at(self, TK_OPTINDEX)) {
            int opt = PsP_at(self, TK_OPTINDEX);
            PsP_adv(self);
            PsExpr *start = NULL;
            if (!PsP_at(self, TK_COLON)) {
                start = PsP_parse_expr(self);
            }
            if (PsP_at(self, TK_COLON)) {
                PsExpr **parts = Arena_alloc(self->a, 3 * sizeof(*parts));
                parts[0] = start;
                int np = 1;
                while (PsP_accept(self, TK_COLON) && np < 3) {
                    if (!PsP_at(self, TK_COLON) && !PsP_at(self, TK_RBRACKET)) {
                        parts[np] = PsP_parse_expr(self);
                    }
                    np += 1;
                }
                PsP_expect(self, TK_RBRACKET, "slice");
                PsExpr *sl = ps_expr(self->a, PE_SLICE, pos);
                sl->lhs = e;
                sl->args = parts;
                sl->nargs = 3;
                if (opt) {
                    fatal_at(self->file, pos, "`\?[` does not slice: write `x\?[i]` for an optional index");
                }
                e = sl;
                continue;
            }
            PsExpr *ix = ps_expr(self->a, (opt ? PE_OPTINDEX : PE_INDEX), pos);
            ix->lhs = e;
            ix->rhs = start;
            PsP_expect(self, TK_RBRACKET, "index");
            e = ix;
        } else if (PsP_at(self, TK_DOT) || PsP_at(self, TK_OPTDOT)) {
            int opt2 = PsP_at(self, TK_OPTDOT);
            PsP_adv(self);
            PsExpr *f = ps_expr(self->a, (opt2 ? PE_OPTFIELD : PE_FIELD), pos);
            f->lhs = e;
            f->text = PsP_member_name(self);
            e = f;
        } else {
            break;
        }
    }
    return e;
}

static PsExpr *PsP_parse_pow(PsP *self) {
    PsExpr *base = PsP_parse_postfix(self);
    if (PsP_at(self, TK_POW)) {
        Pos pos = PsP_adv(self)->pos;
        PsExpr *e = ps_expr(self->a, PE_BINARY, pos);
        e->op = TK_POW;
        e->lhs = base;
        e->rhs = PsP_parse_unary(self);
        return e;
    }
    return base;
}

static PsExpr *PsP_parse_unary(PsP *self) {
    if (PsP_at(self, TK_MINUS) || PsP_at(self, TK_PLUS) || PsP_at(self, TK_TILDE)) {
        Token *tk = PsP_adv(self);
        PsExpr *e = ps_expr(self->a, PE_UNARY, tk->pos);
        e->op = tk->kind;
        e->lhs = PsP_parse_unary(self);
        return e;
    }
    return PsP_parse_pow(self);
}

static PsExpr *PsP_parse_mul(PsP *self) {
    PsExpr *e = PsP_parse_unary(self);
    while (PsP_at(self, TK_STAR) || PsP_at(self, TK_SLASH) || PsP_at(self, TK_FLOORDIV) || PsP_at(self, TK_PERCENT) || PsP_at(self, TK_WRAP_STAR)) {
        Token *tk = PsP_adv(self);
        PsExpr *b = ps_expr(self->a, PE_BINARY, tk->pos);
        b->op = tk->kind;
        b->lhs = e;
        b->rhs = PsP_parse_unary(self);
        e = b;
    }
    return e;
}

static PsExpr *PsP_parse_add(PsP *self) {
    PsExpr *e = PsP_parse_mul(self);
    while (PsP_at(self, TK_PLUS) || PsP_at(self, TK_MINUS) || PsP_at(self, TK_WRAP_PLUS) || PsP_at(self, TK_WRAP_MINUS)) {
        Token *tk = PsP_adv(self);
        PsExpr *b = ps_expr(self->a, PE_BINARY, tk->pos);
        b->op = tk->kind;
        b->lhs = e;
        b->rhs = PsP_parse_mul(self);
        e = b;
    }
    return e;
}

static PsExpr *PsP_parse_shift(PsP *self) {
    PsExpr *e = PsP_parse_add(self);
    while (PsP_at(self, TK_SHL) || PsP_at(self, TK_SHR)) {
        Token *tk = PsP_adv(self);
        PsExpr *b = ps_expr(self->a, PE_BINARY, tk->pos);
        b->op = tk->kind;
        b->lhs = e;
        b->rhs = PsP_parse_add(self);
        e = b;
    }
    return e;
}

static PsExpr *PsP_parse_bitand(PsP *self) {
    PsExpr *e = PsP_parse_shift(self);
    while (PsP_at(self, TK_AMP)) {
        Token *tk = PsP_adv(self);
        PsExpr *b = ps_expr(self->a, PE_BINARY, tk->pos);
        b->op = tk->kind;
        b->lhs = e;
        b->rhs = PsP_parse_shift(self);
        e = b;
    }
    return e;
}

static PsExpr *PsP_parse_bitxor(PsP *self) {
    PsExpr *e = PsP_parse_bitand(self);
    while (PsP_at(self, TK_CARET)) {
        Token *tk = PsP_adv(self);
        PsExpr *b = ps_expr(self->a, PE_BINARY, tk->pos);
        b->op = tk->kind;
        b->lhs = e;
        b->rhs = PsP_parse_bitand(self);
        e = b;
    }
    return e;
}

static PsExpr *PsP_parse_bitor(PsP *self) {
    PsExpr *e = PsP_parse_bitxor(self);
    while (PsP_at(self, TK_PIPE)) {
        Token *tk = PsP_adv(self);
        PsExpr *b = ps_expr(self->a, PE_BINARY, tk->pos);
        b->op = tk->kind;
        b->lhs = e;
        b->rhs = PsP_parse_bitxor(self);
        e = b;
    }
    return e;
}

static PsExpr *PsP_parse_coalesce(PsP *self) {
    PsExpr *e = PsP_parse_bitor(self);
    while (PsP_at(self, TK_COALESCE)) {
        Token *tk = PsP_adv(self);
        PsExpr *c = ps_expr(self->a, PE_COALESCE, tk->pos);
        c->lhs = e;
        c->rhs = PsP_parse_bitor(self);
        e = c;
    }
    return e;
}

static PsExpr *PsP_parse_cmp(PsP *self) {
    PsExpr *e = PsP_parse_coalesce(self);
    int32_t nchain = 0;
    while (1) {
        TokKind k = PsP_pk(self)->kind;
        if (nchain > 0 && (k == TK_EQ || k == TK_NE || k == TK_LT || k == TK_LE || k == TK_GT || k == TK_GE || k == TK_IN || k == TK_IS || (k == TK_NOT && PsP_pk1(self)->kind == TK_IN))) {
            fatal_at(self->file, PsP_pk(self)->pos, "a comparison does not chain here: Python reads `a < b < c` as `a < b and b < c`, and reading it left to right would compare a bool with a number — write the `and`");
        }
        if (k == TK_EQ || k == TK_NE || k == TK_LT || k == TK_LE || k == TK_GT || k == TK_GE) {
            nchain += 1;
            Token *tk = PsP_adv(self);
            PsExpr *b = ps_expr(self->a, PE_BINARY, tk->pos);
            b->op = tk->kind;
            b->lhs = e;
            b->rhs = PsP_parse_coalesce(self);
            e = b;
        } else if (k == TK_IN) {
            nchain += 1;
            Token *tk2 = PsP_adv(self);
            PsExpr *m = ps_expr(self->a, PE_IN, tk2->pos);
            m->lhs = e;
            m->rhs = PsP_parse_coalesce(self);
            e = m;
        } else if (k == TK_IS) {
            nchain += 1;
            Token *tk3 = PsP_adv(self);
            PsExpr *idn = ps_expr(self->a, PE_IS, tk3->pos);
            idn->op = (PsP_accept(self, TK_NOT) ? TK_NOT : TK_EOF);
            idn->lhs = e;
            idn->rhs = PsP_parse_coalesce(self);
            e = idn;
        } else if (k == TK_NOT && PsP_pk1(self)->kind == TK_IN) {
            nchain += 1;
            Token *tk4 = PsP_adv(self);
            PsP_adv(self);
            PsExpr *nm = ps_expr(self->a, PE_IN, tk4->pos);
            nm->op = TK_NOT;
            nm->lhs = e;
            nm->rhs = PsP_parse_coalesce(self);
            e = nm;
        } else {
            break;
        }
    }
    return e;
}

static PsExpr *PsP_parse_not(PsP *self) {
    if (PsP_at(self, TK_NOT)) {
        Token *tk = PsP_adv(self);
        PsExpr *e = ps_expr(self->a, PE_UNARY, tk->pos);
        e->op = TK_NOT;
        e->lhs = PsP_parse_not(self);
        return e;
    }
    return PsP_parse_cmp(self);
}

static PsExpr *PsP_parse_and(PsP *self) {
    PsExpr *e = PsP_parse_not(self);
    while (PsP_at(self, TK_AND)) {
        Token *tk = PsP_adv(self);
        PsExpr *b = ps_expr(self->a, PE_BINARY, tk->pos);
        b->op = TK_AND;
        b->lhs = e;
        b->rhs = PsP_parse_not(self);
        e = b;
    }
    return e;
}

static PsExpr *PsP_parse_or(PsP *self) {
    PsExpr *e = PsP_parse_and(self);
    while (PsP_at(self, TK_OR)) {
        Token *tk = PsP_adv(self);
        PsExpr *b = ps_expr(self->a, PE_BINARY, tk->pos);
        b->op = TK_OR;
        b->lhs = e;
        b->rhs = PsP_parse_and(self);
        e = b;
    }
    return e;
}

static PsExpr *PsP_parse_ternary(PsP *self) {
    PsExpr *e = PsP_parse_or(self);
    if (PsP_at(self, TK_IF)) {
        Pos pos = PsP_adv(self)->pos;
        PsExpr *t = ps_expr(self->a, PE_TERNARY, pos);
        t->lhs = e;
        t->cond = PsP_parse_or(self);
        PsP_expect(self, TK_ELSE, "conditional expression");
        t->rhs = PsP_parse_ternary(self);
        return t;
    }
    return e;
}

static PsExpr *PsP_parse_as_chain(PsP *self, PsExpr *e) {
    while (PsP_at(self, TK_AS)) {
        Pos pos = PsP_adv(self)->pos;
        PsExpr *c = ps_expr(self->a, PE_CAST, pos);
        c->lhs = e;
        c->type = PsP_parse_type(self);
        e = c;
    }
    return e;
}

static PsExpr *PsP_parse_expr(PsP *self) {
    return PsP_parse_as_chain(self, PsP_parse_ternary(self));
}

static PsExpr *PsP_parse_lambda(PsP *self) {
    Pos pos = PsP_expect(self, TK_LAMBDA, "lambda")->pos;
    PsExpr *e = ps_expr(self->a, PE_LAMBDA, pos);
    Vec_PsParam ps;
    Vec_PsParam_init(&ps);
    while (PsP_at(self, TK_IDENT)) {
        PsParam p = {0};
        p.pos = PsP_pk(self)->pos;
        p.name = PsP_adv(self)->text;
        Vec_PsParam_push(&ps, p);
        if (!PsP_accept(self, TK_COMMA)) {
            break;
        }
    }
    PsP_expect(self, TK_COLON, "lambda");
    e->params = ps.data;
    e->nparams = ps.len;
    e->lhs = PsP_parse_expr(self);
    return e;
}

static PsExpr *PsP_parse_list_or_comprehension(PsP *self) {
    Pos pos = PsP_expect(self, TK_LBRACKET, "list")->pos;
    if (PsP_accept(self, TK_RBRACKET)) {
        PsExpr *e0 = ps_expr(self->a, PE_LIST, pos);
        return e0;
    }
    PsExpr *first = PsP_parse_expr(self);
    if (PsP_at(self, TK_FOR)) {
        return PsP_finish_comprehension(self, pos, first, TK_RBRACKET);
    }
    Vec_pPsExpr items;
    Vec_pPsExpr_init(&items);
    Vec_pPsExpr_push(&items, first);
    while (PsP_accept(self, TK_COMMA)) {
        if (PsP_at(self, TK_RBRACKET)) {
            break;
        }
        Vec_pPsExpr_push(&items, PsP_parse_expr(self));
    }
    PsP_expect(self, TK_RBRACKET, "list");
    PsExpr *e = ps_expr(self->a, PE_LIST, pos);
    e->args = items.data;
    e->nargs = items.len;
    return e;
}

static PsExpr *PsP_finish_comprehension(PsP *self, Pos pos, PsExpr *elem, TokKind close) {
    PsP_expect(self, TK_FOR, "comprehension");
    PsExpr *e = ps_expr(self->a, PE_COMPREHEND, pos);
    e->op = close;
    e->lhs = elem;
    Vec_pchar cv;
    Vec_pchar_init(&cv);
    Vec_pchar_push(&cv, (char *)PsP_expect(self, TK_IDENT, "comprehension variable")->text);
    while (PsP_accept(self, TK_COMMA)) {
        Vec_pchar_push(&cv, (char *)PsP_expect(self, TK_IDENT, "comprehension variable")->text);
    }
    e->cvars = cv.data;
    e->ncvars = cv.len;
    e->var = cv.data[0];
    PsP_expect(self, TK_IN, "comprehension");
    e->rhs = PsP_parse_as_chain(self, PsP_parse_or(self));
    if (PsP_accept(self, TK_IF)) {
        e->cond = PsP_parse_or(self);
    }
    PsP_expect(self, close, "comprehension");
    return e;
}

static PsExpr *PsP_parse_dict_or_set(PsP *self) {
    Pos pos = PsP_expect(self, TK_LBRACE, "dict or set")->pos;
    if (PsP_accept(self, TK_RBRACE)) {
        return ps_expr(self->a, PE_DICT, pos);
    }
    PsExpr *first = PsP_parse_expr(self);
    if (PsP_accept(self, TK_COLON)) {
        PsExpr *val = PsP_parse_expr(self);
        PsExpr *pair = ps_expr(self->a, PE_DESIG, first->pos);
        pair->lhs = first;
        pair->rhs = val;
        if (PsP_at(self, TK_FOR)) {
            return PsP_finish_comprehension(self, pos, pair, TK_RBRACE);
        }
        Vec_pPsExpr items;
        Vec_pPsExpr_init(&items);
        Vec_pPsExpr_push(&items, pair);
        while (PsP_accept(self, TK_COMMA)) {
            if (PsP_at(self, TK_RBRACE)) {
                break;
            }
            PsExpr *k = PsP_parse_expr(self);
            PsP_expect(self, TK_COLON, "dict entry");
            PsExpr *v = PsP_parse_expr(self);
            PsExpr *pr = ps_expr(self->a, PE_DESIG, k->pos);
            pr->lhs = k;
            pr->rhs = v;
            Vec_pPsExpr_push(&items, pr);
        }
        PsP_expect(self, TK_RBRACE, "dict");
        PsExpr *d = ps_expr(self->a, PE_DICT, pos);
        d->args = items.data;
        d->nargs = items.len;
        return d;
    }
    if (PsP_at(self, TK_FOR)) {
        return PsP_finish_comprehension(self, pos, first, TK_RBRACE);
    }
    Vec_pPsExpr sitems;
    Vec_pPsExpr_init(&sitems);
    Vec_pPsExpr_push(&sitems, first);
    while (PsP_accept(self, TK_COMMA)) {
        if (PsP_at(self, TK_RBRACE)) {
            break;
        }
        Vec_pPsExpr_push(&sitems, PsP_parse_expr(self));
    }
    PsP_expect(self, TK_RBRACE, "set");
    PsExpr *st = ps_expr(self->a, PE_SET, pos);
    st->args = sitems.data;
    st->nargs = sitems.len;
    return st;
}

static PsExpr *PsP_fstring(PsP *self, const char *lex, Pos pos) {
    size_t n = 0;
    char *body = str_lit_decode(self->a, lex, &n);
    PsExpr *acc = NULL;
    StrBuf lit = {0};
    size_t i = 0;
    while (i < n) {
        char c = body[i];
        if (c == '{' && i + 1 < n && body[i + 1] == '{') {
            StrBuf_putc(&lit, '{');
            i += 2;
            continue;
        }
        if (c == '}' && i + 1 < n && body[i + 1] == '}') {
            StrBuf_putc(&lit, '}');
            i += 2;
            continue;
        }
        if (c != '{') {
            StrBuf_putc(&lit, c);
            i += 1;
            continue;
        }
        size_t j = i + 1;
        int32_t depth = 0;
        size_t colon = 0;
        while (j < n && (body[j] != '}' || depth > 0)) {
            if (body[j] == '[' || body[j] == '(') {
                depth += 1;
            } else if (body[j] == ']' || body[j] == ')') {
                depth -= 1;
            } else if (body[j] == ':' && depth == 0) {
                colon = j;
            } else if (body[j] == '{') {
                fatal_at(self->file, pos, "a nested brace in an f-string spec is not supported (45.1)");
            }
            j += 1;
        }
        if (j >= n) {
            fatal_at(self->file, pos, "unterminated '{' in an f-string");
        }
        if (lit.len > 0) {
            acc = PsP_fs_join(self, acc, PsP_fs_lit(self, lit.data, lit.len, pos), pos);
            lit.len = 0;
            lit.data[0] = '\0';
        }
        const char *etext = Arena_strndup(self->a, body + i + 1, (colon > 0 ? colon : j) - i - 1);
        const char *spec = (colon > 0 ? Arena_strndup(self->a, body + colon + 1, j - colon - 1) : "");
        acc = PsP_fs_join(self, acc, PsP_fs_hole(self, etext, spec, pos), pos);
        i = j + 1;
    }
    if (lit.len > 0) {
        acc = PsP_fs_join(self, acc, PsP_fs_lit(self, lit.data, lit.len, pos), pos);
    }
    StrBuf_deinit(&lit);
    if (acc == NULL) {
        acc = PsP_fs_lit(self, "", 0, pos);
    }
    return acc;
}

static PsExpr *PsP_fs_lit(PsP *self, const char *bytes, size_t n, Pos pos) {
    PsExpr *e = ps_expr(self->a, PE_STR, pos);
    e->text = c_string_literal(self->a, bytes, n);
    return e;
}

static PsExpr *PsP_fs_join(PsP *self, PsExpr *acc, PsExpr *one, Pos pos) {
    if (acc == NULL) {
        return one;
    }
    PsExpr *b = ps_expr(self->a, PE_BINARY, pos);
    b->op = TK_PLUS;
    b->lhs = acc;
    b->rhs = one;
    return b;
}

static PsExpr *PsP_fs_hole(PsP *self, const char *etext, const char *spec, Pos pos) {
    PsExpr *inner;
    if (self->sub) {
        inner = PsP_fs_key(self, etext, pos);
    } else {
        TokenList tl = ps_lex(self->file, etext, strlen(etext), self->a);
        PsP sub = {tl.toks, tl.n, 0, self->file, self->a};
        inner = PsP_parse_expr(&sub);
        ps_retag(inner, pos);
        if (!PsP_at(&sub, TK_NEWLINE) && !PsP_at(&sub, TK_EOF)) {
            fatal_at(self->file, pos, "trailing text in an f-string hole: '%s'", etext);
        }
    }
    char align = '\0';
    int zero = 0;
    int32_t width = 0;
    int32_t prec = -1;
    char ty = '\0';
    size_t k = 0;
    size_t m = strlen(spec);
    if (m > 0 && (spec[0] == '<' || spec[0] == '>' || spec[0] == '^')) {
        align = spec[0];
        k = 1;
    }
    if (k < m && spec[k] == '0') {
        zero = 1;
        k += 1;
    }
    while (k < m && spec[k] >= '0' && spec[k] <= '9') {
        width = width * 10 + (int32_t)(spec[k] - '0');
        k += 1;
    }
    if (k < m && spec[k] == '.') {
        k += 1;
        prec = 0;
        while (k < m && spec[k] >= '0' && spec[k] <= '9') {
            prec = prec * 10 + (int32_t)(spec[k] - '0');
            k += 1;
        }
    }
    if (k < m) {
        ty = spec[k];
        k += 1;
    }
    if (k < m) {
        fatal_at(self->file, pos, "unsupported format spec '%s' (45.1: align, zero, width, .precision and one of d/f/x/X/b/o/s)", spec);
    }
    PsExpr *c = ps_expr(self->a, PE_CALL, pos);
    c->lhs = ps_expr(self->a, PE_NAME, pos);
    c->lhs->text = "__fmt";
    c->args = Arena_alloc(self->a, 5 * sizeof(*c->args));
    c->args[0] = inner;
    c->args[1] = PsP_fs_num(self, width, pos);
    c->args[2] = PsP_fs_num(self, prec, pos);
    c->args[3] = PsP_fs_num(self, (int32_t)align, pos);
    c->args[4] = PsP_fs_num(self, (zero ? 1 : 0) * 256 + (int32_t)ty, pos);
    c->nargs = 5;
    return c;
}

static PsExpr *PsP_fs_key(PsP *self, const char *etext, Pos pos) {
    const char *s = etext;
    while (*s == ' ' || *s == '\t') {
        s += 1;
    }
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t')) {
        n -= 1;
    }
    if (n == 0) {
        fatal_at(self->file, pos, "an empty hole in a template: `{}` has no key to look up (75.2)");
    }
    size_t i;
    for (i = 0; i < self->sn; i += 1) {
        if (strlen(self->sk[i]) == n && strncmp(self->sk[i], s, n) == 0) {
            if (self->su[i]) {
                return ps_clone_expr(self->a, self->sv[i], self->file);
            }
            self->su[i] = 1;
            return self->sv[i];
        }
    }
    StrBuf have = {0};
    for (i = 0; i < self->sn; i += 1) {
        if (i > 0) {
            StrBuf_puts(&have, ", ");
        }
        StrBuf_puts(&have, self->sk[i]);
    }
    fatal_at(self->file, pos, "the template asks for '%.*s', which the dict does not have (it has: %s)", (int32_t)n, s, (have.len > 0 ? have.data : "nothing"));
    return NULL;
}

static PsExpr *PsP_fs_num(PsP *self, int32_t v, Pos pos) {
    PsExpr *e = ps_expr(self->a, PE_INT, pos);
    e->text = Arena_printf(self->a, "%d", v);
    return e;
}

static PsBlock *PsP_parse_block(PsP *self) {
    PsP_expect(self, TK_COLON, "block");
    PsP_expect(self, TK_NEWLINE, "block");
    PsP_expect(self, TK_INDENT, "block");
    Vec_pPsStmt stmts;
    Vec_pPsStmt_init(&stmts);
    while (!PsP_at(self, TK_DEDENT) && !PsP_at(self, TK_EOF)) {
        if (PsP_accept(self, TK_NEWLINE)) {
            continue;
        }
        Vec_pPsStmt_push(&stmts, PsP_parse_stmt(self));
    }
    PsP_expect(self, TK_DEDENT, "block");
    PsBlock *b = Arena_alloc(self->a, sizeof(PsBlock));
    b->stmts = stmts.data;
    b->n = stmts.len;
    return b;
}

static void PsP_refuse_python(PsP *self) {
    Token *tk = PsP_pk(self);
    if (tk->kind == TK_DEF) {
        fatal_at(self->file, tk->pos, "a function inside a function does not exist here (5.4): there is no capture, so it could not read this one's locals anyway — write it at the top level and pass what it needs, or use a `lambda` for a callback");
    }
    if (tk->kind != TK_IDENT) {
        return;
    }
    const char *n = tk->text;
    TokKind nx = PsP_pk1(self)->kind;
    if (strcmp(n, "class") == 0 && nx == TK_IDENT) {
        fatal_at(self->file, tk->pos, "there is no `class` (5.3): the fields come from `record` or `struct`, and behaviour is a function that takes the object — a `struct` may carry methods, and a `trait` says what a type implements");
    }
    if (strcmp(n, "yield") == 0 && nx != TK_ASSIGN && nx != TK_COLON) {
        fatal_at(self->file, tk->pos, "there is no `yield`, because there are no generators: a function returns once, and the thing that suspends and resumes is an `async def` with `await` (35.1)");
    }
    if (strcmp(n, "del") == 0 && nx != TK_ASSIGN && nx != TK_COLON) {
        fatal_at(self->file, tk->pos, "there is no `del`: a dict removes with `d.remove(k)`, a list with `xs.remove_at(i)`, and a variable lives to the end of its scope — the collector decides when the object goes (4.2)");
    }
    if (strcmp(n, "except") == 0 && (nx == TK_COLON || nx == TK_IDENT)) {
        fatal_at(self->file, tk->pos, "the clause is spelled `catch e:` here, not `except` (5.1): there is one error type and no hierarchy to filter by, so there is nothing to name between the two");
    }
}

static PsStmt *PsP_parse_stmt(PsP *self) {
    if (PsP_at(self, TK_INDENT)) {
        fatal_at(self->file, PsP_pk(self)->pos, "unexpected indentation");
    }
    PsP_refuse_python(self);
    if (PsP_at(self, TK_CONST) && PsP_pk1(self)->kind == TK_IF) {
        PsP_adv(self);
        PsStmt *cif = PsP_parse_if(self);
        cif->must_fold = 1;
        return cif;
    }
    switch (PsP_pk(self)->kind) {
        case TK_IF: {
            return PsP_parse_if(self);
        }
        case TK_WHILE: {
            Pos pos = PsP_adv(self)->pos;
            PsStmt *s = ps_stmt(self->a, PS_WHILE, pos);
            s->cond = PsP_parse_expr(self);
            s->body = PsP_parse_block(self);
            if (PsP_at(self, TK_ELSE)) {
                fatal_at(self->file, PsP_pk(self)->pos, "a loop has no `else` here: Python's runs when the loop ended without a `break`, and the same thing is a bool set before the loop and checked after it");
            }
            return s;
        }
        case TK_FOR: {
            return PsP_parse_for(self);
        }
        case TK_MATCH: {
            return PsP_parse_match(self);
        }
        case TK_TRY: {
            return PsP_parse_try(self);
        }
        case TK_WITH: {
            Pos pos2 = PsP_adv(self)->pos;
            PsStmt *w = ps_stmt(self->a, PS_WITH, pos2);
            w->expr = PsP_parse_ternary(self);
            if (PsP_accept(self, TK_AS)) {
                w->name = PsP_expect(self, TK_IDENT, "with ... as name")->text;
            }
            w->body = PsP_parse_block(self);
            return w;
        }
        case TK_DEFER: {
            Pos pos3 = PsP_adv(self)->pos;
            PsStmt *d = ps_stmt(self->a, PS_DEFER, pos3);
            d->body = PsP_parse_block(self);
            return d;
        }
        case TK_UNSAFE: {
            Pos pos4 = PsP_adv(self)->pos;
            PsStmt *u = ps_stmt(self->a, PS_UNSAFE, pos4);
            u->body = PsP_parse_block(self);
            return u;
        }
        case TK_NOGC: {
            Pos pos5 = PsP_adv(self)->pos;
            PsStmt *g = ps_stmt(self->a, PS_NOGC, pos5);
            if (PsP_accept(self, TK_LPAREN)) {
                g->expr = PsP_parse_expr(self);
                PsP_expect(self, TK_RPAREN, "nogc(budget)");
            }
            g->body = PsP_parse_block(self);
            return g;
        }
        default: {
            ;
            break;
        }
    }
    PsStmt *s2 = PsP_parse_simple_stmt(self);
    if (PsP_at(self, TK_COMMA) && s2->kind == PS_UNPACK) {
        Vec_pPsExpr rv9;
        Vec_pPsExpr_init(&rv9);
        Vec_pPsExpr_push(&rv9, s2->rhs);
        while (PsP_accept(self, TK_COMMA)) {
            Vec_pPsExpr_push(&rv9, PsP_parse_expr(self));
        }
        PsExpr *rt9 = ps_expr(self->a, PE_TUPLE, s2->rhs->pos);
        rt9->args = rv9.data;
        rt9->nargs = rv9.len;
        s2->rhs = rt9;
    } else if (PsP_at(self, TK_COMMA)) {
        fatal_at(self->file, PsP_pk(self)->pos, "a comma here reads as unpacking (`a, b = ...`), and the left side has to be plain names (98.1)");
    }
    if (self->blocked) {
        self->blocked = 0;
    } else {
        PsP_expect(self, TK_NEWLINE, "statement");
    }
    return s2;
}

static PsStmt *PsP_parse_simple_stmt(PsP *self) {
    Token *tk = PsP_pk(self);
    Pos pos = tk->pos;
    switch (tk->kind) {
        case TK_RETURN: {
            PsP_adv(self);
            PsStmt *r = ps_stmt(self->a, PS_RETURN, pos);
            if (!PsP_at(self, TK_NEWLINE)) {
                r->expr = PsP_parse_expr(self);
            }
            return r;
        }
        case TK_BREAK: {
            PsP_adv(self);
            return ps_stmt(self->a, PS_BREAK, pos);
        }
        case TK_CONTINUE: {
            PsP_adv(self);
            return ps_stmt(self->a, PS_CONTINUE, pos);
        }
        case TK_PASS: {
            PsP_adv(self);
            return ps_stmt(self->a, PS_PASS, pos);
        }
        case TK_RAISE: {
            PsP_adv(self);
            PsStmt *rz = ps_stmt(self->a, PS_RAISE, pos);
            if (!PsP_at(self, TK_NEWLINE)) {
                rz->expr = PsP_parse_expr(self);
            }
            return rz;
        }
        case TK_ASSERT: {
            PsP_adv(self);
            PsStmt *az = ps_stmt(self->a, PS_ASSERT, pos);
            az->expr = PsP_parse_expr(self);
            if (PsP_accept(self, TK_COMMA)) {
                az->rhs = PsP_parse_expr(self);
            }
            return az;
        }
        case TK_GLOBAL:
        case TK_NONLOCAL: {
            PsP_adv(self);
            PsStmt *gz = ps_stmt(self->a, (tk->kind == TK_GLOBAL ? PS_GLOBAL : PS_NONLOCAL), pos);
            gz->name = PsP_expect(self, TK_IDENT, "global/nonlocal")->text;
            return gz;
        }
        default: {
            ;
            break;
        }
    }
    int is_const = PsP_accept(self, TK_CONST);
    if (PsP_at(self, TK_IDENT) && (PsP_pk1(self)->kind == TK_COLON || (is_const && PsP_pk1(self)->kind == TK_ASSIGN))) {
        Token *nt = PsP_adv(self);
        PsStmt *v = ps_stmt(self->a, PS_VAR, pos);
        v->name = nt->text;
        v->is_const = is_const;
        if (PsP_accept(self, TK_COLON)) {
            v->type = PsP_parse_type(self);
        }
        if (PsP_accept(self, TK_ASSIGN)) {
            v->rhs = PsP_parse_expr(self);
        } else if (v->type == NULL) {
            fatal_at(self->file, pos, "'%s' needs a type or a value", nt->text);
        }
        return v;
    }
    if (is_const) {
        fatal_at(self->file, pos, "const needs a name and a value: `const NAME = ...`");
    }
    PsExpr *lhs = PsP_parse_expr(self);
    if (PsP_at(self, TK_COMMA)) {
        Vec_pPsExpr items;
        Vec_pPsExpr_init(&items);
        Vec_pPsExpr_push(&items, lhs);
        while (PsP_accept(self, TK_COMMA)) {
            Vec_pPsExpr_push(&items, PsP_parse_expr(self));
        }
        PsExpr *tp = ps_expr(self->a, PE_TUPLE, pos);
        tp->args = items.data;
        tp->nargs = items.len;
        lhs = tp;
    }
    TokKind k = PsP_pk(self)->kind;
    if (k == TK_ASSIGN && lhs->kind == PE_NAME) {
        PsP_adv(self);
        PsStmt *v2 = ps_stmt(self->a, PS_VAR, pos);
        v2->name = lhs->text;
        v2->rhs = PsP_parse_expr(self);
        return v2;
    }
    if (k == TK_ASSIGN && lhs->kind == PE_TUPLE) {
        PsP_adv(self);
        PsStmt *up = ps_stmt(self->a, PS_UNPACK, pos);
        up->lhs = lhs;
        up->rhs = PsP_parse_expr(self);
        return up;
    }
    if (is_ps_assign_op(k)) {
        PsP_adv(self);
        PsStmt *asg = ps_stmt(self->a, PS_ASSIGN, pos);
        asg->lhs = lhs;
        asg->op = k;
        asg->rhs = PsP_parse_expr(self);
        return asg;
    }
    PsStmt *ex = ps_stmt(self->a, PS_EXPR, pos);
    ex->expr = lhs;
    return ex;
}

static int PsP_const_cond(PsP *self, PsExpr *e) {
    if (e == NULL) {
        return 0;
    }
    switch (e->kind) {
        case PE_NAME: {
            int k = 1;
            int64_t v = parser_predef_value(e->text, &k);
            if (!k) {
                fatal_at(self->file, e->pos, "a top-level `const if` can only look at a compiler predefine (`__PLANG_LINUX__`, `__PLANG_MACOS__`, `__PLANG_BSD__`) or a `-D` name: '%s' is neither", e->text);
            }
            return v != 0;
        }
        case PE_INT: {
            return strtoll(e->text, NULL, 0) != 0;
        }
        case PE_BOOL: {
            return strcmp(e->text, "True") == 0;
        }
        case PE_CALL: {
            if (e->lhs != NULL && e->lhs->kind == PE_NAME && (strcmp(e->lhs->text, "defined") == 0 || strcmp(e->lhs->text, "is_defined") == 0)) {
                if (e->nargs != 1 || e->args[0]->kind != PE_NAME) {
                    fatal_at(self->file, e->pos, "`defined(NAME)` takes one name");
                }
                int known = 1;
                parser_predef_value(e->args[0]->text, &known);
                return known;
            }
            fatal_at(self->file, e->pos, "a `const if` at the top takes a name, `defined(NAME)`, `not`, `and`, `or`, or `== \"...\"`");
            return 0;
        }
        case PE_UNARY: {
            if (e->op == TK_NOT) {
                return !PsP_const_cond(self, e->lhs);
            }
            fatal_at(self->file, e->pos, "a `const if` at the top takes a name, `defined(NAME)`, `not`, `and`, `or`, or `== \"...\"`");
            return 0;
        }
        case PE_BINARY: {
            if (e->op == TK_AND) {
                return PsP_const_cond(self, e->lhs) && PsP_const_cond(self, e->rhs);
            }
            if (e->op == TK_OR) {
                return PsP_const_cond(self, e->lhs) || PsP_const_cond(self, e->rhs);
            }
            if (e->op == TK_EQ || e->op == TK_NE) {
                PsExpr *nm = e->lhs;
                PsExpr *lit = e->rhs;
                if (nm->kind != PE_NAME || lit->kind != PE_STR) {
                    nm = e->rhs;
                    lit = e->lhs;
                }
                if (nm->kind != PE_NAME || lit->kind != PE_STR || strcmp(nm->text, "__PLANG_OS__") != 0) {
                    fatal_at(self->file, e->pos, "the only comparison a `const if` at the top takes is `__PLANG_OS__ == \"name\"`");
                }
                size_t ln = 0;
                char *sv = str_lit_decode(self->a, lit->text, &ln);
                int same = strcmp(sv, parser_predef_os()) == 0;
                return (e->op == TK_EQ ? same : !same);
            }
            fatal_at(self->file, e->pos, "a `const if` at the top takes a name, `defined(NAME)`, `not`, `and`, `or`, or `== \"...\"`");
            return 0;
        }
        default: {
            fatal_at(self->file, e->pos, "a `const if` at the top takes a name, `defined(NAME)`, `not`, `and`, `or`, or `== \"...\"`");
            return 0;
        }
    }
}

static PsStmt *PsP_parse_if(PsP *self) {
    Pos pos = PsP_expect(self, TK_IF, "if")->pos;
    PsStmt *s = ps_stmt(self->a, PS_IF, pos);
    Vec_pPsExpr conds;
    Vec_pPsExpr_init(&conds);
    Vec_pPsBlock blocks;
    Vec_pPsBlock_init(&blocks);
    Vec_pPsExpr_push(&conds, PsP_parse_expr(self));
    Vec_pPsBlock_push(&blocks, PsP_parse_block(self));
    while (PsP_at(self, TK_ELIF)) {
        PsP_adv(self);
        Vec_pPsExpr_push(&conds, PsP_parse_expr(self));
        Vec_pPsBlock_push(&blocks, PsP_parse_block(self));
    }
    if (PsP_accept(self, TK_ELSE)) {
        s->else_block = PsP_parse_block(self);
    }
    s->conds = conds.data;
    s->blocks = blocks.data;
    s->nconds = conds.len;
    return s;
}

static PsStmt *PsP_parse_for(PsP *self) {
    Pos pos = PsP_expect(self, TK_FOR, "for")->pos;
    PsStmt *s = ps_stmt(self->a, PS_FOR, pos);
    Vec_pchar vs;
    Vec_pchar_init(&vs);
    do {
        Vec_pchar_push(&vs, (char *)PsP_expect(self, TK_IDENT, "for variable")->text);
    } while (PsP_accept(self, TK_COMMA));
    s->names = vs.data;
    s->nnames = vs.len;
    s->name = vs.data[0];
    PsP_expect(self, TK_IN, "for");
    s->iter = PsP_parse_expr(self);
    s->body = PsP_parse_block(self);
    if (PsP_at(self, TK_ELSE)) {
        fatal_at(self->file, PsP_pk(self)->pos, "a loop has no `else` here: Python's runs when the loop ended without a `break`, and the same thing is a bool set before the loop and checked after it");
    }
    return s;
}

static PsStmt *PsP_parse_match(PsP *self) {
    Pos pos = PsP_expect(self, TK_MATCH, "match")->pos;
    PsStmt *s = ps_stmt(self->a, PS_MATCH, pos);
    if (PsP_at(self, TK_IDENT) && strcmp(PsP_pk(self)->text, "type") == 0 && PsP_pk1(self)->kind == TK_LPAREN) {
        PsP_adv(self);
        PsP_adv(self);
        s->is_typematch = 1;
        s->subject = PsP_parse_expr(self);
        PsP_expect(self, TK_RPAREN, "match type(x)");
    } else {
        s->subject = PsP_parse_expr(self);
    }
    PsP_expect(self, TK_COLON, "match");
    PsP_expect(self, TK_NEWLINE, "match");
    PsP_expect(self, TK_INDENT, "match");
    Vec_pPsCase cases;
    Vec_pPsCase_init(&cases);
    while (!PsP_at(self, TK_DEDENT) && !PsP_at(self, TK_EOF)) {
        if (PsP_accept(self, TK_NEWLINE)) {
            continue;
        }
        PsP_expect(self, TK_CASE, "match case");
        PsCase *c = Arena_alloc(self->a, sizeof(PsCase));
        if (PsP_at(self, TK_IDENT) && strcmp(PsP_pk(self)->text, "_") == 0) {
            PsP_adv(self);
            c->is_default = 1;
        } else {
            Vec_pPsExpr vals;
            Vec_pPsExpr_init(&vals);
            do {
                Vec_pPsExpr_push(&vals, PsP_parse_expr(self));
            } while (PsP_accept(self, TK_COMMA));
            c->vals = vals.data;
            c->nvals = vals.len;
        }
        c->body = PsP_parse_block(self);
        Vec_pPsCase_push(&cases, c);
    }
    PsP_expect(self, TK_DEDENT, "match");
    s->cases = cases.data;
    s->ncases = cases.len;
    return s;
}

static PsStmt *PsP_parse_try(PsP *self) {
    Pos pos = PsP_expect(self, TK_TRY, "try")->pos;
    PsStmt *s = ps_stmt(self->a, PS_TRY, pos);
    s->body = PsP_parse_block(self);
    if (PsP_accept(self, TK_CATCH)) {
        if (PsP_at(self, TK_IDENT)) {
            s->name = PsP_adv(self)->text;
        }
        s->catch_block = PsP_parse_block(self);
    }
    if (PsP_accept(self, TK_FINALLY)) {
        s->finally_block = PsP_parse_block(self);
    }
    if (s->catch_block == NULL && s->finally_block == NULL) {
        if (PsP_at(self, TK_IDENT) && strcmp(PsP_pk(self)->text, "except") == 0) {
            fatal_at(self->file, PsP_pk(self)->pos, "the clause is spelled `catch e:` here, not `except` (5.1): there is one error type and no hierarchy to filter by");
        }
        fatal_at(self->file, pos, "try needs a catch or a finally");
    }
    return s;
}

static void PsP_parse_decorators(PsP *self, Vec_pPsExpr *into) {
    while (PsP_at(self, TK_AT)) {
        PsP_adv(self);
        Vec_pPsExpr_push(into, PsP_parse_postfix(self));
        PsP_expect(self, TK_NEWLINE, "decorator");
        while (PsP_accept(self, TK_NEWLINE)) {
            ;
        }
    }
}

static PsFunc *PsP_parse_func_head(PsP *self, int no_recv, int is_async, const char *owner) {
    Pos pos = PsP_expect(self, TK_DEF, "def")->pos;
    PsFunc *f = Arena_alloc(self->a, sizeof(PsFunc));
    f->pos = pos;
    f->is_smethod = no_recv && owner != NULL;
    f->is_private = no_recv && owner == NULL;
    f->is_async = is_async;
    f->owner = owner;
    f->is_method = owner != NULL;
    f->name = PsP_expect(self, TK_IDENT, "function name")->text;
    if (PsP_at(self, TK_LT)) {
        PsP_adv(self);
        Vec_PsTParam tps;
        Vec_PsTParam_init(&tps);
        do {
            PsTParam tp = {0};
            tp.pos = PsP_pk(self)->pos;
            tp.name = PsP_expect(self, TK_IDENT, "type parameter")->text;
            if (PsP_accept(self, TK_COLON)) {
                tp.bound = PsP_expect(self, TK_IDENT, "trait bound")->text;
            }
            Vec_PsTParam_push(&tps, tp);
        } while (PsP_accept(self, TK_COMMA));
        PsP_expect(self, TK_GT, "type parameter list");
        f->tparams = tps.data;
        f->ntparams = tps.len;
    }
    PsP_expect(self, TK_LPAREN, "parameter list");
    Vec_PsParam ps;
    Vec_PsParam_init(&ps);
    if (!PsP_at(self, TK_RPAREN)) {
        do {
            PsParam p = {0};
            p.pos = PsP_pk(self)->pos;
            p.is_in = PsP_accept(self, TK_IN);
            if (!p.is_in && PsP_at(self, TK_IDENT) && PsP_pk1(self)->kind == TK_IDENT) {
                if (strcmp(PsP_pk(self)->text, "out") == 0) {
                    PsP_adv(self);
                    p.is_out = 1;
                } else if (strcmp(PsP_pk(self)->text, "ref") == 0) {
                    PsP_adv(self);
                    p.is_ref = 1;
                }
            }
            p.is_varargs = PsP_accept(self, TK_STAR);
            p.name = PsP_expect(self, TK_IDENT, "parameter name")->text;
            if (PsP_accept(self, TK_COLON)) {
                p.type = PsP_parse_type(self);
            }
            if (PsP_accept(self, TK_ASSIGN)) {
                p.dflt = PsP_parse_expr(self);
            }
            Vec_PsParam_push(&ps, p);
        } while (PsP_accept(self, TK_COMMA));
    }
    PsP_expect(self, TK_RPAREN, "parameter list");
    f->params = ps.data;
    f->nparams = ps.len;
    if (PsP_accept(self, TK_ARROW)) {
        f->ret = PsP_parse_type(self);
    }
    return f;
}

static PsFunc *PsP_parse_func(PsP *self, int no_recv, int is_async, const char *owner) {
    PsFunc *f = PsP_parse_func_head(self, no_recv, is_async, owner);
    PsP_expect(self, TK_COLON, "def");
    PsP_expect(self, TK_NEWLINE, "def");
    PsP_expect(self, TK_INDENT, "def");
    f->doc = PsP_docstring(self);
    Vec_pPsStmt stmts;
    Vec_pPsStmt_init(&stmts);
    while (!PsP_at(self, TK_DEDENT) && !PsP_at(self, TK_EOF)) {
        if (PsP_accept(self, TK_NEWLINE)) {
            continue;
        }
        Vec_pPsStmt_push(&stmts, PsP_parse_stmt(self));
    }
    PsP_expect(self, TK_DEDENT, "def");
    PsBlock *b = Arena_alloc(self->a, sizeof(PsBlock));
    b->stmts = stmts.data;
    b->n = stmts.len;
    f->body = b;
    return f;
}

static PsDecl *PsP_parse_trait(PsP *self) {
    Pos pos = PsP_adv(self)->pos;
    PsDecl *d = ps_decl(self->a, PD_TRAIT, pos);
    d->name = PsP_expect(self, TK_IDENT, "trait name")->text;
    PsP_expect(self, TK_COLON, "trait");
    PsP_expect(self, TK_NEWLINE, "trait");
    PsP_expect(self, TK_INDENT, "trait body");
    d->doc = PsP_docstring(self);
    Vec_pPsFunc ms;
    Vec_pPsFunc_init(&ms);
    while (!PsP_at(self, TK_DEDENT) && !PsP_at(self, TK_EOF)) {
        if (PsP_accept(self, TK_NEWLINE)) {
            continue;
        }
        if (PsP_at(self, TK_IDENT) && strcmp(PsP_pk(self)->text, "type") == 0 && PsP_pk1(self)->kind == TK_IDENT) {
            Pos tpos = PsP_adv(self)->pos;
            if (d->assoc != NULL) {
                fatal_at(self->file, tpos, "a trait has at most one associated type for now");
            }
            d->assoc = PsP_expect(self, TK_IDENT, "associated type name")->text;
            PsP_expect(self, TK_NEWLINE, "type");
            continue;
        }
        if (!PsP_at(self, TK_DEF)) {
            fatal_at(self->file, PsP_pk(self)->pos, "a trait holds method signatures: `def name(...) -> T`");
        }
        PsFunc *f = PsP_parse_func_head(self, 0, 0, d->name);
        if (PsP_at(self, TK_COLON)) {
            fatal_at(self->file, PsP_pk(self)->pos, "a trait method has no body — `implement %s for T:` supplies it", d->name);
        }
        PsP_expect(self, TK_NEWLINE, "trait method");
        Vec_pPsFunc_push(&ms, f);
    }
    PsP_expect(self, TK_DEDENT, "trait");
    d->methods = ms.data;
    d->nmethods = ms.len;
    return d;
}

static PsDecl *PsP_parse_impl(PsP *self) {
    Pos pos = PsP_adv(self)->pos;
    PsDecl *d = ps_decl(self->a, PD_IMPL, pos);
    d->trait_type = PsP_parse_type(self);
    PsP_expect(self, TK_FOR, "implement Trait for Type");
    d->for_type = PsP_parse_type(self);
    d->name = d->trait_type->name;
    PsP_expect(self, TK_COLON, "implement ... for");
    PsP_expect(self, TK_NEWLINE, "implement ... for");
    PsP_expect(self, TK_INDENT, "implement ... for");
    d->doc = PsP_docstring(self);
    Vec_pPsFunc ms;
    Vec_pPsFunc_init(&ms);
    while (!PsP_at(self, TK_DEDENT) && !PsP_at(self, TK_EOF)) {
        if (PsP_accept(self, TK_NEWLINE)) {
            continue;
        }
        if (PsP_at(self, TK_IDENT) && strcmp(PsP_pk(self)->text, "type") == 0 && PsP_pk1(self)->kind == TK_IDENT) {
            PsP_adv(self);
            d->assoc = PsP_expect(self, TK_IDENT, "associated type name")->text;
            PsP_expect(self, TK_ASSIGN, "type Item = T");
            d->assoc_type = PsP_parse_type(self);
            PsP_expect(self, TK_NEWLINE, "type Item = T");
            continue;
        }
        if (!PsP_at(self, TK_DEF)) {
            fatal_at(self->file, PsP_pk(self)->pos, "an `implement ... for` block holds method bodies");
        }
        Vec_pPsFunc_push(&ms, PsP_parse_func(self, 0, 0, d->for_type->name));
    }
    PsP_expect(self, TK_DEDENT, "implement ... for");
    d->methods = ms.data;
    d->nmethods = ms.len;
    return d;
}

static PsDecl *PsP_parse_aggregate(PsP *self, int is_record) {
    Pos pos = PsP_adv(self)->pos;
    PsDecl *d = ps_decl(self->a, (is_record ? PD_RECORD : PD_STRUCT), pos);
    d->name = PsP_expect(self, TK_IDENT, "record/struct name")->text;
    if (PsP_accept(self, TK_IMPLEMENTS)) {
        Vec_pchar ifs;
        Vec_pchar_init(&ifs);
        do {
            Vec_pchar_push(&ifs, (char *)PsP_expect(self, TK_IDENT, "implements")->text);
        } while (PsP_accept(self, TK_COMMA));
        d->implements = ifs.data;
        d->nimplements = ifs.len;
    }
    PsP_expect(self, TK_COLON, "record/struct");
    PsP_expect(self, TK_NEWLINE, "record/struct");
    PsP_expect(self, TK_INDENT, "record/struct");
    d->doc = PsP_docstring(self);
    Vec_PsField fields;
    Vec_PsField_init(&fields);
    Vec_pPsFunc methods;
    Vec_pPsFunc_init(&methods);
    while (!PsP_at(self, TK_DEDENT) && !PsP_at(self, TK_EOF)) {
        if (PsP_accept(self, TK_NEWLINE)) {
            continue;
        }
        Vec_pPsExpr mdecs;
        Vec_pPsExpr_init(&mdecs);
        if (PsP_at(self, TK_AT)) {
            PsP_parse_decorators(self, &mdecs);
        }
        int st = PsP_accept(self, TK_STATIC);
        int masync = PsP_accept(self, TK_ASYNC);
        if (PsP_at(self, TK_IDENT) && strcmp(PsP_pk(self)->text, "type") == 0 && PsP_pk1(self)->kind == TK_IDENT) {
            PsP_adv(self);
            d->assoc = PsP_expect(self, TK_IDENT, "associated type name")->text;
            PsP_expect(self, TK_ASSIGN, "type Item = T");
            d->assoc_type = PsP_parse_type(self);
            PsP_expect(self, TK_NEWLINE, "type Item = T");
            continue;
        }
        if (PsP_at(self, TK_DEF)) {
            PsFunc *mf = PsP_parse_func(self, st, masync, d->name);
            mf->decorators = mdecs.data;
            mf->ndecorators = mdecs.len;
            Vec_pPsFunc_push(&methods, mf);
            continue;
        }
        if (mdecs.len > 0) {
            fatal_at(self->file, PsP_pk(self)->pos, "a decorator has to be followed by a def");
        }
        if (st || masync) {
            fatal_at(self->file, PsP_pk(self)->pos, "'%s' here introduces a method", (st ? "static" : "async"));
        }
        Pos fp = PsP_pk(self)->pos;
        PsField fl = {0};
        fl.pos = fp;
        fl.name = PsP_expect(self, TK_IDENT, "field name")->text;
        PsP_expect(self, TK_COLON, "field");
        fl.type = PsP_parse_type(self);
        PsP_expect(self, TK_NEWLINE, "field");
        Vec_PsField_push(&fields, fl);
    }
    PsP_expect(self, TK_DEDENT, "record/struct");
    d->fields = fields.data;
    d->nfields = fields.len;
    d->methods = methods.data;
    d->nmethods = methods.len;
    return d;
}

static PsDecl *PsP_parse_enum(PsP *self) {
    Pos pos = PsP_expect(self, TK_ENUM, "enum")->pos;
    PsDecl *d = ps_decl(self->a, PD_ENUM, pos);
    d->name = PsP_expect(self, TK_IDENT, "enum name")->text;
    PsP_expect(self, TK_COLON, "enum");
    PsP_expect(self, TK_NEWLINE, "enum");
    PsP_expect(self, TK_INDENT, "enum");
    Vec_PsEnumItem items;
    Vec_PsEnumItem_init(&items);
    while (!PsP_at(self, TK_DEDENT) && !PsP_at(self, TK_EOF)) {
        if (PsP_accept(self, TK_NEWLINE)) {
            continue;
        }
        PsEnumItem it = {0};
        it.pos = PsP_pk(self)->pos;
        it.name = PsP_expect(self, TK_IDENT, "enum item")->text;
        if (PsP_accept(self, TK_ASSIGN)) {
            it.value = PsP_parse_expr(self);
        }
        PsP_expect(self, TK_NEWLINE, "enum item");
        Vec_PsEnumItem_push(&items, it);
    }
    PsP_expect(self, TK_DEDENT, "enum");
    d->items = items.data;
    d->nitems = items.len;
    return d;
}

static PsDecl *PsP_parse_import(PsP *self) {
    Pos pos = PsP_expect(self, TK_IMPORT, "import")->pos;
    if (PsP_at(self, TK_HEADER) || PsP_at(self, TK_LT)) {
        PsDecl *hd = ps_decl(self->a, PD_INCLUDE, pos);
        if (PsP_at(self, TK_HEADER)) {
            hd->path = PsP_adv(self)->text;
        } else {
            PsP_adv(self);
            const char *hp = "";
            while (!PsP_at(self, TK_GT) && !PsP_at(self, TK_NEWLINE) && !PsP_at(self, TK_EOF)) {
                hp = Arena_printf(self->a, "%s%s", hp, spell_tok(PsP_adv(self)));
            }
            PsP_expect(self, TK_GT, "import <pkg/module.ph> (missing '>')");
            hd->path = hp;
        }
        if (has_suffix_ps(hd->path, ".ph")) {
            hd->is_pmod = 1;
            hd->import_system = 1;
            PsP_expect(self, TK_NEWLINE, "import");
            return hd;
        }
        if (has_suffix_ps(hd->path, ".psc") || strchr(hd->path, '/') == NULL) {
            PsDecl *d2 = ps_decl(self->a, PD_IMPORT, pos);
            d2->path = hd->path;
            d2->import_system = 1;
            if (PsP_accept(self, TK_AS)) {
                d2->alias = PsP_expect(self, TK_IDENT, "import ... as")->text;
            }
            PsP_expect(self, TK_NEWLINE, "import");
            return d2;
        }
        fatal_at(self->file, pos, "`import <%s>`: um módulo de pacote é `<pkg>` (a raiz), `<pkg/mod.psc>` (um módulo pscript) ou `<pkg/mod.ph>` (um módulo P). Um header de C é `include <stdio.h>` (45.5)", hd->path);
        return hd;
    }
    if (PsP_at(self, TK_STRING)) {
        PsDecl *pd = ps_decl(self->a, PD_INCLUDE, pos);
        const char *raw = PsP_adv(self)->text;
        size_t rl = strlen(raw);
        pd->path = Arena_strndup(self->a, raw + 1, (rl >= 2 ? rl - 2 : 0));
        pd->is_pmod = 1;
        if (!has_suffix_ps(pd->path, ".ph")) {
            fatal_at(self->file, pos, "`import \"...\"` names a P module by its header: `import \"shim.ph\"` (75.3). A C header is `include \"shim.h\"` (45.5)");
        }
        PsP_expect(self, TK_NEWLINE, "import");
        return pd;
    }
    PsDecl *d = ps_decl(self->a, PD_IMPORT, pos);
    d->path = PsP_expect(self, TK_IDENT, "module name")->text;
    if (PsP_accept(self, TK_AS)) {
        d->alias = PsP_expect(self, TK_IDENT, "import ... as")->text;
    }
    PsP_expect(self, TK_NEWLINE, "import");
    return d;
}

static PsDecl *PsP_parse_from(PsP *self) {
    Pos pos = PsP_expect(self, TK_FROM, "from")->pos;
    PsDecl *d = ps_decl(self->a, PD_FROM_IMPORT, pos);
    if (PsP_at(self, TK_LT)) {
        PsP_adv(self);
        const char *hp = "";
        while (!PsP_at(self, TK_GT) && !PsP_at(self, TK_NEWLINE) && !PsP_at(self, TK_EOF)) {
            hp = Arena_printf(self->a, "%s%s", hp, spell_tok(PsP_adv(self)));
        }
        PsP_expect(self, TK_GT, "from <pkg/module.psc> import ... (falta o '>')");
        if (!has_suffix_ps(hp, ".psc") && strchr(hp, '/') != NULL) {
            fatal_at(self->file, pos, "`from <%s> import`: só um módulo PSCRIPT se importa assim — `<pkg>` ou `<pkg/mod.psc>`. Um módulo P entra inteiro (`import <pkg/mod.ph>`), porque o que dele atravessa é decidido pela 45.5 e não por uma lista de nomes.", hp);
        }
        d->path = hp;
        d->import_system = 1;
    } else {
        d->path = PsP_expect(self, TK_IDENT, "module name")->text;
    }
    PsP_expect(self, TK_IMPORT, "from ... import");
    Vec_pchar names;
    Vec_pchar_init(&names);
    Vec_pchar aliases;
    Vec_pchar_init(&aliases);
    do {
        Vec_pchar_push(&names, (char *)PsP_expect(self, TK_IDENT, "imported name")->text);
        if (PsP_accept(self, TK_AS)) {
            Vec_pchar_push(&aliases, (char *)PsP_expect(self, TK_IDENT, "import ... as")->text);
        } else {
            Vec_pchar_push(&aliases, NULL);
        }
    } while (PsP_accept(self, TK_COMMA));
    d->names = names.data;
    d->aliases = aliases.data;
    d->nnames = names.len;
    PsP_expect(self, TK_NEWLINE, "from ... import");
    return d;
}

static PsDecl *PsP_parse_include(PsP *self) {
    Pos pos = PsP_adv(self)->pos;
    PsDecl *d = ps_decl(self->a, PD_INCLUDE, pos);
    if (PsP_at(self, TK_LT)) {
        PsP_adv(self);
        const char *path = "";
        while (!PsP_at(self, TK_GT) && !PsP_at(self, TK_NEWLINE) && !PsP_at(self, TK_EOF)) {
            path = Arena_printf(self->a, "%s%s", path, spell_tok(PsP_adv(self)));
        }
        PsP_expect(self, TK_GT, "include <header> (missing '>')");
        d->path = path;
        d->import_system = 1;
    } else if (PsP_at(self, TK_STRING)) {
        const char *raw = PsP_adv(self)->text;
        size_t len = strlen(raw);
        d->path = Arena_strndup(self->a, raw + 1, (len >= 2 ? len - 2 : 0));
    } else {
        fatal_at(self->file, pos, "include expects a C header: include <stdio.h>");
    }
    PsP_expect(self, TK_NEWLINE, "include");
    return d;
}

int32_t ps_width_name(const char *n) {
    if (strcmp(n, "i8") == 0 || strcmp(n, "u8") == 0) {
        return 8;
    }
    if (strcmp(n, "i16") == 0 || strcmp(n, "u16") == 0) {
        return 16;
    }
    if (strcmp(n, "i32") == 0 || strcmp(n, "u32") == 0 || strcmp(n, "f32") == 0) {
        return 32;
    }
    if (strcmp(n, "u64") == 0) {
        return 64;
    }
    return 0;
}

static int is_float_lexeme(const char *t) {
    if (strchr(t, '.') != NULL) {
        return 1;
    }
    if (t[0] == '0' && (t[1] == 'x' || t[1] == 'X')) {
        return 0;
    }
    return strchr(t, 'e') != NULL || strchr(t, 'E') != NULL;
}

static int is_ps_assign_op(TokKind k) {
    return k == TK_ASSIGN || k == TK_PLUS_EQ || k == TK_MINUS_EQ || k == TK_STAR_EQ || k == TK_SLASH_EQ || k == TK_PERCENT_EQ || k == TK_AMP_EQ || k == TK_PIPE_EQ || k == TK_CARET_EQ || k == TK_SHL_EQ || k == TK_SHR_EQ || k == TK_POW_EQ || k == TK_FLOORDIV_EQ || k == TK_COALESCE_EQ;
}

static void ps_retag(PsExpr *e, Pos pos) {
    if (e == NULL) {
        return;
    }
    e->pos = pos;
    ps_retag(e->lhs, pos);
    ps_retag(e->rhs, pos);
    ps_retag(e->cond, pos);
    size_t i;
    for (i = 0; i < e->nargs; i += 1) {
        ps_retag(e->args[i], pos);
    }
}

static int has_suffix_ps(const char *s, const char *suf) {
    size_t n = strlen(s);
    size_t m = strlen(suf);
    return n >= m && strcmp(s + n - m, suf) == 0;
}

PsExpr *ps_template(Arena *a, const char *file, const char *lexeme, Pos pos) {
    TokenList tl = ps_lex(file, "", 0, a);
    PsP p = {tl.toks, tl.n, 0, file, a};
    return PsP_fstring(&p, lexeme, pos);
}

PsExpr *ps_template_dict(Arena *a, const char *file, const char *lexeme, Pos pos, char **keys, PsExpr **vals, int *used, int32_t n) {
    TokenList tl = ps_lex(file, "", 0, a);
    PsP p = {tl.toks, tl.n, 0, file, a};
    p.sub = 1;
    p.sk = keys;
    p.sv = vals;
    p.su = used;
    p.sn = n;
    return PsP_fstring(&p, lexeme, pos);
}

static PsExpr *ps_clone_expr(Arena *a, PsExpr *e, const char *file) {
    if (e == NULL) {
        return NULL;
    }
    if (e->body != NULL || e->params != NULL) {
        fatal_at(file, e->pos, "a lambda cannot be the value of a template key that two holes ask for (75.2)");
    }
    PsExpr *c = Arena_alloc(a, sizeof(PsExpr));
    *c = *e;
    c->lhs = ps_clone_expr(a, e->lhs, file);
    c->rhs = ps_clone_expr(a, e->rhs, file);
    c->cond = ps_clone_expr(a, e->cond, file);
    if (e->nargs > 0 && e->args != NULL) {
        c->args = Arena_alloc(a, (size_t)e->nargs * sizeof(*c->args));
        size_t i;
        for (i = 0; i < e->nargs; i += 1) {
            c->args[i] = ps_clone_expr(a, e->args[i], file);
        }
    }
    return c;
}

static void ps_const_if_block(PsP *p, Vec_pPsDecl *decls, Vec_pPsStmt *top, Arena *a, int keep) {
    PsP_expect(p, TK_COLON, "const if");
    PsP_expect(p, TK_NEWLINE, "const if");
    PsP_expect(p, TK_INDENT, "const if");
    while (!PsP_at(p, TK_DEDENT) && !PsP_at(p, TK_EOF)) {
        if (PsP_accept(p, TK_NEWLINE)) {
            continue;
        }
        if (PsP_at(p, TK_CONST) && PsP_pk1(p)->kind == TK_IF) {
            ps_const_if_top(p, decls, top, a);
            continue;
        }
        if (PsP_at(p, TK_IMPORT)) {
            PsDecl *d = PsP_parse_import(p);
            if (keep) {
                Vec_pPsDecl_push(decls, d);
            }
            continue;
        }
        if (PsP_at(p, TK_FROM)) {
            PsDecl *d2 = PsP_parse_from(p);
            if (keep) {
                Vec_pPsDecl_push(decls, d2);
            }
            continue;
        }
        if (PsP_at(p, TK_IDENT) && strcmp(PsP_pk(p)->text, "include") == 0) {
            PsDecl *d3 = PsP_parse_include(p);
            if (keep) {
                Vec_pPsDecl_push(decls, d3);
            }
            continue;
        }
        if (PsP_at(p, TK_DEF) || PsP_at(p, TK_ASYNC)) {
            int isa = PsP_accept(p, TK_ASYNC);
            PsDecl *fd = ps_decl(a, PD_FUNC, PsP_pk(p)->pos);
            fd->func = PsP_parse_func(p, 0, isa, NULL);
            fd->name = fd->func->name;
            if (keep) {
                Vec_pPsDecl_push(decls, fd);
            }
            continue;
        }
        if (PsP_at(p, TK_STATIC) || PsP_at(p, TK_PRIVATE)) {
            if (PsP_at(p, TK_STATIC)) {
                fatal_at(p->file, PsP_pk(p)->pos, "'static' no longer spells module privacy: write 'private' (inside a struct it still marks a static method)");
            }
            PsP_adv(p);
            int sa = PsP_accept(p, TK_ASYNC);
            PsDecl *sd = ps_decl(a, PD_FUNC, PsP_pk(p)->pos);
            sd->is_private = 1;
            sd->func = PsP_parse_func(p, 1, sa, NULL);
            sd->name = sd->func->name;
            if (keep) {
                Vec_pPsDecl_push(decls, sd);
            }
            continue;
        }
        PsStmt *st = PsP_parse_stmt(p);
        if (keep) {
            Vec_pPsStmt_push(top, st);
        }
    }
    PsP_expect(p, TK_DEDENT, "const if");
}

static void ps_const_if_top(PsP *p, Vec_pPsDecl *decls, Vec_pPsStmt *top, Arena *a) {
    PsP_adv(p);
    PsP_adv(p);
    PsExpr *c0 = PsP_parse_expr(p);
    int taken = PsP_const_cond(p, c0);
    ps_const_if_block(p, decls, top, a, taken);
    while (PsP_at(p, TK_ELIF)) {
        PsP_adv(p);
        PsExpr *ce = PsP_parse_expr(p);
        int ve = PsP_const_cond(p, ce) && !taken;
        ps_const_if_block(p, decls, top, a, ve);
        if (ve) {
            taken = 1;
        }
    }
    if (PsP_at(p, TK_ELSE)) {
        PsP_adv(p);
        ps_const_if_block(p, decls, top, a, !taken);
    }
}

PsModule *ps_parse(Arena *a, const char *file, TokenList tl) {
    PsP p = {tl.toks, tl.n, 0, file, a};
    PsModule *m = Arena_alloc(a, sizeof(PsModule));
    m->path = Arena_strdup(a, file);
    m->name = ps_module_name(a, file);
    Vec_pPsDecl decls;
    Vec_pPsDecl_init(&decls);
    Vec_pPsStmt top;
    Vec_pPsStmt_init(&top);
    while (PsP_accept(&p, TK_NEWLINE)) {
        ;
    }
    m->doc = PsP_docstring(&p);
    while (!PsP_at(&p, TK_EOF)) {
        if (PsP_accept(&p, TK_NEWLINE)) {
            continue;
        }
        if (PsP_at(&p, TK_INDENT)) {
            fatal_at(file, PsP_pk(&p)->pos, "unexpected indentation at top level");
        }
        Vec_pPsExpr decs;
        Vec_pPsExpr_init(&decs);
        if (PsP_at(&p, TK_AT)) {
            PsP_parse_decorators(&p, &decs);
            if (!PsP_at(&p, TK_DEF) && !PsP_at(&p, TK_ASYNC) && !PsP_at(&p, TK_STATIC) && !PsP_at(&p, TK_PRIVATE)) {
                fatal_at(file, PsP_pk(&p)->pos, "a decorator has to be followed by a def");
            }
        }
        switch (PsP_pk(&p)->kind) {
            case TK_IMPORT: {
                Vec_pPsDecl_push(&decls, PsP_parse_import(&p));
                break;
            }
            case TK_FROM: {
                Vec_pPsDecl_push(&decls, PsP_parse_from(&p));
                break;
            }
            case TK_RECORD: {
                Vec_pPsDecl_push(&decls, PsP_parse_aggregate(&p, 1));
                break;
            }
            case TK_STRUCT: {
                Vec_pPsDecl_push(&decls, PsP_parse_aggregate(&p, 0));
                break;
            }
            case TK_ENUM: {
                Vec_pPsDecl_push(&decls, PsP_parse_enum(&p));
                break;
            }
            case TK_DEF: {
                PsDecl *fd = ps_decl(a, PD_FUNC, PsP_pk(&p)->pos);
                fd->func = PsP_parse_func(&p, 0, 0, NULL);
                fd->func->decorators = decs.data;
                fd->func->ndecorators = decs.len;
                fd->name = fd->func->name;
                Vec_pPsDecl_push(&decls, fd);
                break;
            }
            case TK_ASYNC: {
                if (PsP_pk1(&p)->kind == TK_COLON) {
                    Vec_pPsStmt_push(&top, PsP_parse_stmt(&p));
                    continue;
                }
                PsP_adv(&p);
                PsDecl *afd = ps_decl(a, PD_FUNC, PsP_pk(&p)->pos);
                afd->func = PsP_parse_func(&p, 0, 1, NULL);
                afd->func->decorators = decs.data;
                afd->func->ndecorators = decs.len;
                afd->name = afd->func->name;
                Vec_pPsDecl_push(&decls, afd);
                break;
            }
            case TK_STATIC:
            case TK_PRIVATE: {
                if (PsP_at(&p, TK_STATIC)) {
                    fatal_at(p.file, PsP_pk(&p)->pos, "'static' no longer spells module privacy: write 'private' (inside a struct it still marks a static method)");
                }
                PsP_adv(&p);
                int sasync = PsP_accept(&p, TK_ASYNC);
                PsDecl *sfd = ps_decl(a, PD_FUNC, PsP_pk(&p)->pos);
                sfd->is_private = 1;
                sfd->func = PsP_parse_func(&p, 1, sasync, NULL);
                sfd->func->decorators = decs.data;
                sfd->func->ndecorators = decs.len;
                sfd->name = sfd->func->name;
                Vec_pPsDecl_push(&decls, sfd);
                break;
            }
            case TK_CONST: {
                if (PsP_pk1(&p)->kind == TK_IF) {
                    ps_const_if_top(&p, &decls, &top, a);
                    continue;
                }
                Pos cpos = PsP_adv(&p)->pos;
                PsDecl *cd = ps_decl(a, PD_VAR, cpos);
                cd->is_const = 1;
                cd->name = PsP_expect(&p, TK_IDENT, "const name")->text;
                if (PsP_accept(&p, TK_COLON)) {
                    cd->type = PsP_parse_type(&p);
                }
                PsP_expect(&p, TK_ASSIGN, "const");
                cd->init = PsP_parse_expr(&p);
                PsP_expect(&p, TK_NEWLINE, "const");
                Vec_pPsDecl_push(&decls, cd);
                break;
            }
            case TK_SHARED: {
                Pos spos = PsP_adv(&p)->pos;
                PsDecl *sd = ps_decl(a, PD_SHARED, spos);
                sd->name = PsP_expect(&p, TK_IDENT, "shared variable")->text;
                if (PsP_accept(&p, TK_COLON)) {
                    sd->type = PsP_parse_type(&p);
                }
                if (PsP_accept(&p, TK_ASSIGN)) {
                    sd->init = PsP_parse_expr(&p);
                }
                PsP_expect(&p, TK_NEWLINE, "shared");
                Vec_pPsDecl_push(&decls, sd);
                break;
            }
            case TK_IDENT: {
                if (strcmp(PsP_pk(&p)->text, "include") == 0) {
                    Vec_pPsDecl_push(&decls, PsP_parse_include(&p));
                } else if (strcmp(PsP_pk(&p)->text, "trait") == 0 && PsP_pk1(&p)->kind == TK_IDENT) {
                    Vec_pPsDecl_push(&decls, PsP_parse_trait(&p));
                } else if (strcmp(PsP_pk(&p)->text, "implement") == 0 && PsP_pk1(&p)->kind == TK_IDENT) {
                    Vec_pPsDecl_push(&decls, PsP_parse_impl(&p));
                } else {
                    Vec_pPsStmt_push(&top, PsP_parse_stmt(&p));
                }
                break;
            }
            default: {
                Vec_pPsStmt_push(&top, PsP_parse_stmt(&p));
                break;
            }
        }
    }
    PsBlock *b = Arena_alloc(a, sizeof(PsBlock));
    b->stmts = top.data;
    b->n = top.len;
    m->main = b;
    m->decls = decls.data;
    m->ndecls = decls.len;
    return m;
}

static const char *ps_module_name(Arena *a, const char *path) {
    const char *slash = strrchr(path, '/');
    const char *base = (slash != NULL ? slash + 1 : path);
    const char *dot = strrchr(base, '.');
    if (dot == NULL) {
        return Arena_strdup(a, base);
    }
    return Arena_strndup(a, base, (size_t)(dot - base));
}
