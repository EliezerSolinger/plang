"""`hash` e `hmac` (S2), vistos do lado do pscript — que é o lado que os vai usar.

Este ficheiro é duas coisas ao mesmo tempo. É o portão dos VECTORES OFICIAIS
(RFC 1321 para o MD5, FIPS 180-4 para o SHA-1, RFC 4231 para o HMAC), e é a prova
de que **não há uma segunda implementação**: o pscript chama a mesma função em P
que o compilador e o `pforge` chamam, com um `List<u8>` a virar `CBytes` à ida e
um `CStr` a virar `str` à volta (45.5/84.1).

E diz-se aqui, onde se lê: **o CRC32 é uma soma de verificação e o SHA-1 e o MD5
estão partidos.** Estão neste pacote para LER o que já existe — um id de objecto
do git é SHA-1, e meio mundo ainda publica MD5 — e não para decidir se se confia
em alguma coisa. Isso é o `sha2`, e o gestor de pacotes já o usa.
"""
import <hash/hash.ph>
import <hmac/hmac.ph>


def b(s: str) -> bytes:
    # was `u8(ord(ch))`, which is Latin-1; `encode()` gives the UTF-8 the string
    # already holds
    return s.encode()


def rep(v: int, n: int) -> List<u8>:
    out: List<u8> = []
    for _ in range(n):
        out.append(u8(v))
    return out


e: List<int> = [0, 0]


def check(name: str, got: str, wants: str):
    if got == wants:
        e[0] += 1
    else:
        e[1] += 1
        print("  " + name + ": deu   " + got)
        print("  " + name + ": devia " + wants)


def main():
    empty: List<u8> = []

    # ---- CRC32 (IEEE): os dois valores que toda a gente conhece ----
    check("crc32 vazio", crc32_hex(empty), "00000000")
    check("crc32 123456789", crc32_hex(b("123456789")), "cbf43926")
    # e em pedaços dá o mesmo que inteiro — que é o que permite verificar um
    # fluxo sem o segurar
    half = crc32_update(0, b("12345"))
    check("crc32 aos pedacos", str(crc32_update(half, b("6789"))), str(crc32_of(b("123456789"))))

    # ---- SHA-1 (FIPS 180-4) ----
    check("sha1 vazio", sha1_of(empty), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    check("sha1 abc", sha1_of(b("abc")), "a9993e364706816aba3e25717850c26c9cd0d89d")
    check("sha1 448 bits", sha1_of(b("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
          "84983e441c3bd26ebaae4aa1f95129e5e54670f1")

    # ---- MD5 (RFC 1321 §A.5) ----
    check("md5 vazio", md5_of(empty), "d41d8cd98f00b204e9800998ecf8427e")
    check("md5 abc", md5_of(b("abc")), "900150983cd24fb0d6963f7d28e17f72")
    check("md5 message digest", md5_of(b("message digest")), "f96b697d7cb7938d525a2f31aaf161d0")
    check("md5 alfabeto", md5_of(b("abcdefghijklmnopqrstuvwxyz")), "c3fcd3d76192e4007dfb496cca67e13b")

    # ---- o caminho de MUITOS blocos, que é onde o enchimento se engana ----
    mil = rep(97, 1000)
    million: List<u8> = []
    for _ in range(1000):
        for x in mil:
            million.append(x)
    check("sha1 um milhao de 'a'", sha1_of(million), "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
    check("md5 um milhao de 'a'", md5_of(million), "7707d6ae4e027c70eea2a935c2296f21")

    # ---- e a fronteira dos 56 bytes, onde o bloco extra nasce ----
    for n in range(50, 66):
        _ = sha1_of(rep(65, n))
        _ = md5_of(rep(65, n))
    check("fronteira 55", sha1_of(rep(97, 55)), "c1c8bbdc22796e28c0e15163d20899b65621d65a")
    check("fronteira 56", sha1_of(rep(97, 56)), "c2db330f6083854c99d4b5bfb6e8f29f201be699")

    # ---- HMAC-SHA256: RFC 4231 ----
    check("hmac caso 1", hmac_sha256(rep(11, 20), b("Hi There")),
          "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    check("hmac caso 2", hmac_sha256(b("Jefe"), b("what do ya want for nothing?")),
          "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    check("hmac caso 3", hmac_sha256(rep(170, 20), rep(221, 50)),
          "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe")
    # o caso 6 é o que importa: a chave é MAIOR do que o bloco, e a RFC manda
    # hashá-la primeiro em vez de a truncar — truncar faria duas chaves
    # diferentes dar o mesmo MAC
    check("hmac chave grande", hmac_sha256(rep(170, 131), b("Test Using Larger Than Block-Size Key - Hash Key First")),
          "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")

    print("hash: " + str(e[0]) + " ok, " + str(e[1]) + " falharam")


main()
