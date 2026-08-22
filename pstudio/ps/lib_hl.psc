"""O realce, em pscript, com o lexer DO COMPILADOR do outro lado da fronteira.

113: o adaptador `hl.p` lexa e responde em números (ver `hl.ph`); tudo o que é
DECISÃO mora aqui — quais classes se pintam, o que é comentário, como um span
vira uma cor na coluna. É a mesma divisão do `shim`: a mão que toca o ponteiro
fica em P, a lógica fica aqui.

Duas coisas que o adaptador NÃO diz, e por que não fazem falta:

  * o TEXTO do token. Quem precisa do nome de um identificador fatia o próprio
    texto pela (linha, coluna, comprimento) — o buffer já está aqui, e assim
    nada de cadeia atravessa de volta;
  * o COMENTÁRIO. O lexer do compilador come comentário (não é token), então o
    editor em P já procurava o `#` à mão. Continua sendo à mão, mas aqui: é a
    única regra de realce que não é do lexer, e ela precisa saber quais spans
    são cadeia — que é informação que já está nesta camada.
"""
import "hl.ph"

import lib_core as core


# as classes que o editor pinta. HL_TEXT é "nada de especial" e não vira span.
const HL_TEXT: int = 0
const HL_KW: int = 1
const HL_STR: int = 2
const HL_NUM: int = 3
const HL_COMMENT: int = 4


record HlSpan:
    col: int          # primeiro codepoint
    length: int       # comprimento em codepoints
    cls: int


struct Hl:
    lines: list<list<HlSpan>>   # um por linha do buffer
    version: int                # a versão do buffer de que isto saiu
    enabled: bool               # False = não é arquivo P (span nenhum)

    def class_at(self, line: int, col: int) -> int:
        if not self.enabled or line < 0 or line >= len(self.lines):
            return HL_TEXT
        for sp in self.lines[line]:
            if col >= sp.col and col < sp.col + sp.length:
                return sp.cls
        return HL_TEXT

    def add(self, line: int, col: int, length: int, cls: int):
        if line >= 0 and line < len(self.lines) and length > 0:
            self.lines[line].append(HlSpan(col, length, cls))

    def update(self, b: core.Buffer):
        """Relexa o arquivo INTEIRO quando a versão do buffer mudou. É o que o
        editor em P faz, e é barato o suficiente: o lexer do compilador passa
        por um arquivo de mil linhas em menos de um milissegundo."""
        if self.version == b.version and len(self.lines) == b.nlines():
            return
        self.lines = []
        for i in range(b.nlines()):
            self.lines.append([])
        self.version = b.version
        if not self.enabled:
            return
        n = hl_lex(b.text())
        for i in range(n):
            cls = hl_tok_class(i)
            # identificador não é span (é o texto normal) e pontuação não se
            # pinta — as duas ficam de fora, como no editor em P
            if cls == HLC_TEXT or cls == HLC_PUNCT:
                continue
            mine = HL_KW
            if cls == HLC_STR:
                mine = HL_STR
            elif cls == HLC_NUM:
                mine = HL_NUM
            self.add(hl_tok_line(i), hl_tok_col(i), hl_tok_cp(i), mine)
        # o comentário: o primeiro `#` FORA de uma cadeia vai até o fim da linha
        for ln in range(b.nlines()):
            s = b.line_text(ln)
            col = 0
            for ch in s:
                if ch == "#":
                    inside = False
                    for sp in self.lines[ln]:
                        if sp.cls == HL_STR and col >= sp.col and col < sp.col + sp.length:
                            inside = True
                            break
                    if not inside:
                        self.add(ln, col, len(s) - col, HL_COMMENT)
                        break
                col += 1


def new_hl(enabled: bool) -> Hl:
    return Hl([], 0, enabled)


def is_p_file(path: str) -> bool:
    """Realce é do P e do pscript — os outros arquivos abrem sem span nenhum,
    que é o que `enabled=False` quer dizer."""
    for ext in [".p", ".ph", ".psc", ".psh"]:
        if path.endswith(ext):
            return True
    return False
