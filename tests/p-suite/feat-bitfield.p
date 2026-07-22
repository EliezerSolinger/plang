include <stdio.h>

# Campos de bit: `nome: tipo : largura`. Empacotamento SysV (bitfields
# consecutivos compartilham a unidade do tipo); `_: tipo : 0` fecha a unidade.

struct Flags:
    a: u32 : 3
    b: u32 : 5
    c: u32 : 1
    d: i32 : 4

struct Split:
    x: u32 : 4
    _: u32 : 0     # força nova unidade para y
    y: u32 : 4

def main() -> i32:
    f: Flags
    f.a = 5
    f.b = 20
    f.c = 1
    f.d = -3
    printf("a=%u b=%u c=%u d=%d sz=%zu\n", f.a, f.b, f.c, f.d, sizeof(Flags))
    s: Split
    s.x = 9
    s.y = 12
    printf("x=%u y=%u sz=%zu\n", s.x, s.y, sizeof(Split))
    return 0
