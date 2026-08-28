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
shared sessoes: Dict<str, str> = {}
shared expira: Dict<str, int> = {}
# o contador do rate limit: UMA entrada por IP, com o número da janela dentro do
# valor — ver `permite`, que explica porque não é uma chave por janela
shared batidas: Dict<str, int> = {}


def assina(chave: str, id: str) -> str:
    """`id.assinatura`. O ponto separa porque não aparece em base64 nem em hex."""
    return id + "." + str(hmac_sha256(bytes(chave.encode()), bytes(id.encode())))


def confere(chave: str, token: str) -> str:
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
    dada = token[i + 1:]
    esperada = str(hmac_sha256(bytes(chave.encode()), bytes(id.encode())))
    if not hmac_equal(dada, esperada):
        return ""
    return id


async def novo_id() -> str:
    """32 bytes do gerador CRIPTOGRÁFICO, em hex.

    Do `csprng` e não do `random`: um ID de sessão previsível é uma sessão que se
    adivinha, e o Mersenne Twister do `random` reconstrói-se de 624 saídas. É o
    caso onde a diferença entre os dois geradores é a diferença entre seguro e
    não.
    """
    return await rng.token_hex(32)


async def cria(chave: str, valor: str, ttl: int = 86400) -> str:
    """Uma sessão nova. Devolve o TOKEN, que é o que vai no cookie."""
    global sessoes
    global expira
    id = await novo_id()
    sessoes[id] = valor
    expira[id] = int(time.time()) + ttl
    return assina(chave, id)


def le(chave: str, token: str) -> str:
    """O valor da sessão, ou "". Uma sessão expirada é apagada aqui.

    Apagar na LEITURA e não por um varredor é uma escolha: um varredor precisa de
    uma tarefa a correr e de decidir a periodicidade dela, e o que ele apanharia a
    mais são entradas que ninguém está a ler. As que interessam morrem à primeira
    tentativa de usá-las.
    """
    global sessoes
    global expira
    id = confere(chave, token)
    if len(id) == 0:
        return ""
    if id not in sessoes:
        return ""
    if id in expira and expira[id] < int(time.time()):
        sessoes.remove(id)
        expira.remove(id)
        return ""
    return sessoes[id]


def revoga(chave: str, token: str) -> bool:
    """Mata a sessão NA HORA, que é a coisa que um cookie assinado não sabe fazer."""
    global sessoes
    global expira
    id = confere(chave, token)
    if len(id) == 0 or id not in sessoes:
        return False
    sessoes.remove(id)
    if id in expira:
        expira.remove(id)
    return True


def quantas() -> int:
    return len(sessoes)


# ---------- F8d/D37: o RATE LIMIT ----------

def permite(ip: str, teto: int, janela_s: int) -> bool:
    """`teto` pedidos por `janela_s` segundos, por IP. Correcto entre workers.

    **UMA entrada por IP, e a janela vai DENTRO do valor.** É o que evita ter de
    varrer a tabela: `janela * MIL_MILHOES + contagem` num inteiro, e quando a
    janela roda o valor é sobrescrito em vez de acumulado. A tabela cresce com o
    número de IPs distintos vistos — que é o mesmo tecto de qualquer estrutura por
    IP — e não com o número de janelas.

    A alternativa, uma chave `ip|janela`, obrigaria a percorrer a tabela para
    apagar as janelas velhas. E percorrer um `shared dict` é uma pergunta de
    desenho que ainda não tem resposta: um instantâneo (que pode estar velho ao
    ser lido) ou ao vivo (que precisa do cadeado durante o laço inteiro). Fica
    registada nos ACHADOS, e este ficheiro não precisou dela.

    A janela é FIXA e não deslizante. O preço está sabido — na fronteira entre
    duas janelas passa o dobro do tecto num instante — e para o que isto serve,
    travar um cliente que dispara em rajada, é um preço que se paga. Uma janela
    deslizante precisa dos instantes de cada pedido; esta precisa de um inteiro.
    """
    global batidas
    if teto <= 0:
        return True
    janela = int(time.time()) // janela_s
    # UM `if` EXPLÍCITO e não um ternário, e a razão é a ordem de avaliação: um
    # `batidas[ip] if ip in batidas else 0` sobre uma tabela PARTILHADA hasteia
    # a leitura para uma instrução antes do ternário (ela precisa de um sítio
    # onde o valor caia), e portanto ela corre mesmo quando a chave não está lá —
    # e levanta. Com um dicionário normal o mesmo código funciona, o que faz
    # deste um engano que só aparece na tabela partilhada.
    v = 0
    if ip in batidas:
        v = batidas[ip]
    j = v // 1000000000
    n = v % 1000000000
    if j != janela:
        # janela nova: a contagem recomeça, e a entrada velha é SOBRESCRITA
        batidas[ip] = janela * 1000000000 + 1
        return True
    if n >= teto:
        return False
    batidas[ip] = janela * 1000000000 + n + 1
    return True


def quantos_ips() -> int:
    return len(batidas)
