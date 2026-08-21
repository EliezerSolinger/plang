"""As categorias do Unicode (105), conferidas ponto de código por ponto de código.

Não são exemplos escolhidos: o arquivo VARRE o intervalo — todo ponto de código
até U+3000, e depois de 31 em 31 até o fim do último plano — e imprime, para
cada um em que algum predicado responde sim, quais responderam. Depois faz o
mesmo com os mapeamentos de caixa e de título. O `python3` roda o mesmo programa
e as saídas são diffadas, então uma faixa errada na tabela gerada aparece aqui
com o ponto de código exato.

Os substitutos (U+D800..U+DFFF) ficam de fora: não são caracteres, o UTF-8 não
os codifica, e o Python só os aceita porque as strings dele não são UTF-8.
"""


def flags(c):
    out = ""
    out += "a" if c.isalpha() else "-"
    out += "d" if c.isdigit() else "-"
    out += "D" if c.isdecimal() else "-"
    out += "n" if c.isnumeric() else "-"
    out += "N" if c.isalnum() else "-"
    out += "s" if c.isspace() else "-"
    out += "u" if c.isupper() else "-"
    out += "l" if c.islower() else "-"
    out += "t" if c.istitle() else "-"
    return out


def sweep(lo, hi, step):
    npred = 0
    ncase = 0
    cp = lo
    while cp < hi:
        if cp >= 0xD800 and cp <= 0xDFFF:
            cp += step
            continue
        c = chr(cp)
        f = flags(c)
        if f != "---------":
            print(f"{cp} {f}")
            npred += 1
        up = c.upper()
        lw = c.lower()
        ti = c.title()
        sw = c.swapcase()
        ca = c.capitalize()
        if up != c or lw != c or ti != c or sw != c or ca != c:
            print(f"{cp} {up} {lw} {ti} {sw} {ca}")
            ncase += 1
        cp += step
    print(f"-- {lo}..{hi}/{step}: {npred} pred, {ncase} case")


sweep(0, 0x3000, 1)
sweep(0x3000, 0x110000, 31)

# e as palavras, onde `title` tem de decidir o que é fronteira
words = ["hello world", "HELLO WORLD", "hello-world", "hello's cat", "a1b2",
         "  spaced  out  ", "ǳon", "straße", "ÁÉÍ óú", "日本 語", "x", "",
         "MiXeD cAsE", "3 blind mice", "l'élan", "o'neill", "van der berg"]
for w in words:
    print(f"[{w}] [{w.title()}] [{w.capitalize()}] [{w.swapcase()}] [{w.upper()}] [{w.lower()}]")
    print(f"  {w.istitle()} {w.isupper()} {w.islower()} {w.isalpha()} {w.isalnum()} {w.isspace()}")

# os dígitos de todo canto, que é onde um `isdigit` de ASCII se trai
digits = ["123", "١٢٣", "๓", "³", "½", "三", "Ⅶ", "𝟛", "12a", ""]
for d in digits:
    print(f"[{d}] {d.isdigit()} {d.isdecimal()} {d.isnumeric()} {d.isalnum()}")
