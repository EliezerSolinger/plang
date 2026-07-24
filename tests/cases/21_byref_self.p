include <stdio.h>

struct Caixa:
    itens: i32[4]
    n: i32

    def init(out self: Caixa):
        self.n = 0

    def push(ref self: Caixa, v: i32):
        self.itens[self.n] = v
        self.n += 1

    def soma(in self: Caixa) -> i32:
        t: i32 = 0
        for i in range(self.n):
            t += self.itens[i]
        return t

    def copia(self: Caixa) -> i32:     # por valor: recebe uma CÓPIA
        return self.n

def main() -> int:
    c: Caixa
    c.init()                 # out self: inicializa c (definite assignment)
    c.push(10)
    c.push(32)
    printf("%d %d %d\n", c.soma(), c.copia(), c.n)
    return 0
