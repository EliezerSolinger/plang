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

### It compiles C *and* Plang, side by side

`plangc` also has a **C front end**: it accepts `.c`/`.i` files as well as
`.p`/`.ph`, and both go through the same back ends. So in one project you can
mix C and Plang and compile it all with `plangc`. Two things fall out of this:

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

For code aimed at very old toolchains, emit strict C89:

```sh
plangc --std=c89 prog.p -o prog.c   # C89-conformant output
```

### Compiling C (the C front end)

`plangc` reads C too. Preprocess first if the file has `#include`/`#define`
(any `cpp`), then let `plangc` re-emit it:

```sh
cpp modern.c > modern.i              # your preprocessor of choice
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

## What the language has

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

See **[specs.md](specs.md)** for the language reference.

## Repository layout

```
selfhost/     the compiler, written in Plang (.p source, .ph headers)
bootstrap/    the C seed generated from selfhost/ — builds plangc with cc
stl/          optional standard library (header-only generic templates, .ph)
Makefile      builds plangc from the seed
specs.md      language reference
```

`plangc` is the compiler; `selfhost/` is both its implementation and a large,
real example of idiomatic Plang. To rebuild the compiler from the Plang source
(and confirm it still self-hosts on your machine):

```sh
make selfhost   # rebuilds plangc from selfhost/ using the seed compiler
```

## Status

This is a feature-frozen snapshot of the language. The compiler self-hosts and
passes its test suite on Unix systems with a standard C toolchain.

## License

MIT — see [LICENSE](LICENSE).
