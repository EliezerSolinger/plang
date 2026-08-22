# O repositório de pacotes — o desenho, a partir do que já está decidido

> **Este arquivo não reabre nada.** Ele junta as decisões que já estão em
> `ppack/DESIGN.md`, mede o que existe hoje para as pagar, e leva cada uma até a
> forma concreta — o formato exato, a ordem de fazer, e o que ainda não tem
> resposta. Onde uma decisão já foi tomada, ela aparece com a fonte.

## 1. O que já está DECIDIDO (com a fonte)

| decisão | onde |
|---|---|
| um repositório é um **FORMATO**, não um serviço — modelo `apt`/`pacman` | DESIGN 2.5 |
| **só fonte**: um tarball e um hash, sem matriz de plataforma | DESIGN 2.3 |
| a confiança vem do **conteúdo**, não da conexão (por isso funciona sem TLS) | DESIGN, §repos |
| **dois modos**: seguro (índice assinado pelo REPO + versão assinada pelo AUTOR) e **unsafe** explícito | DESIGN 2.12 |
| o **hash nunca é dispensado**, nem no modo unsafe; e "unsafe" fica gravado no lock | DESIGN 2.12 |
| **só versão EXATA na v1**; sem resolvedor; conflito é mensagem, não busca | DESIGN, §versão |
| **uma versão por nome** no grafo (os nomes no C são achatados) | DESIGN 2.2 |
| o **lock** é JSON com procedência: nome, versão, sha256, repositório, unsafe, toolchain | DESIGN, §lock |
| a árvore extraída vive em **`build/pkg/<nome>-<versão>-<hash>/`** | DESIGN, §E |
| o **armazém é endereçado por conteúdo** e é o mesmo do `plangc run` | DESIGN 3, 2.4 |
| o **índice carrega a lista canónica da API** — `ppack search` por SÍMBOLO, offline | DESIGN, §mais quatro |
| **manifesto declarativo; um pacote tem só o manifesto** (nada de programa de build) | DESIGN, §manifesto |
| a lista de programas que as ferramentas invocam é **fixa** (`plangc`, `cc`, `pkg-config`) | DESIGN 2.11 |
| quem chama o `pkg-config` é o **ppack/pbuild**, nunca o pacote | DESIGN 2.7 |
| a faixa de **toolchain** é conferida na fase 1, antes de compilar | DESIGN, §toolchain |
| `ppack run` constrói e depois **o programa É o processo** (`exec`) | DESIGN, §mais quatro |
| **TOFU** na primeira vez que se vê um repositório | esta sessão |
| o envelope é **`.tar`** (ustar simples) e mais nada | esta sessão |
| **NADA É GLOBAL**: índice, tarballs, árvores e chaves são todos do PROJETO | esta sessão |
| a chave aceite no TOFU mora no **`pack.lock`**, junto da procedência | esta sessão |
| o SHA-256 é um **pacote P** (`packages/sha2`), o terceiro do ecossistema | esta sessão |
| o `.tar` leva a árvore inteira **menos uma lista fixa** que o `ppack` decide | esta sessão |
| índice velho → **recusa** e manda rodar `ppack update`; a rede é quando você manda | esta sessão |
| a chave do AUTOR é **uma por pessoa**, e o índice diz qual assinou cada versão | esta sessão |
| `search` procura nome, descrição **e símbolo**, marcando de onde veio o acerto | esta sessão |
| o modo **unsafe** liga-se das duas formas: por comando e por repositório | esta sessão |

## 2. O que existe hoje para pagar por isso (medido)

| peça | estado |
|---|---|
| transporte local (`file://`) | ✅ `os`/`path` na stdlib |
| HTTP/1.1 | ✅ `pscript/lib/http.psc`, 689 linhas, conferido contra o llhttp (202/202) |
| URL | ✅ `pscript/lib/url.psc`, 1 322 linhas, conferido contra o WPT (890/891) |
| socket aguardável | ✅ `net.listen`/`connect`/`lookup`, com `poll` no escalonador |
| índice pesquisável offline | ✅ `json` na stdlib + `dict` |
| manifesto e workspace | ✅ `pbuild/ps/lib_manifest.psc`, com erro posicionado |
| grafo de pacotes, `tree`, `why` | ✅ `pbuild/ps/lib_pkg.psc` |
| hash de interface por módulo | ✅ `plangc --api` (resposta 5), agora por linguagem |
| versão e hash do compilador | ✅ `plangc --version` |
| cliente HTTP montado | ◐ as peças existem; o embrulho são ~40 linhas |
| **SHA-256** | ❌ o `hash_str` é FNV — sujeira de build, não adversário |
| **Ed25519** | ❌ nada |
| **tar** | ❌ nada |

