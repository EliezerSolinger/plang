"""The official FIPS 180-4 vectors, plus the ones people tend to recognise.

A cryptographic hash is the one thing in this repository where "looks right"
means nothing: a one-bit error anywhere gives a plausible and completely wrong
number. That is why the test is against the PUBLISHED vectors, and not against
what our implementation produced on the day it was written.

The first three are from the FIPS appendix; the fourth (a million 'a') exercises
the multi-block path and the padding at its limit; the fifth and sixth exercise
the two cases that break hasty implementations — the message that ends exactly at
byte 55 and the one that ends at 56, which is where the length stops fitting in
the last block.
"""
include <stdio.h>
include <string.h>
include <stdlib.h>
import <sha2/sha2.ph>

private const EXPECT_EMPTY: const *char = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
private const EXPECT_ABC: const *char = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
private const EXPECT_448: const *char = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
private const EXPECT_MILLION: const *char = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"

ok: i32 = 0
failed: i32 = 0

private def check(name: const *char, data: const *char, n: usize, expected: const *char):
    hex: char[65]
    sha256_hex(data, n, hex)
    if strcmp(hex, expected) == 0:
        ok += 1
    else:
        failed += 1
        printf("  FAIL %s\n    expected %s\n    got      %s\n", name, expected, hex)

# ---------- SHA-512 (FIPS 180-4 §6.4) ----------
#
# The same two official vectors and the boundaries where the padding decides —
# which here are different ones, because the block is 128 bytes and the length
# takes 16: 111 (fits exactly), 112 (does not fit, and the padding takes one more
# block), 113, 127, 128 and 129.
private def check512(name: const *char, msg: const *char, n: usize, wants: const *char, ref ok: i32, ref bad: i32):
    got: char[129]
    sha512_hex(msg, n, got)
    if strcmp(got, wants) == 0:
        ok += 1
    else:
        bad += 1
        printf("  %s:\n    got    %s\n    wanted %s\n", name, got, wants)

def prove512(ref ok: i32, ref bad: i32):
    a111: char[130]
    for i in range(129):
        a111[i] = 'a'
    a111[129] = '\0'
    check512("empty", "", usize(0),
            "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e", ref ok, ref bad)
    check512("abc", "abc", usize(3),
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f", ref ok, ref bad)
    check512("896 bits", "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu", usize(112),
            "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909", ref ok, ref bad)
    check512("111 'a'", a111, usize(111),
            "fa9121c7b32b9e01733d034cfc78cbf67f926c7ed83e82200ef86818196921760b4beff48404df811b953828274461673c68d04e297b0eb7b2b4d60fc6b566a2", ref ok, ref bad)
    check512("112 'a'", a111, usize(112),
            "c01d080efd492776a1c43bd23dd99d0a2e626d481e16782e75d54c2503b5dc32bd05f0f1ba33e568b88fd2d970929b719ecbb152f58f130a407c8830604b70ca", ref ok, ref bad)
    check512("113 'a'", a111, usize(113),
            "55ddd8ac210a6e18ba1ee055af84c966e0dbff091c43580ae1be703bdb85da31acf6948cf5bd90c55a20e5450f22fb89bd8d0085e39f85a86cc46abbca75e24d", ref ok, ref bad)
    check512("127 'a'", a111, usize(127),
            "828613968b501dc00a97e08c73b118aa8876c26b8aac93df128502ab360f91bab50a51e088769a5c1eff4782ace147dce3642554199876374291f5d921629502", ref ok, ref bad)
    check512("128 'a'", a111, usize(128),
            "b73d1929aa615934e61a871596b3f3b33359f42b8175602e89f7e06e5f658a243667807ed300314b95cacdd579f3e33abdfbe351909519a846d465c59582f321", ref ok, ref bad)
    check512("129 'a'", a111, usize(129),
            "4f681e0bd53cda4b5a2041cc8a06f2eabde44fb16c951fbd5b87702f07aeab611565b19c47fde30587177ebb852e3971bbd8d3fd30da18d71037dfbd98420429", ref ok, ref bad)


def main() -> int:
    check("empty", "", 0, EXPECT_EMPTY)
    check("abc", "abc", 3, EXPECT_ABC)
    m448: const *char = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    check("448 bits", m448, strlen(m448), EXPECT_448)

    # a million 'a': many blocks, and the padding far from the start
    n: usize = 1000000
    big: *char = (*char)(malloc(n))
    memset(big, int('a'), n)
    check("a million a", big, n, EXPECT_MILLION)
    free(big)

    # THE PADDING BOUNDARIES, which is where a hasty implementation goes wrong:
    # 55 bytes fit with the length in the same block, 56 do not and force an
    # extra block; 63/64/65 are the block boundary itself. The values come from
    # python3's `hashlib` — the same rule as this repository's other oracles, and
    # the only honest one: a hash test that checked what our own implementation
    # produced would not be checking anything at all.
    lim: const *char[5] = {"d5e285683cd4efc02d021a5c62014694958901005d6f71e89e0989fac77e4072",
                           "04c26261370ee7541549d16dee320c723e3fd14671e66a099afe0a377c16888e",
                           "75220b47218278e656f2013bb8f0c455a25eaf01e86c64924e9d48d89776d6f2",
                           "7ce100971f64e7001e8fe5a51973ecdfe1ced42befe7ee8d5fd6219506b5393c",
                           "9537c5fdf120482f7d58d25e9ed583f52c02b4e304ea814db1633ad565aed7e9"}
    sizes: const i32[5] = {55, 56, 63, 64, 65}
    bx: char[80]
    memset(bx, int('x'), 80)
    for i in range(5):
        name: char[32]
        sprintf(name, "%d bytes", sizes[i])
        check(name, bx, usize(sizes[i]), lim[i])

    # and the init/update/final trio has to give the SAME as the quick path:
    # whoever has the bytes in pieces cannot get a different hash
    s: Sha256
    sha256_init(out s)
    sha256_update(ref s, "a", 1)
    sha256_update(ref s, "b", 1)
    sha256_update(ref s, "c", 1)
    d: char[32]
    sha256_final(ref s, d)
    hex: char[65]
    quick: char[65]
    for i in range(32):
        sprintf(hex + i * 2, "%02x", int(u8(d[i])))
    sha256_hex("abc", 3, quick)
    if strcmp(hex, quick) == 0:
        ok += 1
    else:
        failed += 1
        printf("  FAIL in pieces: %s != %s\n", hex, quick)

    prove512(ref ok, ref failed)
    printf("sha2: %d ok, %d failed\n", ok, failed)
    return 1 if failed > 0 else 0
