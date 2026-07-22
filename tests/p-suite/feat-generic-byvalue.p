include <stdio.h>

# Struct genérica com um campo de tipo T POR VALOR (tamanho depende da
# instância). Regressão: a monomorfização precisa copiar bit_width (=-1) dos
# campos, senão o layout QBE trata o campo como bitfield de largura 0 e o
# colapsa no offset 0.

struct Box<T>:
    v: T
    tag: i32

    def setup(self: *Box<T>, val: T):
        with self:
            .v = val
            .tag = 7

declare Box<i32>
implement Box<i32>
declare Box<f64>
implement Box<f64>

def main() -> i32:
    a: Box<i32>
    a.setup(42)
    printf("i32: v=%d tag=%d\n", a.v, a.tag)
    b: Box<f64>
    b.setup(3.5)
    printf("f64: v=%g tag=%d\n", b.v, b.tag)
    return 0
