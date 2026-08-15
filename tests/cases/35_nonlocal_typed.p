# `nonlocal x` says the FIRST assignment of x lives at function scope, so the
# name survives the block that assigns it — Python's if/else idiom.
#
# The typed form used to declare a SECOND, block-scoped variable that shadowed
# the hoisted one, so the read afterwards saw a slot nobody wrote.
include <stdio.h>

def pick(n: i32) -> const *char:
    nonlocal label
    if n > 2:
        label: const *char = "big"     # typed first assignment
    else:
        label = "small"
    return label

def total(n: i32) -> i64:
    nonlocal acc
    if n > 0:
        acc: i64 = 10
    else:
        acc = 20
    acc += 5
    return acc

def main() -> int:
    printf("%s %s\n", pick(3), pick(1))
    printf("%lld %lld\n", total(1), total(0))
    return 0
