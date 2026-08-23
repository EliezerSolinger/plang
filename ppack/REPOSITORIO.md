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
ppack keygen <arquivo>         uma chave nova: privada + .pub        (local)
ppack update                   baixa os índices e guarda-os          (rede)
ppack search <termo>           procura no índice guardado            (offline)
ppack add <nome>@<versão>      escreve no manifesto e no lock        (rede: só para o hash)
ppack install [--frozen]       materializa o que o lock diz          (rede se faltar)
ppack up [<nome>]              sobe a versão e regrava o lock        (rede)
ppack publish <pkg> --to <dir> faz o .tar, assina, escreve no índice (local)
ppack check                    as invariantes dos pacotes            (local)
```

**Todos estão feitos**, e `tests/repo.sh` mede-os de ponta a ponta (55
verificações) por `file://` e por `http://`.

Três que a lista acima não deixa ver:

* `install --frozen` é o do CI: o lock e o manifesto têm de contar a mesma
  história, e um `install` que instalasse o lock velho em silêncio é a fonte do
  "na minha máquina funciona". Sem `--frozen` ele imprime o diff e continua.
* `up` sobe para a mais ALTA que o índice tem, e é um comando e não um efeito do
  `install`: subir de versão é uma escolha, e uma escolha que acontece sozinha é
  uma escolha que ninguém reviu.
* `check` é o que mantém a promessa de P através dos pacotes — ver §9.

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

1. ✅ **SHA-256** — `packages/sha2`, FIPS 180-4 §6.2 em P. Os quatro vetores
   oficiais mais os cinco tamanhos onde o padding decide, e o mesmo hash visto
   do pscript pela fronteira da 45.5 (`sha256_of(in data: CBytes) -> CStr`), o
   que prova que não há uma segunda implementação.
2. ✅ **tar** — `packages/tar`, `ustar` e nada mais. O portão é o `tar` do
   sistema a listar e EXTRAIR o nosso; a metade que importa é a leitura, que
   recusa caminho absoluto, `..`, link simbólico, checksum errado e tarball
   cortado. Escrever é reprodutível por decisão (data zero, modo fixo): o hash
   do tarball É a identidade.
3. ✅ **`ppack publish` e um repositório `file://`** — `publish <pacote> --to
   <dir>` produz o `.tar`, o hash e a entrada no índice, com a lista canónica de
   símbolos de cada módulo DO pacote. Uma versão publicada é imutável.
4. ✅ **`ppack update`/`search`/`add`/`install` sobre `file://`** — a fase 1
   completa, prendida de ponta a ponta em `tests/repo.sh` (18 verificações, do
   `publish` até um programa que usa o pacote instalado e roda). O `add` traz as
   dependências pela versão EXATA que o índice declara — seguir um pino não é
   resolver —, e discordância vira mensagem.
5. ✅ **HTTP** — o mesmo caminho com outro transporte, e nada acima mudou: o
   único ponto por onde bytes de fora entram é `R.buscar`, e o HTTP é um `if` lá
   dentro. O `tests/repo.sh` faz a volta inteira duas vezes, por `file://` e por
   `http://` contra um `python3 -m http.server`, e confere que o hash é o mesmo.
   Sem TLS, e é decisão: a confiança vem do conteúdo, não da conexão.
6. ✅ **Ed25519 e as duas assinaturas** — `packages/ed25519`, RFC 8032, com os
   vetores da própria RFC (incluindo o de 1023 bytes, que é onde um erro de
   padding do SHA-512 se esconde). `ppack keygen` faz a chave a partir do
   `/dev/urandom` e de mais lado nenhum; `publish --key` assina o tarball (como
   AUTOR) e o índice (como REPOSITÓRIO); `update` confere o índice contra a
   chave gravada no lock e `add` confere cada tarball contra o autor que o
   índice declara. Um repositório que não assina tem de se declarar `unsafe`, e
   isso fica no lock para quem revisa o PR ver.

### O que construir isto para valer ensinou

Nove defeitos que nenhuma leitura acharia:

* **o motor do build mentia duas vezes** — a pergunta `--deps` era feita sem o
  modo (`--out-dir`), então a 1.5(a) não aparecia na resposta e editar o lexer do
  compilador não reconstruía nada; e os dois contadores de `node_done` não se
  encontravam quando as entradas de uma aresta eram MISTURADAS, o que deixava o
  build "terminar com sucesso" com trabalho por fazer;
* **o C gerado não era função só do fonte** — o contador do temporário de `defer`
  era global ao processo, então duas escadas de bootstrap que invocam o
  compilador de maneiras diferentes divergiam;
* **o prelúdio não chegava aos módulos importados** — `error(msg, VALUE)` dentro
  de um pacote não compilava;
* **uma chamada que levanta no meio de uma instrução deixava rasto** —
  `xs.append(item as str)` num `try` reservava o lugar na lista antes de o valor
  existir, e o segfault aparecia longe do `catch`;
