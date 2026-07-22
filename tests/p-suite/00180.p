include <stdio.h>
include <string.h>

def main() -> int:
    a: char[10]
    strcpy(a, "abcdef")
    printf("%s\n", &a[1])

    return 0