**Falta um hash, uma assinatura e um envelope** — os três em código nosso, sem
dependência nova. É o que os torna possíveis dentro da regra da casa.

## 3. A forma de um repositório

```
repo/
  index.json              o que dá para pesquisar e resolver
  index.json.sig          a assinatura do índice — a confiança do REPO
  pkg/<nome>/<nome>-<versão>.tar        o fonte
  pkg/<nome>/<nome>-<versão>.tar.sig    a assinatura do AUTOR
```

Quatro nomes e um diretório. Servível por `python3 -m http.server`, por um
bucket, por `file://`, por um pen drive.

### 3.1 `index.json`

```json
{
  "format": 1,
  "name": "plang-oficial",
  "updated": "2026-08-22T18:00:00Z",
  "packages": {
    "pui": {
      "0.1.0": {
        "file":      "pkg/pui/pui-0.1.0.tar",
        "size":      48213,
        "sha256":    "9f2c…",
        "author":    "8b1e…",
        "lang":      "pscript",
        "root":      "pui.psc",
        "deps":      { "stl": "0.1.0" },
        "system":    { },
        "toolchain": ">= 0.1.0",
        "api":       { "pui.psc": { "hash": "bfe2f2c769a3c239",
                                    "symbols": ["def new_ui(int, int) -> Ui", "…"] } },
        "description": "toolkit de interface em pscript"
      }
    }
  }
}
```

`deps` traz **versão exata** (a v1 não tem resolvedor); `author` é a chave que
assinou o tarball; `api` é a lista canónica que o compilador já produz — e é ela
que faz `ppack search draw_rect` procurar **por símbolo** sem baixar nada, e a
honestidade de semver ser verificável a partir do índice.

Consequência a antecipar, já anotada no DESIGN: o índice cresce com as listas de
API, e é **aí** que os dois níveis do apt (um `release` pequeno assinado que
aponta para índices grandes) se pagam. Não hoje.

### 3.2 O `.tar`

`ustar` simples: cabeçalho de 512 bytes com os campos em octal e o checksum,
blocos de 512, dois blocos de zeros no fim. Sem links, sem esparso, sem PAX — e a
LEITURA recusa o que não entende em vez de adivinhar (um caminho absoluto, um
`..`, um tipo que não seja arquivo comum ou diretório). Um leitor assim são ~120
linhas e um escritor ~80.

O ganho de ser tar de verdade e não um envelope nosso: `tar tf` funciona sem nós,
e "o que há dentro deste pacote" não exige a nossa ferramenta.

### 3.3 Os repositórios de um projeto

```json
{
  "members": ["packages/stl", "packages/pui"],
  "repos":   ["https://pkg.plang.org/", "file:///mnt/espelho/plang/"]
}
```

No `pack.json` do WORKSPACE, porque é do PROJETO: dois projetos na mesma máquina
podem usar repositórios diferentes, e um projeto que se clona traz consigo de onde
as suas dependências vêm. A ordem é a de busca. Sem a lista, entra o padrão; com
ela, só ela — para "eu só uso o meu espelho" ser dizível.

Um repositório pode ser declarado **unsafe** inteiro, que é o caso do espelho de
desenvolvimento sem chave:

```json
"repos": ["https://pkg.plang.org/",
          {"url": "file:///tmp/meu-repo/", "unsafe": true}]
```

E um pacote solto também: `ppack add exp@0.1.0 --unsafe`. As duas formas existem
porque as duas situações existem — um repo inteiro de trabalho, e um pacote
avulso de origem desconhecida. Em qualquer delas o **hash continua exigido**, e
o lock grava `"unsafe": true`, então quem revisa um PR vê.

O `<repo-id>` é o hash do URL normalizado: um nome estável que não depende de
alguém escolher um apelido, e que não deixa dois projetos chamarem de `oficial`
repositórios diferentes.

## 4. O armazém — NADA É GLOBAL

Tudo o que um projeto usa mora dentro dele. Não há diretório em `~` que este
gerenciador escreva, e a consequência é que **copiar o projeto leva tudo junto**,
dois checkouts não se contaminam, e não há estado escondido numa máquina que
explique por que "aqui funciona".