* **`--ps-runtime` absoluto com fontes relativos** emitia um `#include` para fora
  do espelho. Agora é recusado com a mesma regra que os pacotes já tinham;
* **faltar a palavra `in` numa chamada** dava "incompatible types in assignment
  (scalar from 'Fe')" — verdade, e sobre nada. Agora diz qual é o parâmetro e
  qual é a palavra;
* **`implement X` colide entre pacotes**: dois pacotes que precisavam da
  fronteira do pscript materializavam `CStr` os dois, e o linker queixava-se de
  `CStr_at`. A regra que isso ensinou está agora escrita e aplicada — **quem
  DECLARA o tipo é quem o materializa** (`packages/stl/cstr.p`), e a 1.5(a) leva
  o arquivo a reboque de quem importa o header;
* **um `out` preenchido campo a campo** era avisado como "nunca atribuído": o
  analisador via `r = ...` e não via `f(out r.X)`;
* **o mesmo `.c` com duas linhas de comando** (um programa com os `-D` do
  runtime, outro com os do SDL) queria o mesmo `.o`. Agora o objeto leva o selo
  do comando no nome, em vez de o grafo recusar e cada arreio inventar um objdir
  por combinação de flags.



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

1. ✅ **`make clean` em dois níveis** — feito, e a linha é a ORIGEM: `make clean`
   apaga o que este repositório produziu e guarda `build/pkg` (o que ele
   baixou), `make clean-all` apaga tudo. Voltar a baixar custa tempo e nunca
   risco, porque o lock tem o hash.
2. **O cache do `plangc run`** continua global até o `run` sair do compilador
   (F7); quando sair, vai para `build/run/` como tudo o mais.
3. **O repositório PADRÃO** — o URL, e se a chave dele viaja no binário. Sem
   servidor não há o que decidir ainda; o que existe hoje é: sem `repos` no
   `pack.json`, não há repositório nenhum, e a mensagem diz como se declara um.
4. **HTTPS** — o transporte recusa-o em vez de fingir. A confiança vem do
   conteúdo, então um espelho em `http://` serve; o que não serve é dizer que se
   falou TLS quando não se falou.
5. **pscript não tem teste de tipo.** `as` é checado e LEVANTA (55.2), o que
   serve para o nosso formato, mas ler um documento de fora obriga a usar `try`
   como controlo de fluxo. É a única coisa neste trabalho que se escreveu a
   torcer a linguagem em vez de a usar, e é uma bateria a fazer.


## 9. `ppack check`: as invariantes que o build não confere

O build constrói. Estas três perguntas não são sobre construir, e por isso são
um comando à parte — que corre no `verify`:

1. **um pacote `lang: p` não depende de um pacote `pscript`.** Quem usa um
   pacote P espera o que P promete: sem coletor, sem alocação escondida, a ABI
   do C. Um `p` que puxasse um `pscript` traria o runtime a reboque, e a
   promessa quebrava-se em silêncio uma dependência abaixo de onde alguém a leu.
   O contrário NÃO é simétrico e não devia ser: um pacote pscript pode depender
   de um P — a travessia da 45.5 existe exatamente para isso, e é assim que o
   `ppack` usa o `sha2`.

2. **nenhum `.psc` no FECHO do módulo-raiz de um pacote `p`** — a mesma coisa
   dita onde ela realmente acontece, porque um `import` alcança mais longe do
   que um manifesto. O primeiro portão é o próprio compilador (um `.ph` que
   importe um módulo pscript ele já recusa); quando ele fala, é o que ELE diz
   que sai, não a nossa paráfrase.
   O que NÃO é problema: um pacote P com TESTES em pscript. O `sha2` tem um, de
   propósito — é como se prova que a fronteira funciona. Ele não está no fecho
   da raiz.

3. **a biblioteca de sistema que um manifesto declara existe nesta máquina.**
   A 2.7 diz que a dependência de sistema é DECLARAÇÃO e que o `pkg-config` é um
   dos resolvedores dela; quem o chama somos nós, nunca o pacote — a lista de
   programas que estas ferramentas invocam é FIXA (`plangc`, `cc`,
   `pkg-config`). Aqui a declaração passa a valer alguma coisa antes de o build
   começar.

E há uma quarta, que não vive aqui porque acontece mais cedo: a **faixa de
toolchain**. `add` e `install` perguntam ao compilador quem ele é (resposta 4) e
comparam com o `>= x.y.z` do manifesto — antes de gastar um segundo a compilar.
A mensagem que sai daí ("o pacote foo exige plangc >= X, o seu é Y") é a melhor
que existe para este problema; a alternativa é um erro de sintaxe a meio de um
módulo que usa uma coisa que ainda não existe. Se não houver `plangc` nenhum
para perguntar, ele DIZ que não conferiu — um portão que se desliga em silêncio
é pior do que não existir.
