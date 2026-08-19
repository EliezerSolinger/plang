# Plang

**A Python-syntax systems language that compiles to C.**

Plang looks like Python — indentation blocks, `def`, `match`, no semicolons —
but it is a small, statically-typed *systems* language: fixed-width integers,
raw pointers, structs, manual memory, and direct C interop. The compiler
(`plangc`) translates Plang to **readable C** (the default) or to **QBE IL**,
so a Plang program is exactly as fast and as portable as the C it becomes.

```python
import <stdio.h>

def main() -> int:
    printf("hello from Plang\n")
    return 0
```

```sh
plangc hello.p -o hello.c && cc hello.c -o hello && ./hello
```

The compiler is **written in Plang itself** and bootstraps to a fixed point.
This repository ships that Plang source plus the generated C **seed**, so the
whole thing builds with nothing but a C compiler.

### One compiler, three languages

`plangc` accepts `.c`/`.i` (a full **C front end**), `.p`/`.ph` (Plang) and
`.psc` (**pscript**, the garbage-collected sibling language described below),
and all three go through the same back ends. So one project can mix C, Plang
and pscript and be built by one compiler. Two things fall out of the C half:

- **C11 → C89 on any C89 compiler.** Feed modern C (C11, plus common GNU
  extensions) and emit **strict C89** — so code written today builds on an
  ancient or vendor C89-only toolchain. VLAs become `malloc`/`free`,
  designated initializers are lowered, etc.; the semantics are preserved.
- **Emits C89 or C99/C11.** Default output targets C99/C11; `--std=c89` emits
  conformant C89 that should build on **any C89-conformant compiler**.

That makes Plang (and the C→C89 path) practical for **embedded systems, OS
kernels, and microcontrollers** — anywhere you have a small conformant C
compiler and want either a nicer language or a way to run modern C on it.

## Build

You only need a C compiler (`cc`/`gcc`/`clang`) and `make`:

```sh
make            # builds ./plangc from the C seed in bootstrap/
make check      # builds, then compiles & runs a hello-world
```

`plangc` has no runtime and no dependencies — it reads a `.p`/`.ph` file and
writes C (or QBE IL) to stdout or `-o`.

## Using the compiler

```sh
plangc prog.p -o prog.c      # Plang -> C (default backend)
cc prog.c -o prog            # then any C compiler builds it
```

For a project, `--out-dir` compiles many files at once and mirrors the source
tree in the output (builds never write next to your sources):

```sh
plangc --out-dir out stl/*.ph src/*.ph src/*.p
cc out/src/*.c -o prog
```

For code aimed at very old toolchains, emit strict C89:

```sh
plangc --std=c89 prog.p -o prog.c   # C89-conformant output
```

