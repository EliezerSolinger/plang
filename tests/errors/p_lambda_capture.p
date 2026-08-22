# 65.4: no capture. A local of the enclosing function would have to be captured,
# and the message names it so the fix (pass it as a parameter) is obvious.
include <stdio.h>
def main() -> i32:
    n: i32 = 5
    f: def(i32) -> i32 = lambda v: v + n
    printf("%d\n", f(1))
    return 0
