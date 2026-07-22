include <stdio.h>

def main() -> int:
    s: short
    i: int
    l: long
    ll: long long
    p: *void
    if sizeof(s) == 2 and sizeof(i) == 4 and sizeof(l) == 8 and sizeof(ll) == 8 and sizeof(p) == 8:
        printf("Ok\n")
    else:
        printf("KO __LP64__\n")
    return 0
