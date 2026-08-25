"""O motor de regex (S2b): um autómato de Thompson, e a garantia que ele traz.

**A razão de ele existir cabe numa linha:** um motor com retrocesso pode ser
feito parar por uma cadeia de entrada. `(a+)+b` contra sessenta `a` são 2^60
caminhos, e o processo não volta. Uma linguagem que promete quatro eixos de
segurança de memória (9.1) e depois oferece um regex que uma entrada consegue
travar está a prometer com uma mão e a tirar com a outra.

**O preço está pago à cabeça, e é matemática e não esforço:** um motor de tempo
linear NÃO PODE ter retrocesso (`\\1`) nem lookaround (`(?=…)`). O autómato não
guarda o texto que já casou — é essa a razão de ele ser linear. É o dialecto do
RE2, que é o do Go e o do `regex` do Rust.

**Os vectores vêm do `re` do CPython**, varridos: cinquenta e um padrões contra
cinquenta e um textos, com os grupos todos. O que aqui se prova não é que o motor
é consistente consigo próprio — é que ele responde o mesmo que o motor que toda a
gente usa, nos casos que separam uma implementação certa de uma plausível.
"""
import re
import time


PATS: List<str> = ["a", "a", "a*", "a*", "a+", "a?", "ab|cd", "(a|b)+", "(ab)+", "a{3}", "a{2,3}", "a{2,}", "a{0,2}", "(a+)+b", "[abc]+", "[^abc]+", "[a-z]+", "[0-9a-fA-F]+", "[]]", "[-a]+", "[a-]+", "[\\d]+", "\\d+", "\\w+", "\\s+", "\\D+", "\\W+", "\\S+", "^abc", "^abc", "abc$", "abc$", "\\bfoo\\b", "\\Boo\\B", ".", "(?s).", "(?i)HeLLo", "(?i)[A-Z]+", "<.+>", "<.+?>", "a??b", "a*?b", "(?:ab)+", "(a)(b)(c)", "(a)?b", "(a)?b", "x*", "(|a)", "a\\.b", "a\\.b", "\\x41+"]
TEXTS: List<str> = ["a", "b", "", "aaa", "aaa", "a", "cd", "abab", "ababc", "aaaa", "aaaa", "aaaaa", "aaa", "aaaaaaaaaaaaaaaaaaaab", "cabx", "xyzabc", "abcZ", "deadBEEF!", "]", "a-a", "a-a", "42x", "abc123def", "  foo_bar!", "a \t b", "123abc", "ab!!cd", "  ab  ", "abc", "xabc", "abc", "abcx", "a foo b", "foobar", "\n", "\n", "hello", "abc", "<a><b>", "<a><b>", "ab", "aaab", "ababc", "abc", "b", "ab", "yyy", "a", "a.b", "axb", "AAA"]
WANT: List<str> = ["a", "-", "", "aaa", "aaa", "a", "cd", "abab|b", "abab|ab", "aaa", "aaa", "aaaaa", "aa", "aaaaaaaaaaaaaaaaaaaab|aaaaaaaaaaaaaaaaaaaa", "cab", "xyz", "abc", "deadBEEF", "]", "a-a", "a-a", "42", "-", "-", "-", "-", "-", "-", "abc", "-", "abc", "-", "-", "-", "-", "\n", "hello", "abc", "<a><b>", "<a>", "ab", "aaab", "abab", "abc|a|b|c", "b|", "ab|a", "", "|", "a.b", "-", "AAA"]


e: List<int> = [0, 0]


def got_of(pat: str, s: str) -> str:
    m = re.match(pat, s)
    if m == None:
        return "-"
    out: List<str> = []
    for g in m:
        out.append(g)
    return "|".join(out)


def ck(name: str, got: str, want: str):
    if got == want:
        e[0] += 1
    else:
        e[1] += 1
        print("  " + name + ": deu [" + got + "], devia [" + want + "]")


