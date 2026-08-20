# `const if` (99): a condição é constante, e o ramo NÃO tomado não é checado.
#
# É o que destrava escrever dois caminhos de plataforma no mesmo arquivo — um
# deles nomeia símbolo que o outro sistema não tem, e checar os dois seria
# impossível. O `if` comum já dobrava condição constante e já checava só o ramo
# vivo; o que `const if` acrescenta é a GARANTIA: sem ela, um erro de digitação
# na condição a torna de runtime, e aí os dois lados precisam compilar.
#
# No topo do arquivo (99.2) ele guarda DECLARAÇÃO, inclusive `include` — o header
# da outra plataforma não existe, então nem pode ser lido. Este teste prova isso
# de verdade: cada ramo inclui o header do seu sistema e chama a API que só
# existe nele.
#
# A saída é a MESMA nas duas plataformas de propósito: um teste de plataforma que
# só passa numa é um teste que a outra não roda.
include <stdio.h>

const if __PLANG_LINUX__:
    include <sys/epoll.h>

    def mux_open() -> i32:
        return epoll_create1(0)
elif __PLANG_OS__ == "macos":
    include <sys/event.h>

    def mux_open() -> i32:
        return kqueue()
else:
    def mux_open() -> i32:
        return -2

# dentro de função: este ramo está morto nas DUAS plataformas, e é onde se vê que
# um ramo morto pode nomear o que não existe em lugar nenhum
def dead_branch_is_not_checked() -> i32:
    const if __PLANG_OS__ == "nowhere":
        return this_function_exists_nowhere()
    else:
        return 7

# `and`, `or`, `not` e a comparação com o nome do sistema, todos numa condição
const if __PLANG_LINUX__ or __PLANG_MACOS__ or __PLANG_BSD__ or __PLANG_OS__ == "other":
    def operators() -> i32:
        return 1 if not (__PLANG_OS__ == "nowhere") else 0
else:
    def operators() -> i32:
        return 0

def main() -> int:
    fd: i32 = mux_open()
    printf("mux=%d dead=%d ops=%d\n", 1 if fd >= 0 else 0, dead_branch_is_not_checked(), operators())
    return 0
