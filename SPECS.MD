# Plang — Language Reference

Plang is a small, statically-typed systems language with Python-like syntax.
It compiles to readable C (default) or to QBE IL. There is no runtime: a Plang
program is the C it becomes.

This is a practical reference, not a formal standard. Examples are the spec.

---

## 1. Lexical structure

- **Comments:** `#` to end of line.
- **Blocks:** by indentation (like Python). A `:` opens an indented block.
- **Statements:** one per line. `;` separates simple statements on one line
  (`a += 1; f()`); it never opens or closes a block.
- **Identifiers:** letters, digits, `_`; case-sensitive.
- **Line continuation:** implicit inside `()`, `[]`, `{}`.

Literals:

```python
42        0xFF   0o17   0b1010     # ints
42u  42l  42ull                    # C-style integer suffixes
2.5   1e9   2.5f                   # float (f = float, else double)
'a'   '\n'  '\0'                   # char
"text\n"                           # string (const *char, NUL-terminated)
True   False   None                # bool / bool / null pointer
```

---

## 2. Types

Fixed-width and native types:

| Plang | C |
|---|---|
| `i8 i16 i32 i64` | `int8_t … int64_t` |
| `u8 u16 u32 u64` | `uint8_t … uint64_t` |
| `f32 f64` | `float double` |
| `usize isize` | `size_t ptrdiff_t` |
| `bool` | `int` (0/1) |
| `char int long short unsigned …` | passed through to C verbatim |

Composite:

```python
*T          # pointer to T            (None is the null pointer)
T[N]        # fixed array of N        (N must be a compile-time constant)
T[]         # unsized array / flexible member
const *T    # pointer to const T
```

`sizeof(T)` and `sizeof(expr)` are compile-time. Casts:

```python
i32(x)          # value cast
(*char)(p)      # pointer cast
```

---

## 3. Variables and constants

```python
x: i32 = 5          # explicit type
y = 5               # inferred: int (literal 3 -> int, 2.5 -> double, 2.5f -> float)
z = "hi"            # inferred: *char
p: *Point = None

const N = 64        # compile-time constant (folds; usable as an array size)
```

`name = value` declares a new local when `name` is not yet in scope
(Python-style); otherwise it is an assignment. Multiple simple statements may
share a line with `;`.

**Walrus** — `(x := expr)` assigns *and* yields the value, inside an
expression. On first use it declares `x` at **function scope** (like Python),
so the classic read loop works:

```python
while (c := next_char(src)) != '\0':
    ...
```

The parenthesized form is required.

---

## 4. Functions

```python
def add(a: i32, b: i32) -> i32:
    return a + b

def greet(name: const *char):        # no `->` means void
    printf("hi %s\n", name)

def log(fmt: const *char, ...):      # variadic (C varargs)
    ...
```

A `def` header with **no `:`/body** is a *prototype* — declare before use, as
in C. There is no automatic prototype generation.

### Default values and named arguments

```python
def area(w: i32, h: i32 = 10, scale: i32 = 1) -> i32:
    return w * h * scale

area(2)                   # 20
area(2, 3)                # 6
area(2, scale=5)          # 100  (named argument)
area(2, h=4, scale=2)     # 16
```

Defaults must be **compile-time constants** and may only appear on trailing
parameters. Both features are resolved entirely at compile time: the call is
rewritten to plain positional form, so the emitted C is an ordinary call —
zero cost, ordinary C ABI. Named arguments cannot be used with variadic
functions, and a positional argument cannot follow a named one.

### out / ref / in — by-reference parameters

C#-style **sugar over pointers**. The real parameter type is a pointer
(`const *T` for `in`); the keyword documents the intent, lets the body use the
name without `*`, and drives the compiler's init-tracking:

| form | emitted C | contract (checked) |
|---|---|---|
| `out v: T` | `T *v` | the **call initializes** the caller's variable; a body that never assigns it warns |
| `ref v: T` | `T *v` | must arrive **initialized** (else `-Wuninitialized`); read and written |
| `in v: T` | `const T *v` | read-only by reference (no copy); writes are compile errors |

```python
def divmod(a: i32, b: i32, out resto: i32) -> i32:
    resto = a % b            # no '*': the name auto-derefs
    return a / b

r: i32
q: i32 = divmod(17, 5, out r)     # call site says which way data flows
divmod(9, 4, &r)                  # raw pointer still works — SAME function
```

