# A literal containing `??X` is a TRIGRAPH in any strictly conforming C mode,
# and trigraphs are replaced in translation phase 1 — before escape sequences
# are read. So `"??'"` would silently become `"^"` in the generated C.
#
# The compiler found this in its own diagnostics: `"'??' takes an option"` was
# printing as `'^ takes an option`.
include <stdio.h>
include <string.h>

def main() -> int:
    a: const *char = "'??' is the coalescing operator"
    b: const *char = "??/ ??( ??) ??< ??> ??= ??! ??-"
    printf("%s\n", a)
    printf("%s\n", b)
    printf("%zu %zu\n", strlen(a), strlen(b))
    return 0
