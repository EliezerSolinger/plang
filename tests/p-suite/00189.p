include <stdio.h>

def fred(p: int) -> int:
    printf("yo %d\n", p)
    return 42

f: def(int) -> int = &fred

fprintfptr: def(*FILE, *char, ...) -> int = &fprintf

def main() -> int:
    fprintfptr(stdout, "%d\n", f(24))
    return 0
