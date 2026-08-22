# P's f-string IS a printf format: what printf cannot do, it cannot do.
include <stdio.h>
def main() -> i32:
    n: i32 = 1
    printf(f"{n:^5}\n")
    return 0
