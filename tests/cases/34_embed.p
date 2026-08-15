# embed()/embed_bytes(): comptime file inclusion. The file's bytes become a
# string literal at parse time, so the rest of the compiler only ever sees a
# literal — the array length included, which is what makes `len(BLOB)` fold.
include <stdio.h>
include <string.h>

# text: nul-terminated, so the declared length carries the nul like C's
# `char x[] = "..."`
TEXT: const *char = embed("34_embed.txt")
TEXT_ARR: const char[] = embed("34_embed.txt")

# bytes: the array is EXACTLY the file's size — no nul, because the file's
# own bytes are the whole content
BLOB: const u8[] = embed_bytes("34_embed.bin")

# a fixed size still wins over inference, and C's rule applies: an initializer
# that fills the array EXACTLY drops the nul, a larger array is zero-padded
EXACT: const u8[13] = embed_bytes("34_embed.bin")
PADDED: const u8[16] = embed_bytes("34_embed.bin")


def dump(name: const *char, b: const *u8, n: i32):
    printf("%s[%d]:", name, n)
    for i in range(n):
        printf(" %02x", b[i])
    printf("\n")


def main() -> int:
    printf("%s", TEXT)
    printf("text bytes: %d\n", i32(strlen(TEXT)))
    printf("text array: %d\n", len(TEXT_ARR))
    printf("blob bytes: %d\n", len(BLOB))
    dump("BLOB", BLOB, len(BLOB))
    dump("EXACT", EXACT, len(EXACT))
    dump("PADDED", PADDED, len(PADDED))
    # the nul survives inside the byte array: it is data, not a terminator
    printf("nul at 0: %d, nul at 7: %d\n", i32(BLOB[0]), i32(BLOB[7]))
    # embedding inside an expression works too — it is just a literal
    printf("local: %d\n", i32(strlen(embed("34_embed.txt"))))
    return 0
