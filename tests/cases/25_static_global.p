# `static` on a module-level global keeps the symbol TU-local (without it two
# modules with a table of the same name collide at link time)
include <stdio.h>

static table: const *char[] = {"alpha", "beta", None}
static counter: i32 = 7

def main() -> i32:
    printf("%s %s %d\n", table[0], table[1], counter)
    return 0
