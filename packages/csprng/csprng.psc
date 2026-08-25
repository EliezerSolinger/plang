"""`csprng` — random bytes you may build a secret out of, and no other kind.

**It is a package and not runtime**, and the reason is the first clause of 141.1:
reading `/dev/urandom` is an `open()`. It encapsulates no pointer, no buffer and
no raw system call — so it is not what the rule sends inside. It lives here, next
to `hash` and `hmac`, which is where anyone looking for it will look.

**It never falls back.** If `/dev/urandom` is not there, this FAILS. The obvious
temptation is to reach for the Mersenne Twister that `random` already has, and
that would be the worst thing this file could do: a predictable generator wearing
the word "secure" is worse than no generator at all, because the program that
uses it looks correct.

> `random` is for simulations and shuffles: same seed, same sequence, on purpose.
> This is for keys and tokens: **never** the same sequence, and no seed to give.
> They are two different questions and the answer is two different modules.
"""


async def random_bytes(n: int) -> bytes:
    """`n` bytes from the system's entropy source. Raises if there is none, and
    raises if it gives fewer bytes than asked — a short read here would silently
    produce a key with less entropy than the caller believes it has."""
    if n < 0:
        raise error("random_bytes(n): n cannot be negative", VALUE)
    if n == 0:
        return b""
    # `with await open(...)` fecha o ficheiro em toda a saída — incluindo a que
    # o `raise` abaixo toma — e fecha-o SEM suspender, que é a razão de isto ser
    # um `with` e não um `try`/`finally` com `await f.close()`: uma limpeza que
    # suspende é uma peça que a linguagem ainda não tem, e o compilador recusa-a
    # em vez de a fingir.
    with await open("/dev/urandom", "r") as f:
        with Buffer(n) as buf:
            got = 0
            while got < n:
                k = await f.read_into(buf, got, n - got)
                if k <= 0:
                    # uma leitura curta AQUI produziria em silêncio uma chave com
                    # menos entropia do que quem a pediu acredita ter
                    raise error("/dev/urandom gave " + str(got) + " bytes instead of " + str(n), IO)
                got += k
            return bytes(buf[0:n])


async def token_hex(nbytes: int = 32) -> str:
    """`nbytes` of entropy, written as hex. Thirty-two bytes is the size that
    stops anybody arguing about whether it is enough."""
    return (await random_bytes(nbytes)).hex()
