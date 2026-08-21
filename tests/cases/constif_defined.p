# `defined(NOME)` num `const if` de topo (110): o nome AUSENTE é falso, e é isso
# que permite "use o valor de fora, senão o padrão". O nome NU segue estrito, que
# é o que pega um predefinido escrito errado.
include <stdio.h>

const if defined(MEU_TETO):
    const TETO = MEU_TETO
else:
    const TETO = 42

const if is_defined(OUTRO_NOME):
    const SEG = OUTRO_NOME
else:
    const SEG = 7

def main() -> int:
    printf("%d %d\n", TETO, SEG)
    return 0
