# `puts` takes one `const *char` and is not variadic: the holes would have
# nowhere to go.
include <stdio.h>
def main() -> i32:
    n: i32 = 1
    puts(f"{n}")
    return 0
