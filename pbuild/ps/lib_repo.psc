"""O REPOSITÓRIO: um formato, não um serviço.

O desenho inteiro está em `ppack/REPOSITORIO.md`; o que segue é o que este
arquivo implementa dele.

Um repositório são quatro nomes e um diretório:

    repo/
      index.json                            o que dá para pesquisar e resolver
      index.json.sig                        a assinatura do repo (ainda não)
      pkg/<nome>/<nome>-<versão>.tar        o fonte
      pkg/<nome>/<nome>-<versão>.tar.sig    a assinatura do autor (ainda não)

Servível por `python3 -m http.server`, por um bucket, por `file://`, por um pen
drive. É essa a consequência de ser formato: publicar não envia nada, produz —
e enviar é `rsync`, `scp` ou `git push`.

**NADA É GLOBAL.** O índice guardado, os tarballs e as árvores abertas moram em
`build/pkg/` do PROJETO. Não há diretório em `~` que isto escreva, e a
consequência é que copiar o projeto leva tudo junto, dois checkouts não se
contaminam, e não existe estado escondido numa máquina que explique um "aqui
funciona". A CHAVE aceite no TOFU é a exceção que confirma: ela mora no
`pack.lock`, que é COMITADO — a confiança é versionada e passa por revisão de
código, em vez de por um aviso no terminal de uma pessoa só.

Enquanto não há Ed25519, tudo corre em **modo unsafe** — explícito, avisado em
cada operação e gravado no lock. O hash NUNCA é dispensado: ele é a única coisa
que impede que o que chegou seja outra coisa.
"""
import json
import os
import path
import time
import lib_manifest as M
import <tar/tar.psc> as tar
import <sha2/sha2.ph>

# tudo o que este projeto guarda de fora vive aqui, e `make clean` leva junto —
# é seguro por construção, porque o lock tem o hash de tudo
const ARMAZEM: str = "build/pkg"


def dir_indices() -> str:
    return path.join(ARMAZEM, ".index")


def dir_paks() -> str:
    return path.join(ARMAZEM, ".pak")


# ---------- o endereço ----------

struct Repo:
    url: str        # normalizado, sempre a terminar em "/"
    inseguro: bool
    id: str         # o hash do URL: um nome estável que ninguém escolhe

def normaliza(url: str) -> str:
    return url if url.endswith("/") else url + "/"


def id_de(url: str) -> str:
    """O `<repo-id>`: os 16 primeiros dígitos do SHA-256 do URL normalizado.

    Não é um apelido porque um apelido é uma escolha, e duas pessoas escolhem
    `oficial` para repositórios diferentes. O hash não tem essa liberdade."""
    return sha256_of(tar.bytes_de(normaliza(url)))[0:16]


def repo(url: str, inseguro: bool) -> Repo:
    n = normaliza(url)
    return Repo(n, inseguro, id_de(n))


def eh_arquivo(r: Repo) -> bool:
    return r.url.startswith("file://")


def caminho_local(r: Repo) -> str:
    """O diretório por trás de um `file://`. Levanta para qualquer outro esquema."""
    if not eh_arquivo(r):
        raise error("não é um repositório local: " + r.url, VALUE)
    return r.url[7:len(r.url)]


async def buscar(r: Repo, rel: str) -> list<u8>:
    """UM arquivo do repositório, pelo caminho relativo. É o único ponto por onde
    bytes de fora entram, e é de propósito: quando o HTTP entrar, entra aqui e
    nada acima muda."""
    if eh_arquivo(r):
        alvo = path.join(caminho_local(r), rel)
        if not path.isfile(alvo):
            raise error("não existe no repositório: " + alvo, IO)
        f = await open(alvo, "r")
        b = await f.read_all()
        await f.close()
        return b
    raise error("transporte ainda não implementado para: " + r.url, VALUE)


# ---------- o índice ----------

