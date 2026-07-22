def zero() -> int:
    return 0

struct S:
    zerofunc: def() -> int

s: S = {&zero}

def anon() -> *S:
    return &s

def go() -> def() -> *S:
    return &anon

def main() -> int:
    return go()()->zerofunc()
