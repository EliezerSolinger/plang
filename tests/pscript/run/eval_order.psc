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
