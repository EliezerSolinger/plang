"""O mesmo SHA-256, visto do outro lado da fronteira (45.5).

Este teste existe para provar que não há uma segunda implementação: o pscript
chama a mesma função em P, com `list<u8>` a virar `CBytes` na ida e `CStr` a
virar `str` na volta.
"""

import <sha2/sha2.ph>


def bytes_de(s: str) -> list<u8>:
    b: list<u8> = []
    for ch in s:
        b.append(u8(ord(ch)))
    return b


e: list<int> = [0, 0]


def conf(nome: str, tem: str, quer: str):
    if tem == quer:
        e[0] += 1
    else:
        e[1] += 1
        print(f"  {nome}: deu    {tem}")
        print(f"  {nome}: queria {quer}")


vazio: list<u8> = []
conf("vazio", sha256_of(vazio),
     "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
conf("abc", sha256_of(bytes_de("abc")),
     "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
conf("448 bits", sha256_of(bytes_de("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
     "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")

# um milhão de 'a': o caminho de muitos blocos, que é o do tarball de verdade
mil: list<u8> = []
for _ in range(1000):
    mil.append(u8(97))
grande: list<u8> = []
for _ in range(1000):
    for b in mil:
        grande.append(b)
conf("um milhão de 'a'", sha256_of(grande),
     "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")

print(f"sha2/pscript: {e[0]} ok, {e[1]} failed")
