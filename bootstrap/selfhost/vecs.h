#pragma once

#include <stdint.h>

#include "ast.h"
#include "../stl/vec.h"

typedef struct Vec_pExpr Vec_pExpr;
typedef struct Vec_pStmt Vec_pStmt;
typedef struct Vec_pBlock Vec_pBlock;
typedef struct Vec_pDecl Vec_pDecl;
typedef struct Vec_pType Vec_pType;
typedef struct Vec_pFunc Vec_pFunc;
typedef struct Vec_pMatchCase Vec_pMatchCase;
typedef struct Vec_pchar Vec_pchar;
typedef struct Vec_Param Vec_Param;
typedef struct Vec_Field Vec_Field;
typedef struct Vec_EnumItem Vec_EnumItem;

struct Vec_pExpr {
    Expr **data;
    int32_t len;
    int32_t cap;
};

void Vec_pExpr_init(Vec_pExpr *self);

void Vec_pExpr_reserve(Vec_pExpr *self, int32_t n);

void Vec_pExpr_push(Vec_pExpr *self, Expr *item);

Expr *Vec_pExpr_pop(Vec_pExpr *self);

Expr *Vec_pExpr_get(Vec_pExpr *self, int32_t i);

void Vec_pExpr_set(Vec_pExpr *self, int32_t i, Expr *item);

Expr *Vec_pExpr_last(Vec_pExpr *self);

int Vec_pExpr_is_empty(Vec_pExpr *self);

void Vec_pExpr_remove_at(Vec_pExpr *self, int32_t i);

void Vec_pExpr_swap_remove(Vec_pExpr *self, int32_t i);

void Vec_pExpr_clear(Vec_pExpr *self);

void Vec_pExpr_deinit(Vec_pExpr *self);

struct Vec_pStmt {
    Stmt **data;
    int32_t len;
    int32_t cap;
};

void Vec_pStmt_init(Vec_pStmt *self);

void Vec_pStmt_reserve(Vec_pStmt *self, int32_t n);

void Vec_pStmt_push(Vec_pStmt *self, Stmt *item);

Stmt *Vec_pStmt_pop(Vec_pStmt *self);

Stmt *Vec_pStmt_get(Vec_pStmt *self, int32_t i);

void Vec_pStmt_set(Vec_pStmt *self, int32_t i, Stmt *item);

Stmt *Vec_pStmt_last(Vec_pStmt *self);

int Vec_pStmt_is_empty(Vec_pStmt *self);

void Vec_pStmt_remove_at(Vec_pStmt *self, int32_t i);

void Vec_pStmt_swap_remove(Vec_pStmt *self, int32_t i);

void Vec_pStmt_clear(Vec_pStmt *self);

void Vec_pStmt_deinit(Vec_pStmt *self);

struct Vec_pBlock {
    Block **data;
    int32_t len;
    int32_t cap;
};

void Vec_pBlock_init(Vec_pBlock *self);

void Vec_pBlock_reserve(Vec_pBlock *self, int32_t n);

void Vec_pBlock_push(Vec_pBlock *self, Block *item);

Block *Vec_pBlock_pop(Vec_pBlock *self);

Block *Vec_pBlock_get(Vec_pBlock *self, int32_t i);

void Vec_pBlock_set(Vec_pBlock *self, int32_t i, Block *item);

Block *Vec_pBlock_last(Vec_pBlock *self);

int Vec_pBlock_is_empty(Vec_pBlock *self);

void Vec_pBlock_remove_at(Vec_pBlock *self, int32_t i);

void Vec_pBlock_swap_remove(Vec_pBlock *self, int32_t i);

void Vec_pBlock_clear(Vec_pBlock *self);

void Vec_pBlock_deinit(Vec_pBlock *self);

struct Vec_pDecl {
    Decl **data;
    int32_t len;
    int32_t cap;
};

void Vec_pDecl_init(Vec_pDecl *self);

void Vec_pDecl_reserve(Vec_pDecl *self, int32_t n);

void Vec_pDecl_push(Vec_pDecl *self, Decl *item);

Decl *Vec_pDecl_pop(Vec_pDecl *self);

Decl *Vec_pDecl_get(Vec_pDecl *self, int32_t i);

void Vec_pDecl_set(Vec_pDecl *self, int32_t i, Decl *item);

Decl *Vec_pDecl_last(Vec_pDecl *self);

int Vec_pDecl_is_empty(Vec_pDecl *self);

void Vec_pDecl_remove_at(Vec_pDecl *self, int32_t i);

void Vec_pDecl_swap_remove(Vec_pDecl *self, int32_t i);

void Vec_pDecl_clear(Vec_pDecl *self);

void Vec_pDecl_deinit(Vec_pDecl *self);

struct Vec_pType {
    Type **data;
    int32_t len;
    int32_t cap;
};

void Vec_pType_init(Vec_pType *self);

void Vec_pType_reserve(Vec_pType *self, int32_t n);

void Vec_pType_push(Vec_pType *self, Type *item);

Type *Vec_pType_pop(Vec_pType *self);

Type *Vec_pType_get(Vec_pType *self, int32_t i);

void Vec_pType_set(Vec_pType *self, int32_t i, Type *item);

Type *Vec_pType_last(Vec_pType *self);

int Vec_pType_is_empty(Vec_pType *self);

void Vec_pType_remove_at(Vec_pType *self, int32_t i);

void Vec_pType_swap_remove(Vec_pType *self, int32_t i);

void Vec_pType_clear(Vec_pType *self);

void Vec_pType_deinit(Vec_pType *self);

struct Vec_pFunc {
    Func **data;
    int32_t len;
    int32_t cap;
};

