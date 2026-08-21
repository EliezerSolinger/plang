"""O ferramental de sequência (104), contra o Python.

`sum`, `any`, `all`, `round`, `divmod`, `min`/`max` de uma lista, os métodos que
faltavam em list/dict/str e os operadores de conjunto. Cada linha aqui é uma
decisão de borda que o Python já tomou e que seria fácil errar: `sum([])` é 0,
`all([])` é True, `round` é meio para o PAR, `"aaa".count("aa")` é 1 (não
sobrepõe), `zfill` põe o sinal antes dos zeros, e o `center` do CPython joga a
sobra para a esquerda quando a folga e a largura são ímpares.

Conjuntos não são impressos direto: a ordem de um `set` no Python vem do hash e
aqui vem da inserção (91.1). O que se compara é o conteúdo ordenado.
"""

xs = [3, 1, 4, 1, 5, 9, 2, 6]
fs = [1.5, -2.5, 3.0]
ws = ["pera", "abacate", "uva"]
mt: list<int> = []
mb: list<bool> = []

# ---- sum, any, all ----
print(sum(xs), sum(fs), sum(xs, 100), sum(mt))
print(any([False, True]), any([False]), any(mb))
print(all([True, True]), all([True, False]), all(mb))
print(any([x > 8 for x in xs]), all([x > 0 for x in xs]))
print(sum([x * 2 for x in xs]))

# ---- round: meio para o PAR, e int sem casas ----
print(round(0.5), round(1.5), round(2.5), round(3.5), round(-0.5), round(-1.5))
print(round(2.4), round(2.6), round(-2.4), round(-2.6))
print(round(2.675, 2), round(3.14159, 2), round(1.005, 2), round(0.125, 2))
print(round(1234.5678, -2), round(1250.0, -2), round(1350.0, -2), round(-1250.0, -2))
print(round(0.1 + 0.2, 17), round(2.0), round(-0.0))

# ---- divmod ----
print(divmod(17, 5), divmod(-17, 5), divmod(17, -5), divmod(-17, -5))
print(divmod(0, 7), divmod(7, 7))

# ---- min/max de uma lista ----
print(min(xs), max(xs), min(fs), max(fs), min(ws), max(ws))
print(min(3, 7), max(3, 7), min(1.5, 2.5), max(1.5, 2.5))

# ---- métodos de lista ----
a = [3, 1, 4, 1, 5]
print(a.pop(), a)
print(a.pop(0), a)
print(a.pop(-1), a)
b = [1, 2]
b.extend([3, 4])
print(b)
b.extend(b)
print(b)
print(b.index(2), b.count(1), b.count(99))
b.remove(1)
print(b)
c = b.copy()
c.clear()
print(len(b), len(c), c)
d = [3, 1, 2]
d.sort()
print(d)
e = ["pera", "uva", "abacate"]
e.sort()
print(e)
f = [1.5, -2.5]
f.sort()
print(f)

# ---- + e * de listas, e o += que estende NO LUGAR ----
print([1, 2] + [3], [1] * 3, [1] * 0)
g = [1, 2]
h = g
g += [3]
print(g, h)
i2 = [0]
i2 += i2
print(i2)

# ---- métodos de dict ----
dd = {"a": 1, "b": 2, "c": 3}
print(dd.pop("a"), dd)
print(dd.pop("zz", -1))
print(dd.setdefault("b", 99), dd.setdefault("z", 26), dd)
dd.update({"c": 30, "d": 40})
print(dd)
ee = dd.copy()
ee["novo"] = 0
print(len(dd), len(ee))
dd.clear()
print(dd, len(dd))

# ---- conjuntos: conteúdo ordenado, não a ordem ----
s1 = {1, 2, 3}
s2 = {3, 4}
print(sorted([x for x in s1 | s2]))
print(sorted([x for x in s1 & s2]))
print(sorted([x for x in s1 - s2]))
print(sorted([x for x in s1 ^ s2]))
print(len(s1 | s2), len(s1 & s2), len(s1 - s2), len(s1 ^ s2))
s3 = {1, 2}
print(s3 <= s1, s1 <= s3, s3 < s1, s1 < s1, s1 <= s1)
print(s1 >= s3, s3 >= s1, s1 > s3, s1 > s1)

# ---- métodos de str ----
t = "hello world hello"
print(t.count("hello"), t.count("l"), t.count("xyz"), "aaa".count("aa"), "abc".count(""))
print(t.find("hello"), t.rfind("hello"), t.find("hello", 1), t.find("zz"), t.rfind("zz"))
print(t.index("world"), t.rindex("hello"))
print("  a  b  ".split(), "".split(), " ".split(), "a  b".split())
print("a b".split(" "), " a  b ".split(" "))
print("a\nb\r\nc\rd".splitlines(), "".splitlines(), "a\n".splitlines(), "\n".splitlines())
print("prefix-x".removeprefix("prefix-"), "x.txt".removesuffix(".txt"), "abc".removeprefix("z"), "abc".removesuffix("z"))
print("xxhixx".strip("x"), "xxhixx".lstrip("x"), "xxhixx".rstrip("x"), "--a-b--".strip("-"))
print("abcba".strip("ab"), "  hi  ".strip(), "xyx".strip("xyz"))
for w in range(2, 10):
    print(w, "hi".center(w, "*"), "abc".center(w, "."), "hi".ljust(w, "-"), "hi".rjust(w, "-"))
print("42".zfill(5), "-42".zfill(5), "+42".zfill(5), "12345".zfill(3), "".zfill(3))

# ---- e tudo isso com UTF-8, onde o índice é de CARÁCTER ----
u = "héllo wörld"
print(len(u), u.find("l"), u.rfind("l"), u.count("l"), u.index("w"))
print(u.center(15, "-"), u.split(), u.upper())
print("日本語".center(7, "-"), "日本語".rfind("本"), len("日本語"), "日本語".count("本"))
