def outer(n: int) -> int:
    def inner() -> int:
        return 1
    return inner()