At the call site `out x` / `ref x` / `in x` is exactly `&x`; the keyword must
match the parameter's kind when present, and plain `&x` is always accepted
(C interop). Const-ness of `in` is **shallow**, as in C: `p.next.x = 1`
through a loaded pointer is legal; `p.x = 1` is not. The keywords are
contextual — `out`/`ref` remain valid identifiers elsewhere. C code calls
these functions with ordinary pointers; nothing byref-specific crosses the ABI.

### ref T — the non-nullable reference (69.1)

`ref T` generalizes the trio into a first-class TYPE for **locals and
returns**: a reference that is never `None`, binds exactly once, and
auto-derefs like a byref parameter always did. The pointer stays what C made
it — nullable — and `ref` is the opt-in for the places the flow can vouch for.
Same layout and ABI as `*T`; the guarantee lives entirely in sema.

```python
n: i32 = 5
r: ref i32 = n           # binds to the PLACE n (auto-&)
r = 7                    # writes THROUGH: n == 7 (a rebind cannot be spelled)

def pick(a: *Pt) -> ref Pt:
    if a != None:
        return *a        # a raw pointer enters ref-land only under proof (69.2)
    return fallback      # any lvalue of Pt works
x: Pt = pick(p)          # a ref result in value position loads through
```

Rules the compiler enforces:
- binding sources: an lvalue of `T`, another `ref T`, a ref-returning call, or
  `*p` **proven** non-None by the flow (`if p != None:` / `if p == None: return`) —
  the proof is per-function and conservative (loops, labels, `&x` and case
  labels drop facts). An unproven `*p` is `-Wnullability` (error by default,
  demotable with `-Wno-error=nullability`);
- positions: local and return only. Parameters keep the trio spelling
  (`ref v: T`); fields, globals, generics arguments and anything behind a
  pointer hold `*T` — the parser says why at the exact position;
- inference never creates a ref: `v = f()` from `f() -> ref T` gives `v: *T`.

### `??` — the None-coalescing pair (69.3)

`a ?? b` yields `a` unless it is `None`, then `b`. Pointers only (`??` IS the
None test), `a` evaluated exactly once, `b` only on the None path. Binds
tighter than the ternary, looser than `or`. Lowered to a hoisted temporary +
`?:` — plain C89, identical under both backends.

### -Wnull-dereference (69.7)

The same flow facts that admit a `ref` binding also flag the opposite: a
dereference of a pointer **proven** `None` on every path that reaches it
(`if p == None: return p->x`). Only proven facts fire — the warning never
guesses.

Function pointers:

```python
cmp: def(a: *void, b: *void) -> i32
```

---

## 5. Control flow

```python
if x > 0:
    ...
elif x < 0:
    ...
else:
    ...

while cond:
    ...

do:                 # do/while: body runs once, then while cond
    ...
while cond

for i in range(10):          # 0..9
for i in range(2, 10):       # 2..9
for i in range(10, 0, -1):   # countdown

r = a if cond else b         # ternary
break     continue     goto label     label:
```

The `for` iterator is declared implicitly (`usize`, or `isize` when a bound
is negative) and stays visible after the loop. It is **reusable**: a later
`for i in ...` in the same scope reuses the variable, and a later explicit
declaration of the *same type* (`i: usize = 0`) is accepted and becomes a
plain assignment. A redeclaration with a *different* type is still an error.

When a later loop over the same iterator **counts down through negative
values**, an unsigned iterator would compile to `i > -1` — a loop that never
runs. So: if the compiler owns that declaration it is **promoted to `isize`**
(which represents both ranges); if *you* declared the variable unsigned, the
descending loop is a compile error telling you to use `isize`.

C's three-part `for` and `switch` are also accepted (mainly for the C
frontend); the idiomatic forms above cover normal use.

### match

`match` on a value:

```python
match tok:
    case TK_PLUS, TK_MINUS:
        ...
    case _:
        ...
```

`match` on a **string** compares content (`strcmp`), not pointers — the C
`switch` can't, so it lowers to an if/else chain; duplicate string cases are
compile errors and the subject must be side-effect-free:

```python
match name:
    case "float", "f32":
        return "float"
    case _:
        return name
```

`match type(x)` selects by the **static type** of `x` at compile time (see §9).

---

## 6. Operators

- Logical: `and`, `or`, `not` (keywords).
- Comparison: `== != < <= > >=`.
- Arithmetic: `+ - * / %`.
- Bitwise: `& | ^ ~ << >>`.
- Address / deref: `&x`, `*p`. Member: `p.field` (dot works through pointers).
- Index: `a[i]`. Assignment ops: `= += -= *= /= %= &= |= ^= <<= >>=`.
- Identity: `is`, `is not` — **pointer** equality (contextual words).
- Membership: `in`, `not in` (below).

