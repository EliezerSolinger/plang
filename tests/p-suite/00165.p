include <stdio.h>

# porte de 00165: macro de objeto -> const; macro de função (args constantes)
# -> const def (avaliada em compile-time).
const FRED = 12
const def BLOGGS(x: i32) -> i32:
    return 12 * x

def main() -> i32:
    printf("%d\n", FRED)
    printf("%d, %d, %d\n", BLOGGS(1), BLOGGS(2), BLOGGS(3))
    return 0
