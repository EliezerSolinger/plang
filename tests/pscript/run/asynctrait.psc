"""`async def` numa trait, e o genérico que espera por cima dela.

Um trait diz ASSINATURAS, e `async` é parte de uma assinatura: uma dá um
`Task<T>` e a outra dá o `T`, portanto quem escreve contra o trait escreve
`await` ou não escreve. Sem isto, um `Reader` não podia cobrir um socket — e um
socket é metade da razão de haver um.

O que este ficheiro prende é a volta inteira: declarar, implementar, chamar
directamente, e chamar através de um genérico com limite de trait — que é a
forma em que uma função de cópia serve ficheiro, socket e memória sem saber qual
é qual.
"""


trait Src:
    """Alguma coisa de onde se lê, esperando."""
    async def get(self, n: int) -> int


trait Sink:
    """... e alguma coisa para onde se escreve. Sem `async`, de propósito: as
    duas formas têm de conviver no mesmo programa, senão a regra não é uma regra
    e sim uma imposição."""
    def put(self, v: int) -> int


struct Mem implements Src, Sink:
    base: int
    total: int

    async def get(self, n: int) -> int:
        await sleep(0.0)
        return self.base + n

    def put(self, v: int) -> int:
        self.total += v
        return self.total


# o genérico que espera: a instância dele é uma função assíncrona comum, com a
# sua própria moldura — e é isso que quase se perdeu, porque a recolha de
# molduras não excluía o TEMPLATE, onde `T` ainda não é um tipo
async def pump<T: Src>(s: T, k: int) -> int:
    a = await s.get(k)
    b = await s.get(k + 1)
    return a + b


# ... e o genérico que não espera, sobre o outro trait
def drain<T: Sink>(d: T, v: int) -> int:
    return d.put(v)


async def go() -> int:
    m = Mem(10, 0)
    direct = await m.get(5)
    via_generic = await pump(m, 1)
    print("direto", direct, "pelo generico", via_generic)
    print("sincrono", drain(m, 7), drain(m, 3))
    return direct + via_generic


print("total", await go())
print("asynctrait-ok")
