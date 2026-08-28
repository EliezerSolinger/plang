# Um zero à esquerda é a armadilha que o C tem e uma linguagem de sintaxe Python
# não devia herdar: em C `0755` vale 493 em silêncio. Aqui é ERRO, e a mensagem
# diz como se escreve octal.
include <stdio.h>

def main() -> int:
    mode: int = 0755
    printf("%d\n", mode)
    return 0