### Strings compare by content

When one side of `==`/`!=` is a **string literal** and the other is
string-typed, the comparison is `strcmp` content equality — never a pointer
test. Pointer identity is spelled `is`:

```python
if t->name == "void":       # strcmp under the hood
if a is b:                  # same pointer?
```

(Two string *variables* still compare as pointers; only literal comparisons
are rewritten.)

### in / not in — membership

A `bool` expression, at the same precedence as `==`:

```python
c in "aeiou"                      # char vs each byte of the literal (unrolled)
n in {1, 3, 5, 7}                 # == chain
name in {"float", "double"}       # strcmp chain — content, never pointers
q in primes                       # fixed array T[N] (N ≤ 64, unrolled)
x not in {A, B}                   # negation
```

The left side is expanded into one comparison per element, so it must be
side-effect-free (`f() in {...}` is an error — assign it to a variable
first). Everything is lowered at compile time; the emitted C is the chain of
comparisons you would have written by hand.

---

## 7. Structs, unions, enums

```python
struct Point:
    x: i32
    y: i32

    def norm2(self: *Point) -> i32:      # method: first param is `self`
        return self->x * self->x + self->y * self->y

p: Point = {3, 4}
d: i32 = p.norm2()
```

Methods compile to free functions named `Struct_method`.

`self` takes any of five forms — value, pointer, or the by-ref trio (§4):

```python
struct Caixa:
    def init(out self: Caixa):        # constructor: v.init() COUNTS as
        self.n = 0                    #   initializing v (definite assignment)
    def push(ref self: Caixa, v: i32): ...   # mutator
    def soma(in self: Caixa) -> i32: ...     # read-only, no copy (const T*)
    def copia(self: Caixa) -> i32: ...       # by value (a copy)
    def klass(self: *Caixa) -> i32: ...      # classic pointer receiver
```

A receiver that may be written through (`ref`/`out`/`self: *T`) requires an
**lvalue**: `make().push(1)` is an error, because the mutation would land in a
temporary. A read-only `in self` accepts an rvalue — the compiler materializes
a temporary for it, so `pg_rect(0, 0, 8, 8).contains(x, y)` just works.

```python
enum Color:
    RED          # 0
    GREEN        # 1
    BLUE = 5     # explicit; next continues at 6

union Value:
    i: i64
    f: f64

struct Flags:            # bitfields
    a: u32 : 1
    b: u32 : 3
```

### with — struct subcontext

Inside `with target:`, a leading `.field` refers to `target`:

```python
with p:
    .x = 10
    .y = 20        # same as p.x = 10; p.y = 20
```

---

## 8. defer

`defer` schedules a statement (or a `defer:` block) to run on every exit from
the enclosing block — normal fall-through, `return`, `break`, `continue`.
Multiple defers run in reverse (LIFO) order.

```python
def read(path: const *char) -> *char:
    f: *FILE = fopen(path, "rb")
    if f == None:
        return None
    defer fclose(f)          # runs on any return below
    ...
```

The deferred code is *moved*, not captured: it uses the values at the time it
runs. `return expr` evaluates `expr` before the defers run.

---

## 9. Generics

Generics are **monomorphized explicitly** — the C ABI has no overloading, so
each instance is a distinctly-named concrete type/function that you request.
A template emits no code by itself.

### Generic structs

```python
struct Vec<T>:
    data: *T
    len: i32
    def push(self: *Vec<T>, x: T): ...

declare Vec<int>       # emits struct Vec_int + method prototypes
implement Vec<int>     # emits the method bodies

v: Vec<int> = {None, 0}     # Vec<int> resolves to Vec_int
v.push(42)                  # -> Vec_int_push(&v, 42)
```

### Generic functions

```python
def max<T>(a: T, b: T) -> T:
    return a if a > b else b

declare max<int>    ; implement max<int>       # -> max_int
declare max<double> ; implement max<double>    # -> max_double

max(3, 7)        # type args inferred from arguments -> max_int
max(2.5, 1.5)    # -> max_double
```

The call infers each type parameter by unifying a parameter's type against the
argument's type (`T`, `*T`, nested). The instance must have been `declare`d.

### inline — instantiate in place

