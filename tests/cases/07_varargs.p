# funções variádicas: '...' no def; va_start/va_end passam verbatim p/ o C
include <stdio.h>
include <stdarg.h>

def logf(level: *char, fmt: *char, ...) -> void:
    ap: va_list
    va_start(ap, fmt)
    printf("[%s] ", level)
    vprintf(fmt, ap)
    va_end(ap)

def format_v(out_s: *char, cap: int, fmt: *char, ...) -> int

def format_v(out_s: *char, cap: int, fmt: *char, ...) -> int:
    ap: va_list
    va_start(ap, fmt)
    n: int = vsnprintf(out_s, size_t(cap), fmt, ap)
    va_end(ap)
    return n

def main() -> int:
    logf("info", "x=%d y=%s\n", 42, "oi")
    buf: char[64]
    n: int = format_v(buf, 64, "%d+%d=%d", 2, 3, 2 + 3)
    printf("%s (%d chars)\n", buf, n)
    return 0
