"""A autenticação do handshake — `mysql_native_password`.

Porte de `scramble_native_password` em `pymysql/_auth.py`. A conta é a defesa do
protocolo contra um espião: a senha nunca viaja, e o que viaja é uma prova de que
o cliente a conhece, ligada a um desafio (`salt`) que o servidor sorteia a cada
conexão — então capturar a prova não serve para a próxima.

    resposta = SHA1(senha) XOR SHA1( salt ++ SHA1(SHA1(senha)) )

`caching_sha2_password` (o padrão do MySQL 8) e `ed25519` (uma opção do MariaDB)
ficam de fora por ora: o primeiro precisa de RSA para o caminho lento e o segundo
de curva de Edwards, e o alvo aqui — o MariaDB do Desbravacraft — usa
`mysql_native_password`. O ponto onde cada um entraria está dito no `mysql.psc`,
onde o pedido de troca de plugin é tratado.
"""

import <mysql/sha1.psc> as sha
import <mysql/sha256.psc> as sha2


def scramble_native_password(password: bytes, salt: bytes) -> bytes:
    """A resposta de 20 bytes, ou vazia se a senha for vazia (é o que o
    protocolo manda: sem senha, sem prova)."""
    if len(password) == 0:
        return bytes([])

    stage1 = sha.sha1(password)
    stage2 = sha.sha1(stage1)

    # SHA1( primeiros 20 bytes do salt ++ stage2 )
    combined: List<u8> = []
    n = 20 if len(salt) >= 20 else len(salt)
    i = 0
    while i < n:
        combined.append(salt[i])
        i += 1
    j = 0
    while j < len(stage2):
        combined.append(stage2[j])
        j += 1
    result = sha.sha1(bytes(combined))

    # XOR com stage1, byte a byte
    out: List<u8> = []
    k = 0
    while k < len(result):
        out.append(u8(int(result[k]) ^ int(stage1[k])))
        k += 1
    return bytes(out)


def scramble_caching_sha2(password: bytes, nonce: bytes) -> bytes:
    """O scramble do `caching_sha2_password` (o padrão do MySQL 8), caminho
    rápido: `XOR(SHA256(pw), SHA256(SHA256(SHA256(pw)) ++ nonce))`.

    É o que basta quando a senha já está no cache do servidor. No primeiro login
    (cache vazio) o servidor pede o caminho lento, e aí a senha viaja — cifrada
    por RSA, ou em claro sobre TLS. Com a ligação já em TLS, o caminho lento é
    mandar a senha e um NUL, e é o que o conector faz."""
    if len(password) == 0:
        return bytes([])
    p1 = sha2.sha256(password)
    p2 = sha2.sha256(p1)
    combined: List<u8> = []
    j = 0
    while j < len(p2):
        combined.append(p2[j])
        j += 1
    n = 20 if len(nonce) >= 20 else len(nonce)
    k = 0
    while k < n:
        combined.append(nonce[k])
        k += 1
    p3 = sha2.sha256(bytes(combined))
    out: List<u8> = []
    i = 0
    while i < len(p1):
        out.append(u8(int(p1[i]) ^ int(p3[i])))
        i += 1
    return bytes(out)