void Vec_pFunc_init(Vec_pFunc *self);

void Vec_pFunc_reserve(Vec_pFunc *self, int32_t n);

void Vec_pFunc_push(Vec_pFunc *self, Func *item);

Func *Vec_pFunc_pop(Vec_pFunc *self);

Func *Vec_pFunc_get(Vec_pFunc *self, int32_t i);

void Vec_pFunc_set(Vec_pFunc *self, int32_t i, Func *item);

Func *Vec_pFunc_last(Vec_pFunc *self);

int Vec_pFunc_is_empty(Vec_pFunc *self);

void Vec_pFunc_remove_at(Vec_pFunc *self, int32_t i);

void Vec_pFunc_swap_remove(Vec_pFunc *self, int32_t i);

void Vec_pFunc_clear(Vec_pFunc *self);

void Vec_pFunc_deinit(Vec_pFunc *self);

struct Vec_pMatchCase {
    MatchCase **data;
    int32_t len;
    int32_t cap;
};

void Vec_pMatchCase_init(Vec_pMatchCase *self);

void Vec_pMatchCase_reserve(Vec_pMatchCase *self, int32_t n);

void Vec_pMatchCase_push(Vec_pMatchCase *self, MatchCase *item);

MatchCase *Vec_pMatchCase_pop(Vec_pMatchCase *self);

MatchCase *Vec_pMatchCase_get(Vec_pMatchCase *self, int32_t i);

void Vec_pMatchCase_set(Vec_pMatchCase *self, int32_t i, MatchCase *item);

MatchCase *Vec_pMatchCase_last(Vec_pMatchCase *self);

int Vec_pMatchCase_is_empty(Vec_pMatchCase *self);

void Vec_pMatchCase_remove_at(Vec_pMatchCase *self, int32_t i);

void Vec_pMatchCase_swap_remove(Vec_pMatchCase *self, int32_t i);

void Vec_pMatchCase_clear(Vec_pMatchCase *self);

void Vec_pMatchCase_deinit(Vec_pMatchCase *self);

struct Vec_pchar {
    char **data;
    int32_t len;
    int32_t cap;
};

void Vec_pchar_init(Vec_pchar *self);

void Vec_pchar_reserve(Vec_pchar *self, int32_t n);

void Vec_pchar_push(Vec_pchar *self, char *item);

char *Vec_pchar_pop(Vec_pchar *self);

char *Vec_pchar_get(Vec_pchar *self, int32_t i);

void Vec_pchar_set(Vec_pchar *self, int32_t i, char *item);

char *Vec_pchar_last(Vec_pchar *self);

int Vec_pchar_is_empty(Vec_pchar *self);

void Vec_pchar_remove_at(Vec_pchar *self, int32_t i);

void Vec_pchar_swap_remove(Vec_pchar *self, int32_t i);

void Vec_pchar_clear(Vec_pchar *self);

void Vec_pchar_deinit(Vec_pchar *self);

struct Vec_Param {
    Param *data;
    int32_t len;
    int32_t cap;
};

void Vec_Param_init(Vec_Param *self);

void Vec_Param_reserve(Vec_Param *self, int32_t n);

void Vec_Param_push(Vec_Param *self, Param item);

Param Vec_Param_pop(Vec_Param *self);

Param Vec_Param_get(Vec_Param *self, int32_t i);

void Vec_Param_set(Vec_Param *self, int32_t i, Param item);

Param Vec_Param_last(Vec_Param *self);

int Vec_Param_is_empty(Vec_Param *self);

void Vec_Param_remove_at(Vec_Param *self, int32_t i);

void Vec_Param_swap_remove(Vec_Param *self, int32_t i);

void Vec_Param_clear(Vec_Param *self);

void Vec_Param_deinit(Vec_Param *self);

struct Vec_Field {
    Field *data;
    int32_t len;
    int32_t cap;
};

void Vec_Field_init(Vec_Field *self);

void Vec_Field_reserve(Vec_Field *self, int32_t n);

void Vec_Field_push(Vec_Field *self, Field item);

Field Vec_Field_pop(Vec_Field *self);

Field Vec_Field_get(Vec_Field *self, int32_t i);

void Vec_Field_set(Vec_Field *self, int32_t i, Field item);

Field Vec_Field_last(Vec_Field *self);

int Vec_Field_is_empty(Vec_Field *self);

void Vec_Field_remove_at(Vec_Field *self, int32_t i);

void Vec_Field_swap_remove(Vec_Field *self, int32_t i);

void Vec_Field_clear(Vec_Field *self);

void Vec_Field_deinit(Vec_Field *self);

struct Vec_EnumItem {
    EnumItem *data;
    int32_t len;
    int32_t cap;
};

void Vec_EnumItem_init(Vec_EnumItem *self);

void Vec_EnumItem_reserve(Vec_EnumItem *self, int32_t n);

void Vec_EnumItem_push(Vec_EnumItem *self, EnumItem item);

EnumItem Vec_EnumItem_pop(Vec_EnumItem *self);

EnumItem Vec_EnumItem_get(Vec_EnumItem *self, int32_t i);

void Vec_EnumItem_set(Vec_EnumItem *self, int32_t i, EnumItem item);

EnumItem Vec_EnumItem_last(Vec_EnumItem *self);

int Vec_EnumItem_is_empty(Vec_EnumItem *self);

void Vec_EnumItem_remove_at(Vec_EnumItem *self, int32_t i);

void Vec_EnumItem_swap_remove(Vec_EnumItem *self, int32_t i);

void Vec_EnumItem_clear(Vec_EnumItem *self);

void Vec_EnumItem_deinit(Vec_EnumItem *self);
