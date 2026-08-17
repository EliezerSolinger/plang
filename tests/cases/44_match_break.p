# `break` inside a `match` arm.
#
# The C back end prints a `switch`, and there `break` leaves the switch — that
# is, it ends the ARM. The QBE back end had no break target for a `match`: the
# stack was empty and the jump went to a block that does not exist, which `qbe`
# refused with "block @l0 is used undefined". The two have to say the same
# thing, and a `match` is breakable in both.
#
# (A P `match` does not fall through from one arm to the next, so this `break`
# only serves to leave early — which is exactly what it does.)
include <stdio.h>

def classify(n: i32) -> i32:
    r: i32 = 0
    match n:
        case 1:
            r = 10
            break
            r = 99          # unreachable, on purpose
        case 2:
            r = 20
        case _:
            r = 30
    return r

# and inside a loop the arm's `break` is still the MATCH's, not the loop's:
# leaving the loop takes a condition, which is what C does too
def count_to(limit: i32) -> i32:
    total: i32 = 0
    i: i32 = 0
    while i < limit:
        match i % 3:
            case 0:
                total += 1
                break
            case _:
                total += 10
        i += 1
    return total

def main() -> int:
    printf("%d %d %d\n", classify(1), classify(2), classify(7))
    printf("%d\n", count_to(6))
    return 0
