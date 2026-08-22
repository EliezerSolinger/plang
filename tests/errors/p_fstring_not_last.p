# the holes BECOME the arguments after the format, so anything written after the
# f-string would land in the middle of them.
include <stdio.h>
def main() -> i32:
    n: i32 = 1
    printf(f"{n}", 1)
    return 0
