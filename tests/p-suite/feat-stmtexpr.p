include <stdio.h>

# statement expression GNU (forma só-expressão: portável ao backend C via
# operador vírgula; o backend QBE aceita também declarações/controle)
def main() -> i32:
    x: i32 = ({ 1 + 2; 10 * 4 })
    y: i32 = ({ 42 })
    printf("x=%d y=%d\n", x, y)
    return 0