def main():
    for i in range(len(PATS)):
        ck(PATS[i] + " vs " + TEXTS[i], got_of(PATS[i], TEXTS[i]), WANT[i])

    # ---- a garantia, medida ----
    #
    # Num motor com retrocesso isto não volta. Aqui é linear, e o portão
    # verifica as duas coisas: que a resposta é "não casa" e que ela chega.
    t0 = time.monotonic()
    ck("(a+)+b com 60 a", "-" if re.match("(a+)+b", "a" * 60) == None else "casou", "-")
    ck("(a+)+b com 200 a", "-" if re.match("(a+)+b", "a" * 200) == None else "casou", "-")
    ck("(x+x+)+y com 100 x", "-" if re.match("(x+x+)+y", "x" * 100) == None else "casou", "-")
    ck("(a|aa)+c com 80 a", "-" if re.match("(a|aa)+c", "a" * 80) == None else "casou", "-")
    dt = time.monotonic() - t0
    ck("e os quatro juntos demoraram menos de cinco segundos", "sim" if dt < 5.0 else "nao", "sim")

    # ---- as funções que faltavam ----
    ck("findall", "|".join(re.findall("\\d+", "a1b22c333")), "1|22|333")
    ck("findall com grupo", "|".join(re.findall("(\\w)\\d", "a1 b2")), "a|b")
    ck("split", "|".join(re.split(",", "a,b,c")), "a|b|c")
    ck("split com grupo", "|".join(re.split("(,)", "a,b")), "a|,|b")
    ck("split com limite", "|".join(re.split(",", "a,b,c", 1)), "a|b,c")
    ck("split sem separador", "|".join(re.split("x", "abc")), "abc")
    ck("sub", re.sub("\\d+", "N", "a1b22c333"), "aNbNcN")
    ck("sub com grupos", re.sub("(\\w+)@(\\w+)", "\\2 at \\1", "ana@exemplo"), "exemplo at ana")
    ck("sub com limite", re.sub("a", "X", "aaa", 2), "XXa")
    ck("sub com nome", re.sub("(?P<a>\\w+) (?P<b>\\w+)", "\\g<b> \\g<a>", "ola mundo"), "mundo ola")
    ck("search acha no meio", "sim" if re.search("b+", "aabbb") != None else "nao", "sim")
    ck("match nao", "sim" if re.match("b+", "aabbb") == None else "nao", "sim")
    ck("finditer", "|".join([str(x) for x in re.finditer("\\d+", "a1b22")]), "1|2|3|5")

    # ---- o casamento VAZIO avança, senão o laço não acaba ----
    ck("findall de vazio", str(len(re.findall("a*", "bb"))), "3")
    ck("sub de vazio", re.sub("x*", "-", "ab"), "-a-b-")

    # ---- grupos com nome, nas duas grafias ----
    g = re.match("(?P<user>\\w+)@(?<host>\\w+)", "ana@exemplo")
    if g != None:
        ck("nomes", g[1] + "/" + g[2], "ana/exemplo")

    # ---- as marcas ----
    ck("(?m)^", "sim" if re.search("(?m)^b", "a\nb") != None else "nao", "sim")
    ck("sem (?m)", "sim" if re.search("^b", "a\nb") == None else "nao", "sim")
    ck("(?s).", str(len(got_of("(?s).+", "a\nb"))), "3")

    # ---- o que ele RECUSA, e a mensagem diz PORQUÊ ----
    #
    # Não é uma falta: é o preço da garantia, e uma mensagem que diga
    # "não suportado" faria alguém pensar que um dia vem.
    try:
        _ = re.match("(a)\\1", "aa")
        print("  ISTO NAO DEVIA APARECER: aceitou um retrocesso")
        e[1] += 1
    catch err:
        ck("recusa o retrocesso", "sim" if "linear-time" in err.message else err.message, "sim")
    try:
        _ = re.match("a(?=b)", "ab")
        print("  ISTO NAO DEVIA APARECER: aceitou um lookahead")
        e[1] += 1
    catch err2:
        ck("recusa o lookahead", "sim" if "linear-time" in err2.message else err2.message, "sim")

    # ---- e o que é simplesmente inválido ----
    for mau in ["(", "[", "a{2,1}", "*a", "a{1000000}", "(?<x", "\\x4"]:
        try:
            _ = re.match(mau, "a")
            print("  ISTO NAO DEVIA APARECER: aceitou " + mau)
            e[1] += 1
        catch err3:
            e[0] += 1

    # ---- 152.6: as categorias Unicode, e a dobra de caixa ----
    #
    # As tabelas já existiam — geradas e conferidas por um oráculo que varre
    # todo o ponto de código (105). O que faltava era uma porta: o motor mora na
    # camada da biblioteca e os leitores eram privados da dos valores.
    ck("\\p{L}", got_of("\\p{L}+", "ábcÇ1"), "ábcÇ")
    ck("\\p{Lu}", got_of("\\p{Lu}+", "ÁB c"), "ÁB")
    ck("\\p{Ll}", got_of("\\p{Ll}+", "áb C"), "áb")
    # dígitos árabe-índicos: um `\\d` de ASCII não os apanha e um `\\p{Nd}` sim
    ck("\\p{Nd}", got_of("\\p{Nd}+", "٣٤5x"), "٣٤5")
    ck("\\d nao apanha", got_of("\\d+", "٣٤5"), "-")
    ck("\\p{N}", got_of("\\p{N}+", "123"), "123")
    ck("\\p{Alnum}", got_of("\\p{Alnum}+", "aé1!"), "aé1")
    ck("forma curta \\pL", got_of("\\pL+", "abc1"), "abc")
    ck("\\P{L} negado", got_of("\\P{L}+", "123abc"), "123")
    ck("dentro de uma classe", got_of("[\\p{L}0-9]+", "aé9!"), "aé9")

    # o `(?i)` dobra a caixa do UNICODE, e não só o ASCII
    ck("(?i) com acentos", got_of("(?i)ÁÉÍ", "áéí"), "áéí")
    ck("(?i) grego", got_of("(?i)ΣΙΓΜΑ", "σιγμα"), "σιγμα")
    ck("(?i) ascii", got_of("(?i)[a-z]+", "ABC"), "ABC")

    # ... e uma categoria que não existe é recusada com a lista das que há
    try:
        _ = re.match("\\p{Xyz}", "a")
        print("  ISTO NAO DEVIA APARECER: aceitou uma categoria inventada")
        e[1] += 1
    catch err4:
        ck("categoria inventada", "sim" if "unknown Unicode category" in err4.message else err4.message, "sim")

    print("re: " + str(e[0]) + " ok, " + str(e[1]) + " falharam")


main()