struct Versao:
    nome: str
    versao: str
    arquivo: str          # o caminho do `.tar` dentro do repositório
    tamanho: int
    sha256: str
    autor: str            # a chave que assinou o tarball ("" enquanto unsafe)
    lang: str
    raiz: str
    deps: list<M.Dep>
    toolchain: str
    descricao: str
    api: dict<str, list<str>>    # módulo -> a lista canónica de símbolos
    api_hash: dict<str, str>     # módulo -> o hash de interface


struct Indice:
    formato: int
    nome: str
    atualizado: str
    # nome -> versão -> a entrada
    pacotes: dict<str, dict<str, Versao>>

    def tem(self, nome: str, versao: str) -> bool:
        if nome not in self.pacotes:
            return False
        return versao in self.pacotes[nome]

    def pega(self, nome: str, versao: str) -> Versao:
        if not self.tem(nome, versao):
            raise error(f"{nome}@{versao} não está no índice", KEY)
        return self.pacotes[nome][versao]

    def nomes(self) -> list<str>:
        out: list<str> = []
        for n in self.pacotes:
            out.append(n)
        return sorted(out)

    def versoes(self, nome: str) -> list<str>:
        out: list<str> = []
        if nome not in self.pacotes:
            return out
        for v in self.pacotes[nome]:
            out.append(v)
        return sorted(out)


def vazia() -> Versao:
    return Versao("", "", "", 0, "", "", "", "", [], "", "", {}, {})


def indice_novo(nome: str) -> Indice:
    return Indice(1, nome, "", {})


# ---------- JSON: ler ----------
#
# Lido com `as`, que é CHECADO e levanta (55.2). Não há aqui a leniência de
# "ignora o que não entendes": este é o NOSSO formato, escrito pelo `publish`, e
# um índice com a forma errada é um índice corrompido — seguir em frente com ele
# daria um build que resolve versões a partir de lixo. O que a leitura faz é
# emprestar a mensagem o nome do arquivo, para o erro dizer QUAL índice.

private def txt(d: dict<str, any>, k: str, padrao: str) -> str:
    if k not in d:
        return padrao
    return d[k] as str


private def num(d: dict<str, any>, k: str) -> int:
    if k not in d:
        return 0
    return d[k] as int


def ler_indice(raw: str, de_onde: str) -> Indice:
    try:
        return ler_indice_x(raw)
    catch e:
        raise error(de_onde + ": " + e.message, VALUE)


private def ler_indice_x(raw: str) -> Indice:
    d = json.parse(raw) as dict<str, any>
    ix = indice_novo(txt(d, "name", ""))
    ix.formato = num(d, "format")
    if ix.formato != 1:
        raise error(f"formato de índice {ix.formato}, e esta versão lê 1", VALUE)
    ix.atualizado = txt(d, "updated", "")
    if "packages" not in d:
        return ix
    pacotes = d["packages"] as dict<str, any>
    nomes: list<str> = []
    for n in pacotes:
        nomes.append(n)
    for nome in sorted(nomes):
        porver = pacotes[nome] as dict<str, any>
        saida: dict<str, Versao> = {}
        vs: list<str> = []
        for vn in porver:
            vs.append(vn)
        for versao in sorted(vs):
            e = porver[versao] as dict<str, any>
            u = vazia()
            u.nome = nome
            u.versao = versao
            u.arquivo = txt(e, "file", "")
            u.tamanho = num(e, "size")
            u.sha256 = txt(e, "sha256", "")
            u.autor = txt(e, "author", "")
            u.lang = txt(e, "lang", "")
            u.raiz = txt(e, "root", "")
            u.toolchain = txt(e, "toolchain", "")
            u.descricao = txt(e, "description", "")
            if "deps" in e:
                dd = e["deps"] as dict<str, any>
                dns: list<str> = []
                for dn in dd:
                    dns.append(dn)
                for dn2 in sorted(dns):
                    u.deps.append(M.Dep(dn2, dd[dn2] as str))
            if "api" in e:
                aa = e["api"] as dict<str, any>
                mods: list<str> = []
                for mn in aa:
                    mods.append(mn)
                for mod in sorted(mods):
                    mm = aa[mod] as dict<str, any>
                    u.api_hash[mod] = txt(mm, "hash", "")
                    simb: list<str> = []
                    if "symbols" in mm:
                        for sv in mm["symbols"] as list<any>:
                            simb.append(sv as str)
                    u.api[mod] = simb
            saida[versao] = u
        ix.pacotes[nome] = saida
    return ix


