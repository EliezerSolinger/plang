"""`assert` stripped by the build (46.4), which is what `-O` means here.

The companion `.flags` file is what makes this a gate: the same program without
`-O` would die on the first assert, and the only way to see that a flag CHANGED
what was emitted is to build it with the flag. `-O` says nothing about
optimisation — the C compiler is what optimises — it is the spelling a Python
reader already knows.
"""

n = 1

assert n == 2, "this would stop the program"
print("past the first")

assert False
print("past the second")


def checked(v: int) -> int:
    assert v > 100, "and inside a function too"
    return v


print(f"got {checked(1)}")
