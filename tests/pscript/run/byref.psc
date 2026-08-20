"""`out` and `ref` in pscript (65.12) — the two thirds of the trio 55.4 left out.

The reason they came back is the RECORD. It is a value type (52.1), so a big one
is copied in and copied back; `ref` skips both copies, and `out` says the call
is what initializes the variable.

Three things are refused, and each for a reason worth stating:

  * calling without the word (`bump(n)` where `n` is `ref`) — a call that can
    write to your variable says so where you READ the call, which is the same
    rule P has;
  * a `str`, `list`, `dict` or `struct` — those are already references, so
    writing through one is what mutating it does, and rebinding the caller's
    name is what a return value is for;
  * a FIELD or an element (`ref h.v`) — that address points INSIDE an object the
    collector moves, which 17.2 refuses outright.

`out` and `ref` are contextual words, recognised only when an identifier follows
— so a variable called `out` still works, and that is tested too.
"""

record Vec:
    x: float
    y: float


def scale(ref v: Vec, k: float):
    v.x *= k
    v.y *= k


def bump(ref n: int, by: int):
    n += by


def fill(out n: int):
    n = 42


def sum3(in v: Vec) -> float:
    return v.x + v.y


a = Vec(1.0, 2.0)
scale(ref a, 3.0)
print(f"record {a.x} {a.y}")

# a module variable and a local both work: one lives in the context's globals,
# the other on the C stack, and neither address moves
g = 10
bump(ref g, 5)
print(f"global {g}")


def locals_too() -> int:
    m = 5
    bump(ref m, 2)
    z = 0
    fill(out z)
    return m + z


print(f"local {locals_too()}")

# `in` still reads without copying, and the three words compose in one signature
print(f"in {sum3(in a)}")

# A fixed array needs NEITHER word: it is already handed over as a reference
# (C decays it), so a plain parameter writes through — and `ref` on one is
# refused for saying nothing. `in` on an array is the promise not to write,
# which is what 60.2 asks for.
def zero(xs: int[3]):
    xs[0] = 0


def total(in xs: int[3]) -> int:
    return xs[0] + xs[1] + xs[2]


arr: int[3] = [7, 8, 9]
print(f"array in {total(in arr)}")
zero(arr)
print(f"array written {arr[0]} {total(in arr)}")

# the SIZE may be a named const, which is the shape a real program writes —
# and it has to be FOLDED, because C says an array size is a constant
# expression and a `static const int` is not one (that is C++)
const WIDTH: int = 3


def widest(in row: int[WIDTH]) -> int:
    best = row[0]
    for v in row:
        if v > best:
            best = v
    return best


sized: int[WIDTH] = [4, 9, 2]
print(f"const size {len(sized)} {widest(in sized)}")

# and a LOCAL array with a literal, which is the third of the three places
# 33.4 says `T[N]` is a complete type in
def local_array() -> int:
    ys: int[3] = [1, 2, 3]
    ys[1] = 9
    return ys[0] + ys[1] + ys[2]


print(f"array local {local_array()}")

# the words are still names
out = 3
ref = 4
print(f"names {out + ref}")
