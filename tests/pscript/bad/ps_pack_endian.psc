# the byte order is an `Endian`, not a number (59.2, extended)
record R:
    a: int
b = pack(R(1), 1)
