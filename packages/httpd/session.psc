"""Sessão assinada e rate limit, os dois sobre um `shared dict` (F8b/F8d).

**É aqui que a resposta da linguagem aparece.** Onde o Bun responde "sobe um
Redis", a primitiva está na linguagem: uma tabela fora de todos os heaps, com
cadeado próprio, que N workers leem e escrevem — e portanto uma sessão criada no
worker 1 é vista pelo worker 3 sem nada externo.

O que o cookie leva é um **ID assinado** e mais nada. O estado fica do lado do
servidor, e isso compra três coisas que um cookie assinado não dá:

  * **revogar funciona.** Apagar a entrada mata a sessão na hora; um cookie
    assinado é válido até expirar, e não há como o chamar de volta;
  * **o tamanho não é o do cookie.** Os 4 KiB de um cookie são um tecto duro, e
    o estado de um jogador não cabe lá;
  * **nada sensível viaja.** O que vai e volta é um número aleatório.

O custo, dito em voz alta: **a sessão morre com o processo.** Um `shared dict` é
memória, não é uma base de dados. Quem precisa que ela sobreviva a um reinício
persiste-a — e a `packages/mysql` está ao lado para isso.

A ASSINATURA é HMAC-SHA256 do `packages/hmac`, e existe por uma razão que não é
óbvia: o ID já é aleatório, então porquê assiná-lo? Porque sem assinatura um
atacante pode **sondar** — mandar IDs ao calhas e ver qual responde diferente. Com
a assinatura, um ID que não bate é recusado antes de a tabela ser sequer
consultada, e não há resposta nenhuma de onde tirar informação.
"""
import <httpd/httpd.psc> as httpd
import <csprng/csprng.psc> as rng
import <hmac/hmac.ph>
import time


# A TABELA. Uma por processo, partilhada por todos os workers — e é isto que faz
# uma sessão criada no worker 1 ser vista pelo worker 3.
shared sessions: Dict<str, str> = {}
shared expires_at: Dict<str, int> = {}
# o contador do rate limit: UMA entrada por IP, com o número da janela dentro do
# valor — ver `allow`, que explica porque não é uma chave por janela
shared hits: Dict<str, int> = {}


def sign(secret: str, id: str) -> str:
    """`id.assinatura`. O ponto separa porque não aparece em base64 nem em hex."""
    return id + "." + str(hmac_sha256(bytes(secret.encode()), bytes(id.encode())))


def verify(secret: str, token: str) -> str:
    """O ID de um token válido, ou "" — e a comparação é em TEMPO CONSTANTE.

    O `hmac_equal` do pacote existe por isso: um `==` de strings sai no primeiro
    byte diferente, e o tempo que ele leva conta quantos bytes bateram. Com um
    oráculo de tempo, uma assinatura de 32 bytes cai em 32 × 256 tentativas em vez
    de 2^256 — e é um ataque real, não um exercício.
    """
    i = token.rfind(".")
    if i <= 0:
        return ""
    id = token[0:i]
    given = token[i + 1:]
    expected = str(hmac_sha256(bytes(secret.encode()), bytes(id.encode())))
    if not hmac_equal(given, expected):
        return ""
    return id


async def new_id() -> str:
    """32 bytes do gerador CRIPTOGRÁFICO, em hex.

    Do `csprng` e não do `random`: um ID de sessão previsível é uma sessão que se
    adivinha, e o Mersenne Twister do `random` reconstrói-se de 624 saídas. É o
    caso onde a diferença entre os dois geradores é a diferença entre seguro e
    não.
    """
    return await rng.token_hex(32)


async def create(secret: str, value_s: str, ttl: int = 86400) -> str:
    """Uma sessão nova. Devolve o TOKEN, que é o que vai no cookie."""
    global sessions
    global expires_at
    id = await new_id()
    sessions[id] = value_s
    expires_at[id] = int(time.time()) + ttl
    return sign(secret, id)


def read(secret: str, token: str) -> str:
    """O valor da sessão, ou "". Uma sessão expirada é apagada aqui.

    Apagar na LEITURA e não por um varredor é uma escolha: um varredor precisa de
    uma tarefa a correr e de decidir a periodicidade dela, e o que ele apanharia a
    mais são entradas que ninguém está a ler. As que interessam morrem à primeira
    tentativa de usá-las.
    """
    global sessions
    global expires_at
    id = verify(secret, token)
    if len(id) == 0:
        return ""
    if id not in sessions:
        return ""
    if id in expires_at and expires_at[id] < int(time.time()):
        sessions.remove(id)
        expires_at.remove(id)
        return ""
    return sessions[id]


def revoke(secret: str, token: str) -> bool:
    """Mata a sessão NA HORA, que é a coisa que um cookie assinado não sabe fazer."""
    global sessions
    global expires_at
    id = verify(secret, token)
    if len(id) == 0 or id not in sessions:
        return False
    sessions.remove(id)
    if id in expires_at:
        expires_at.remove(id)
    return True


def count() -> int:
    return len(sessions)


# ---------- F8d/D37: o RATE LIMIT ----------

def allow(ip: str, ceiling: int, window_s: int) -> bool:
    """`ceiling` pedidos por `window_s` segundos, por IP. Correcto entre workers.

    **UMA entrada por IP, e a janela vai DENTRO do valor.** É o que evita ter de
    varrer a tabela: `window * MIL_MILHOES + contagem` num inteiro, e quando a
    janela roda o valor é sobrescrito em vez de acumulado. A tabela cresce com o
    número de IPs distintos vistos — que é o mesmo tecto de qualquer estrutura por
    IP — e não com o número de janelas.

    A alternativa, uma chave `ip|window`, obrigaria a percorrer a tabela para
    apagar as janelas velhas. E percorrer um `shared dict` é uma pergunta de
    desenho que ainda não tem resposta: um instantâneo (que pode estar velho ao
    ser lido) ou ao vivo (que precisa do cadeado durante o laço inteiro). Fica
    registada nos ACHADOS, e este ficheiro não precisou dela.

    A janela é FIXA e não deslizante. O preço está sabido — na fronteira entre
    duas janelas passa o dobro do tecto num instante — e para o que isto serve,
    travar um cliente que dispara em rajada, é um preço que se paga. Uma janela
    deslizante precisa dos instantes de cada pedido; esta precisa de um inteiro.
    """
    global hits
    if ceiling <= 0:
        return True
    window = int(time.time()) // window_s
    # UM `if` EXPLÍCITO e não um ternário, e a razão é a ordem de avaliação: um
    # `hits[ip] if ip in hits else 0` sobre uma tabela PARTILHADA hasteia
    # a leitura para uma instrução antes do ternário (ela precisa de um sítio
    # onde o valor caia), e portanto ela corre mesmo quando a chave não está lá —
    # e levanta. Com um dicionário normal o mesmo código funciona, o que faz
    # deste um engano que só aparece na tabela partilhada.
    v = 0
    if ip in hits:
        v = hits[ip]
    j = v // 1000000000
    n = v % 1000000000
    if j != window:
        # janela nova: a contagem recomeça, e a entrada velha é SOBRESCRITA
        hits[ip] = window * 1000000000 + 1
        return True
    if n >= ceiling:
        return False
    hits[ip] = window * 1000000000 + n + 1
    return True


def ip_count() -> int:
    return len(hits)
