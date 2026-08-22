# `:s` says "format this as a string"; an integer is not one, and there is no
# runtime to make it into one.
include <stdio.h>
def main() -> i32:
    n: i32 = 1
    printf(f"{n:s}\n")
    return 0
