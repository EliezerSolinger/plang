# funções variádicas: '...' no def; va_start/va_end passam verbatim p/ o C
include <stdio.h>
include <stdarg.h>

def logf(nivel: *char, fmt: *char, ...) -> void:
    ap: va_list
    va_start(ap, fmt)
    printf("[%s] ", nivel)
    vprintf(fmt, ap)
    va_end(ap)

def formata(saida: *char, cap: int, fmt: *char, ...) -> int

def formata(saida: *char, cap: int, fmt: *char, ...) -> int:
    ap: va_list
    va_start(ap, fmt)
    n: int = vsnprintf(saida, size_t(cap), fmt, ap)
    va_end(ap)
    return n

def main() -> int:
    logf("info", "x=%d y=%s\n", 42, "oi")
    buf: char[64]
    n: int = formata(buf, 64, "%d+%d=%d", 2, 3, 2 + 3)
    printf("%s (%d chars)\n", buf, n)
    return 0
