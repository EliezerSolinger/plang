"""Escrever, ler de volta, e recusar o que tem de ser recusado.

O portão que interessa mais não está aqui: é o `tar` do sistema abrir o nosso
(`bash packages/tar/test/sistema.sh`). Este confere a volta inteira sem sair de
casa, e sobretudo confere as RECUSAS — que são a razão de o leitor existir.
"""

import <tar/tar.psc> as tar

e: list<int> = [0, 0]


def conf(nome: str, cond: bool):
    if cond:
        e[0] += 1
    else:
        e[1] += 1
        print("  FALHOU: " + nome)


def bs(s: str) -> list<u8>:
    return tar.bytes_de(s)


def txt(b: list<u8>) -> str:
    return str(b)


# ---------- a volta ----------
ms: list<tar.Membro> = [
    tar.diretorio("pkg", 0o755, 1700000000),
    tar.arquivo("pkg/pack.json", bs("{\"name\": \"x\"}"), 0o644, 1700000001),
    tar.arquivo("pkg/vazio.txt", bs(""), 0o644, 1700000002),
    # 512 bytes exatos: o tamanho onde o preenchimento é zero e um leitor
    # desatento acrescenta um bloco a mais
    tar.arquivo("pkg/exato.bin", bs("z" * 512), 0o600, 1700000003),
    tar.arquivo("pkg/acentuado-ção.txt", bs("olá"), 0o644, 1700000004),
]
b = tar.escrever(ms)
conf("o tarball é múltiplo de 512", len(b) % 512 == 0)
volta = tar.ler(b)
conf("o mesmo número de membros", len(volta) == len(ms))
conf("o diretório voltou como diretório", volta[0].tipo == "dir" and volta[0].nome == "pkg/")
conf("o conteúdo voltou", txt(volta[1].dados) == "{\"name\": \"x\"}")
conf("o modo voltou", volta[1].modo == 0o644)
conf("o mtime voltou", volta[1].mtime == 1700000001)
conf("um arquivo vazio é um arquivo", volta[2].nome == "pkg/vazio.txt" and len(volta[2].dados) == 0)
conf("512 bytes exatos", len(volta[3].dados) == 512 and volta[3].modo == 0o600)
conf("o nome com acento voltou", volta[4].nome == "pkg/acentuado-ção.txt")
conf("o conteúdo com acento voltou", txt(volta[4].dados) == "olá")

# ---------- o nome longo, pelo prefix ----------
longo = "pacote-de-nome-comprido/" + ("dir/" * 20) + "arquivo.txt"
b2 = tar.escrever([tar.arquivo(longo, bs("k"), 0o644, 1700000000)])
v2 = tar.ler(b2)
conf("nome de mais de 100 bytes, pelo prefix", v2[0].nome == longo)

# ---------- as recusas ----------
def recusa(nome: str, f: def() -> int) -> bool:
    try:
        f()
        return False
    catch err:
        return True


def caminho_absoluto() -> int:
    return len(tar.ler(tar.escrever([tar.arquivo("/etc/passwd", bs("x"), 0o644, 1)])))


def sobe() -> int:
    return len(tar.ler(tar.escrever([tar.arquivo("a/../../etc/passwd", bs("x"), 0o644, 1)])))


def checksum_errado() -> int:
    mau = tar.escrever([tar.arquivo("a.txt", bs("x"), 0o644, 1)])
    mau[0] = u8(ord("b"))          # muda o nome sem mexer no checksum
    return len(tar.ler(mau))


def magic_errado() -> int:
    mau = tar.escrever([tar.arquivo("a.txt", bs("x"), 0o644, 1)])
    mau[257] = u8(ord("g"))
    return len(tar.ler(mau))


def tipo_recusado() -> int:
    mau = tar.escrever([tar.arquivo("a.txt", bs("x"), 0o644, 1)])
    mau[156] = u8(ord("2"))        # link simbólico
    soma = 0
    for i in range(512):
        soma += 32 if i >= 148 and i < 156 else int(mau[i])
    d = tar.octal(soma, 7)
    j = 0
    for ch in d:
        mau[148 + j] = u8(ord(ch))
        j += 1
    return len(tar.ler(mau))


def acaba_a_meio() -> int:
    inteiro = tar.escrever([tar.arquivo("a.txt", bs("x" * 600), 0o644, 1)])
    cortado: list<u8> = []
    for i in range(700):
        cortado.append(inteiro[i])
    return len(tar.ler(cortado))


conf("recusa caminho absoluto", recusa("abs", caminho_absoluto))
conf("recusa `..`", recusa("..", sobe))
conf("recusa checksum errado", recusa("cks", checksum_errado))
conf("recusa magic errado", recusa("magic", magic_errado))
conf("recusa link simbólico", recusa("link", tipo_recusado))
conf("recusa tarball cortado", recusa("curto", acaba_a_meio))

print(f"tar: {e[0]} ok, {e[1]} failed")
