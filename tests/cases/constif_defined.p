# `defined(NOME)` num `const if` de topo (110): o nome AUSENTE é falso, e é isso
# que permite "use o valor de fora, senão o padrão". O nome NU segue estrito, que
# é o que pega um predefinido escrito errado.
include <stdio.h>

const if defined(MY_CEILING):
    const CEILING = MY_CEILING
else:
    const CEILING = 42

const if is_defined(OTHER_NAME):
    const SEG = OTHER_NAME
else:
    const SEG = 7

def main() -> int:
    printf("%d %d\n", CEILING, SEG)
    return 0
