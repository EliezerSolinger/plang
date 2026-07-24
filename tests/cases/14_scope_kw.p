# pass / global / nonlocal (adaptação P das keywords Python)
include <stdio.h>
counter: i32 = 0
other: i32 = 100

def noop():
    pass

def bump():
    global counter, other      # vários nomes por linha (estilo Python)
    counter = counter + 1
    other = other + counter

def pick(c: i32) -> i32:
    if c > 0:
        nonlocal r
        r = c * 10
    else:
        r = -1
    return r

def main() -> int:
    noop()
    bump()
    bump()
    printf("%d %d %d %d\n", counter, other, pick(3), pick(0))
    return 0
