include <stdio.h>

t: char[] = "012345678"

def main() -> int:
    data: *char = t
    r: u64 = 4
    a: unsigned = 5
    b: u64 = 12

    *(*unsigned)(data + r) += a - b

    printf("data = \"%s\"\n", data)
    return 0
