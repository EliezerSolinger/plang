include <stdio.h>

# is_defined(NOME): 1 se NOME é uma const conhecida em compile-time, 0 senão.
# Alimenta a poda de branch (#ifdef). Consts -D do driver contam como definidas.

const KNOWN = 7

def main() -> i32:
    if is_defined(KNOWN):
        printf("known=%d\n", KNOWN)
    if is_defined(NOPE):
        printf("tem nope\n")     # branch morta (NOPE indefinido): podada
    else:
        printf("sem nope\n")
    return 0
