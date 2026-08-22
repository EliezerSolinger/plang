# `0o`, `0b` e o separador `_`: a base escreve-se, não se adivinha.
#
# Em C um zero à esquerda é octal e ninguém o vê; aqui `0755` é erro e o octal
# tem prefixo. O texto do token é normalizado para DECIMAL no lexer, então o C
# gerado e o QBE recebem o mesmo número — e o `0b`, que não é C, nunca chega lá.
include <stdio.h>

def main() -> int:
    printf("%d %d %d\n", 0o755, 0o0, 0o7777)
    printf("%d %d %d\n", 0b1010, 0b0, 0b1111_1111)
    printf("%d %d\n", 0xff_ff, 1_000_000)
    printf("%d\n", 1 if 0o644 == 420 and 0b11 == 3 else 0)
    return 0
