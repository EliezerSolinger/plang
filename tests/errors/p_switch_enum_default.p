# -Wswitch-enum: the same hole, but the `match` HAS a `case _:`. Clang keeps
# this group OFF by default and out of -Wall, and we keep that split: with a
# catch-all the match is total, so it is only worth reporting when you ask.
#
# It is worth asking at a dispatch over an AST node kind, where the catch-all
# exists for the kinds that need no work and a NEW kind must still be
# considered. plangc's own sources are clean under plain -Wswitch (the
# load-bearing dispatches carry no catch-all on purpose) — this test pins the
# behaviour of the opt-in group, including clang's different wording
# ("not EXPLICITLY handled") when a default is present.
include <stdio.h>

enum Cor:
    VERMELHO
    VERDE
    AZUL
    ROXO

def nome(c: Cor) -> const *char:
    match c:
        case VERMELHO:
            return "vermelho"
        case _:
            return "outro"

def main() -> i32:
    printf("%s\n", nome(AZUL))
    return 0
