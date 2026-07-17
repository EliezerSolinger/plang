#pragma once

#include <stdint.h>

#include "plang.h"
#include "ast.h"

typedef struct Cc Cc;

struct Cc {
    Arena arena;
    Module **mods;
    int32_t nmods;
    int32_t cmods;
    char **defines;
    int32_t ndefines;
    const char *backend_name;
    int32_t std_version;
};

Module *cc_load_module(Cc *cc, const char *path);

void sema_run(Cc *cc, Module *m);
