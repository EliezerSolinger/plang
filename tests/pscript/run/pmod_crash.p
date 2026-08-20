import "pmod_crash.ph"

# The address goes through a function so the C compiler cannot see the constant
# and turn the store into something else — a null it can prove is a null is
# undefined behaviour it may delete.
static def wild(n: i64) -> *i32:
    return (*i32)(n)

def crash_now():
    p: *i32 = wild(4)
    *p = 1
