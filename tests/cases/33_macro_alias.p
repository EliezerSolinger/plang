# A C header that declares an OBJECT under one name and exposes another via
# `#define NAME OTHER`. See 33_macro_alias.h for why: it is how macOS spells the
# standard streams, and `stderr` there is a macro over `__stderrp` with no object
# named `stderr` anywhere. P sources are not preprocessed, so the macro cannot
# apply itself — sema follows the rename instead.
#
# The generated C names the TARGET (`ma_real_value`), not the macro. That is the
# faithful choice: the alias only fires when this platform has no object under
# the public name, and the emitted `#include` declares the target, so it is also
# exactly what cpp would have produced.
include <stdio.h>
include "33_macro_alias.h"

# provides the objects the header declares
ma_real_value: i32 = 41

def ma_real_fn(x: i32) -> i32:
    return x * 2

def main() -> i32:
    # through the macro name: an object, a function, and a CHAINED alias
    printf("%d %d %d\n", ma_value, ma_fn(10), ma_value2)
    # an alias to an integer constant still folds as a constant (comptime), so it
    # is usable where only a constant is allowed — an array dimension
    buf: i32[MA_LIMIT_ALIAS]
    buf[MA_LIMIT_ALIAS - 1] = 5
    printf("%d %d\n", i32(len(buf)), buf[6])
    return 0
