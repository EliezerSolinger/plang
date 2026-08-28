"""O escopo da variável de laço e da comprehension (64.1), nas duas máquinas.

A 64.1 decidiu escopo de BLOCO: a variável de um `for` é uma variável nova, e a
de uma comprehension também (é o escopo próprio do Python). Dentro de um `async
def` isso não valia — o frame guarda um campo por NOME, então o laço escrevia na
variável de fora que se chamasse igual, e a comprehension lia a de fora em vez da
dela. Aqui as duas máquinas respondem o mesmo, que é o que 64.1 pede.

A divergência com o Python é DELIBERADA e é a 64.1: lá o `for` deixa a variável
viva depois do laço. Por isso este arquivo não é par de oráculo.
"""


def s_range() -> int:
    i = 99
    t = 0
    for i in range(3):
        t += i
    return t * 1000 + i


async def a_range() -> int:
    i = 99
    t = 0
    for i in range(3):
        t += i
    return t * 1000 + i


async def a_range_await() -> int:
    i = 99
    t = 0
    for i in range(3):
        await sleep(0.0)
        t += i
    return t * 1000 + i


def s_list(xs: List<int>) -> int:
    v = 99
    t = 0
    for v in xs:
        t += v
    return t * 1000 + v


async def a_list(xs: List<int>) -> int:
    v = 99
    t = 0
    for v in xs:
        await sleep(0.0)
        t += v
    return t * 1000 + v


async def a_str(s: str) -> int:
    c = "zz"
    t = 0
    for c in s:
        t += 1
    return t * 1000 + len(c)


async def a_pairs(d: Dict<str, int>) -> int:
    k = "zzz"
    v = 0
    t = 0
    for k, v in d.items():
        t += v
    return t * 1000 + len(k) + v


def s_comp() -> int:
    i = 7
    xs = [i * 2 for i in range(3)]
    return xs[2] + i


async def a_comp() -> int:
    i = 7
    xs = [i * 2 for i in range(3)]
    ys = [v for v in xs]
    ds = {j: j for j in range(2)}
    return xs[2] + i + len(ys) + len(ds)


async def a_nested() -> int:
    n = 2
    zs = [[n for n in range(2)] for n in range(3)]
    return len(zs) * 100 + len(zs[0]) * 10 + n


# o laço não anda o CURSOR para fora: `for i in range(3)` não deixa 3 em lugar
# nenhum, e a variável de fora fica como estava
print(s_range(), await a_range(), await a_range_await())
print(s_list([4, 5]), await a_list([4, 5]))
print(await a_str("abc"), await a_pairs({"x": 1, "yy": 2}))
print(s_comp(), await a_comp(), await a_nested())

# e o laço sem homônimo continua sendo um laço
async def sum_v(n: int) -> int:
    t = 0
    for i in range(n):
        t += i * i
    return t

print(await sum_v(5))
