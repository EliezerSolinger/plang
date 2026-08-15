"""`embed` and `embed_bytes` (63.1/63.5): the file becomes DATA at compile time.

The text form is a `str` like any other, so it costs what a string literal
costs. The binary form is the fixed array of 33.4, initialized from a static —
which is why a megabyte of font is a megabyte of data and not a megabyte of AST.
"""

TEXT: str = embed("embed_data.txt")
BYTES: u8[6] = embed_bytes("embed_data.bin")

def main():
    print(len(TEXT), TEXT[0:5])
    print(len(BYTES), BYTES[0], BYTES[3], BYTES[4], BYTES[5])
    local = embed("embed_data.txt")
    print(local == TEXT)
    total = 0
    for b in BYTES:
        total += int(b)
    print("sum", total)
main()
