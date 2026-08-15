# `embed_bytes` with data that is really BINARY (63.1/63.5).
#
# The file holds every byte value, each followed by an ASCII '3'. That second
# byte is the trap: a byte like 0x0A is written `\012` in the C literal, and a
# reader that does not stop at THREE octal digits (C11 6.4.4.4) would read
# `\0123`, producing a value past a byte AND swallowing the '3' — shifting
# everything after it. Two back ends decode that literal by hand, so the bug is
# invisible in the C output and shows up only here.
include <stdio.h>

DATA: const u8[] = embed_bytes("42_embed_bytes.bin")

def main() -> int:
    n: i32 = i32(len(DATA))
    sum: i64 = 0
    for i in range(n):
        sum += i64(DATA[i])
    printf("bytes %d sum %lld\n", n, sum)
    # every value landed where it belongs, and the '3' after it survived
    bad: i32 = -1
    for i in range(256):
        if i32(DATA[i * 2]) != i or DATA[i * 2 + 1] != u8('3'):
            bad = i
            break
    printf("first wrong %d\n", bad)
    printf("0a=%d after=%c ff=%d\n", DATA[10 * 2], char(DATA[10 * 2 + 1]), DATA[255 * 2])
    return 0
