def main() -> int:
    x: int
    foo: *void
    bar: **void
    x = 0
    foo = (*void)(&x)
    bar = &foo
    return **(**int)(bar)
