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
