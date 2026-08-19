"""Left to right, as Python promises — which C does not (44.2/49.x).

A call in one argument and a read of what it writes in the next: the answer is
decided by the ORDER, so the compiler binds all but the last effectful value to
a temporary before the call. A module variable counts as effectful to read,
because a call sitting next to it may be the thing that writes it.
"""

n = 0

def bump() -> int:
    global n
    n += 1
    return n

def main():
    print(bump(), n)
    print(n, bump())
    xs = [1, 2, 3]
    print(len(xs), bump(), n)
main()


# ---- ONCE, and only once, on BOTH sides of an operator ----
#
# `f() + g()` binds each operand to a hidden temporary so the ORDER is pinned
# (C promises none). The trap is that the substitution which makes the operator
# read those temporaries is a single pair of slots, and a nested lowering saves
# and clears it — so installing the left one and then lowering the right THROUGH
# it lost the left, and the left operand was lowered a second time.
#
# Nothing caught it: with pure operands the answer is identical and only the
# clock says so — `fib(n-1) + fib(n-2)` went from 2^n calls to 3^n. A counter is
# what makes it visible.
calls = 0


def tick(by: int) -> int:
    global calls
    calls += 1
    return by


print("both sides once:", tick(3) + tick(4), calls)
calls = 0
print("nested once:", tick(1) + tick(2) * tick(3), calls)
calls = 0
print("compare once:", tick(5) < tick(6), calls)
calls = 0
s2 = str(tick(1)) + str(tick(2))
print("string once:", s2, calls)