# ---------- JSON: escrever ----------
#
# À mão, e de propósito: a ORDEM é o que faz dois `publish` do mesmo conteúdo
# darem o mesmo arquivo, e um `dict` despejado sem ordem daria um diff enorme a
# cada publicação. Tudo aqui sai ordenado por chave.

private def esc(s: str) -> str:
    out = "\""
    for ch in s:
        c = ord(ch)
        if ch == "\"" or ch == "\\":
            out += "\\" + ch
        elif c == 10:
            out += "\\n"
        elif c == 13:
            out += "\\r"
        elif c == 9:
            out += "\\t"
        elif c < 32:
            out += f"\\u{c:04x}"
        else:
            out += ch
    return out + "\""


def escrever_indice(ix: Indice) -> str:
    b = "{\n"
    b += "  \"format\": 1,\n"
    b += "  \"name\": " + esc(ix.nome) + ",\n"
    b += "  \"updated\": " + esc(ix.atualizado) + ",\n"
    b += "  \"packages\": {"
    primeiro = True
    for nome in ix.nomes():
        b += "" if primeiro else ","
        primeiro = False
        b += "\n    " + esc(nome) + ": {"
        pv = True
        for versao in ix.versoes(nome):
            u = ix.pega(nome, versao)
            b += "" if pv else ","
            pv = False
            b += "\n      " + esc(versao) + ": {\n"
            b += "        \"file\": " + esc(u.arquivo) + ",\n"
            b += "        \"size\": " + str(u.tamanho) + ",\n"
            b += "        \"sha256\": " + esc(u.sha256) + ",\n"
            b += "        \"author\": " + esc(u.autor) + ",\n"
            b += "        \"lang\": " + esc(u.lang) + ",\n"
            b += "        \"root\": " + esc(u.raiz) + ",\n"
            b += "        \"toolchain\": " + esc(u.toolchain) + ",\n"
            b += "        \"description\": " + esc(u.descricao) + ",\n"
            b += "        \"deps\": {"
            pd = True
            for d in u.deps:
                b += "" if pd else ", "
                pd = False
                b += esc(d.nome) + ": " + esc(d.faixa)
            b += "},\n"
            b += "        \"api\": {"
            pa = True
            mods: list<str> = []
            for mk in u.api:
                mods.append(mk)
            for mod in sorted(mods):
                b += "" if pa else ","
                pa = False
                b += "\n          " + esc(mod) + ": {\n"
                b += "            \"hash\": " + esc(u.api_hash[mod] if mod in u.api_hash else "") + ",\n"
                b += "            \"symbols\": ["
                ps = True
                for s in u.api[mod]:
                    b += "" if ps else ","
                    ps = False
                    b += "\n              " + esc(s)
                b += "\n            ]" if not ps else "]"
                b += "\n          }"
            b += "\n        }" if not pa else "}"
            b += "\n      }"
        b += "\n    }"
    b += "\n  }" if not primeiro else "}"
    b += "\n}\n"
    return b


# ---------- empacotar ----------
#
# O que entra no `.tar` é A ÁRVORE INTEIRA menos uma lista FIXA — decidida pelo
# `ppack` e não pelo pacote. Um manifesto com regras de empacotamento seria uma
# segunda verdade sobre o que o pacote é, e a primeira (o grafo de imports) já
# existe. O que a lista tira é o que nunca é fonte: o que o build produziu, o que
# o controlo de versões guarda, e o lixo de editor.

