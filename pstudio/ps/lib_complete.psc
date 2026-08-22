"""O índice de completamento, em pscript (porte do `pstudio/complete.p`).

Ele se monta com o LEXER DO COMPILADOR, através do adaptador da 113 — que é o
que o faz funcionar num buffer meio digitado: são tokens de verdade, então
cadeia, comentário e número nunca entram como candidato. Do fluxo de tokens ele
recupera declarações (`def f(...)`, `struct S:` e os membros dela, `x: T`) e,
para o caso `x.`, o TIPO de uma variável — que é o que transforma "palavras do
arquivo" em completamento de membro.

O que ele NÃO é: um verificador de tipos. Tipar expressão inteira precisa de
parser tolerante mais sema sobre o buffer; quando isso existir, entra atrás da
mesma API.

**Uma diferença do porte, e é de LAYERING:** em P, `build` lia os `.ph` que o
buffer importa, ele mesmo, com o `psys`. Aqui ele não faz I/O — `imports_of`
DIZ quais arquivos são, e quem tem o laço de eventos (que é quem pode esperar)
lê e passa os textos em `extra`. O índice deixa de ter opinião sobre arquivo, e
com isso continua SÍNCRONO: o `codeview` chama sem ser `async`.
"""
import "hl.ph"

import lib_core as core


enum SymKind:
    SYM_KEYWORD       # as palavras da própria linguagem
    SYM_WORD          # um identificador visto no arquivo (a base do Sublime)
    SYM_TYPE          # struct / enum / union
    SYM_FUNC          # `def` no escopo do arquivo
    SYM_MEMBER        # campo ou método de um struct


struct CSym:
    name: str         # o que entra no texto
    detail: str       # mostrado apagado à direita (assinatura, tipo); "" = nada
    owner: str        # SYM_MEMBER: o struct a que pertence; "" = nenhum
    kind: SymKind


# `struct` e não `record`: um record só guarda número (58.2), e estes dois campos
# são cadeias — que são referência de heap
struct CVar:
    name: str
    type_name: str


# as palavras da própria linguagem: sempre oferecidas, e classificadas por
# último. Uma cadeia `const` e não uma lista, porque um módulo IMPORTADO é um
# conjunto de definições e não um programa — ele não tem onde rodar um literal
# de lista (o `split` acontece na chamada, uma vez por índice construído).
const KEYWORDS: str = "def return if elif else while for in do match case break continue goto const struct enum union import include and or not True False None static inline extern volatile restrict defer with out ref is pass global nonlocal declare implement sizeof range i8 i16 i32 i64 u8 u16 u32 u64 f32 f64 bool char void usize isize"


# o texto de um token: fatiado do próprio arquivo pela posição, porque cadeia
# não volta pela fronteira (113) — e o buffer já está deste lado
def tok_text(lines: list<str>, i: int) -> str:
    ln = hl_tok_line(i)
    if ln < 0 or ln >= len(lines):
        return ""
    s = lines[ln]
    c0 = hl_tok_col(i)
    c1 = c0 + hl_tok_cp(i)
    if c0 < 0 or c0 > len(s):
        return ""
    return s[c0:c1 if c1 < len(s) else len(s)]


# O NOME do tipo a que uma declaração se liga, a partir do token depois do `:`.
# Passa por cima de `const` e das estrelas: neste código quase toda variável é
# `x: *Tipo`, e parar no `*` fazia o completamento de membro nunca resolver nada.
def decl_type_name(lines: list<str>, n: int, at: int) -> str:
    i = at
    while i < n and (hl_tok_kind(i) == HLK_STAR or hl_tok_kind(i) == HLK_CONST):
        i += 1
    if i < n and hl_tok_kind(i) == HLK_IDENT:
        return tok_text(lines, i)
    return ""


