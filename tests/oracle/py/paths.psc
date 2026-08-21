# paths.psc — `path` contra o `posixpath` do CPython, por VARREDURA.
#
# 111: a camada de sistema nasceu do `psys.p` do editor, que tinha as três
# contas escritas à mão e "quase" iguais às do Python (o `dirname` de um nome
# sem barra devolvia `.`, o Python devolve `''`). Uma varredura de mil caminhos
# — prefixo de zero a três barras, três componentes tirados de {vazio, ., .., a,
# b}, com e sem barra final — é o que separa "quase" de "igual".
import path

COMPS = ["", ".", "..", "a", "b"]
PRES = ["", "/", "//", "///"]
SUFS = ["", "/"]

ps = [""]
for pre in PRES:
    for i in range(len(COMPS)):
        for j in range(len(COMPS)):
            for k in range(len(COMPS)):
                mid = COMPS[i] + "/" + COMPS[j] + "/" + COMPS[k]
                for suf in SUFS:
                    ps.append(pre + mid + suf)

for p in ps:
    print("normpath [" + p + "] [" + path.normpath(p) + "]")
    print("dirname [" + p + "] [" + path.dirname(p) + "]")
    print("basename [" + p + "] [" + path.basename(p) + "]")

# `join` de dois e de três: o pedaço absoluto joga fora o que veio antes, e a
# barra que sobra não vira duas
JS = ["", ".", "..", "a", "a/", "/a", "/", "//", "a//"]
for i in range(len(JS)):
    for j in range(len(JS)):
        print("join2 [" + JS[i] + "] [" + JS[j] + "] [" + path.join(JS[i], JS[j]) + "]")
        for k in range(len(JS)):
            print("join3 [" + JS[i] + "] [" + JS[j] + "] [" + JS[k] + "] [" + path.join(JS[i], JS[j], JS[k]) + "]")
