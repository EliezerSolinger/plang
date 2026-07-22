struct S:
    fptr: def() -> int

def foo() -> int:
    return 0

def main() -> int:
    v: S
    v.fptr = foo
    return v.fptr()
