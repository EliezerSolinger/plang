"""`csv` (S9): a RFC 4180, e as três coisas que a vida acrescentou.

O formato tem uma página de norma e mil variações. Este pacote lê a NORMA e mais
três coisas que existem em ficheiros a sério e sem as quais ele seria inútil: o
**separador** (`;` em meia Europa, porque a vírgula é o separador decimal), os
**três fins de linha** (a norma diz `\\r\\n`, o mundo escreve `\\n`, e um ficheiro
a sério tem os dois) e o **BOM** que o Excel põe à frente — sem o tirar, a
primeira coluna passa a chamar-se `\\ufeffnome`.

**E ele NÃO adivinha tipos.** Tudo sai `str`. Um leitor que decidisse que `007` é
o número sete perderia o zero à esquerda de um código postal, que é o defeito mais
caro que esta família de bibliotecas tem.
"""
import <csv/csv.psc> as csv


def visible(s: str) -> str:
    out: List<str> = []
    for c in s:
        if c == "\r":
            out.append("\\r")
        elif c == "\n":
            out.append("\\n")
        else:
            out.append(c)
    return "".join(out)


def main():
    # ---- 1. a norma: aspas, separador dentro de aspas, aspas duplicadas ----
    t = "nome,idade\r\nana,30\r\n\"silva, joao\",41\r\n\"com \"\"aspas\"\"\",7\r\n"
    rows = csv.parse(t)
    print(len(rows), rows[0])
    print(rows[2][0], "|", rows[3][0])

    # ---- 2. os tres fins de linha, e o BOM ----
    print(csv.parse("﻿a,b\nc,d\r\ne,f\rg,h"))

    # ---- 3. o separador do Excel europeu ----
    print(csv.parse("a;b;c", ";"))
    print(csv.parse("a,b;c", ";"))

    # ---- 4. os casos de canto que partem os leitores caseiros ----
    print("vazio:", csv.parse(""))
    print("uma linha sem fim de linha:", csv.parse("a,b"))
    print("campos vazios:", csv.parse("a,,c"))
    print("linha vazia no meio:", csv.parse("a\r\n\r\nb"))
    print("aspas com fim de linha dentro:", csv.parse("\"a\r\nb\",c"))
    print("nada adivinhado:", csv.parse("007,1.5,true")[0])

    # ---- 5. escrever, e a ida e volta ----
    w = csv.write([["x", "com,virgula"], ["com \"aspas\"", "com\nlinha"], ["", "simples"]])
    print(visible(w))
    print(csv.parse(w))

    # ---- 6. a tabela com cabecalho ----
    tb = csv.parse_table(t)
    print(tb.header, len(tb.rows))
    print(csv.get(tb, 1, "nome"), csv.get(tb, 0, "idade"))
    print("coluna que nao ha:", csv.column_of(tb, "xpto"))
    # uma linha CURTA da string vazia, que e o que o Excel mostra
    short = csv.parse_table("a,b,c\r\n1\r\n")
    print("linha curta:", "[" + csv.get(short, 0, "c") + "]")

    # ---- 7. o que ele recusa ----
    try:
        _ = csv.get(tb, 0, "xpto")
        print("ISTO NAO DEVIA APARECER")
    catch e:
        print("sem coluna:", e.message)
    try:
        _ = csv.get(tb, 99, "nome")
        print("ISTO NAO DEVIA APARECER")
    catch e2:
        print("fora da tabela:", e2.message)
    try:
        _ = csv.parse("a,\"b")
        print("ISTO NAO DEVIA APARECER")
    catch e3:
        print("aspas abertas:", e3.message)

    print("csv-ok")


main()