`inline X<...>` is `declare` + `implement` in one directive, with the bodies
emitted **`static inline`** (internal linkage):

```python
inline Vec<int>       # definition + bodies, right here, TU-local
inline max<int>
```

Because each translation unit gets its own local copy, several TUs may
`inline` the *same* instance and still link — no "one `implement` per
program" coordination. Use `declare`/`implement` when you want one shared
extern instance; use `inline` for self-contained files and header-style use.
Repeating `inline X<T>` in the same TU is an error.

### Mangling

| Plang | C name |
|---|---|
| `Vec<int>` | `Vec_int` |
| `Vec<*char>` | `Vec_pchar` |
| `Map<int, *char>` | `Map_int_pchar` |
| `max<int>` | `max_int` |

### Compile-time type dispatch

Both `match type(x)` and `typestr(x)` are resolved at compile time. Inside a
template they fold **per instance** and the dead branch is not even type-checked
— zero-cost dispatch (like C11 `_Generic`):

```python
def key_hash<K>(k: K) -> u64:
    match type(k):
        case *char:
            return hash_cstr(k)          # only in the *char instance
        case _:
            return hash_bytes(&k, sizeof(K))
```

`typestr(x)` returns the static type as a string; `if typestr(x) == "*char":`
prunes the same way.

---

## 10. Compile-time evaluation

- **Constant folding:** `const` integers fold in constant contexts (array
  sizes, `case` labels). Enum constants are C integer constants and stay as
  their names.
- **`const def`** — a function evaluated at compile time (primitives only),
  never emitted:

  ```python
  const def kib(n: i32) -> i32:
      return n * 1024
  buf: char[kib(4)]        # char[4096]
  ```

- **Branch pruning:** `if COND:` with a compile-time-constant `COND` keeps only
  the live branch — the idiomatic `#ifdef` without a preprocessor.