struct Index:
    syms: list<CSym>
    vars: list<CVar>
    version: int      # a versão do buffer de que isto saiu
    ready: bool

    def is_stale(self, b: core.Buffer) -> bool:
        return not self.ready or self.version != b.version

    def sym(self, i: int) -> CSym:
        return self.syms[i]

    def has(self, name: str, owner: str) -> bool:
        for s in self.syms:
            if s.name == name and s.owner == owner:
                return True
        return False

    def add(self, name: str, detail: str, owner: str, kind: SymKind):
        if len(name) == 0 or self.has(name, owner):
            return
        self.syms.append(CSym(name, detail, owner, kind))

    def scan(self, text: str, words: bool) -> list<str>:
        """Percorre o fluxo de tokens de UM arquivo. `words` = também colhe
        identificador solto (só para o buffer sendo editado; um import
        contribui apenas com as declarações dele). Devolve os imports vistos."""
        imports: list<str> = []
        lines = text.split("\n")
        n = hl_lex(text)
        cur_struct = ""     # o struct em cujo corpo estamos
        depth = 0           # profundidade de INDENT desde aquele cabeçalho
        paren = 0           # dentro de uma lista de parâmetros?
        i = 0
        while i < n:
            k = hl_tok_kind(i)
            # "primeiro token da sua linha" se pergunta às POSIÇÕES, não a
            # tokens de NEWLINE: um '(' não fechado suprime esses (continuação
            # implícita), e um buffer meio digitado é cheio deles.
            pv = i - 1
            while pv >= 0:
                pk = hl_tok_kind(pv)
                if pk != HLK_NEWLINE and pk != HLK_INDENT and pk != HLK_DEDENT:
                    break
                pv -= 1
            line_start = pv < 0 or hl_tok_line(pv) != hl_tok_line(i)
            if k == HLK_INDENT:
                if len(cur_struct) > 0:
                    depth += 1
                i += 1
                continue
            if k == HLK_DEDENT:
                if len(cur_struct) > 0:
                    depth -= 1
                    if depth <= 0:
                        cur_struct = ""
                i += 1
                continue
            if k == HLK_NEWLINE:
                i += 1
                continue
            if k == HLK_IMPORT:
                if i + 1 < n and hl_tok_kind(i + 1) == HLK_STRING:
                    q = tok_text(lines, i + 1)             # "x.ph" com as aspas
                    if len(q) > 2:
                        imports.append(q[1:len(q) - 1])
            elif k == HLK_DEF:
                if i + 1 < n and hl_tok_kind(i + 1) == HLK_IDENT:
                    sig = lines[hl_tok_line(i + 1)].strip() if hl_tok_line(i + 1) < len(lines) else ""
                    if len(cur_struct) > 0:
                        self.add(tok_text(lines, i + 1), sig, cur_struct, SYM_MEMBER)
                    else:
                        self.add(tok_text(lines, i + 1), sig, "", SYM_FUNC)
                    i += 1        # o nome já entrou: não entra também como palavra
            elif k == HLK_STRUCT or k == HLK_UNION or k == HLK_ENUM:
                if i + 1 < n and hl_tok_kind(i + 1) == HLK_IDENT:
                    self.add(tok_text(lines, i + 1), "", "", SYM_TYPE)
                    cur_struct = tok_text(lines, i + 1)
                    depth = 0
                    i += 1
            elif k == HLK_LPAREN:
                paren += 1
            elif k == HLK_RPAREN:
                if paren > 0:
                    paren -= 1
            elif k == HLK_IDENT:
                # um parâmetro também é declaração: `def f(p: Point)` é o que
                # faz `p.` funcionar dentro do corpo
                if paren > 0 and i + 2 < n and hl_tok_kind(i + 1) == HLK_COLON:
                    ptn = decl_type_name(lines, n, i + 2)
                    if len(ptn) > 0:
                        self.vars.append(CVar(tok_text(lines, i), ptn))
                # `nome: Tipo` — campo dentro de struct, variável fora
                if line_start and i + 2 < n and hl_tok_kind(i + 1) == HLK_COLON:
                    tyname = decl_type_name(lines, n, i + 2)
                    if len(cur_struct) > 0:
                        d = lines[hl_tok_line(i)].strip() if hl_tok_line(i) < len(lines) else ""
                        self.add(tok_text(lines, i), d, cur_struct, SYM_MEMBER)
                    elif len(tyname) > 0:
                        self.vars.append(CVar(tok_text(lines, i), tyname))
                if words:
                    self.add(tok_text(lines, i), "", "", SYM_WORD)
            i += 1
        return imports

    def imports_of(self, b: core.Buffer) -> list<str>:
        """Os `.ph` que o buffer importa, sem indexar nada — para quem PODE ler
        arquivo (o laço de eventos) buscar os textos."""
        probe = Index([], [], 0, False)
        return probe.scan(b.text(), False)

    def build(self, b: core.Buffer, extra: list<str>):
        """Monta do buffer e dos textos já lidos que vieram com ele."""
        self.syms = []
        self.vars = []
        for kw in KEYWORDS.split(" "):
            self.add(kw, "", "", SYM_KEYWORD)
        self.scan(b.text(), True)
        for src in extra:
            self.scan(src, False)
        self.version = b.version
        self.ready = True

    def owner_of(self, expr: str) -> str:
        """O struct cujos membros `expr` expõe: o tipo declarado de uma
        variável, ou o próprio nome quando ele JÁ é um tipo. "" = não sei."""
        for v in self.vars:
            if v.name == expr:
                return v.type_name
        for s in self.syms:
            if s.kind == SYM_TYPE and s.name == expr:
                return s.name
        return ""

    def rank(self, i: int, prefix: str) -> int:
        """Mais alto é melhor: caixa exata, declaração antes de palavra solta,
        e nome mais curto (o mais perto do que se quis dizer)."""
        s = self.syms[i]
        r = 60
        match s.kind:
            case SYM_MEMBER:
                r = 400
            case SYM_FUNC:
                r = 300
            case SYM_TYPE:
                r = 250
            case SYM_WORD:
                r = 120
            case _:
                r = 60
        if s.name.startswith(prefix):
            r += 50                      # a mesma caixa que se digitou
        return r - len(s.name) // 2

    def query(self, prefix: str, owner: str) -> list<int>:
        """Índices em `syms` que completam `prefix`, melhor primeiro. `owner`
        não vazio restringe aos membros daquele struct (o caso `x.`)."""
        hits: list<int> = []
        pl = len(prefix)
        low = prefix.lower()
        for i in range(len(self.syms)):
            s = self.syms[i]
            if len(owner) > 0:
                if s.kind != SYM_MEMBER or s.owner != owner:
                    continue
            elif s.kind == SYM_MEMBER:
                continue                 # membro só depois de `.`/`->`
            if pl > 0 and not s.name.lower().startswith(low):
                continue
            if pl > 0 and len(s.name) == pl:
                continue                 # já digitado inteiro
            hits.append(i)
        # ordenação por inserção (as listas são curtas)
        for i in range(1, len(hits)):
            v = hits[i]
            rv = self.rank(v, prefix)
            k = i
            while k > 0 and self.rank(hits[k - 1], prefix) < rv:
                hits[k] = hits[k - 1]
                k -= 1
            hits[k] = v
        return hits


def new_index() -> Index:
    return Index([], [], 0, False)
