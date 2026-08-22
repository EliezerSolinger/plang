# 65.2: an f-string is a FORMAT. Outside a variadic call there is nothing for it
# to expand into, and P has no runtime that could build a string instead.
include <stdio.h>
def main() -> i32:
    n: i32 = 1
    s: const *char = f"{n}"
    printf("%s\n", s)
    return 0
