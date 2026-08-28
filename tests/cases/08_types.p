# aliases de largura fixa: i8..i64, u8..u64, f32/f64, usize
# (o #include <stdint.h> deve entrar sozinho no C gerado)
include <stdio.h>

def soma(a: i32, b: i32) -> i64:
    return i64(a) + i64(b)

# sem '->' = void
def cabecalho(titulo: *char):
    printf("== %s ==\n", titulo)

def main() -> int:
    cabecalho("tipos")
    x: u8 = 200
    y: u8 = 100
    z: u16 = u16(x) + u16(y)
    printf("%u\n", z)

    f: f32 = 1.5
    d: f64 = f64(f) * 2
    printf("%.1f\n", d)

    n: usize = sizeof(i64)
    printf("%zu\n", n)

    printf("%ld\n", long(soma(2000000000, 2000000000)))

    v: u32[3] = {1, 2, 3}
    p: *u32 = &v[0]
    printf("%u\n", *p + v[2])
    return 0
