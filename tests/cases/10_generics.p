# generics com monomorfização explícita: a struct genérica não vai pro C;
# declare X<T> emite a definição, implement X<T> emite os corpos
include <stdio.h>
include <stdlib.h>

struct Vec<T>:
    data: *T
    len: i32
    cap: i32

    def push(self: *Vec<T>, item: T):
        if self->len >= self->cap:
            novo: i32 = 8 if self->cap == 0 else self->cap * 2
            self->data = realloc(self->data, sizeof(T) * usize(novo))
            self->cap = novo
        self->data[self->len] = item
        self->len += 1

    def get(self: *Vec<T>, i: i32) -> T:
        return self->data[i]

    def pop(self: *Vec<T>) -> T:
        self->len -= 1
        return self->data[self->len]

declare Vec<int>
implement Vec<int>

declare Vec<*char>
implement Vec<*char>

struct Par<A, B>:
    primeiro: A
    segundo: B

    def troca(self: *Par<A, B>) -> B:
        return self->segundo

declare Par<int, *char>
implement Par<int, *char>

def main() -> int:
    v: Vec<int> = {None, 0, 0}
    i: i32
    for i in range(5):
        v.push(i * i)
    printf("%d %d %d\n", v.get(0), v.get(2), v.get(4))
    ultimo: int = v.pop()
    printf("pop=%d len=%d\n", ultimo, v.len)

    s: Vec<*char> = {None, 0, 0}
    s.push("oi")
    s.push("mundo")
    printf("%s %s\n", s.get(0), s.get(1))

    par: Par<int, *char> = {42, "resposta"}
    printf("%d %s\n", par.primeiro, par.troca())

    # nome manglado também é utilizável diretamente
    tam: usize = sizeof(Vec_int)
    printf("%d\n", tam == sizeof(v))

    free(v.data)
    free(s.data)
    return 0
