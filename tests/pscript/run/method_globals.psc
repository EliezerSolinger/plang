"""A METHOD is a function body like any other (42.2).

It used to be checked in a pass of its own, before the top-level statements had
declared the module variables — so a method could not read a name that a free
function beside it read fine. The signatures still resolve early (a type from
another module carries a qualifier that resolving strips, and a call checked
before that would refuse the very type it asked for); only the bodies moved.
"""

LIMIT: int = 7
NAME: str = "buffer"
counter = 0


def free_fn() -> int:
    return LIMIT


struct S:
    n: int

    def total(self) -> int:
        return LIMIT + self.n

    def label(self) -> str:
        return NAME + "/" + str(self.n)

    def bump(self):
        global counter
        counter += LIMIT


record R:
    v: int

    def scaled(in self) -> int:
        return self.v * LIMIT


s = S(3)
print(free_fn(), s.total(), s.label())
s.bump()
s.bump()
print("counter", counter)
print("record", R(2).scaled())