A `.psc` (pscript) compiles the same way — it just needs its runtime compiled
alongside; see [pscript](#pscript--the-sibling-language-with-a-runtime) below.

### Compiling C (the C front end)

`plangc` reads C too. A `.c` file is preprocessed automatically (`--cpp`
chooses the compiler used for that; default `cc`); pass a `.i` if you already
preprocessed it yourself:

```sh
cpp modern.c > modern.i              # optional: your preprocessor of choice
plangc --std=c89 modern.i -o out.c   # C11 (+ GNU exts) -> strict C89
cc89 out.c -o modern                 # builds on a C89-only compiler
```

The C front end understands C11 plus common GNU extensions (statement
expressions `({...})`, `_Generic`, `__attribute__`, compound literals,
designated initializers, `__builtin_*`). It can target the C89 back end (as
above) or the QBE back end (`--backend qbe`).

### QBE backend (optional)

Plang can also emit [QBE](https://c9x.me/compile/) IL instead of C, for a fast
native path without a full C compiler:

```sh
plangc --backend qbe prog.p -o prog.ssa
qbe -o prog.s prog.ssa       # QBE: IL -> assembly   (external tool)
as -o prog.o prog.s          # assembler
cc prog.o -o prog            # link
```

This requires the external `qbe` tool (and an assembler/linker); the C backend
above needs only `cc`, so it is the recommended default.

## What Plang has

Plang keeps C's memory model and ABI but adds the ergonomics C never had —
**all at zero runtime cost** (everything lowers to plain C):

- **Generics by explicit monomorphization** — something C lacks entirely:
  `struct Vec<T>` and `def max<T>(...)`, instantiated with `declare`/
  `implement`. No hidden code generation: you ask for each instance, and each
  becomes a distinctly-named concrete type/function.
- **Compile-time type dispatch:** `match type(x)` and `typestr(x)` fold at
  compile time and prune dead branches (zero-cost, like — but nicer than —
  C11's `_Generic`).
- **`defer`** for scope-exit cleanup, **`with`** for struct subcontexts,
  **`const def`** for compile-time functions, and compile-time constant folding
  / branch pruning (an `#ifdef` without a preprocessor).
- **Python-ish syntax:** indentation blocks, `def name(args) -> T:`, `if/elif/
  else`, `while`, `for i in range(...)`, `match`, ternary `a if c else b`.
- **Systems types:** `i8..i64`, `u8..u64`, `f32/f64`, `bool`, `char`, pointers
  (`*T`), fixed arrays (`T[N]`), `usize`/`isize`; plus the native C spellings.
- **Structs with methods**, unions, enums, bitfields, function pointers.
- **`out` / `ref` / `in` parameters** — sugar over plain pointers
  (`divmod(17, 5, out r)`; `in` emits `const T*`). The ABI stays a raw
  pointer; C calls it as always.
- **`ref T`, a non-nullable reference** for locals and returns: it binds once,
  auto-dereferences, and is a plain `T*` in the emitted C. `*T` stays nullable
  as C made it, and a raw pointer enters `ref` only under proof
  (`if p != None:`). The same flow analysis powers **`-Wnull-dereference`**,
  and **`??`** coalesces pointers (`p ?? fallback`).
- **Traits**: `trait Comparable:` plus `implement Comparable for T:`, used as
  generic bounds (`def sort<T: Comparable>`) that are checked where the type is
  concrete and then monomorphized — no vtable, no dispatch, nothing at run
  time. An implementation has to match the trait's signature *whole*, return
  type included. A trait may declare an **associated type** (`type Item`) that
  each implementation fills in (`type Item = f64`), so `Iterable` is a contract
  about iterating rather than a contract about `i64`. `for v in it` works over
  any type that implements `Iterable`, and lowers to a cursor and direct calls.
- **`record`** — a struct the compiler has *checked* to be pure bytes: safe to
  memcpy, to write to disk, and to compare by content.
- **`embed("f.txt")` / `embed_bytes("f.bin")`** — a file becomes data at
  compile time (a `static const` array), so a program ships as one binary.
- **`in` / `not in`**, string `==` by content (`strcmp`; identity is `is`),
  and `match` on strings.
- **Default and named arguments**, resolved at compile time.
- **Clang-compatible warnings:** `-W<group>`, `-Wall`, `-Werror`,
  `-pedantic-errors` — same group names and defaults as clang.
- **First-class C interop:** `import <stdio.h>` becomes `#include`; call libc
  directly; the emitted C is clean enough to read and diff.

### Optional standard library (STL)

Plang ships an **optional**, header-only generic library in `stl/` — nothing
requires it; import only what you want:

`Vec<T>`, `List<T>`, `Map<K,V>`, `Dict<K,V>`, `Set<T>`, `Queue<T>`, `Str`,
`Slice<T>`.

Because it's built on generics, containers store elements **by value** (a
`Vec<Point>` holds `Point`s inline, no per-element indirection). It's
header-only: `import "stl/vec.ph"`, then `declare Vec<int>` / `implement
Vec<int>`. Skip it entirely and use raw pointers + libc if you prefer.

See **[SPECS.MD](SPECS.MD)** for the language reference.

## pscript — the sibling language, with a runtime

Plang's promise is *zero runtime*: no collector, no hidden allocation, C's ABI.
That promise is also a ceiling. **pscript** (`.psc`) is the other side of it —
a language for the code where safety matters more than the last byte:

```python
record Point:
    x: float
    y: float

def farthest(ps: list<Point>) -> Point:
    best = ps[0]
    for p in ps:
        if p.x * p.x + p.y * p.y > best.x * best.x + best.y * best.y:
            best = p
    return best

pts = [Point(1.0, 2.0), Point(3.0, 4.0)]
print(farthest(pts))            # Point(x=3.0, y=4.0)
```

It has a **copying garbage collector**, exceptions with `try`/`catch`, real
strings and `list`/`dict`/`set`, `T?` options with flow narrowing, closures,
`async`/`await`, and **workers** — OS threads with a heap and a collector each,
so nothing is shared by accident. Bounds are checked, integer overflow raises
instead of wrapping (the wrap has its own spelling, `%+ %- %*`), and a
`shared dict` gives workers named state without a pointer ever crossing two
heaps.

A message crosses as a **copy**: numbers and records by memcpy, and anything
the collector owns — a string, a list, a dict, a set, a `struct` with
references — written out on one side and built again on the other, with a
cycle guard, so an object that appears twice arrives as one object and an
object that contains itself arrives at all. `await w.recv()` **parks** like
`await sleep()` does: the scheduler waits on the queues' descriptors with the
nearest deadline as its timeout, so a program can wait for a message and a
clock at once and neither is missed.

Talking to Plang is one import:

```python
import "shim.ph"                 # compiles shim.p into this build too

const WINDOW: Rect = Rect(1280, 720)
open_window(WINDOW)              # a `const` record crosses by reference, read-only
```

The boundary is unchanged — pointer-free signatures, enum members, scalar
constants, plus that one `const` record by reference — but the build is now a
single command instead of two.

It is not a second compiler: a `.psc` is lowered to **Plang's own AST** and
from there down the pipeline is the one Plang already had — the same checker
(which doubles as a verifier of the lowering), the same C and QBE back ends,
the same three build modes. The runtime is Plang source compiled alongside your
program, so there is still no library to install:

```sh
plangc --out-dir out pscript/runtime/psrt.ph pscript/runtime/psrt.p   # once
plangc --out-dir out hello.psc
cc -D_POSIX_C_SOURCE=200112L -D_DEFAULT_SOURCE \
   out/hello.c out/pscript/runtime/psrt.c -o hello -lm -pthread
```

(`--ps-runtime <dir>` says where the runtime lives if it is not in
`pscript/runtime`.)

The validation program is a **path tracer**: `pscript/examples/smallpt_core.psc`
renders and writes a PPM, `smallpt_workers.psc` renders it in parallel across
workers, and `smallpt_full.psc` adds a CLI, a JSON scene and a shared
framebuffer. All three run in the test suite, in all three modes.

The design is written down decision by decision in
[pscript/DESIGN.md](pscript/DESIGN.md), what exists in
[pscript/FEATURES.md](pscript/FEATURES.md), and what is next in
[pscript/PLAN.md](pscript/PLAN.md).

### The trial by fire: the editor, ported

`pstudio/ps/` is Plang Studio's buffer and application **written in pscript**,
with the hand that touches SDL2 still in Plang:

```sh
make pstudio-ps          # -> out/bin/pstudio-ps
```

The boundary rule (only a pointer-free signature crosses) decides the split by
itself: SDL2 is nothing but pointers, so `shim.p` keeps the window, the events
and the pixels and exposes them as **scalars** — a handle, a key code, a
colour, one codepoint at a time — while the editor above it (lines, carets,
selection, undo, search, folding, layout, key bindings, painting) is pscript.
The two meet through `include "shim.h"`, the header the compiler itself emits:
no FFI, no bindings.

It is 933 lines of pscript where the Plang buffer needs 1505, and the
difference is not style — a line is a `str`, `len(s)` is codepoints, slicing
copies, and the collector owns the graph, so three UTF-8 helpers, every
`malloc`/`free` pair and every `deinit` simply are not there.

Both halves are gated: the buffer runs headless in the test suite, and the
whole editor runs its own self-test with SDL's dummy driver — open, type,
select, undo, multi-caret, **draw** and save. What the port found on the way
(six real compiler bugs, three registered gaps) is written down in
[pstudio/ps/README.md](pstudio/ps/README.md).

## Plang Studio — a code editor written in Plang

`pstudio/` is a GUI code editor written in **pure Plang**, with SDL2 as its
only dependency: tabs, a file tree, a fuzzy command palette (ctrl+p), multi
caret editing (ctrl+d), coalesced undo, incremental search (ctrl+f, POSIX
regex with a `/` prefix), and syntax highlighting that reuses **the
compiler's own lexer**. The UI toolkit (`pui`) and software rasterizer
(`pgfx`) are Plang too — no widget library involved.

```sh
sudo apt install libsdl2-dev
make pstudio                 # -> out/bin/pstudio
./out/bin/pstudio .          # open the tree in the current directory
```

It doubles as the largest Plang program after the compiler itself, so
`make verify` compiles it as a gate and runs `tests/pstudio/` — headless
tests that drive the editor with synthetic events. See
[pstudio/DESIGN.md](pstudio/DESIGN.md).

The font atlas shows what `embed_bytes` is for: 263 KB of glyphs used to be
eleven thousand lines of decimal in a `.p`, and are now one line reading a
`.bin` at compile time — same single binary, same static array, a page of
source instead of a phone book.

## Repository layout

```
selfhost/     the compiler, written in Plang (.p source, .ph headers)
              — including the C front end (cfront) and pscript's (ps_*)
bootstrap/    the C seed generated from selfhost/ (+ bootstrap/stl headers)
stl/          optional standard library (header-only generic templates, .ph)
pscript/      the sibling language: its runtime (in Plang), design and examples
pstudio/      Plang Studio: a code editor in pure Plang (SDL2 only)
tests/        gating suites; corpora somebody else wrote (c-testsuite,
              wacct, JSONTestSuite, web-platform-tests); clang, python3 and
              node as oracles; and the collector under stress
tools/        generators for data that is not written by hand (the Unicode
              case table)
Makefile      builds plangc from the seed
SPECS.MD      language reference
```

`plangc` is the compiler; `selfhost/` is both its implementation and a large,
real example of idiomatic Plang. To rebuild the compiler from the Plang source
(and confirm it still self-hosts on your machine):

```sh
make selfhost   # rebuilds plangc from selfhost/ using the seed compiler
```

## Status

The compiler self-hosts (3-stage fixed point, through both back ends) and
passes its test suite on Unix systems with a standard C toolchain. Every gating
suite runs three times — C, QBE and strict C89 — and `make verify` runs the
whole battery, from the seed's fixed point to the editor's headless tests.

Both front ends are measured against corpora written by other people rather
than against claims of our own.

For C: the c-testsuite passes 220/220, 741 wacct programs produce their expected
exit codes, and 155 diagnostics match clang's text exactly.

For pscript, `bash tests/conformance/run.sh` runs the corpora the rest of the
world is measured on — nst/JSONTestSuite at **318/318**, and the
web-platform-tests URL corpus at **890/891**, the one exception written down in
`tests/conformance/url.skips` with what it would take. Neither number was free:
the JSON parser was not decoding `\uXXXX` at all, took `01` and `NaN` as numbers,
and had no depth limit — a hundred thousand `[` was a segfault reachable from a
string somebody else wrote.

`bash tests/oracle/run.sh` measures the other half, the part no downloadable
corpus can: it runs our own programs twice, once here and once by the
implementation whose behaviour we said we would copy. `python3` is the oracle for
the language — the arithmetic and string rules the design keeps stating "as
Python does", including case mapping compared over all 1 114 112 code points —
and `node` is the oracle for the runtime model, where the promises are about
ORDER. It found, among others, that timers with the same deadline were waking in
the wrong order.

`bash tests/gc-stress.sh` collects at every safe point and poisons the space it
frees. A copying collector has one way to be wrong — something held a pointer
across a safe point without telling the collector — and the danger is not the
fix but the invisibility: with the normal threshold a small program never
collects at all. The first run turned thirteen green tests red, and every one was
a real defect. The worst answered wrongly rather than crashing: `in` over a
collected element is an interior pointer, so a path tracer rendered a different
image for every collection frequency.

pscript is still younger than the C front end: `unsafe` and the epoll/kqueue I/O
loop are ahead, and [pscript/PLAN.md](pscript/PLAN.md) says where each piece
stands and why.

## License

MIT — see [LICENSE](LICENSE).
