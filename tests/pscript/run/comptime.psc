"""The comptime surface of 65.10/65.11, and the `-O` of 46.4.

`__FILE__`, `__LINE__`, `__func__` and `__COUNTER__` are folded to literals by
the front end, exactly as the P folds them — there is no preprocessor in either
language, so whoever READS the name has to answer it.

`is_defined`, `typestr` and `hasfield` answer at compile time too, and the first
one never CHECKS its argument: the whole point of asking is that the name may
not exist.
"""


def where() -> str:
    return __func__


record Vec:
    x: float
    y: float


print(f"line {__LINE__}")
print(f"func {where()}")
print(f"counter {__COUNTER__} {__COUNTER__} {__COUNTER__}")

n = 3
print(f"defined {is_defined(n)} {is_defined(Vec)} {is_defined(where)} {is_defined(nothing_at_all)}")
ti = typestr(n)
tf = typestr(1.5)
ts = typestr("x")
tl = typestr([1, 2])
print(f"typestr {ti} {tf} {ts} {tl}")
hx = hasfield(Vec, "x")
hz = hasfield(Vec, "z")
print(f"hasfield {hx} {hz}")

# the branch a missing name prunes: this is what `is_defined` is FOR
if is_defined(nothing_at_all):
    print("never")
else:
    print("pruned")

# `assert` runs unless the build strips it (46.4). This one holds, so it is the
# stripping that a second build measures — `tests/pscript/bad/` cannot, because
# there the program must fail.
assert n == 3, "three"
print("assert passed")
