def main() -> int:
    i: int
    q: *int
    p: *void
    i = 0 if i else 0l
    p = (*void)(0) if i else 0
    p = 0 if i else (*void)(0)
    p = 0 if i else (*void)(0)
    q = 0 if i else p
    q = p if i else 0
    q = q if i else 0
    q = 0 if i else q
    return int(q)