const DIRS_FORA: list<str> = ["build", ".git", ".hg", ".svn", ".verify",
                              "__pycache__", "node_modules", ".idea", ".vscode"]
const SUFIXOS_FORA: list<str> = [".o", ".a", ".so", ".dylib", ".dll", ".exe",
                                 ".tar", ".sig", ".orig", ".rej", ".swp", "~"]
const NOMES_FORA: list<str> = [".DS_Store", "pack.lock", "core"]


def fora(nome: str, eh_dir: bool) -> bool:
    if eh_dir:
        return nome in DIRS_FORA
    if nome in NOMES_FORA:
        return True
    for s in SUFIXOS_FORA:
        if nome.endswith(s):
            return True
    return False


private async def andar(raiz: str, rel: str, saida: list<str>):
    """Os arquivos da árvore, em ordem. A ordem é o que faz dois `publish` do
    mesmo conteúdo darem o MESMO tarball — e o tarball é a identidade."""
    aqui = raiz if rel == "" else path.join(raiz, rel)
    for nome in sorted(os.listdir(aqui)):
        cheio = path.join(aqui, nome)
        eh_dir = path.isdir(cheio)
        if fora(nome, eh_dir):
            continue
        r2 = nome if rel == "" else rel + "/" + nome
        if eh_dir:
            await andar(raiz, r2, saida)
        else:
            saida.append(r2)


async def empacotar(dir: str, prefixo: str) -> list<u8>:
    """A árvore de um pacote como `.tar`, dentro de um diretório `prefixo/`.

    REPRODUTÍVEL, e isso não é elegância: o hash do tarball É a identidade do
    pacote no índice e no lock, então dois empacotamentos do mesmo fonte têm de
    dar o mesmo hash. Por isso a data é ZERO e o modo é fixo — a data de
    modificação de um arquivo no disco de quem publica não é conteúdo, e deixá-la
    entrar faria a mesma versão ter dois hashes conforme a máquina.

    O preço é conhecido e aceite: o bit de execução não sobrevive. Um pacote de
    CÓDIGO-FONTE não precisa dele, e quem precisar de um script chama `sh x.sh`.
    """
    arquivos: list<str> = []
    await andar(dir, "", arquivos)
    if len(arquivos) == 0:
        raise error("não há nada para empacotar em " + dir, VALUE)
    membros: list<tar.Membro> = [tar.diretorio(prefixo, 0o755, 0)]
    vistos: dict<str, int> = {}
    for rel in arquivos:
        # os diretórios intermédios entram antes do primeiro arquivo que os
        # habita: um `tar` que extrai sem eles depende do comportamento do
        # extrator, e este formato não depende de bondade alheia
        partes = rel.split("/")
        acc = prefixo
        i = 0
        while i < len(partes) - 1:
            acc = acc + "/" + partes[i]
            if acc not in vistos:
                vistos[acc] = 1
                membros.append(tar.diretorio(acc, 0o755, 0))
            i += 1
        f = await open(path.join(dir, rel), "r")
        dados = await f.read_all()
        await f.close()
        membros.append(tar.arquivo(prefixo + "/" + rel, dados, 0o644, 0))
    return tar.escrever(membros)


def hash_de(b: list<u8>) -> str:
    return sha256_of(b)


# ---------- guardar e ler o que veio ----------

async def escrever_bytes(alvo: str, b: list<u8>):
    d = path.dirname(alvo)
    if len(d) > 0 and not path.isdir(d):
        os.makedirs(d)
    f = await open(alvo, "w")
    await f.write(b)
    await f.close()


async def ler_bytes(alvo: str) -> list<u8>:
    f = await open(alvo, "r")
    b = await f.read_all()
    await f.close()
    return b


