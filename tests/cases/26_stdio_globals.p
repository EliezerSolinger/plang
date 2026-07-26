# stderr/stdout/stdin are libc FILE* globals: their VALUE is the loaded pointer
# (QBE class 'l'). The class query used to answer 'w' for them, so the caller
# coerced w->l with `extsw` and handed the callee a pointer truncated to 32 bits
# — every write through it crashed.
include <stdio.h>

def echo(f: *FILE, msg: const *char):
    fputs(msg, f)

def main() -> i32:
    fprintf(stdout, "one\n")      # the global straight into a variadic call
    echo(stdout, "two\n")         # ... and through a typed *FILE parameter
    fprintf(stderr, "ignored\n")  # stderr is discarded by the runner
    fflush(stdout)
    printf("three\n")
    return 0
