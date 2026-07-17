#include <stdint.h>
#include <stddef.h>

#include "vecs.h"


void Vec_pExpr_init(Vec_pExpr *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pExpr_reserve(Vec_pExpr *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(Expr *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pExpr_push(Vec_pExpr *self, Expr *item) {
    Vec_pExpr_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

Expr *Vec_pExpr_pop(Vec_pExpr *self) {
    self->len -= 1;
    return self->data[self->len];
}

Expr *Vec_pExpr_get(Vec_pExpr *self, int32_t i) {
    return self->data[i];
}

void Vec_pExpr_set(Vec_pExpr *self, int32_t i, Expr *item) {
    self->data[i] = item;
}

Expr *Vec_pExpr_last(Vec_pExpr *self) {
    return self->data[self->len - 1];
}

int Vec_pExpr_is_empty(Vec_pExpr *self) {
    return self->len == 0;
}

void Vec_pExpr_remove_at(Vec_pExpr *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(Expr *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pExpr_swap_remove(Vec_pExpr *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pExpr_clear(Vec_pExpr *self) {
    self->len = 0;
}

void Vec_pExpr_deinit(Vec_pExpr *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_pStmt_init(Vec_pStmt *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pStmt_reserve(Vec_pStmt *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(Stmt *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pStmt_push(Vec_pStmt *self, Stmt *item) {
    Vec_pStmt_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

Stmt *Vec_pStmt_pop(Vec_pStmt *self) {
    self->len -= 1;
    return self->data[self->len];
}

Stmt *Vec_pStmt_get(Vec_pStmt *self, int32_t i) {
    return self->data[i];
}

void Vec_pStmt_set(Vec_pStmt *self, int32_t i, Stmt *item) {
    self->data[i] = item;
}

Stmt *Vec_pStmt_last(Vec_pStmt *self) {
    return self->data[self->len - 1];
}

int Vec_pStmt_is_empty(Vec_pStmt *self) {
    return self->len == 0;
}

void Vec_pStmt_remove_at(Vec_pStmt *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(Stmt *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pStmt_swap_remove(Vec_pStmt *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pStmt_clear(Vec_pStmt *self) {
    self->len = 0;
}

void Vec_pStmt_deinit(Vec_pStmt *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_pBlock_init(Vec_pBlock *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pBlock_reserve(Vec_pBlock *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(Block *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pBlock_push(Vec_pBlock *self, Block *item) {
    Vec_pBlock_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

Block *Vec_pBlock_pop(Vec_pBlock *self) {
    self->len -= 1;
    return self->data[self->len];
}

Block *Vec_pBlock_get(Vec_pBlock *self, int32_t i) {
    return self->data[i];
}

void Vec_pBlock_set(Vec_pBlock *self, int32_t i, Block *item) {
    self->data[i] = item;
}

Block *Vec_pBlock_last(Vec_pBlock *self) {
    return self->data[self->len - 1];
}

int Vec_pBlock_is_empty(Vec_pBlock *self) {
    return self->len == 0;
}

void Vec_pBlock_remove_at(Vec_pBlock *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(Block *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pBlock_swap_remove(Vec_pBlock *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pBlock_clear(Vec_pBlock *self) {
    self->len = 0;
}

void Vec_pBlock_deinit(Vec_pBlock *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_pDecl_init(Vec_pDecl *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pDecl_reserve(Vec_pDecl *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(Decl *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pDecl_push(Vec_pDecl *self, Decl *item) {
    Vec_pDecl_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

Decl *Vec_pDecl_pop(Vec_pDecl *self) {
    self->len -= 1;
    return self->data[self->len];
}

Decl *Vec_pDecl_get(Vec_pDecl *self, int32_t i) {
    return self->data[i];
}

void Vec_pDecl_set(Vec_pDecl *self, int32_t i, Decl *item) {
    self->data[i] = item;
}

Decl *Vec_pDecl_last(Vec_pDecl *self) {
    return self->data[self->len - 1];
}

int Vec_pDecl_is_empty(Vec_pDecl *self) {
    return self->len == 0;
}

void Vec_pDecl_remove_at(Vec_pDecl *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(Decl *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pDecl_swap_remove(Vec_pDecl *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pDecl_clear(Vec_pDecl *self) {
    self->len = 0;
}

void Vec_pDecl_deinit(Vec_pDecl *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_pType_init(Vec_pType *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pType_reserve(Vec_pType *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(Type *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pType_push(Vec_pType *self, Type *item) {
    Vec_pType_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

Type *Vec_pType_pop(Vec_pType *self) {
    self->len -= 1;
    return self->data[self->len];
}

Type *Vec_pType_get(Vec_pType *self, int32_t i) {
    return self->data[i];
}

void Vec_pType_set(Vec_pType *self, int32_t i, Type *item) {
    self->data[i] = item;
}

Type *Vec_pType_last(Vec_pType *self) {
    return self->data[self->len - 1];
}

int Vec_pType_is_empty(Vec_pType *self) {
    return self->len == 0;
}

void Vec_pType_remove_at(Vec_pType *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(Type *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pType_swap_remove(Vec_pType *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pType_clear(Vec_pType *self) {
    self->len = 0;
}

void Vec_pType_deinit(Vec_pType *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_pFunc_init(Vec_pFunc *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pFunc_reserve(Vec_pFunc *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(Func *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pFunc_push(Vec_pFunc *self, Func *item) {
    Vec_pFunc_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

Func *Vec_pFunc_pop(Vec_pFunc *self) {
    self->len -= 1;
    return self->data[self->len];
}

Func *Vec_pFunc_get(Vec_pFunc *self, int32_t i) {
    return self->data[i];
}

void Vec_pFunc_set(Vec_pFunc *self, int32_t i, Func *item) {
    self->data[i] = item;
}

Func *Vec_pFunc_last(Vec_pFunc *self) {
    return self->data[self->len - 1];
}

int Vec_pFunc_is_empty(Vec_pFunc *self) {
    return self->len == 0;
}

void Vec_pFunc_remove_at(Vec_pFunc *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(Func *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pFunc_swap_remove(Vec_pFunc *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pFunc_clear(Vec_pFunc *self) {
    self->len = 0;
}

void Vec_pFunc_deinit(Vec_pFunc *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_pMatchCase_init(Vec_pMatchCase *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pMatchCase_reserve(Vec_pMatchCase *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(MatchCase *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pMatchCase_push(Vec_pMatchCase *self, MatchCase *item) {
    Vec_pMatchCase_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

MatchCase *Vec_pMatchCase_pop(Vec_pMatchCase *self) {
    self->len -= 1;
    return self->data[self->len];
}

MatchCase *Vec_pMatchCase_get(Vec_pMatchCase *self, int32_t i) {
    return self->data[i];
}

void Vec_pMatchCase_set(Vec_pMatchCase *self, int32_t i, MatchCase *item) {
    self->data[i] = item;
}

MatchCase *Vec_pMatchCase_last(Vec_pMatchCase *self) {
    return self->data[self->len - 1];
}

int Vec_pMatchCase_is_empty(Vec_pMatchCase *self) {
    return self->len == 0;
}

void Vec_pMatchCase_remove_at(Vec_pMatchCase *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(MatchCase *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pMatchCase_swap_remove(Vec_pMatchCase *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pMatchCase_clear(Vec_pMatchCase *self) {
    self->len = 0;
}

void Vec_pMatchCase_deinit(Vec_pMatchCase *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_pchar_init(Vec_pchar *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_pchar_reserve(Vec_pchar *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(char *) * (size_t)nc);
    self->cap = nc;
}

void Vec_pchar_push(Vec_pchar *self, char *item) {
    Vec_pchar_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

char *Vec_pchar_pop(Vec_pchar *self) {
    self->len -= 1;
    return self->data[self->len];
}

char *Vec_pchar_get(Vec_pchar *self, int32_t i) {
    return self->data[i];
}

void Vec_pchar_set(Vec_pchar *self, int32_t i, char *item) {
    self->data[i] = item;
}

char *Vec_pchar_last(Vec_pchar *self) {
    return self->data[self->len - 1];
}

int Vec_pchar_is_empty(Vec_pchar *self) {
    return self->len == 0;
}

void Vec_pchar_remove_at(Vec_pchar *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(char *) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_pchar_swap_remove(Vec_pchar *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_pchar_clear(Vec_pchar *self) {
    self->len = 0;
}

void Vec_pchar_deinit(Vec_pchar *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_Param_init(Vec_Param *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_Param_reserve(Vec_Param *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(Param) * (size_t)nc);
    self->cap = nc;
}

void Vec_Param_push(Vec_Param *self, Param item) {
    Vec_Param_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

Param Vec_Param_pop(Vec_Param *self) {
    self->len -= 1;
    return self->data[self->len];
}

Param Vec_Param_get(Vec_Param *self, int32_t i) {
    return self->data[i];
}

void Vec_Param_set(Vec_Param *self, int32_t i, Param item) {
    self->data[i] = item;
}

Param Vec_Param_last(Vec_Param *self) {
    return self->data[self->len - 1];
}

int Vec_Param_is_empty(Vec_Param *self) {
    return self->len == 0;
}

void Vec_Param_remove_at(Vec_Param *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(Param) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_Param_swap_remove(Vec_Param *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_Param_clear(Vec_Param *self) {
    self->len = 0;
}

void Vec_Param_deinit(Vec_Param *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_Field_init(Vec_Field *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_Field_reserve(Vec_Field *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(Field) * (size_t)nc);
    self->cap = nc;
}

void Vec_Field_push(Vec_Field *self, Field item) {
    Vec_Field_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

Field Vec_Field_pop(Vec_Field *self) {
    self->len -= 1;
    return self->data[self->len];
}

Field Vec_Field_get(Vec_Field *self, int32_t i) {
    return self->data[i];
}

void Vec_Field_set(Vec_Field *self, int32_t i, Field item) {
    self->data[i] = item;
}

Field Vec_Field_last(Vec_Field *self) {
    return self->data[self->len - 1];
}

int Vec_Field_is_empty(Vec_Field *self) {
    return self->len == 0;
}

void Vec_Field_remove_at(Vec_Field *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(Field) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_Field_swap_remove(Vec_Field *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_Field_clear(Vec_Field *self) {
    self->len = 0;
}

void Vec_Field_deinit(Vec_Field *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}


void Vec_EnumItem_init(Vec_EnumItem *self) {
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}

void Vec_EnumItem_reserve(Vec_EnumItem *self, int32_t n) {
    if (n <= self->cap) {
        return;
    }
    int32_t nc = (self->cap == 0 ? 8 : self->cap);
    while (nc < n) {
        nc *= 2;
    }
    self->data = realloc(self->data, sizeof(EnumItem) * (size_t)nc);
    self->cap = nc;
}

void Vec_EnumItem_push(Vec_EnumItem *self, EnumItem item) {
    Vec_EnumItem_reserve(self, self->len + 1);
    self->data[self->len] = item;
    self->len += 1;
}

EnumItem Vec_EnumItem_pop(Vec_EnumItem *self) {
    self->len -= 1;
    return self->data[self->len];
}

EnumItem Vec_EnumItem_get(Vec_EnumItem *self, int32_t i) {
    return self->data[i];
}

void Vec_EnumItem_set(Vec_EnumItem *self, int32_t i, EnumItem item) {
    self->data[i] = item;
}

EnumItem Vec_EnumItem_last(Vec_EnumItem *self) {
    return self->data[self->len - 1];
}

int Vec_EnumItem_is_empty(Vec_EnumItem *self) {
    return self->len == 0;
}

void Vec_EnumItem_remove_at(Vec_EnumItem *self, int32_t i) {
    memmove(&self->data[i], &self->data[i + 1], sizeof(EnumItem) * (size_t)(self->len - i - 1));
    self->len -= 1;
}

void Vec_EnumItem_swap_remove(Vec_EnumItem *self, int32_t i) {
    self->len -= 1;
    self->data[i] = self->data[self->len];
}

void Vec_EnumItem_clear(Vec_EnumItem *self) {
    self->len = 0;
}

void Vec_EnumItem_deinit(Vec_EnumItem *self) {
    free(self->data);
    self->data = NULL;
    self->len = 0;
    self->cap = 0;
}
