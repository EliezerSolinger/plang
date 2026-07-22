# typestr(x) folds at compile time, so `if typestr(x) == "T":` prunes the dead
# branch per instantiation (zero-cost type dispatch, like `match type`). The
# dead branch is not even type-checked — so strlen on an int below is fine.
include <stdio.h>
include <string.h>

struct Box<T>:
    val: T
    def measure(self: *Box<T>) -> i32:
        if typestr(self->val) == "*char":
            return i32(strlen(self->val))   # pruned away when T = int
        else:
            return i32(self->val)           # pruned away when T = *char

declare Box<int>
declare Box<*char>
implement Box<int>
implement Box<*char>

def main() -> int:
    a: Box<int> = {42}
    b: Box<*char> = {"hello"}
    printf("%d %d\n", a.measure(), b.measure())   # 42 5
    return 0
