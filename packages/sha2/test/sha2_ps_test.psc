"""The same SHA-256, seen from the other side of the boundary (45.5).

This test exists to prove there is no second implementation: pscript calls the
same function in P, with `list<u8>` becoming a `CBytes` on the way in and a
`CStr` becoming a `str` on the way back.
"""

import <sha2/sha2.ph>


def bytes_of(s: str) -> list<u8>:
    b: list<u8> = []
    for ch in s:
        b.append(u8(ord(ch)))
    return b


e: list<int> = [0, 0]


def check(name: str, got: str, wants: str):
    if got == wants:
        e[0] += 1
    else:
        e[1] += 1
        print(f"  {name}: got    {got}")
        print(f"  {name}: wanted {wants}")


empty: list<u8> = []
check("empty", sha256_of(empty),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
check("abc", sha256_of(bytes_of("abc")),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
check("448 bits", sha256_of(bytes_of("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")

# a million 'a': the many-block path, which is the real tarball's
thousand: list<u8> = []
for _ in range(1000):
    thousand.append(u8(97))
big: list<u8> = []
for _ in range(1000):
    for b in thousand:
        big.append(b)
check("a million 'a'", sha256_of(big),
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")

print(f"sha2/pscript: {e[0]} ok, {e[1]} failed")
