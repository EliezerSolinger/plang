# A static table whose fields name module-level `const`s built from constant
# EXPRESSIONS. The C backend just emits the name and lets C resolve it; the QBE
# backend has no preprocessor, so it has to FOLD the const itself — and it used
# to fail and fall back to zero-filling the whole table SILENTLY. That produced
# a compiler whose own `backends[]` table was all zeros, so it could not find its
# own backends. The fold now works, and a genuinely unfoldable initializer is a
# hard error instead of quiet zeros.
include <stdio.h>

enum Flag:
    F_A
    F_B
    F_C

MASK_AB: const u64 = (1 << F_A) | (1 << F_B)
MASK_C: const u64 = 1 << F_C
WIDTH: const i32 = 4 * 2

struct Entry:
    name: const *char
    mask: u64
    width: i32
    on: bool
    next: *Entry          # a null pointer constant is a constant zero

table: Entry[] = {{"ab", MASK_AB, WIDTH, True, None},
                  {"c", MASK_C, WIDTH * 2, False, None},
                  {None, 0, 0, False, None}}

def main() -> i32:
    i: i32 = 0
    while table[i].name != None:
        printf("%s mask=%llu width=%d on=%d next=%d\n", table[i].name,
               table[i].mask, table[i].width, 1 if table[i].on else 0,
               1 if table[i].next == None else 0)
        i += 1
    printf("rows=%d\n", i)
    return 0
