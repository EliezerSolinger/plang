# -Wswitch: a `match` over an enum with NO `case _:` that leaves enumerators
# uncovered. On by default (clang's default too), promoted to an error here via
# the .flags file so the suite can assert it.
#
# This is the shape that once let ST_BLOCK fall out of the QBE backend's
# collect_vars unnoticed: a dispatch over a node kind, no catch-all, and a kind
# nobody wrote a case for. Falling out of a `match` emits nothing and says
# nothing — which is why the omission has to be reported here.
include <stdio.h>

enum Color:
    RED
    GREEN
    BLUE
    PURPLE

def name_of(c: Color) -> const *char:
    match c:
        case RED:
            return "red"
        case GREEN:
            return "green"
    return "?"

def main() -> i32:
    printf("%s\n", name_of(RED))
    return 0