async def extrair(b: list<u8>, destino: str) -> int:
    """Abre um tarball em `destino`. Devolve quantos arquivos saíram.

    O leitor já recusou caminho absoluto, `..` e o que não é arquivo nem
    diretório — aqui é só escrever. A recusa acontece ANTES de qualquer byte
    tocar o disco, que é a ordem que importa: um extrator que valida enquanto
    escreve já escreveu."""
    membros = tar.ler(b)
    n = 0
    for m in membros:
        alvo = path.join(destino, m.nome)
        if m.tipo == "dir":
            if not path.isdir(alvo):
                os.makedirs(alvo)
            continue
        await escrever_bytes(alvo, m.dados)
        n += 1
    return n


def bytes_de_texto(s: str) -> list<u8>:
    return tar.bytes_de(s)


# ---------- a data ----------
#
# O `time` da linguagem dá segundos desde a época e mais nada, e o índice quer
# uma data que uma pessoa leia. A conversão é o algoritmo civil-from-days do
# Hinnant, que é aritmética pura: sem fuso, sem tabela, sem biblioteca — e
# sempre em UTC, porque uma data com fuso local num arquivo que viaja é uma data
# que mente para quem a lê do outro lado.

private def dois(n: int) -> str:
    return ("0" + str(n)) if n < 10 else str(n)


def iso_utc(epoch: int) -> str:
    dias = epoch // 86400
    seg = epoch - dias * 86400
    z = dias + 719468
    era = (z if z >= 0 else z - 146096) // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    mes = mp + 3 if mp < 10 else mp - 9
    ano = y + 1 if mes <= 2 else y
    return f"{ano}-{dois(mes)}-{dois(d)}T{dois(seg // 3600)}:{dois((seg // 60) % 60)}:{dois(seg % 60)}Z"


def agora_iso() -> str:
    return iso_utc(int(time.time()))


def dir_do_pacote(nome: str, versao: str, sha: str) -> str:
    """`build/pkg/<nome>-<versão>-<hash>/` — e é ISTO que o `--pkg-path` aponta.

    O hash no nome é o que faz "a mesma versão com conteúdo diferente" ser
    impossível de confundir, que é o furo apontado em toda análise de
    `requirements.txt`. Dentro dele fica `<nome>/`, porque uma raiz de pacote é
    um diretório cujos filhos são nomes de pacote."""
    return path.join(ARMAZEM, nome + "-" + versao + "-" + sha[0:12])


async def extrair_pacote(b: list<u8>, destino: str, nome: str) -> int:
    """Abre o tarball em `<destino>/<nome>/`, tirando o prefixo com que ele foi
    empacotado (`<nome>-<versão>/`).

    A troca do prefixo é o que faz o diretório servir de raiz de pacote sem
    ninguém ter de saber a versão: `import <sha2/sha2.ph>` procura `sha2/` e é
    isso que está lá."""
    membros = tar.ler(b)
    n = 0
    for m in membros:
        partes = m.nome.split("/")
        if len(partes) < 2:
            continue        # o diretório de topo: quem o substitui é `nome`
        resto = "/".join(partes[1:len(partes)])
        alvo = path.join(destino, nome, resto)
        if m.tipo == "dir":
            if not path.isdir(alvo):
                os.makedirs(alvo)
            continue
        await escrever_bytes(alvo, m.dados)
        n += 1
    return n


def raizes_instaladas() -> list<str>:
    """As raízes de pacote que o `install` materializou. Entram no `--pkg-path`
    ao lado das do workspace — e depois delas, porque o que está na árvore ganha
    de o que veio de fora."""
    out: list<str> = []
    if not path.isdir(ARMAZEM):
        return out
    for nome in sorted(os.listdir(ARMAZEM)):
        if nome.startswith("."):
            continue
        d = path.join(ARMAZEM, nome)
        if path.isdir(d):
            out.append(d)
    return out
