include <stdio.h>
include <string.h>

def canon(n: const *char) -> const *char:
    match n:
        case "float", "f32":
            return "float"
        case "double", "f64":
            return "double"
        case _:
            return n

def area(w: i32, h: i32 = 10, scale: i32 = 1) -> i32:
    return w * h * scale

def next_tok(s: const *char, i: i32) -> char:
    return s[i]

def main() -> int:
    # match de strings
    printf("%s %s %s\n", canon("f32"), canon("f64"), canon("int"))
    # == de conteúdo com literal
    t: const *char = "float"
    if t == "float":
        printf("eq-conteudo\n")
    if t != "double":
        printf("ne-conteudo\n")
    # walrus
    i: i32 = 0
    src: const *char = "ab"
    while (c := next_tok(src, i)) != '\0':
        printf("%c", c)
        i += 1
    printf("\n")
    # defaults + nomeados
    printf("%d %d %d %d\n", area(2), area(2, 3), area(2, scale=5), area(2, h=4, scale=2))
    return 0
