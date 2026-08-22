#pragma once

#include "plang.h"
#include "ast.h"
#include "ps_ast.h"

void api_dump(Module *m, StrBuf *b);

void ps_api_dump(PsModule *m, StrBuf *b);
