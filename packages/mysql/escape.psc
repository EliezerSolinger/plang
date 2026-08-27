"""Escapar valores para dentro de uma query — a defesa contra injeção de SQL.

O PyMySQL, ao contrário do que o nome "prepared statement" sugere, NÃO usa o
protocolo binário de statements: o `cursor.execute(sql, args)` escapa os valores
no lado do cliente e manda texto. Este módulo é esse escape.

A regra é a do `_escape_table` do pymysql: dentro de uma string entre aspas
simples, sete caracteres têm de virar sequências de escape, senão um deles fecha
a aspa mais cedo e o que vem depois é interpretado como SQL. `'` é o óbvio; `\\`
é o que escaparia a defesa; e `NUL`, `\\n`, `\\r`, `Ctrl-Z` e `"` completam o
conjunto que o servidor trata.

Um valor escapado É seguro, mas escapar não é a única defesa possível — o
protocolo tem `COM_STMT_*`, onde o valor nunca toca o texto. Fica para quando o
servidor de jogo medir que precisa; o pymysql viveu sem ele.
"""


def escape_string(value: str) -> str:
    """Escapa `value` para ir DENTRO de aspas — não põe as aspas. É o miolo, para
    quem quer montar a string à mão."""
    out = ""
    for ch in value:
        c = ord(ch)
        if c == 0:
            out += "\\0"
        elif ch == "\\":
            out += "\\\\"
        elif ch == "\n":
            out += "\\n"
        elif ch == "\r":
            out += "\\r"
        elif c == 26:
            out += "\\Z"
        elif ch == "\"":
            out += "\\\""
        elif ch == "'":
            out += "\\'"
        else:
            out += ch
    return out


def quote_string(value: str) -> str:
    """`value` como um literal de SQL: escapado e entre aspas simples."""
    return "'" + escape_string(value) + "'"


def quote_int(value: int) -> str:
    return f"{value}"


def quote_float(value: float) -> str:
    return f"{value}"


def quote_bool(value: bool) -> str:
    return "1" if value else "0"