```
build/pkg/
  .index/<repo-id>.json         o índice da última atualização
  .pak/<sha256>                 o tarball, tal como veio
  <nome>-<versão>-<hash>/       a árvore aberta — é isto que o `--pkg-path` aponta
```

O hash no nome do diretório é o que faz "a mesma versão com conteúdo diferente"
ser impossível de confundir — o furo que a pesquisa aponta no `requirements.txt`.

`make clean` apaga `build/` inteiro, incluindo isto. **É seguro por construção**:
o lock tem o hash de tudo, então voltar a baixar custa tempo e nunca risco.

**A CHAVE do TOFU não mora aqui** — mora no `pack.lock`, que é comitado:

```json
{ "format": 1,
  "repos": {
    "https://pkg.plang.org/": { "key": "SHA256:9f2c8a1b…",
                                 "first_seen": "2026-08-22" } },
  "packages": [ … ] }
```

E isto é TOFU **melhor** que o do SSH, não pior: a confiança é versionada. Quem
clona o projeto herda a chave que foi aceite; uma chave que muda aparece no DIFF
e passa por revisão de código, em vez de por um aviso no terminal de uma pessoa
só. O `build/` ser descartável deixa de importar.

## 5. Os comandos

```
ppack update                   baixa os índices e guarda-os          (rede)
ppack search <termo>           procura no índice guardado            (offline)
ppack add <nome>@<versão>      escreve no manifesto e no lock        (rede: só para o hash)
ppack install                  materializa o que o lock diz          (rede se faltar)
ppack up [<nome>]              sobe a versão e regrava o lock        (rede)
ppack publish                  faz o .tar, assina, escreve no índice (local)
```

`add` e `build` são comandos diferentes de propósito: um mexe no manifesto e no
lock, o outro compila. O diff do commit fica legível — duas linhas, uma em cada
arquivo.

`publish` **não envia nada**: produz o `.tar`, o `.sig` e a entrada no índice, no
diretório do repositório local do autor. Enviar é `rsync`/`scp`/`git push` — que é
a consequência de um repositório ser um formato. Ele confere que a versão ainda
não existe (uma versão publicada é imutável), que o manifesto é válido e que o
hash de interface bate com o que vai declarar. **Não roda os testes** (decidido).

## 6. A ordem de fazer

Cada passo é útil sozinho, e nenhum precisa do seguinte:

1. **SHA-256** — sem ele nada mais tem sentido. Portão: os vetores do FIPS 180-4
   mais o corpus que já usamos para oráculo.
2. **tar** — ler e escrever, com a recusa do que não se entende. Portão: escrever,
   ler de volta, e o `tar` do sistema a abrir o nosso.
3. **`ppack publish` e um repositório `file://`** — o formato inteiro provado sem
   rede nenhuma, com o `packages/stl` e o `packages/pui` como primeiros pacotes.
4. **`ppack update`/`search`/`add`/`install` sobre `file://`** — a fase 1 completa.
5. **HTTP** — o mesmo caminho com outro transporte. É aqui que a rede entra, e
   nada acima muda.
6. **Ed25519 e as duas assinaturas** — o modo seguro. Até aqui tudo corre em modo
   unsafe, que é explícito, avisa em cada build e fica gravado no lock.

## 7. `search`, e o que ele mostra

O índice carrega a lista de símbolos, então a busca é uma só e cada linha diz de
onde veio o acerto:

```
$ ppack search rect
pui 0.1.0   [nome]     —
pui 0.1.0   [símbolo]  def rect_has(Rect, int, int) -> bool
pui 0.1.0   [símbolo]  record Rect {x: int, y: int, w: int, h: int}
```

Procurar por símbolo sem baixar nada é coisa que nenhum gerenciador faz, e aqui
sai de graça: a lista já está no índice porque o compilador já a produz.

## 8. O que ainda não tem resposta

1. **`make clean` em dois níveis** — hoje ele apaga `build/` inteiro, incluindo
   os tarballs. A ideia de um segundo nível (limpar a compilação e guardar o que
   veio de fora) ficou anotada e não decidida.
2. **O cache do `plangc run`** continua global até o `run` sair do compilador
   (F7); quando sair, vai para `build/run/` como tudo o mais.
3. **O repositório PADRÃO** — o URL, e se a chave dele viaja no binário.
