"""Os vetores oficiais do FIPS 180-4, mais os que a gente costuma reconhecer.

Um hash criptográfico é a única coisa deste repositório em que "parece certo" não
significa nada: um erro de um bit num lugar qualquer dá um número plausível e
completamente errado. Por isso o teste é contra os vetores PUBLICADOS, e não
contra o que a nossa implementação produziu no dia em que foi escrita.

Os três primeiros são os do apêndice do FIPS; o quarto (um milhão de 'a') mede o
caminho de vários blocos e o preenchimento no limite; o quinto e o sexto medem os
dois casos que quebram implementações apressadas — a mensagem que acaba
exactamente no byte 55 e a que acaba no 56, que é onde o comprimento deixa de
caber no último bloco.
"""
include <stdio.h>
include <string.h>
include <stdlib.h>
import <sha2/sha2.ph>

private const ESPERADO_VAZIO: const *char = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
private const ESPERADO_ABC: const *char = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
private const ESPERADO_448: const *char = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
private const ESPERADO_MILHAO: const *char = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"

ok: i32 = 0
falhou: i32 = 0

private def confere(nome: const *char, dado: const *char, n: usize, esperado: const *char):
    hex: char[65]
    sha256_hex(dado, n, hex)
    if strcmp(hex, esperado) == 0:
        ok += 1
    else:
        falhou += 1
        printf("  FAIL %s\n    esperado %s\n    veio     %s\n", nome, esperado, hex)

def main() -> int:
    confere("vazio", "", 0, ESPERADO_VAZIO)
    confere("abc", "abc", 3, ESPERADO_ABC)
    m448: const *char = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    confere("448 bits", m448, strlen(m448), ESPERADO_448)

    # um milhão de 'a': vários blocos, e o preenchimento longe do começo
    n: usize = 1000000
    big: *char = (*char)(malloc(n))
    memset(big, int('a'), n)
    confere("um milhao de a", big, n, ESPERADO_MILHAO)
    free(big)

    # OS LIMITES DO PREENCHIMENTO, que é onde uma implementação apressada erra:
    # 55 bytes cabem com o comprimento no mesmo bloco, 56 não cabem e obrigam a
    # um bloco extra; 63/64/65 são a fronteira do bloco em si. Os valores são do
    # `hashlib` do python3 — a mesma regra dos outros oráculos deste
    # repositório, e a única honesta: um hash em que se conferisse o que a nossa
    # própria implementação produziu não estaria a conferir coisa nenhuma.
    lim: const *char[5] = {"d5e285683cd4efc02d021a5c62014694958901005d6f71e89e0989fac77e4072",
                           "04c26261370ee7541549d16dee320c723e3fd14671e66a099afe0a377c16888e",
                           "75220b47218278e656f2013bb8f0c455a25eaf01e86c64924e9d48d89776d6f2",
                           "7ce100971f64e7001e8fe5a51973ecdfe1ced42befe7ee8d5fd6219506b5393c",
                           "9537c5fdf120482f7d58d25e9ed583f52c02b4e304ea814db1633ad565aed7e9"}
    tam: const i32[5] = {55, 56, 63, 64, 65}
    bx: char[80]
    memset(bx, int('x'), 80)
    for i in range(5):
        nome: char[32]
        sprintf(nome, "%d bytes", tam[i])
        confere(nome, bx, usize(tam[i]), lim[i])

    # e o trio init/update/final tem de dar o MESMO que o caminho curto: quem
    # tem os bytes aos pedaços não pode ter outro hash
    s: Sha256
    sha256_init(out s)
    sha256_update(ref s, "a", 1)
    sha256_update(ref s, "b", 1)
    sha256_update(ref s, "c", 1)
    d: char[32]
    sha256_final(ref s, d)
    hex: char[65]
    curto: char[65]
    for i in range(32):
        sprintf(hex + i * 2, "%02x", int(u8(d[i])))
    sha256_hex("abc", 3, curto)
    if strcmp(hex, curto) == 0:
        ok += 1
    else:
        falhou += 1
        printf("  FAIL aos pedacos: %s != %s\n", hex, curto)

    printf("sha2: %d ok, %d failed\n", ok, falhou)
    return 1 if falhou > 0 else 0
