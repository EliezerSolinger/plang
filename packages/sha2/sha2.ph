"""SHA-256, o hash que responde "isto é o que disseram que era?".

O `hash_bytes` que este repositório já tinha é FNV-1a: ótimo para decidir se uma
saída de build mudou, e **inútil contra um adversário** — quem quer forjar uma
colisão em FNV consegue-a com uma folha de papel. Um gerenciador de pacotes que
baixa código precisa da outra coisa, e é esta.

Escrito em P e sem dependência nenhuma, o que o torna utilizável pelo compilador,
pelo `ppack`, e por qualquer programa das duas linguagens (o pscript o alcança
por `import <sha2/sha2.ph>`, que é a fronteira da 45.5: assinaturas sem ponteiro
atravessam, e estas atravessam).

A implementação é a do FIPS 180-4 §6.2, sem esperteza nenhuma: as constantes são
as raízes cúbicas dos primeiros 64 primos, a mensagem é preenchida com um bit 1,
zeros, e o comprimento em bits num inteiro de 64 bits big-endian. Não há aqui
otimização de que se dependa; há um teste com os vetores oficiais.
"""

import <stl/cstr.ph>

# O estado de um hash em curso: o de quem tem os bytes todos na mão usa
# `sha256_hex`, e o de quem os tem aos pedaços (um arquivo grande, um socket)
# usa o trio init/update/final.
struct Sha256:
    h: u32[8]
    buf: u8[64]
    nbuf: usize
    total: u64

def sha256_init(out s: Sha256):
    """Começa um hash. O estado é do chamador — não há alocação nem estado
    global, então dois hashes em curso ao mesmo tempo não se veem."""

def sha256_update(ref s: Sha256, data: const *char, n: usize):
    """Mais bytes. Pode ser chamada quantas vezes for preciso, e o resultado é o
    mesmo que o de uma chamada só com tudo junto — é isso que permite hashear um
    arquivo grande sem o ter inteiro na memória."""

def sha256_final(ref s: Sha256, out_digest: *char):
    """Fecha o hash e escreve **32 bytes** em `out_digest`. Depois disto o estado
    não serve para mais nada."""

def sha256_hex(data: const *char, n: usize, out_hex: *char):
    """O caminho curto: os bytes todos, e sessenta e quatro dígitos hexadecimais
    minúsculos com o terminador — `out_hex` tem de ter 65 bytes.

    É esta que o gerenciador de pacotes usa: o hash de um tarball, comparado com
    o que o índice declarou."""

# ---------- a travessia para o pscript (45.5/84.1) ----------
#
# A ÚNICA dependência deste pacote, e é só de tipo: `CStr`/`CBytes` são um par
# ponteiro+comprimento declarado no `stl`, sem código nenhum atrás (o `cstr.ph`
# não tem `.p`). O miolo — init/update/final/hex — continua sem depender de
# coisa alguma.
#
# Um `CBytes` é um ponteiro e o seu comprimento como VALOR: do lado do pscript
# isto é `list<u8>`, e o que atravessa é o par, montado na chamada e válido
# enquanto ela dura. A resposta volta como `CStr`, que do outro lado é `str`.
#
# É a mesma implementação — não há uma segunda cópia do SHA-256 em pscript, e
# essa é a razão de o pacote ser em P: a linguagem sem runtime é a que as duas
# alcançam.
def sha256_of(in data: CBytes) -> CStr


# ---------- SHA-512 (FIPS 180-4 §6.4) ----------
#
# É o mesmo desenho com o dobro da largura: palavras de 64 bits, blocos de 128
# bytes, oitenta rondas, e o comprimento no fim ocupa 128 bits em vez de 64. As
# rotações são outras porque a especificação as escolheu para a largura nova.
#
# Existe porque o Ed25519 o exige (RFC 8032): a assinatura é definida sobre
# SHA-512 e não sobre qualquer hash. Uma implementação que trocasse o hash não
# seria Ed25519 — seria outra coisa com o mesmo nome, e as chaves de fora não
# funcionariam.

struct Sha512:
    h: u64[8]
    buf: u8[128]
    nbuf: usize
    total: u64        # bytes; o campo de 128 bits do padding tem a metade alta a zero

def sha512_init(out s: Sha512):
    """Começa um hash de 512 bits. Como o de 256: o estado é do chamador."""

def sha512_update(ref s: Sha512, data: const *char, n: usize):
    """Mais bytes."""

def sha512_final(ref s: Sha512, out_digest: *char):
    """Fecha e escreve **64 bytes**."""

def sha512_hex(data: const *char, n: usize, out_hex: *char):
    """O caminho curto: 128 dígitos hexadecimais e o terminador (129 bytes)."""

def sha512_of(in data: CBytes) -> CStr
