include <stdio.h>
include <string.h>

# Constantes/identificadores pré-definidos (estilo C, resolvidos na sema):
# __FILE__ __LINE__ __func__ __COUNTER__ (posicionais) e __DATE__ __TIME__
# __PLANG__ __PLANG_VERSION__ __PLANG_BACKEND__ (injetadas). Tudo dobra para
# literal — nenhum símbolo é emitido.

struct Point:
    x: i32

    def tag(self: *Point) -> const *char:
        return __func__          # cname do método: "Point_tag"

def helper() -> const *char:
    return __func__

def main() -> i32:
    printf("func=%s helper=%s\n", __func__, helper())
    p: Point
    printf("method=%s\n", p.tag())
    printf("line=%d\n", __LINE__)
    printf("file_ok=%d\n", strstr(__FILE__, "feat-predefined") != None)
    printf("date_len=%zu time_len=%zu\n", strlen(__DATE__), strlen(__TIME__))
    printf("counter=%d,%d,%d\n", __COUNTER__, __COUNTER__, __COUNTER__)
    printf("plang=%d version=%s\n", __PLANG__, __PLANG_VERSION__)
    printf("backend_defined=%d nonempty=%d\n", is_defined(__PLANG_BACKEND__), strlen(__PLANG_BACKEND__) > 0)
    if __PLANG_VERSION__ == "0.6":   # comparação de string em compile-time (poda)
        printf("v06\n")
    return 0
