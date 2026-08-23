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
    # 2.13: o C que o pacote traz ESCRITO À MÃO, e as flags dele. Os caminhos são
    # relativos ao diretório do pacote — ele não sabe onde foi extraído — e quem
    # os torna absolutos é a ferramenta, nunca o manifesto.
    csources: list<str>
    cflags: list<str>
    # workspace
    membros: list<str>
    padrao: str
    # ... e de onde vêm as dependências que NÃO estão na árvore. A lista é do
    # PROJETO e não da máquina: dois projetos no mesmo computador podem usar
    # repositórios diferentes, e um projeto que se clona traz consigo de onde as
    # suas dependências vêm. A ordem é a de busca; sem a lista, entra o padrão.
    repos: list<str>
    repos_unsafe: list<bool>

def vazio(caminho: str) -> Manifesto:
    return Manifesto(caminho, False, "", "", "", "", [], [], "", "", [], [], [], "", [], [])

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

private def lista(d: dict<str, any>, chave: str) -> list<str>:
    out: list<str> = []
    if chave not in d:
        return out
    for x in d[chave] as list<any>:
        out.append(x as str)
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
        # o workspace também declara as dependências EXTERNAS do projeto, que
        # não são membros: um membro é código deste repositório, uma dependência
        # é código de fora com nome, versão e hash
        m.deps = pares(root, "deps")
        if "repos" in root:
            for rv in root["repos"] as list<any>:
                # duas formas, e a curta é a comum: um URL. A longa existe para
                # o espelho de desenvolvimento sem chave, que é `unsafe` inteiro.
                # `as` levanta quando não é do tipo, então tentar a curta e cair
                # na longa é a leitura — e o que não for nenhuma das duas cai no
                # erro com a posição da chave.
                try:
                    m.repos.append(rv as str)
                    m.repos_unsafe.append(False)
                catch e2:
                    try:
                        rd = rv as dict<str, any>
                        m.repos.append(texto(rd, "url", ""))
                        m.repos_unsafe.append(("unsafe" in rd) and (rd["unsafe"] as bool))
                    catch e3:
                        erro(m, raw, "repos", "um repositório é um URL, ou {\"url\": ..., \"unsafe\": true}")
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
    m.csources = lista(root, "csources")
    m.cflags = lista(root, "cflags")

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
    # 2.13: o C do pacote. Conferir aqui é conferir uma vez — o build, a
    # publicação e o `ppack check` leem todos este mesmo manifesto.
    for cs in m.csources:
        if not cs.endswith(".c"):
            erro(m, raw, "csources", "csources é C: '" + cs + "' não acaba em `.c`")
        elif cs.startswith("/") or ".." in cs:
            # a mesma regra do leitor de tar, e pelo mesmo motivo: um caminho que
            # sai do pacote é um pacote que lê a árvore de quem o instalou
            erro(m, raw, "csources", "'" + cs + "': o caminho é relativo ao pacote, e não sai dele")
        elif not path.isfile(path.join(dirp, cs)):
            erro(m, raw, "csources", "'" + cs + "' não existe em " + dirp)
    return m


# ---------- escrever no manifesto, sem o estragar ----------
async def escrever_dep(caminho: str, nome: str, versao: str):
    """A dependência entra no `pack.json` do workspace, à mão e preservando o
    resto do arquivo. Reescrever o JSON inteiro a partir da estrutura perderia
    a formatação de quem o escreveu e reordenaria tudo — um gerenciador que
    estraga o arquivo de quem o usa é um gerenciador de que se desconfia.

    Um nome que já lá está é SUBSTITUÍDO e não repetido: `{"tar": "0.1.0",
    "tar": "0.2.0"}` é um objeto com a mesma chave duas vezes, que cada leitor
    de JSON resolve à sua maneira."""
    f = await open(caminho, "r")
    raw = await f.text()
    await f.close()
    linha = "    " + jstr(nome) + ": " + jstr(versao)
    alvo = jstr(nome) + ":"
    if "\"deps\"" in raw:
        i = raw.find("\"deps\"")
        j = raw.find("{", i)
        if j < 0:
            raise error(caminho + ": `deps` tem de ser um objeto", VALUE)
        k = raw.find("}", j)
        dentro = raw[j + 1:k]
        # o nome já está lá? troca-se a linha dele, e mais nada
        p0 = dentro.find(alvo)
        if p0 >= 0:
            ini = 0
            for z in range(p0):
                if dentro[z] == "\n":
                    ini = z + 1
            fim = dentro.find("\n", p0)
            if fim < 0:
                fim = len(dentro)
            virg = "," if dentro[ini:fim].rstrip().endswith(",") else ""
            raw = raw[0:j + 1] + dentro[0:ini] + linha + virg + dentro[fim:] + raw[k:]
        elif len(dentro.strip()) == 0:
            raw = raw[0:j] + "{\n" + linha + "\n  }" + raw[k + 1:len(raw)]
        else:
            raw = raw[0:j] + "{" + dentro.rstrip() + ",\n" + linha + "\n  }" + raw[k + 1:len(raw)]
    else:
        i2 = raw.rfind("}")
        antes = raw[0:i2].rstrip()
        if antes.endswith(","):
            antes = antes[0:len(antes) - 1]
        raw = antes + ",\n  \"deps\": {\n" + linha + "\n  }\n}\n"
    await gravar_texto(caminho, raw)


