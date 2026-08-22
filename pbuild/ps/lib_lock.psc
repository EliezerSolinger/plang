"""O `pack.lock`: a PROCEDÊNCIA do que este projeto usa.

Ele é comitado, e é essa a decisão que faz o resto funcionar. Um `build/` que se
apaga sem medo, um checkout que se clona e constrói igual, e — a parte que não é
óbvia — um **TOFU melhor que o do SSH**: a chave que se aceitou da primeira vez
mora aqui, versionada. Quem clona o projeto herda a chave aceite; uma chave que
muda aparece no DIFF e passa por revisão de código, em vez de por um aviso no
terminal de uma pessoa só, às onze da noite, com pressa.

    {
      "format": 1,
      "repos": { "file:///tmp/repo/": { "key": "", "first_seen": "2026-08-22" } },
      "packages": [
        { "name": "sha2", "version": "0.1.0", "sha256": "9f2c…",
          "repo": "file:///tmp/repo/", "file": "pkg/sha2/sha2-0.1.0.tar",
          "unsafe": true, "toolchain": ">= 0.1.0" }
      ]
    }

O `sha256` NUNCA falta, nem em modo unsafe: "unsafe" quer dizer que ninguém
assinou, e não que o conteúdo não é conferido. O campo `unsafe` fica gravado
justamente para que quem revisa o PR veja.
"""
import json
import path
import lib_repo as R

struct Travado:
    nome: str
    versao: str
    sha256: str
    repo: str
    arquivo: str
    inseguro: bool
    toolchain: str

struct RepoConhecido:
    url: str
    chave: str
    visto_em: str

struct Lock:
    formato: int
    repos: list<RepoConhecido>
    pacotes: list<Travado>

    def acha(self, nome: str) -> int:
        i = 0
        while i < len(self.pacotes):
            if self.pacotes[i].nome == nome:
                return i
            i += 1
        return -1

    def repo_conhecido(self, url: str) -> int:
        i = 0
        while i < len(self.repos):
            if self.repos[i].url == url:
                return i
            i += 1
        return -1


def novo() -> Lock:
    return Lock(1, [], [])


private def txt(d: dict<str, any>, k: str) -> str:
    if k not in d:
        return ""
    return d[k] as str


private def flag(d: dict<str, any>, k: str) -> bool:
    if k not in d:
        return False
    return d[k] as bool


async def ler(caminho: str) -> Lock:
    lk = novo()
    if not path.isfile(caminho):
        return lk
    f = await open(caminho, "r")
    raw = await f.text()
    await f.close()
    try:
        d = json.parse(raw) as dict<str, any>
        if "repos" in d:
            rr = d["repos"] as dict<str, any>
            urls: list<str> = []
            for u in rr:
                urls.append(u)
            for url in sorted(urls):
                e = rr[url] as dict<str, any>
                lk.repos.append(RepoConhecido(url, txt(e, "key"), txt(e, "first_seen")))
        if "packages" in d:
            for item in d["packages"] as list<any>:
                e2 = item as dict<str, any>
                lk.pacotes.append(Travado(txt(e2, "name"), txt(e2, "version"), txt(e2, "sha256"),
                                          txt(e2, "repo"), txt(e2, "file"),
                                          flag(e2, "unsafe"), txt(e2, "toolchain")))
    catch err:
        raise error(caminho + ": " + err.message, VALUE)
    return lk


private def esc(s: str) -> str:
    out = "\""
    for ch in s:
        if ch == "\"" or ch == "\\":
            out += "\\" + ch
        else:
            out += ch
    return out + "\""


def texto(lk: Lock) -> str:
    """O lock como texto. ORDENADO, sempre: um lock cuja ordem depende de um
    `dict` produz um diff diferente a cada corrida, e um diff que muda sem que
    nada mude é um diff que ninguém lê."""
    b = "{\n  \"format\": 1,\n  \"repos\": {"
    p = True
    ordenados: list<str> = []
    for r in lk.repos:
        ordenados.append(r.url)
    for url in sorted(ordenados):
        i = lk.repo_conhecido(url)
        r = lk.repos[i]
        b += "" if p else ","
        p = False
        b += "\n    " + esc(r.url) + ": {\"key\": " + esc(r.chave) + ", \"first_seen\": " + esc(r.visto_em) + "}"
    b += "\n  }" if not p else "}"
    b += ",\n  \"packages\": ["
    nomes: list<str> = []
    for x in lk.pacotes:
        nomes.append(x.nome)
    p2 = True
    for nome in sorted(nomes):
        t = lk.pacotes[lk.acha(nome)]
        b += "" if p2 else ","
        p2 = False
        b += "\n    {\"name\": " + esc(t.nome) + ", \"version\": " + esc(t.versao)
        b += ", \"sha256\": " + esc(t.sha256) + ", \"repo\": " + esc(t.repo)
        b += ", \"file\": " + esc(t.arquivo)
        b += ", \"unsafe\": " + ("true" if t.inseguro else "false")
        b += ", \"toolchain\": " + esc(t.toolchain) + "}"
    b += "\n  ]" if not p2 else "]"
    return b + "\n}\n"


async def gravar(lk: Lock, caminho: str):
    await R.escrever_bytes(caminho, R.bytes_de_texto(texto(lk)))
