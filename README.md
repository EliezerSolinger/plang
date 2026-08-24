# Plang

**A Python-syntax systems language that compiles to C.**

Plang looks like Python — indentation blocks, `def`, `match`, no semicolons — but
it is a small, statically-typed *systems* language: fixed-width integers, raw
pointers, structs, manual memory, direct C interop. The compiler (`plangc`)
translates it to **readable C** (the default) or to **QBE IL**, so a Plang
program is exactly as fast and as portable as the C it becomes.

```python
include <stdio.h>

def main() -> int:
    """Say hello, and say it in C."""
    printf("hello from Plang\n")
    return 0
```

```sh
plangc hello.p -o hello.c && cc hello.c -o hello && ./hello
```

The compiler is **written in Plang itself** and bootstraps to a fixed point. This
repository ships that Plang source plus the generated C **seed**, so the whole
thing builds with nothing but a C compiler.

## One compiler, three languages

| input | what it is |
|---|---|
| `.p` `.ph` | **Plang** — zero runtime, C's ABI, manual memory |
| `.c` `.i` | **C** — a full front end: C11 plus common GNU extensions |
| `.psc` | **pscript** — the garbage-collected sibling ([below](#pscript--the-sibling-language-with-a-runtime)) |

All three lower to the same AST, go through the same checker, and come out of the
same back ends. One project can mix them and one compiler builds it.

The C half has a consequence worth naming: **C11 → C89**. Feed modern C and emit
strict C89 (`--std=c89`) — VLAs become `malloc`/`free`, designated initializers
are lowered, semantics preserved. That makes both Plang and the C→C89 path
practical for **embedded systems, kernels and microcontrollers**: anywhere you
have a small conformant C compiler and want either a nicer language or a way to
run modern C on it.

## Build

You need a C compiler (`cc`/`gcc`/`clang`), `make`, and — only for the editor —
`libsdl2-dev` and `pkg-config`.

```sh
sudo apt install build-essential pkg-config libsdl2-dev   # Debian/Ubuntu
make -j$(nproc)
```

That is the whole thing: about two minutes from a clean tree on eight cores, then
seconds. It compiles the committed C seed with your `cc`, uses that to build
**pforge** — this repository's own build system, written in pscript — and from
then on the build is a graph. The default build is 105 edges: 97 translations and
compilations, 5 links, and **3 checks** that define what "built" means — the
`s2 == s3` fixed point, no internal libc type in the generated C, and the stamp
that joins them. *Building is not testing:* the suites are a target you ask for.

| command | what it does |
|---|---|
| `make` | the ladder with its fixed point, `pforge`, and the editor |
| `make check` | ... and then compiles and runs a hello-world with it |
| `make test` | the corpus in C plus the pscript suite, case by case |
| `make verify` | the whole battery, 8 gates (~6 min cold, 8 s when nothing moved) |
| `make pstudio` | the editor alone, and it says so if SDL2 is missing |
| `make selfhost` | just the ladder: seed → s1 → s2 → s3 |
| `make doc <mod>` | a module's interface, with its documentation |
| `make clean` \| `clean-all` | drop what was built \| drop what was downloaded too |

Everything lands under `build/` — binaries, the three ladder rungs, objects,
logs, packages. Nothing is installed anywhere else.

Two notes on what is optional. `make` builds the editor **only if `pkg-config`
finds `sdl2`**; without it the build succeeds and the editor simply does not
exist, which is not an error — `make pstudio` is the target that refuses out
loud. And `make verify` alone wants two extras: `git submodule update --init` for
the vendored QBE, and `python3` for the test harnesses.

If you would rather not go through `pforge` at all, `build.ninja` is committed and
describes the same graph:

```sh
cc -O2 -o plangc bootstrap/selfhost/*.c && ninja
```

It is generated (`pforge ninja build.ninja`) and a gate regenerates it and
compares — a committed generated file has exactly one way to fail, which is to
age in silence.

## Using the compiler

`plangc` has no runtime and no dependencies: it reads a file and writes C (or QBE
IL) to stdout or `-o`.

```sh
plangc prog.p -o prog.c              # Plang -> C, then any C compiler builds it
plangc --std=c89 modern.c -o out.c   # C11 (+ GNU exts) -> strict C89
plangc --backend qbe prog.p -o prog.ssa   # needs the external `qbe` + as + ld
```

A `.c` is preprocessed automatically — with **your** `cc -E` (`--cpp` or
`PLANGC_CPP` picks another), because the machine's own preprocessor is the truth
about the machine's own headers. Pass a `.i` if you preprocessed it yourself.

For a project, `--out-dir` compiles many files at once and mirrors the source
tree in the output, so builds never write next to your sources:

```sh
plangc --out-dir out src/main.p      # `import` brings the rest: one file is enough
cc out/src/*.c -o prog
```

Naming one file is enough because `import "x.ph"` implies the module: if `x.ph`
has an `x.p` sibling, the compiler emits both. That is why no list of modules
lives in a Makefile here — and `--deps` / `--outputs` / `--api` / `--version`
answer what it read, what it will emit, what its interface is and who it is,
which is exactly what a build system needs.

## What the language has

Plang keeps C's memory model and ABI and adds the ergonomics C never had, **all
at zero runtime cost** — everything lowers to plain C. The reference is
**[SPECS.MD](SPECS.MD)**; the short list:

- **Generics by explicit monomorphization** — `struct Vec<T>`, `def max<T>(...)`,
  instantiated with `declare`/`implement`. No hidden code generation: you ask for
  each instance, and each becomes a distinctly-named concrete type.
- **Traits** as generic bounds — checked where the type is concrete and then
  monomorphized: no vtable, no dispatch, nothing at run time. A trait may declare
  an **associated type**, so `Iterable` is a contract about iterating rather than
  about `i64`, and `for v in it` lowers to a cursor and direct calls.
- **Compile-time everything** — `match type(x)`, `typestr(x)`, `const def`,
  constant folding and branch pruning (an `#ifdef` without a preprocessor),
  default and named arguments, f-strings resolved into `printf`.
- **Pointers with proof** — `ref T` binds once, auto-dereferences, and is a plain
  `T*` in the emitted C; `*T` stays nullable as C made it, and a raw pointer
  enters `ref` only under `if p != None:`. The same flow analysis powers
  `-Wnull-dereference`, and `??` coalesces.
- **`out` / `ref` / `in` parameters** — sugar over plain pointers
  (`divmod(17, 5, out r)`; `in` emits `const T*`). The ABI stays a raw pointer.
- **`record`** — a struct the compiler has *checked* to be pure bytes: safe to
  memcpy, to write to disk, to compare by content.
- **`embed("f.txt")` / `embed_bytes("f.bin")`** — a file becomes data at compile
  time, so a program ships as one binary.
- **`defer`**, **`with`**, **`private`** (which emits C's `static`), lambdas
  without capture, `in` / `not in`, string `==` by content, `match` on strings.
- **Clang-compatible diagnostics** — `-W<group>`, `-Wall`, `-Werror`,
  `-pedantic-errors`, with clang's own group names and defaults.
- **Docstrings** that reach the AST and emit no code — and `--api` prints them
  *after* the interface hash, so editing documentation never changes what an
  interface hashes to.

### The optional standard library

`packages/stl` is a header-only generic library — `Vec<T>`, `List<T>`, `Map<K,V>`,
`Dict<K,V>`, `Set<T>`, `Queue<T>`, `Str`, `Slice<T>`. Nothing requires it.

```python
include <stdio.h>
import <stl/vec.ph>

declare Vec<i32>
implement Vec<i32>

def main() -> int:
    v: Vec<i32> = {0}
    v.push(3)
    v.push(4)
    printf("%d %d %d\n", v.get(0), v.get(1), v.len)
    v.deinit()
    return 0
```

```sh
plangc --pkg-path packages --out-dir out prog.p
cc $(find out -name '*.c') -o prog
```

Because it is built on generics, containers store elements **by value**: a
`Vec<Point>` holds `Point`s inline, with no per-element indirection.

## pscript — the sibling language, with a runtime

Plang's promise is *zero runtime*. That promise is also a ceiling. **pscript**
(`.psc`) is the other side of it — for the code where safety matters more than
the last byte:

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

print(farthest([Point(1.0, 2.0), Point(3.0, 4.0)]))   # Point(x=3.0, y=4.0)
```

A copying garbage collector, `try`/`catch`, real strings and `list`/`dict`/`set`,
`T?` with flow narrowing, closures, `async`/`await`, and **workers** — OS threads
with a heap and a collector each, so nothing is shared by accident. Bounds are
checked and integer overflow raises instead of wrapping (the wrap has its own
spelling, `%+ %- %*`).

A message between workers crosses as a **copy**, with a cycle guard: an object
that appears twice arrives as one object, and an object that contains itself
arrives at all. `await w.recv()` parks like `await sleep()` does, so a program can
wait for a message and a clock at once and neither is missed.

It is **not a second compiler**: a `.psc` is lowered to Plang's own AST, and the
rest of the pipeline is the one Plang already had — the same checker (which
doubles as a verifier of the lowering), the same back ends, the same build modes.
The runtime is Plang source compiled alongside your program, so there is nothing
to install:

```sh
plangc --out-dir out pscript/runtime/psrt.ph     # naming the umbrella is enough
plangc --out-dir out hello.psc
cc -D_POSIX_C_SOURCE=200112L -D_DEFAULT_SOURCE \
   out/hello.c out/pscript/runtime/psrt_*.c -o hello -lm -pthread
```

Or let the package manager do it, which is what it is for. The second run costs
about six milliseconds: a manifest lists every file the build read with its date,
and if they all still match there is nothing to do.

```sh
pforge run hello.psc arg1 arg2    # builds into build/run/ and BECOMES the process
```

Talking to Plang is one import — `import "shim.ph"` compiles `shim.p` into this
build too. The boundary is pointer-free signatures, enum members, scalar
constants, plus one `const` record by reference.

The validation program is a **path tracer**: `pscript/examples/smallpt_core.psc`
renders and writes a PPM, `smallpt_workers.psc` renders it across workers, and
`smallpt_full.psc` adds a CLI, a JSON scene and a shared framebuffer. All three
run in the suite, in all three modes.

Decisions are in [pscript/DESIGN.md](pscript/DESIGN.md), what exists in
[FEATURES.md](pscript/FEATURES.md), what is next in [PLAN.md](pscript/PLAN.md).

## pcode and pstudio — the trial by fire

A GUI code editor: tabs, a file tree, a fuzzy command palette (ctrl+p),
multi-caret editing (ctrl+d), coalesced undo, incremental search (ctrl+f, POSIX
regex with a `/` prefix), folding, a minimap, and syntax highlighting that reuses
**the compiler's own lexer**. The UI toolkit and the software rasterizer are ours
too — no widget library involved.

There are **two programs from the same layers**: `pcode` is the editor, and
`pstudio` is the editor plus the IDE — the build, the run and the manifest, with
the engine imported as a library rather than called as a process.

```sh
make pcode                     # the editor
make pstudio                   # ... and the IDE
./build/bin/pcode .            # open the tree in the current directory
```

The second one exists twice over: it is the tool, and it is the **proof**. That
the two share every layer below the entry point is not a claim in a document —
`tests/decouple.sh` asks the compiler (`plangc --deps`) which files each binary
reads and fails if the answer changes. Today it is **26 against 31**, and
`pcode --selftest` prints `commands 25` where `pstudio` has 34.

The list is a WHITELIST and not a blacklist, which is the only kind that does not
age: a blacklist names what may not come in, and a module invented next month
under another name walks straight past it.

**It is written in pscript, and the split was decided by the boundary rule rather
than by taste.** Only a pointer-free signature crosses, so the two places that
hold a pointer stay in Plang and expose scalars:

| in Plang | why |
|---|---|
| `shim.p` + `pgfx*.p` + `font_atlas.p` | SDL2 and the pixels: a window handle, a key code, a colour, one glyph at a time |
| `hl.p` | the compiler's lexer: the text goes in as a `CStr` (pointer + length, no copy) and the tokens come back as numbers |

Everything above that — lines, carets, undo, search, folding, the widget tree,
the layout, the key bindings, the painting — is pscript: **4 671 lines of it over
1 103 of Plang**. The editor in pure Plang that came before it was 6 448 lines,
and was retired once parity had been measured method by method.

The ratio is the interesting part: the buffer needs 914 lines of pscript where
the Plang one needed 1 505, and the difference is not style — a line is a `str`,
`len(s)` is codepoints, slicing copies, and the collector owns the graph, so three
UTF-8 helpers, every `malloc`/`free` pair and every `deinit` are simply not there.
The layout code, which is arithmetic, did not shrink at all.

Everything is gated: `make verify` compiles and links the editor and runs its
self-test under SDL's dummy driver, and `pstudio/*_test.psc` drives the buffer,
the toolkit, the editing widget and the whole application headless, with synthetic
events. With no display, `--shot img.ppm` writes a frame instead of opening a
window. The font atlas is what `embed_bytes` is for: 263 KB of glyphs used to be
eleven thousand lines of decimal in a `.p`, and are now one line reading a `.bin`
at compile time.

## pforge — the build system and the package manager

Written **in pscript** and built by the compiler it builds. One binary, three
modes: *resolve* (the only one that touches the network), *describe*, *execute*.

```sh
pforge build [target]      # -j N, -k N, -n (dry run), --explain, --repro
pforge run x.psc [args]    # build it and BECOME it (stdin, stdout, exit code)
pforge test / verify       # the named suites / the whole battery
pforge dev [target]        # rebuild and relaunch on every change
pforge doc <mod> [sym]     # a module's interface and docs; --html for a folder
pforge why / tree / graph / explain      # why did this rebuild, and who pulled that
pforge add x@1.0 / lock / install / up   # the manifest and the lock
pforge publish x --to <dir> --key <k>    # a tarball, a hash and two signatures
```

The engine is the one the ninja documents describe: a node is a file, an edge is
a command, and "out of date" is ninja's six tests — with `restat` comparing
**content** (our compiler rewrites C that is often byte-identical, and then
nothing downstream needs to run) and the queue ordered by the **duration** the log
recorded last time. Commands are `argv`, never a shell string.

Two things are unusual, and both are deliberate:

- **The compiler answers; the build system decides.** What to rebuild, in what
  order, with how many processes is never the compiler's business — which is what
  keeps a second build system from growing inside it.
- **Nothing is global.** Packages, objects, binaries and logs live in the
  project's `build/`. A repository is a *format*, not a service: a directory
  served by anything, with trust coming from content (SHA-256 plus Ed25519), never
  from the transport.

Decisions are in `pforge/DESIGN.md` and `pforge/ARQUITETURA.md`,
`pforge/PACOTES.md` and `pforge/REPOSITORIO.md`, with `pforge/DECISOES.md` as the
one-line index.

The name covers both halves on purpose: one binary that builds *and* fetches
should not be called after only one of them. It used to be `ppack`, in a folder
called `pbuild` next to another called `ppack` — three names for two ideas.

## Repository layout

```
selfhost/     the compiler, in Plang — including the C front end (cfront)
              and pscript's (ps_*)
bootstrap/    the C seed generated from selfhost/, committed
packages/     what WE publish, each with its own pack.json and its own tests:
              stl, pui (the editor's toolkit), sha2, tar, ed25519, http, url,
              and pforge — the engine and the package manager, as a library
pforge/       the tool's documents (DESIGN is the engine, PACOTES the packages,
              REPOSITORIO the format) and src/: main.psc (the CLI),
              build_plang.psc (THIS repository's descriptor), its own suite
pscript/      the sibling language: runtime (in Plang), design, examples
pstudio/      the editor: pscript on top, the SDL2 driver and the lexer bridge
              in Plang
qbe/          the vendored QBE, as a submodule
tests/        gating suites; corpora somebody else wrote; clang, python3 and
              node as oracles; the collector under stress
tools/        generators for data that is not written by hand
pack.json     this repository IS a workspace, like any project pforge builds
build.ninja   generated and committed, so a clean machine needs no pforge
Makefile      a thin shell over pforge (and it builds the seed)
SPECS.MD      language reference
```

`selfhost/` is both the compiler's implementation and a large, real example of
idiomatic Plang. `make selfhost` rebuilds it from that source and checks that it
still self-hosts: the seed compiles the sources, the result compiles them again,
and the third pass has to produce byte-identical C. A compiler that reproduces
itself is the only kind you can trust to have compiled itself correctly.

## Status

The compiler self-hosts (3-stage fixed point, through both back ends) and passes
its suite on Unix with a standard C toolchain. Every gating suite runs three
times — C, QBE and strict C89.

Both front ends are measured against corpora written by other people rather than
against claims of our own:

| corpus | |
|---|---|
| c-testsuite | **220/220** |
| wacct programs, by exit code | **741** |
| diagnostics matching clang's text exactly | **155** |
| nst/JSONTestSuite | **318/318** |
| web-platform-tests, URL | **890/891** |
| nodejs/llhttp (the fixtures node itself runs) | **202/202** |

The exceptions are written down in `tests/conformance/*.skips`, one line each with
the reason. None of those numbers was free: the JSON parser was not decoding
`\uXXXX` at all and had no depth limit, and the HTTP parser had twelve
request-smuggling doors open — most of them the same shape, where
`x:<CR>Transfer-Encoding: chunked` was one header to us and two to the hop next
door, which is the whole attack.

Three harnesses measure what no downloadable corpus can:

- **`tests/oracle/run.sh`** runs our own programs twice — once here, once by the
  implementation whose behaviour we said we would copy. `python3` is the oracle
  for the language (including case mapping over all 1 114 112 code points),
  `node` for the runtime model, where the promises are about ORDER.
- **`tests/gc-stress.sh`** collects at every safe point and poisons the space it
  frees. A copying collector has one way to be wrong — something held a pointer
  across a safe point without telling the collector — and the danger is the
  invisibility: with the normal threshold a small program never collects at all.
  The first run turned thirteen green tests red, and every one was a real defect.
- **`tests/bench.sh`** runs the same program here, in `python3` and in `node`.
  None of the speed comes from the code generator, which optimises nothing; it
  comes from GCC plus two fixes measurement forced — LTO (worth 3.4× on
  recursion, because a program and the runtime are two translation units) and a
  collector trigger proportional to what is live rather than a fixed 2 MiB, which
  was making a copying collector quadratic on anything that accumulates.

pscript is younger than the C front end; [pscript/PLAN.md](pscript/PLAN.md) says
where each piece stands and why.

## License

MIT — see [LICENSE](LICENSE).
