"""O `pack.json`: o manifesto de um pacote, e o do WORKSPACE.

Ele é **dado, nunca programa**, e essa é a decisão que sustenta o resto: é o
arquivo que o painel de configuração da IDE edita, e um painel não edita código.
Pelo mesmo motivo ele NÃO repete a lista de arquivos do pacote — o grafo de
imports É o grafo do pacote, e o compilador já responde qual é (respostas 1 e 3
do protocolo). Um manifesto que listasse arquivos teria duas verdades sobre a
mesma coisa, e uma delas ficaria velha.

Duas formas no mesmo formato:

    PACOTE      { "name": "pui", "version": "0.1.0", "lang": "pscript",
                  "root": "pui.psc", "deps": {}, "system": {},
                  "toolchain": ">= 0.1.0", "description": "..." }

    WORKSPACE   { "members": ["packages/stl", "packages/pui"],
                  "default": "build/bin/ppack" }

Quem tem `members` é workspace; quem não tem é pacote. Não há um terceiro
arquivo nem um campo `kind`: a forma diz o que ela é.

**O ERRO tem posição, e a posição é a da CHAVE.** `pack.json:4:12: error: ...` é
clicável na IDE pelo mesmo caminho que um erro de compilação, e é por isso que
vale o trabalho. A posição é achada procurando a chave no texto cru — o
`json.parse` da linguagem devolve a estrutura e não as posições, e escrever um
segundo leitor de JSON só para as ter seria pagar caro por um número. Quando a
chave não é achada (o erro é sobre o arquivo inteiro), a mensagem sai sem
números, que é a mesma forma sem os dois pontos — e não um segundo formato.
"""
import json
import path

struct Dep:
    nome: str
    faixa: str      # a faixa de versão pedida, como escrita

struct Manifesto:
    caminho: str        # de onde ele veio (para a mensagem de erro)
    eh_workspace: bool
    # pacote
    nome: str
    versao: str
    lang: str           # "p" ou "pscript"
    raiz: str           # o módulo raiz, relativo ao diretório do pacote
    deps: list<Dep>
    system: list<Dep>
    toolchain: str
    descricao: str
    # workspace
    membros: list<str>
    padrao: str

def vazio(caminho: str) -> Manifesto:
    return Manifesto(caminho, False, "", "", "", "", [], [], "", "", [], "")

# ---------- a posição de uma chave ----------
def onde(raw: str, chave: str) -> str:
    """`arquivo:linha:coluna` da chave, ou "" se ela não está no texto."""
    alvo = "\"" + chave + "\""
    i = raw.find(alvo)
    if i < 0:
        return ""
    linha = 1
    col = 1
    k = 0
    while k < i:
        if raw[k] == "\n":
            linha += 1
            col = 1
        else:
            col += 1
        k += 1
    return str(linha) + ":" + str(col)

private def erro(m: Manifesto, raw: str, chave: str, msg: str):
    p = onde(raw, chave)
    if len(p) > 0:
        raise error(m.caminho + ":" + p + ": error: " + msg)
    raise error(m.caminho + ": error: " + msg)

# ---------- o que um nome e uma versão podem ser ----------
def nome_ok(s: str) -> bool:
    """Minúsculas, dígitos, `_` e `-`, começando por letra. Estreito de
    propósito: um nome de pacote vira nome de diretório, parte de um caminho de
    import e (mais tarde) parte de uma URL — e cada um desses lugares tem a sua
    lista de caracteres que doem. A interseção é isto."""
    if len(s) == 0:
        return False
    c0 = ord(s[0])
    if not (c0 >= 97 and c0 <= 122):
        return False
    for ch in s:
        c = ord(ch)
        if (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or ch == "_" or ch == "-":
            continue
        return False
    return True

def versao_ok(s: str) -> bool:
    """`x.y.z`, com três números e nada mais. Sem sufixo de pré-lançamento por
    enquanto: acrescentá-lo depois é compatível, tirá-lo não é."""
    partes = s.split(".")
    if len(partes) != 3:
        return False
    for p in partes:
        if len(p) == 0:
            return False
        for ch in p:
            c = ord(ch)
            if c < 48 or c > 57:
                return False
        if len(p) > 1 and p[0] == "0":
            return False        # `01` não é um número de versão
    return True

# ---------- ler ----------
private def texto(d: dict<str, any>, k: str, padrao: str) -> str:
    if k in d:
        return d[k] as str
    return padrao

private def pares(d: dict<str, any>, k: str) -> list<Dep>:
    out: list<Dep> = []
    if k not in d:
        return out
    sub = d[k] as dict<str, any>
    ks: list<str> = []
    for n in sub:
        ks.append(n)
    ks = sorted(ks)     # ordenado: dois manifestos iguais dão a mesma lista
    for n2 in ks:
        out.append(Dep(n2, sub[n2] as str))
    return out

async def ler(caminho: str) -> Manifesto:
    f = await open(caminho, "r")
    raw = await f.text()
    await f.close()
    m = vazio(caminho)
    nonlocal root
    try:
        root = json.parse(raw) as dict<str, any>
    catch e:
        raise error(caminho + ": error: não é um objeto JSON (" + e.message + ")")

    if "members" in root:
        m.eh_workspace = True
        for x in root["members"] as list<any>:
            m.membros.append(x as str)
        m.padrao = texto(root, "default", "")
        if len(m.membros) == 0:
            erro(m, raw, "members", "um workspace sem membros não é um workspace")
        return m

    m.nome = texto(root, "name", "")
    m.versao = texto(root, "version", "")
    m.lang = texto(root, "lang", "")
    m.raiz = texto(root, "root", "")
    m.toolchain = texto(root, "toolchain", "")
    m.descricao = texto(root, "description", "")
    m.deps = pares(root, "deps")
    m.system = pares(root, "system")

    if not nome_ok(m.nome):
        erro(m, raw, "name", "nome de pacote: minúsculas, dígitos, `_` e `-`, começando por letra (veio '" + m.nome + "')")
    if not versao_ok(m.versao):
        erro(m, raw, "version", "versão: três números, `x.y.z` (veio '" + m.versao + "')")
    if m.lang != "p" and m.lang != "pscript":
        erro(m, raw, "lang", "lang: `p` ou `pscript` (veio '" + m.lang + "')")
    # `root` é OPCIONAL, e o `stl` é a razão: são dez `.ph` independentes
    # (vec, str, dict, map, set, list, queue, slice, hash, traits) e nenhum deles
    # é "a interface". Eleger um seria arbitrário e confundiria quem lesse. Um
    # pacote pode ser um CONJUNTO de módulos — e quem quiser `import <pkg>` (a
    # forma curta) é que precisa de uma raiz com o nome do pacote.
    dirp = path.dirname(caminho)
    if len(m.raiz) > 0:
        if m.lang == "p" and m.raiz.endswith(".psc"):
            # a regra que faz um pacote P ser utilizável por quem não tem runtime
            erro(m, raw, "root", "um pacote `p` não tem módulo pscript: a raiz é um `.ph`")
        if not path.isfile(path.join(dirp, m.raiz)):
            erro(m, raw, "root", "a raiz '" + m.raiz + "' não existe em " + dirp)
    for dp in m.deps:
        if not nome_ok(dp.nome):
            erro(m, raw, "deps", "dependência com nome inválido: '" + dp.nome + "'")
    return m
