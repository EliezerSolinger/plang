# cstr.ph — `CStr` e `CBytes`: um PONTEIRO E O TAMANHO DELE, como valor.
#
# O P não tinha tipo de texto: tinha `const *char`, e por isso não tinha
# alocação escondida — não existe operação de string que possa alocar (`a + b`
# entre ponteiros é erro, `==` compara por `strcmp`, e fabricar texto é
# `snprintf` no seu buffer ou o `Str` deste mesmo diretório, cujo `realloc`
# está dentro de uma função que você chamou).
#
# Estes dois preservam essa propriedade inteira: são valores do tamanho de dois
# registradores que **nunca alocam nada**. O que eles trazem é o TAMANHO junto
# com o ponteiro — sem `strlen`, sem exigir terminador, e com fatia de graça.
#
# O que eles NÃO são: donos. Ninguém libera um `CStr`; ele aponta para bytes de
# outra pessoa — um literal, um buffer seu, um `Str` construído, os bytes de um
# `str` do pscript durante uma chamada. Por isso o compilador os deixa viver
# apenas como PARÂMETRO, LOCAL e RETORNO (84.2, a mesma regra do `ref T` da
# 69): assim nenhum deles sobrevive por acidente ao escopo que o criou.
#
# Para a libc, o idioma é `%.*s`, que é o jeito certo em C e não pede
# terminador:
#
#     printf("%.*s\n", i32(s.len), s.ptr)
#
# `CStr` promete texto e `CBytes` não promete nada; por dentro são o mesmo par.
# A separação existe para que a ASSINATURA diga a intenção (85.2).
include <string.h>

struct CStr:
    ptr: const *char
    len: usize

    def at(in self: CStr, i: usize) -> char:
        return self.ptr[i]

    # uma fatia é outro par apontando para dentro do mesmo lugar: não copia, não
    # aloca, e não termina em NUL — que é justamente o que o tamanho resolve
    def slice(in self: CStr, from: usize, to: usize) -> CStr:
        a: usize = from if from < self.len else self.len
        b: usize = to if to < self.len else self.len
        r: CStr = {self.ptr + a, b - a if b > a else usize(0)}
        return r

    def eq(in self: CStr, in other: CStr) -> bool:
        return self.len == other.len and (self.len == 0 or memcmp(self.ptr, other.ptr, self.len) == 0)

    def starts_with(in self: CStr, in p: CStr) -> bool:
        return self.len >= p.len and (p.len == 0 or memcmp(self.ptr, p.ptr, p.len) == 0)

    # o índice do primeiro `c`, ou o tamanho quando não há — a convenção que
    # deixa `slice(0, find(c))` funcionar sem um teste antes
    def find(in self: CStr, c: char) -> usize:
        i: usize = 0
        while i < self.len:
            if self.ptr[i] == c:
                return i
            i += 1
        return self.len

struct CBytes:
    ptr: const *u8
    len: usize

    def at(in self: CBytes, i: usize) -> u8:
        return self.ptr[i]

    def slice(in self: CBytes, from: usize, to: usize) -> CBytes:
        a: usize = from if from < self.len else self.len
        b: usize = to if to < self.len else self.len
        r: CBytes = {self.ptr + a, b - a if b > a else usize(0)}
        return r

    def eq(in self: CBytes, in other: CBytes) -> bool:
        return self.len == other.len and (self.len == 0 or memcmp(self.ptr, other.ptr, self.len) == 0)

# O literal já sabe o próprio tamanho em tempo de compilação (o compilador
# dobra o `strlen`); estas duas são para quando o texto vem de um ponteiro que
# não sabe. `static inline` porque um par de campos não merece uma chamada.
static inline def cstr(s: const *char) -> CStr:
    r: CStr = {s, strlen(s)}
    return r

static inline def cstr_n(s: const *char, n: usize) -> CStr:
    r: CStr = {s, n}
    return r

static inline def cbytes(p: const *u8, n: usize) -> CBytes:
    r: CBytes = {p, n}
    return r
