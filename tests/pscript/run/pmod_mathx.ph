# mathx.ph — a P module a pscript program may import (75.3/2.4).
#
# What crosses is what 45.5 always allowed: signatures without pointers, the
# members of an enum, and scalar constants. Nothing here knows pscript exists,
# and that is the point — this is ordinary P, compiled by the same compiler,
# and the import is what puts it in the same build.
include <stdio.h>

enum Scale:
    SCALE_ONE = 1
    SCALE_TEN = 10

private const MATHX_BASE: const i32 = 7

def mathx_add(a: i64, b: i64) -> i64
def mathx_scaled(v: i64, s: i32) -> i64
def mathx_is_even(v: i64) -> bool
