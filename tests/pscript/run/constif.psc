"""`const if` (bateria 99), no pscript.

Mesma construção do P e pela mesma razão: a condição é respondida em compilação e
o ramo NÃO tomado nunca é checado — que é o que permite a um ramo nomear o que só
existe na plataforma dele.

No TOPO ele guarda DECLARAÇÃO (aqui, duas versões da mesma função; num programa
de verdade, o `import` e o `include <h>` que só um sistema tem). Dentro de função
ele é uma instrução, e aí a condição pode ser qualquer coisa que o compilador
saiba: um predefinido, um `is_defined`, um literal.

A saída é a MESMA nas duas plataformas de propósito: teste de plataforma que só
passa numa é teste que a outra não roda.
"""

const if __PLANG_LINUX__:
    def platform_kind() -> str:
        return "posix"

    def is_linux() -> int:
        return 1
elif __PLANG_OS__ == "macos":
    def platform_kind() -> str:
        return "posix"

    def is_linux() -> int:
        return 0
else:
    def platform_kind() -> str:
        return "unknown"

    def is_linux() -> int:
        return 0


# este ramo está morto nas DUAS plataformas, e é onde se vê que um ramo morto
# pode nomear o que não existe em lugar nenhum
def dead_branch_is_not_checked() -> int:
    const if __PLANG_OS__ == "nowhere":
        return this_name_exists_nowhere()
    else:
        return 7


# `is_defined` como condição: o mesmo comptime da 65.11, agora escolhendo código
def picks_by_definedness() -> int:
    const if is_defined(dead_branch_is_not_checked):
        return 1
    else:
        return also_not_a_real_function()


# and / or / not / == numa condição, e o aninhamento
def operators() -> int:
    const if __PLANG_LINUX__ or __PLANG_MACOS__ or __PLANG_BSD__ or __PLANG_OS__ == "other":
        const if not (__PLANG_OS__ == "nowhere"):
            return 3
        else:
            return nope()
    else:
        return 0


print(f"kind {platform_kind()}")
print(f"dead {dead_branch_is_not_checked()} defined {picks_by_definedness()} ops {operators()}")
ispos = 1 if platform_kind() == "posix" else 0
print(f"posix {ispos}")