- **`is_defined(NAME)`** — 1 if `NAME` is a known compile-time constant
  (including ones injected by the driver's `-D NAME=VALUE`).
- **Predefined constants:** `__FILE__`, `__LINE__`, `__func__`, `__DATE__`,
  `__TIME__`, `__PLANG__`, `__PLANG_STD__`, `__PLANG_BACKEND__`.

### `embed` / `embed_bytes` — a file as a literal

```python
HELP:  const *char = embed("help.txt")        # text, nul-terminated
ATLAS: const u8[]  = embed_bytes("font.bin")  # bytes; len(ATLAS) == file size
```

The file's contents replace the call at parse time, so what the rest of the
compiler sees is an ordinary string literal — nothing is read at run time and
nothing enters the ABI. The path is resolved **against the directory of the
file that spells the embed**, never the working directory, so a module and its
data move together.

The two differ only in how the array is sized and what they will accept:

- `embed` yields a C string. A nul byte anywhere in the file is an error
  (it would silently truncate the string), and `T[]` gets the C length —
  contents plus the nul.
- `embed_bytes` takes any bytes at all, and `T[]` gets **exactly** the file's
  size: no terminator, so `len(ATLAS)` is the file size. Give an explicit
  `T[N]` and C's rule applies — a larger array is zero-padded, an exact fit
  drops the nul.

Both are contextual: a function or variable of your own named `embed` or
`embed_bytes` takes precedence, as with `len`.

---

## 11. Imports and C interop

```python
include <stdio.h>            # -> #include <stdio.h>   (C header)
include "vendor/thing.h"     # -> #include "vendor/thing.h"
import "point.ph"            # -> #include "point.h"   (a Plang header)
import "point.ph" as geo     # the same, plus a qualified spelling
```

`include` is for C headers, `import` for Plang ones — they are not
interchangeable, and `import <h>` is rejected with a message that says so.

### `as` — qualified names

`import "point.ph" as geo` adds a **spelling**: `geo.Point`, `geo.dist(...)`,
`geo.ORIGIN`. It takes nothing away — the flat names stay visible, which is why
putting `as` on an existing import can never break the file that does it.

What the alias buys is a check and a reader: the member has to be declared by
that module (its own imports are not re-exported, as in Python), and whoever
reads the call site can see where the name came from. Since Plang links flat,
`geo.dist` and `dist` are the same symbol; anything genuinely declared as `geo`
— a variable, a type, a function — wins over the alias.

C functions are called directly (`printf`, `malloc`, …). The emitted C is
plain and readable, so it links against any C library and can be inspected or
diffed.

### Headers (`.ph`) and the module model

- A `.ph` file is a Plang header — it emits a `.h`. Bodies written in a `.ph`
  become **prototypes** in the `.h`; the code is materialized elsewhere with
  `implement Name` in a single `.p`. (Same rule for generics.)
- `static inline` methods in a `.ph` are emitted into the `.h` (header-only),
  for small hot functions.
- A generic template lives in a `.ph`; users `declare X<...>` (definition goes
  to their `.h`) and `implement X<...>` in exactly one `.p`.

### `record` — a struct the compiler checks to be pure bytes

```python
record Vec:
    x: f64
    y: f64

    def dot(in self: Vec, b: Vec) -> f64:
        return self.x * b.x + self.y * b.y
```

A `record` is a `struct` with one extra rule: **no pointer anywhere inside** —
only numbers, bools, enums, other records, and fixed arrays of those. The rule
is checked at compile time and costs nothing at run time; what it buys is that
a value of it can be `memcpy`'d, written to a file, sent to another process and
compared as itself, and none of that silently breaks the day someone adds a
`name: const *char`. Use `struct` when it has to hold a pointer.

Rule of thumb: **record is data, struct is entity.**

Two things follow from the guarantee:

- `==` and `!=` compare **content**, field by field — never `memcmp`, because
  the padding a C compiler inserts between fields holds whatever was on the
  stack.
- `Vec(1.0, 2.0)` constructs, positionally or by name (`Vec(y=2.0, x=1.0)`,
  which must name every field). Before this, P had no way to write an aggregate
  **value** inline: it needed a variable to live in.

### `trait` — a named set of method signatures

```python
trait Comparable:
    def cmp(self: *Comparable, other: *Comparable) -> i32

implement Comparable for Point:
    def cmp(self: *Point, other: *Point) -> i32:
        return self->x - other->x

def sort<T: Comparable>(xs: *T, n: usize):
    ...            # cmp() inside is a DIRECT call

declare sort<Point>
implement sort<Point>
```

A trait names methods; an `implement <Trait> for <Type>:` block supplies them
for one type. A generic can then require it: `def sort<T: Comparable>`.

The bound is checked at **instantiation**, where the concrete type is known, so
the calls inside stay direct — **a trait never becomes a vtable**. The impl
block registers its methods as the type's own, so the call resolves through the
ordinary method lookup; nothing new is dispatched and nothing is emitted for the
trait itself.

The check is **nominal** (68.1): having the methods is not enough — the pair has
to be declared with `implement X for T:`. pscript answers the same way (66.2),
and the two languages agreeing here is worth more than the convenience of
"satisfies by accident".

`implement` serves two purposes and the `for` tells them apart:
`implement Vec<int>` instantiates a generic, `implement Printable for Vec:`
satisfies a trait.

**The orphan rule:** at most one implementation per (trait, type) in a program,
and the module must declare either the trait or the type. Without it two modules
could implement the same pair differently and the behaviour would depend on who
linked — with the error landing far from the cause.

### `for v in it` — iteration over an Iterable implementer

```python
trait Iterable:
    def has_next(self: *Iterable) -> bool
    def next(self: *Iterable) -> i64

struct Countdown:
    at: i64

implement Iterable for Countdown:
    def has_next(self: *Countdown) -> bool:
        return self->at > 0
    def next(self: *Countdown) -> i64:
        self->at -= 1
        return self->at

c: Countdown = {5}
for v in c:          # or `for v in p` where p: *Countdown
    total += v
```

`for v in x` takes a sized array (as before) **or a value whose type implements
`Iterable`** — declared, because the bound is nominal (68.1). The loop lowers in
sema to its own block: a cursor bound once, then `while __it->has_next():
v = __it->next()`. Every call is direct, nothing allocates, and no back end
knows the loop was ever a `for` — zero runtime, which is the condition of the
feature. The cursor and `v` live in the loop's block, so two loops in a row can
reuse the name. `stl/traits.ph` declares `Iterable` (with `Comparable` and
`Printable`); a local `trait Iterable:` works the same.

---

## 12. Front ends and back ends

`plangc` reads **two** languages into one AST and emits from **two** back ends,
so C and Plang compile side by side in the same project.

### Front ends

- **Plang:** `.p` source, `.ph` headers.
- **C:** `.c`/`.i` files. Understands C11 plus common GNU extensions —
  statement expressions `({...})`, `_Generic`, `__attribute__`, compound
  literals, designated initializers (including ranges), `__builtin_*`.
  A `.c` input is **preprocessed automatically** (via the compiler named by
  `--cpp` / `PLANGC_CPP`, default `cc -E`); a `.i` file is taken as already
  preprocessed.

### Back ends

- **C (default):** portable, readable C. `plangc f.p -o f.c`.
  - Default output targets **C99/C11**.
  - `--std=c89` emits **strict, conformant C89** for any C89 compiler: aliases
    map to native types (no `<stdint.h>`), designated initializers are lowered
    to positional, `#pragma once` becomes an include guard, VLAs become
    `malloc`/`free`, and 64-bit integers use `--i64-longlong` (the `long long`
    extension) or `--i64-downgrade` (map to 32-bit). Semantics are preserved.
- **QBE:** [QBE](https://c9x.me/compile/) IL. `plangc --backend qbe f.p -o
  f.ssa`. QBE handles the SysV ABI (structs by value, varargs). Requires the
  external `qbe` tool plus an assembler and linker.

### The driver

```sh
plangc file.p -o file.c              # one input, explicit output
plangc --out-dir out stl/*.ph selfhost/*.p    # many inputs, MIRRORED layout
```

`--out-dir <dir>` mirrors each input's path under `<dir>` (creating
directories): `out/stl/vec.h`, `out/selfhost/sema.c`, … Since imports are
file-relative (an `import "../stl/vec.ph"` emits `#include "../stl/vec.h"`),
the mirror resolves them internally — builds never write next to the sources.
Other flags: `-D NAME[=VAL]`, `--std=c89`, `--backend qbe`, `--cpp <cc>`.

`--inline-runtime` makes helpers the **compiler itself injects** (e.g. the
`in` operator's `strcmp`) come from self-contained inline Plang functions
instead of libc — the C output gains no `#include <string.h>`, and the QBE
binary has no undefined `strcmp`. It never touches libc calls *you* write.

### Diagnostics — clang-compatible `-W` flags

Warnings use clang's group names, defaults and flag grammar:

```sh
-W<group>   -Wno-<group>   -Werror   -Werror=<group>   -Wno-error=<group>
-Wall   -Wextra   -w   -pedantic   -pedantic-errors
```

Highlights (defaults match clang, verified case-by-case against a real
clang by `tests/clang-compare.sh`): `-Wincompatible-pointer-types`,
`-Wpointer-sign`, `-Wpointer-integer-compare`,
`-Wcompare-distinct-pointer-types`, `-Wexcess-initializers`, `-Wparentheses`,
`-Wunused-value`, `-Wreturn-type` (warning for a missing return, **error** for
`return;` in a non-void function), `-Wimplicit-function-declaration` and
`-Wint-conversion` (errors by default, demotable with `-Wno-error=`), and the
`-Wall` set: `-Wunused-variable`, `-Wuninitialized`,
`-Wunused-but-set-variable`. GNU/C23 extensions (`{}` initializers, empty
structs, struct self-casts, `void*` arithmetic, `sizeof(void)`) are accepted
by default like gcc/clang; `-pedantic` warns about them and
`-pedantic-errors` rejects them. Plang code is held to the same rules as C
input — the compiler compiles itself with `-Wall` clean.

### C11 → C89, and embedded targets

Because the C front end accepts modern C and the C back end can emit strict
C89, `plangc` doubles as a **C11-to-C89 translator**: modern C (and GNU
extensions) compiled down to run on an ancient or vendor **C89-only** toolchain.

This makes Plang — and the C→C89 path — a fit for **embedded systems, OS
kernels, and microcontrollers**: wherever there is a small conformant C89
compiler, you get either a nicer language or a way to run modern code on it.
The output is plain C with no runtime, so it links against any C library.

Both back ends produce identical program behavior; the compiler self-hosts and
verifies a 3-stage fixed point (stage2 and stage3 generate byte-identical C).

---

## 13. Memory model

- No garbage collector, no hidden allocations. You call `malloc`/`free` (or a
  library allocator) yourself.
- Value types (`int`, structs, `T[N]`) live inline; assignment copies them.
  Containers of value types (`Vec<Point>`) store elements contiguously and own
  their storage — no per-element indirection.
- Pointers are raw. `None` is the null pointer. Lifetimes are the programmer's
  responsibility, exactly as in C.
- `defer` is the tool for deterministic cleanup at scope exit.

---

## Appendix: hello world

```python
import <stdio.h>

def main() -> int:
    printf("hello from Plang\n")
    return 0
```

```sh
plangc hello.p -o hello.c && cc hello.c -o hello && ./hello
```
