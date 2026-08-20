"""A crash that says where it was (12.4).

12.4 divided failure in two: in pscript it is an exception, in C it is a crash —
and added that "crash and debuggable are not opposites". This is that sentence
implemented: a handler for SIGSEGV/SIGBUS/SIGFPE/SIGILL reads the shadow stack,
prints the pscript frames, and then dies exactly as it would have, so the exit
status and the core file are unchanged. It does not catch anything.

The crash itself is a wild write in P, which is where a pointer can be wrong at
all (9.2). Built with `--trace` so every frame has a name — see the `.flags`
file; without it the frames that hold nothing collected are simply not there.

What this CANNOT report is a crash that ran out of stack: the handler would run
on the stack that just overflowed. Reporting that needs an alternate stack,
which needs `sigaction`, whose handler member is a macro over a union spelled
differently on glibc and on macOS — and a macro that is not a number does not
cross the header boundary (72.4).
"""

import "pmod_crash.ph"


def inner(n: int) -> str:
    s = "held across the crash"
    crash_now()
    return s


def outer() -> str:
    t = "also held"
    return t + inner(1)


print("before")
print(outer())
