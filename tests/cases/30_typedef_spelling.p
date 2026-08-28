# A C-header typedef of a TAG (`FILE` is `struct _IO_FILE` on glibc,
# `struct __sFILE` on macOS) must be emitted with the TYPEDEF's name, not the
# tag's. Sema canonicalizes the type onto the tag on purpose — that is how both
# backends learn the layout — but the tag is a libc INTERNAL, so printing it
# makes the generated C specific to one libc.
#
# It broke the macOS build outright: the compiler prototypes popen/pclose itself
# (<stdio.h> hides them under strict -std=c11), and those prototypes came out
# saying `struct _IO_FILE *`, which conflicts with the system header's `FILE *`.
# Reproducible on glibc too, with -std=gnu11 (which makes <stdio.h> declare
# popen): "static declaration of 'popen' follows non-static declaration".
#
# So: the generated C must contain `FILE`, and never `_IO_FILE`. Round-tripped C
# keeps the tag instead — its input was preprocessed, so the typedef is not in
# the output to refer to.
include <stdio.h>

# a by-value use, a pointer use and a function-pointer use: all three go through
# the type printer, so all three must spell the typedef
def write_v(f: *FILE, msg: const *char) -> int:
    return fprintf(f, "%s\n", msg)

fpp: def(f: *FILE, fmt: const *char, ...) -> int = &fprintf

def main() -> i32:
    f: *FILE = stdout
    write_v(f, "typedef")
    fpp(stdout, "%s\n", "ponteiro")
    printf("%d\n", 1 if f != None else 0)
    return 0