async def escrever_campo(caminho: str, chave: str, valor: str):
    """Um campo de TOPO do manifesto, escrito à mão e preservando o resto.

    A mesma cirurgia da `escrever_dep`, e pela mesma razão: reescrever o JSON a
    partir da estrutura perderia a formatação de quem o escreveu e reordenaria
    tudo. Uma ferramenta que estraga o arquivo de quem a usa é uma ferramenta de
    que se desconfia — e um manifesto é um arquivo que se comita.

    A chave que já existe é SUBSTITUÍDA no lugar onde está; a que não existe
    entra antes da chaveta final."""
    f = await open(caminho, "r")
    raw = await f.text()
    await f.close()
    alvo = jstr(chave) + ":"
    k = raw.find(alvo)
    if k >= 0:
        ini = 0
        for z in range(k):
            if raw[z] == "\n":
                ini = z + 1
        fim = raw.find("\n", k)
        if fim < 0:
            fim = len(raw)
        virg = "," if raw[ini:fim].rstrip().endswith(",") else ""
        raw = raw[0:ini] + "  " + alvo + " " + jstr(valor) + virg + raw[fim:len(raw)]
    else:
        i2 = raw.rfind("}")
        antes = raw[0:i2].rstrip()
        if antes.endswith(","):
            antes = antes[0:len(antes) - 1]
        raw = antes + ",\n  " + alvo + " " + jstr(valor) + "\n}\n"
    await gravar_texto(caminho, raw)


private async def gravar_texto(caminho: str, txt: str):
    f = await open(caminho, "w")
    await f.write(txt)
    await f.close()


def jstr(s: str) -> str:
    """Uma string JSON, escapada. É a mesma conta do `lib_graph`, e está aqui
    porque um manifesto não pode depender do grafo — quem lê `pack.json` é o
    gerenciador, e o gerenciador vem antes do build."""
    out = "\""
    for c in s:
        if c == "\"":
            out += "\\\""
        elif c == "\\":
            out += "\\\\"
        elif c == "\n":
            out += "\\n"
        elif c == "\t":
            out += "\\t"
        elif c == "\r":
            out += "\\r"
        else:
            out += c
    return out + "\""


def versao_maior(a: str, b: str) -> bool:
    """`a > b`, comparando NÚMERO a número e não texto a texto.

    "0.10.0" e "0.9.0": como texto o segundo ganha, e como versão perde. É o
    erro clássico, e custa três linhas não o cometer."""
    pa = a.split(".")
    pb = b.split(".")
    i = 0
    while i < 3:
        na = int(pa[i]) if i < len(pa) else 0
        nb = int(pb[i]) if i < len(pb) else 0
        if na != nb:
            return na > nb
        i += 1
    return False


def toolchain_ok(faixa: str, versao: str) -> str:
    """A faixa de toolchain contra a versão que se tem. Devolve "" quando serve,
    e a RAZÃO quando não serve.

    A faixa é `>= X.Y.Z` e mais nada — a v1 não tem resolvedor e também não tem
    álgebra de intervalos. Uma faixa vazia é "serve qualquer uma", que é o que um
    pacote sem exigências quer dizer.

    Conferir isto ANTES de compilar dá a melhor mensagem possível ("o pacote foo
    exige plangc >= X, o seu é Y") em vez de um erro de sintaxe a meio de um
    módulo que usa uma coisa que ainda não existe."""
    f = faixa.strip()
    if len(f) == 0 or len(versao) == 0:
        return ""
    if not f.startswith(">="):
        return "faixa de toolchain que não se entende: `" + faixa + "` (a v1 lê `>= x.y.z`)"
    quer = f[2:].strip()
    if not versao_ok(quer) or not versao_ok(versao):
        return ""
    if versao_maior(quer, versao):
        return "exige plangc " + f + ", e o seu é " + versao
    return ""
