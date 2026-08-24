"""`try` / `catch` / `finally` and `raise`, on the flag model of 49.2.

There is no `goto` to an unwind label — P forbids it in a function with `defer`
and 50.1 already refused it for `async`. So each statement of the try body is
guarded by a flag the raise clears: once it is False the rest of the body is
skipped and control falls to the catch. That IS 49.2's check, with a local
target instead of a label.

`finally` becomes P's `defer`, which is exactly its meaning: it runs on every
way out of the block, a `return` from inside the try included.
"""

def risky(n: int) -> int:
    if n < 0:
        raise error("negative input")
    return n * 2


def guarded(n: int) -> int:
    try:
        return risky(n)
    catch e:
        print("caught: " + e.message)
        return -1


print("ok  " + str(guarded(21)))
print("bad " + str(guarded(-1)))

# an exception raised by the RUNTIME is caught the same way
try:
    x = 10 // 0
    print("unreachable " + str(x))
catch e:
    print("runtime: " + e.message + " (zero? " + str(e.category == ZERO) + ")")

# finally runs either way
def with_cleanup(fail: bool) -> int:
    try:
        if fail:
            raise error("asked to fail")
        return 1
    catch e:
        return 2
    finally:
        print("cleanup ran")


print("no fail -> " + str(with_cleanup(False)))
print("fail    -> " + str(with_cleanup(True)))

# the rest of the try body is skipped after a raise
try:
    print("before")
    raise error("stop here")
    print("after — must not print")
catch e:
    print("handled: " + e.message)

# re-raising passes the same failure on
def rethrow() -> int:
    try:
        raise error("original")
    catch e:
        raise e
    return 0


try:
    n = rethrow()
    print("unreachable " + str(n))
catch e:
    print("rethrown: " + e.message)

print("done")


# 15.2: the category has a NAME. `e.category == IO` reads like what it means,
# and the enum comes from the prelude — no program declares it.
try:
    empty: List<int> = []
    print(empty[3])
catch e:
    print("index?", e.category == INDEX, "io?", e.category == IO)

try:
    raise error("no such thing", IO)
catch e:
    print("mine", e.category == IO, e.message)
