# A typedef from a C header names a type a back end may have to LAY OUT itself.
# `pthread_t` is an `unsigned long`; taking it for four bytes puts every field
# after it at the wrong offset — which is exactly what happened, and what the
# worker control block of the pscript runtime tripped over.
#
# The C back end never has this problem: it prints the typedef and the system
# header answers. This test is here for the ones that do their own layout.
include <stdio.h>
include <pthread.h>

struct Blk:
    a: i32
    t: pthread_t
    b: i32

def main() -> int:
    b: Blk = {1, 0, 2}
    printf("%d %d %d\n", (int)(sizeof(pthread_t)), (int)(sizeof(Blk) >= 16), b.a + b.b)
    return 0
