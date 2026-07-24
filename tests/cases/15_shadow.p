# regression: lexical scoping in the QBE backend. Homonymous variables in
# sibling blocks with DIFFERENT types used to be fused into one slot by the
# flat name-deduped var model — the second one inherited the first's type,
# corrupting field offsets and store classes (the parse_stmt `blk` bug).
include <stdio.h>

struct Wide:
    a: i64
    b: i64

struct Narrow:
    x: i32

def f(sel: i32) -> i64:
    if sel == 0:
        v: Wide
        v.a = 100
        v.b = 23
        return v.a + v.b
    if sel == 1:
        v: Narrow            # same NAME, different type/size (sibling scope)
        v.x = 7
        return i64(v.x)
    v: *char = "ptr"         # and a third with pointer type
    return i64(v[0])

def nested() -> i32:
    total: i32 = 0
    if 1 == 1:
        n: i32 = 10
        total += n
        if 2 == 2:
            m: Narrow        # aggregate declared in a nested block
            m.x = 5
            total += m.x
    if 3 == 3:
        n: i64 = 1000        # sibling block reuses the name with another type
        total += i32(n)
    return total

def main() -> int:
    printf("%lld %lld %lld\n", f(0), f(1), f(2))
    printf("%d\n", nested())
    return 0
