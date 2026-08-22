# 65.2 — an f-string in P is resolved ENTIRELY at compile time: it becomes a
# printf format plus the hole expressions, so there is no allocation and no
# runtime. That is also why it only appears as the format argument of a variadic
# call: a format is the only thing it can BE.
include <stdio.h>
include <string.h>
include <stdarg.h>

struct Pt:
    x: f64
    y: i32

# a METHOD can host an f-string too, and that is the call the feature is really
# for in this codebase (`b.printf(f"...")`). The receiver takes the first
# parameter, so the format slot moves by one — the rule is about the SIGNATURE,
# not about printf by name.
struct Log:
    n: i32

    def say(self: *Log, fmt: const *char, ...):
        ap: va_list
        va_start(ap, fmt)
        vprintf(fmt, ap)
        va_end(ap)
        self->n += 1

def main() -> i32:
    n: i32 = 42
    big: i64 = 9007199254740993
    u: u64 = 18446744073709551615
    sm: u8 = 200
    f: f64 = 3.14159
    g: f32 = 1.5
    s: const *char = "world"
    ok: bool = True
    no: bool = False
    c: char = 'Z'
    p: *Pt = None
    e: Pt = {2.5, 7}

    # the type of the hole picks the conversion: nothing to annotate
    printf(f"hello {s}, n={n}, big={big}, u={u}, small={sm}\n")
    # the spec is Python's, transliterated onto printf's own
    printf(f"pi={f:.3f} g={g:.2f} pad=[{n:5}] left=[{n:<5}] zero={n:05}\n")
    printf(f"hex={n:x} HEX={n:X} oct={n:o} dec={n:d}\n")
    # a bool prints the way both languages print it, with a ternary over two
    # literals — still zero runtime
    printf(f"bool={ok}/{no} char={c}\n")
    # a literal `%` in the text has to survive into the format
    printf(f"pct=100% braces={{literal}}\n")
    # any expression, not just a name
    printf(f"expr={n * 2 + 1} field={e.y} deref={s[0]} call={strlen(s)}\n")
    # a pointer gets `%p` and a cast to `void*`, which is what C requires. The
    # bytes it prints are the library's business, so what this asserts is that
    # it printed SOMETHING — through `snprintf`, a second variadic function, to
    # show the rule is about the signature and not about printf by name
    buf: char[32]
    snprintf(&buf[0], 32, f"{p}")
    printf(f"ptr_printed={i32(strlen(&buf[0]) > 0)}\n")
    # an f-string with no hole at all is just a string
    printf(f"plain\n")
    lg: Log = {0}
    lg.say(f"method who={s} n={n}\n")
    lg.say(f"method again\n")
    printf(f"said={lg.n}\n")
    return 0
