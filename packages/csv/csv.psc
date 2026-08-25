"""`csv` — a RFC 4180, e as três coisas que a vida acrescentou.

O formato tem uma página de norma e mil variações. Este pacote lê a NORMA e mais
três coisas que existem em ficheiros a sério e sem as quais ele seria inútil:

* **o separador** — o Excel de meia Europa escreve `;` porque a vírgula é o
  separador decimal por lá. É um parâmetro, e não um dialecto com nome;
* **os fins de linha** — a norma diz `\\r\\n`, o mundo escreve `\\n`, e um ficheiro
  a sério tem os dois. **Lê os dois; escreve `\\r\\n`**, que é o que a norma manda
  gerar e o que o Excel espera;
* **um BOM à frente** — o Excel põe-no, e um leitor que não o tire chama à
  primeira coluna `\\ufeffnome`. É tirado em silêncio, uma vez, no princípio.

**O que ele NÃO faz é adivinhar tipos.** Tudo o que sai é `str`. Um CSV não tem
tipos, e um leitor que decida que `007` é o número sete perde o zero à esquerda
de um código postal — que é o defeito mais caro que esta família de bibliotecas
tem.

**Aspas: a regra é uma só.** Um campo entre aspas pode conter o separador, um fim
de linha e aspas — e aspas dentro escrevem-se DUAS. É isso, e é tudo.
"""


const QUOTE = "\""


def parse(text: str, sep: str = ",") -> List<List<str>>:
    """O ficheiro inteiro, em linhas de campos.

    **Levanta** num campo com aspas que não fecham: isso não é uma linha
    diferente do que se esperava, é um ficheiro que acaba a meio de uma coisa, e
    continuar a ler daria linhas inventadas.
    """
    rows: List<List<str>> = []
    row: List<str> = []
    field: List<str> = []
    i = 0
    n = len(text)
    inq = False
    started = False
    # o BOM, uma vez e no princípio
    if n > 0 and text[0] == "﻿":
        i = 1
    while i < n:
        c = text[i]
        if inq:
            if c == QUOTE:
                if i + 1 < n and text[i + 1] == QUOTE:
                    field.append(QUOTE)
                    i += 2
                    continue
                inq = False
                i += 1
                continue
            field.append(c)
            i += 1
            continue
        if c == QUOTE and len(field) == 0:
            inq = True
            started = True
            i += 1
            continue
        if c == sep:
            row.append("".join(field))
            field = []
            started = True
            i += 1
            continue
        if c == "\r" or c == "\n":
            # aceita `\r\n`, `\n` e `\r` sozinho — os três existem em ficheiros
            # a sério, e recusar um deles seria recusar metade deles
            if c == "\r" and i + 1 < n and text[i + 1] == "\n":
                i += 1
            row.append("".join(field))
            rows.append(row)
            row = []
            field = []
            started = False
            i += 1
            continue
        field.append(c)
        started = True
        i += 1
    if inq:
        raise error("csv: a quoted field is never closed", VALUE)
    if started or len(field) > 0 or len(row) > 0:
        row.append("".join(field))
        rows.append(row)
    return rows


def needs_quotes(s: str, sep: str) -> bool:
    for c in s:
        if c == sep or c == QUOTE or c == "\n" or c == "\r":
            return True
    return False


def field_out(s: str, sep: str) -> str:
    if not needs_quotes(s, sep):
        return s
    out: List<str> = [QUOTE]
    for c in s:
        if c == QUOTE:
            out.append(QUOTE)
        out.append(c)
    out.append(QUOTE)
    return "".join(out)


def write_row(row: List<str>, sep: str = ",") -> str:
    """Uma linha, JÁ com o `\\r\\n` no fim — que é o que a norma manda gerar."""
    out: List<str> = []
    for i in range(len(row)):
        if i > 0:
            out.append(sep)
        out.append(field_out(row[i], sep))
    out.append("\r\n")
    return "".join(out)


def write(rows: List<List<str>>, sep: str = ",") -> str:
    out: List<str> = []
    for r in rows:
        out.append(write_row(r, sep))
    return "".join(out)


struct Table:
    """Um CSV com CABEÇALHO: os nomes das colunas, e as linhas.

    É um tipo à parte porque a pergunta é outra — `t.get(linha, "nome")` em vez
    de `rows[i][3]`, e um índice numérico numa coluna é o que parte quando
    alguém acrescenta uma coluna no meio.
    """
    header: List<str>
    rows: List<List<str>>


def parse_table(text: str, sep: str = ",") -> Table:
    all = parse(text, sep)
    if len(all) == 0:
        return Table([], [])
    body: List<List<str>> = []
    for i in range(1, len(all)):
        body.append(all[i])
    return Table(all[0], body)


def column_of(t: Table, name: str) -> int:
    """O índice da coluna, ou -1. A pergunta tem resposta, portanto devolve-se
    (4.2) — é o `get` que levanta quando o nome não existe."""
    for i in range(len(t.header)):
        if t.header[i] == name:
            return i
    return -1


def get(t: Table, row: int, name: str) -> str:
    """O valor daquela coluna naquela linha.

    Levanta se a coluna não existe — isso é um erro de PROGRAMA, o nome está
    escrito no código. Uma linha CURTA (que acontece em ficheiros a sério) dá
    string vazia, que é o que o Excel mostra e o que quem lê espera.
    """
    c = column_of(t, name)
    if c < 0:
        raise error("csv: there is no column named " + name, KEY)
    if row < 0 or row >= len(t.rows):
        raise error("csv: row " + str(row) + " is outside the table", INDEX)
    r = t.rows[row]
    return r[c] if c < len(r) else ""
