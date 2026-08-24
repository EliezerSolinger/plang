"""`const` no topo do módulo, e o congelamento fundo (61.3).

Two halves of one decision, and only one of them existed.

**A const that has to be BUILT.** `const NAMES = ["ada"]` was refused with "a
module-level value that has to be built at run time is not compiled yet": a
module const became a C static, and a static cannot hold a list. But a MUTABLE
module variable already lives in the context's own set and is built in the
program's own order — so a const does too. What `const` means is the sema's
business; where it lives is a question about the context, and the answer was
already written next door.

**And `const` freezes DEEP.** 61.3 says a const forbids rebinding AND mutation.
Rebinding was refused; `NAMES.append(x)` was not, and neither was
`NAMES[0] = x`. Now both are, wherever the const is — module or local — and the
check walks to the ROOT of the expression, because `cfg.rows.append(x)` mutates
what `cfg` owns just as much as `cfg.append(x)` would.

> The frozen flag had to be SEPARATE from `is_const`, and finding out why took a
> broken build: `self` in a struct method is const in the sense that it cannot
> be rebound, and mutating what it points at is the entire reason the method
> exists (20.1). A record's `in self` is frozen in both senses (57.1).
"""

const NAMES = ["ada", "linus", "grace"]
const SIZES: Dict<str, int> = {"small": 1, "large": 99}
const GREETING = "hello " + "world"
const TABLE: List<int> = [n * 2 for n in range(4)]

print(f"names {len(NAMES)}: {NAMES[0]} {NAMES[2]}")
big = SIZES["large"]
print(f"sizes {len(SIZES)}: {big}")
print(f"greeting {GREETING}")
print(f"table {len(TABLE)}: {TABLE[3]}")

# reading is all a const is for, and everything below reads
total = 0
for v in TABLE:
    total += v
print(f"total {total}")


def uses_const() -> str:
    # a const is visible from a function, because it lives in the context's set
    # like any other module variable
    return NAMES[1]


print(f"from a function {uses_const()}")


# a struct method still writes through `self`: const in the sense of not being
# rebindable, and mutation is the reason the method exists
struct Counter:
    n: int

    def bump(self):
        self.n += 1


c = Counter(0)
c.bump()
c.bump()
print(f"struct {c.n}")
