include <stdio.h>

def add(a: i32, b: i32) -> i32:
    return a + b

def get_add() -> def(i32, i32) -> i32:
    return add

def main() -> i32:
    f: def(i32, i32) -> i32 = get_add()
    printf("%d\n", f(3, 4))
    return 0
