# ppack — documento de decisões

Gerenciador de pacotes do plang. **Nada aqui está decidido** até você decidir.
Este arquivo parte de duas coisas que já existem: a pesquisa em
`ppack/gerenciador-de-pacotes-ideal.md` (feita por outro agente — os erros
históricos e o desenho ideal) e o que o repositório **já é**, medido enquanto se
investigava o `pbuild`. As perguntas ficam no fim, numeradas, como em
`pscript/DESIGN.md` e `pbuild/DESIGN.md`.

O motivo de escrever isto agora, nas suas palavras: *"vamos aproveitar e decidir
as coisas juntas, pq mais pra frente vamos desenvolver um gerenciador de pacote
(...) caso eles forem conversar entre si também, aí já conseguimos imaginar o
cenário completo"*.

---

## O cenário completo: três engrenagens, e uma regra por engrenagem

| engrenagem | o que ela faz | o que ela NUNCA faz |
|---|---|---|
| **`plangc`** (compilador) | **responde**: o que li, o hash de cada interface, o que vou emitir, quem eu sou | decidir o que recompilar, em que ordem, com quantos processos |
| **`pbuild`** (build) | **decide**: o que está velho, a ordem, o paralelismo, e roda | ir à rede; saber o que é uma "versão" |
| **`ppack`** (pacotes) | **resolve**: que versão de que pacote, baixa, tranca no lock | ter um motor de build próprio |

A terceira regra é a que a pesquisa quase diz e não fecha: o Cargo é famoso por
resolver dependências, mas metade dele é **orquestrador de build** — e é dessa
metade que vem a maior parte da complexidade dele. Aqui o `pbuild` já vai existir
antes, com grafo, sujeira por conteúdo e paralelismo. **O `ppack` acrescenta duas
arestas ao grafo que já existe** — "baixar" e "verificar" — e nada mais. É o mesmo
princípio da forma decidida no pbuild (um binário, dois modos, como o muon
carrega o samurai dentro).

## O que a pesquisa não podia saber: os fatos MEDIDOS deste repositório

Cinco, e cada um muda um ponto do desenho ideal.

**1. O P não decora nomes; o pscript decora.** Medido: `def spell_tok(...)` em P
sai no C como `const char *spell_tok(Token *t)` — o nome que você escreveu é o
símbolo global, de propósito (42.4: o qualificador do P é uma GRAFIA CONFERIDA
sobre um conjunto plano, porque o P é a linguagem que conversa com o C). No
pscript, `import lib_core as core` sai como `lib_core__Buffer`, `lib_core__find`
— renomeação em compilação (41.3).

Consequência dura, e é o ponto 3 da pesquisa (*"permitir múltiplas versões no
grafo, como o Cargo"*): **em P isso é impossível sem quebrar a promessa da
linguagem.** Duas versões do mesmo pacote no mesmo binário são dois
`spell_tok` no link. O Cargo pode porque decora com o hash da crate; o P não
decora porque um nome de P **é** um nome de C. Em pscript seria possível — a
renomeação já está lá. Ou seja: **a resposta ao diamond problem não pode ser a
mesma nas duas linguagens**, e essa é uma decisão sua (2.2).

**2. O hash de interface (1.5b do pbuild) É o verificador de semver.** O ponto 9
da pesquisa — *"roda diff de API pública antes de aceitar um minor; ninguém faz
isso de forma rigorosa hoje"* — sai de graça de uma decisão que já foi tomada por
outro motivo (não recompilar quando a interface não mudou). Se o compilador
publica o hash da interface de cada módulo, então:

- interface igual entre 1.2.0 e 1.2.1 → **patch honesto**;
- interface diferente → **não é patch**, e o `ppack` sabe disso sem heurística;
- e a comparação pode ser mais fina que o hash (o mesmo mecanismo que produz o
  hash pode produzir a LISTA da API pública, e aí se sabe *o que* mudou).

Isto é o item da pesquisa marcado como "espaço real para inovar", e aqui ele não
é um projeto: é um subproduto.

**3. Já existe um armazém endereçado por conteúdo, e um lockfile embrionário.**
`~/.cache/pscript` tem `man/`, `obj/` e `bin/`, e um manifest de verdade:

```
911f9702cce7688f                                   <- a chave do binário
1d855773e81b38fc tests/out/scratch/hello.psc       <- hash de cada fonte lida
e1d0f373ec74ce7f pscript/runtime/psrt.ph
```

A chave inclui o **hash dos bytes do próprio compilador** (`main.p:551`, com um
comentário explicando por que não é mtime). Ou seja: o "trave a versão do
toolchain no lockfile" que a pesquisa pede como ponto comum aos dois cenários
**já está implementado**, dentro do compilador, para um caso só. O `ppack` não
inventa o lockfile: ele generaliza este.

**4. `argv` sem shell (1.6, decidida) mata o pior vetor da pesquisa de graça.**
Pontos 5 e 7 dela — *"sem execução de código arbitrário na instalação"*,
*"build scripts sandboxed"* — são difíceis no npm e no pip porque lá o build de
um pacote **é** um script. Aqui o build de um pacote é um **grafo**: uma lista de
comandos `argv` com entradas e saídas declaradas, sem `/bin/sh`, executada por um
motor que já sabe o que cada aresta pode ler e escrever. Não é sandbox por
confinamento; é sandbox por **declaração**. É a vantagem real sobre o `build.rs`
do Cargo, e ela não custa nada porque a decisão já foi tomada por outro motivo.

**5. Nós temos um terceiro artefato que nenhum dos dois cenários da pesquisa
prevê: o C gerado.** A pesquisa divide o mundo em "distribui binário
pré-compilado" (matriz SO × arquitetura × runtime) e "source-only" (a toolchain
vira o ponto crítico). O plangc emite **C legível e portátil** — e C é o único
formato que compila em qualquer lugar sem matriz. Um pacote pode publicar:

| o que publica | quem precisa de quê | o que se perde |
|---|---|---|
| fonte P/pscript | `plangc` na versão travada | nada |
| **o C gerado** | só um `cc` | os diagnósticos e as checagens da linguagem; e o C tem de ser regenerável para auditoria |
| binário | nada | tudo o que a pesquisa lista no cenário A |

Isto é exatamente o que este repositório já faz consigo mesmo — `bootstrap/` é o
C gerado do compilador, comitado, e é como ele nasce numa máquina que ainda não
tem `plangc`. **O seed é o caso zero de um pacote publicado como C.**

## As perguntas (2.x)

**2.1 O que É um pacote?** A resposta depende da 1.5(a) do pbuild (`import`
implicar o módulo), que você já decidiu: um `.ph` com `.p` irmão é módulo. Então
um pacote é (a) **um módulo**, (b) **um diretório de módulos** com um módulo raiz
que é a interface, ou (c) **um repositório** com um manifesto que lista o que
exporta. O Go escolheu (b) e ganhou o grafo de build de graça; o Cargo escolheu
(c) e precisou de `Cargo.toml` para tudo.

**2.2 O diamond problem, dado o fato 1.** (a) **versão única no grafo** para as
duas linguagens (é o modelo do C e o do Go, e o único que o P suporta sem
decorar); (b) **única em P, múltiplas em pscript** (usa o que cada linguagem
permite, ao custo de duas regras na cabeça de quem lê o lock); (c) **múltiplas em
tudo**, com decoração opcional no P — que é abrir mão do "um nome de P é um nome
de C" quando o pacote pede.

**2.3 O que se publica** — fonte, C gerado, ou os dois? (o fato 5)

**2.4 O lock e o log do build são o mesmo arquivo?** O manifest do `run` já é os
dois misturados (hashes de fonte + chave do binário). Separar por clareza, ou
unificar num armazém só, endereçado por conteúdo, que serve build e pacote?

**2.5 Registry central, ou tags de git como o Go?** A pesquisa recomenda central
**com** content-addressing (ponto 4) para não repetir o left-pad. Um registry é
infraestrutura de verdade (hospedagem, disponibilidade, assinatura); tags de git
são zero infraestrutura e dependem do GitHub estar de pé.

**2.6 A quinta pergunta do protocolo.** O `plangc` já vai responder quatro coisas
ao `pbuild`. A pesquisa pede doc-comments reconhecidos pelo compilador e um JSON
canônico de API+doc (pontos 1 e 3 da seção de documentação). Isso é a **mesma
resposta** do hash de interface, só mais detalhada — e teria três consumidores
(pbuild para sujeira, ppack para semver, o site/offline para doc). Entra no
protocolo agora, ou depois?

---

## O escopo, nas suas palavras (2026-08-22)

> *"vai ser um gerenciador só pra pacotes P e pacotes PSCRIPT, aí um pacote
> PScript poderia depender de um pacote P"*

Isso fecha o escopo e abre três consequências medidas — e uma delas é um
pré-requisito, não um detalhe.

**O grafo de pacotes é DIRIGIDO, e não por falta de implementação.** A 1.1 do
pscript decidiu que ele **não** é embutível num programa P hospedeiro ("isso foi
descartado, e com ele o contrato de embutir"). Então:

```
pacote pscript  ──importa──>  pacote P
(arrasta os 6 módulos          (zero runtime, ABI de C,
 do runtime, nomes              nomes NÃO decorados)
 decorados)                     via `import "x.ph"`

pacote P  ──X──>  pacote pscript      NUNCA (1.1 do pscript)
```

**pscript depende de P; P nunca depende de pscript.** Um pacote P é sem runtime
por construção — é a promessa da linguagem. Um pacote pscript, sozinho ou como
dependência de outro, obriga o runtime na compilação: os seis módulos cuja lista
hoje mora em seis lugares. Ou seja o `ppack` **não pode existir** com essa lista
fora da linguagem: a **1.5(a) do pbuild é pré-requisito dele**, não melhoria.

**E o pior: a dependência que você descreveu é exatamente o caso que eu medi
quebrado.** `import "hl.ph"` dentro de um módulo pscript **importado** não puxa o
módulo P nenhum, e o C gerado continua com o `#include` — não compila (o
`tests/run.sh` contorna à mão). O caso normal de um pacote é justamente esse: uma
lib pscript embrulha uma lib P e **é importada** por quem usa. Então a **1.5(d) é
o pré-requisito do cenário que você acabou de descrever** — sem ela, "um pacote
pscript depende de um pacote P" funciona só quando ninguém importa esse pacote.

**A compatibilidade de um pacote P é a compatibilidade de um header C — e isso é
melhor do que semver.** O que atravessa a fronteira é a ABI: uma struct que muda
de layout quebra quem depende **sem mudar um nome sequer**, e nenhum semver do
mundo pega isso (é o pesadelo clássico do C). O hash de interface do fato 2 pega:
o layout está no `.h` emitido, então o hash muda. Ou seja, para pacotes P a
verificação automática de compatibilidade não é um extra ambicioso — é o único
jeito honesto, e nós já vamos ter o mecanismo por outro motivo.

**O que sobra sem resposta é a dependência de SISTEMA.** Não há pacote C neste
gerenciador, então quem embrulha uma biblioteca do sistema (SDL2, libcurl) é um
**pacote P** — e ele precisa dizer o que o link precisa (`-lm`, `-lSDL2`, o
`pkg-config`, os `-D` que o `plangc` usa para pré-processar `include <SDL2/SDL.h>`
— hoje tudo isso está escrito à mão no `Makefile`, com um comentário de 20 linhas
explicando o macOS). Isso não é código, é **declaração** — e é onde o Cargo usa
`build.rs`, que nós decidimos não ter (fato 4). Vira a pergunta **2.7**.

## 2.1, 2.2, 2.3 e 2.5 — DECIDIDAS (2026-08-22)

**2.1 — um pacote é um DIRETÓRIO de módulos com um módulo raiz de interface.**
O modelo do Go, e com a 1.5(a) o grafo de imports já É o grafo do pacote: o
manifesto não repete o que os imports dizem, ele só diz nome, versão e
dependência de sistema.

**2.2 — VERSÃO ÚNICA no grafo, nas duas linguagens.** É o único modelo que o P
suporta sem abrir mão de "um nome de P é um nome de C" (fato 1), e mantém uma
regra só para as duas. Um conflito de versões é erro de resolução, com mensagem, e
alguém sobe a versão. Consequência boa e não óbvia: **o lock fica pequeno e legível**
— uma linha por pacote, e não uma árvore com o mesmo pacote três vezes.

**2.3 — só FONTE.** Um tarball e um hash; a toolchain travada no lock resolve o
resto. Sem matriz de plataforma, sem artefato derivado para manter sincronizado,
sem provar que um binário veio daquele fonte. (O C gerado continua existindo como
o `bootstrap/` deste repo — mas isso é uma decisão de *como este projeto se
distribui*, não do gerenciador.)

**2.5 — o modelo é o do `apt`/`pacman`, não o do npm/cargo.** Suas palavras:
*"deve existir um padrão para hospedar um repositório, deve ser possível existir
mais de 1 repositório, (...) definir 1 repositório como padrão (que futuramente
vai ser o nosso). (...) deve ser possível ler o repositório do disco (e talvez de
uma url e ftp). (...) encontrar e pesquisar nesses pacotes, algo como um apt ou
pacman faz. (...) eu vou ser o provedor padrão, mas nada pode limitar que a
comunidade crie os seus."*

A inversão que isso traz, e que é o melhor argumento a favor dela:

> **Um repositório é um FORMATO, não um serviço.** O repo do apt é uma árvore de
> arquivos com um índice; qualquer servidor de arquivos estático serve, e
> `file:///mnt/x` funciona exatamente igual. Não há API para implementar nem
> servidor para escrever — e é o que torna "a comunidade cria os seus" verdade em
> vez de promessa. O npm e o crates.io são serviços, e é por isso que ninguém
> roda um.

### O que isso pede, e o que já temos para pagar (medido)

| o que o modelo apt precisa | temos? |
|---|---|
| transporte de arquivo local (`file://`) | ✅ `os`/`path` na stdlib (111) |
| transporte HTTP | ✅ **HTTP/1.1 escrito em pscript**, cliente e servidor, conferido contra o llhttp (77.2/78.1); e um parser de URL conferido contra o WPT |
| **HTTPS/TLS** | ❌ **não existe nada** — nem TLS, nem OpenSSL, nem intenção |
| hash de conteúdo para integridade | ◐ só `ps_hash_bytes`, **não criptográfico**: serve para saber se recompila, **não** serve contra adulteração |
| assinatura (Ed25519/GPG) | ❌ nada |
| índice pesquisável offline | ✅ `json` + `dict` + o índice O(1) da 80.1b; é `ppack update` guardando um arquivo |

**E aqui a sua escolha se prova, e não por acaso: o modelo do apt é justamente o
que funciona SEM TLS.** No apt a confiança não vem do transporte: vem do índice
**assinado** que lista o hash de cada pacote. HTTP simples, proxy de cache no
meio, espelho de terceiro — tudo isso continua seguro porque o que se verifica é o
conteúdo, não a conexão. Se tivéssemos escolhido o modelo de registry-serviço, TLS
seria bloqueio; no modelo escolhido ele é conveniência.

O que **fica faltando de verdade**, e é pequeno e específico:

- **um hash criptográfico** (SHA-256): o nosso hash rápido é ótimo para sujeira de
  build e inútil contra um adversário. São ~200 linhas em P, sem dependência — e é
  exatamente o que o muon carrega vendorizado (`src/sha_256.c`), pelo mesmo motivo;
- **uma assinatura** para o índice (o `Release` do apt). Maior que o hash e ainda
  assim finito (Ed25519 é aritmética pura, ~500 linhas, sem libc).

Os dois cabem na regra da casa: não há dependência nova, é código nosso em P.

### O formato, em esboço (para a 2.6/2.10 discutirem)

Duas coisas por repositório, e nada mais:

```
repo/
  index.json            <- o "Packages": tudo que dá para pesquisar e resolver
  index.json.sig        <- o "Release": a assinatura do índice (a confiança mora aqui)
  pkg/<nome>/<versão>.tar   <- o fonte, endereçado pelo hash que o índice declara
```

E o índice carrega, por versão de pacote: nome, versão, **hash criptográfico do
tarball**, dependências (nome + faixa), dependências de sistema (2.7), a faixa de
toolchain que ele exige — e **o hash de interface** (fato 2), que é o que permite
ao resolvedor dizer "este `patch` mudou a API pública" **antes de baixar
qualquer coisa**. Isso último ninguém faz, e para nós é uma coluna no índice.

## Como os três interagem (o cenário completo, 2026-08-22)

Suas palavras: *"agora vemos como vamos casar isso com o compilador e com o
pbuild... não bem casar, mas eles vão interagir entre si"*. Casar é a palavra
errada mesmo: **um comando, três fases, e a rede só existe na primeira.**

```
 fase 1  RESOLVER   ppack    lê o manifesto + o lock, fala com os repositórios,
                             baixa e VERIFICA, materializa uma árvore de pacotes
                             ---- daqui para frente, ZERO rede ----
 fase 2  PLANEJAR   pbuild   pergunta ao plangc (o que você lê? o que vai emitir?
                             qual o hash de cada interface? quem você é?) e monta o grafo
 fase 3  CONSTRUIR  pbuild   decide o que está velho, ordena, roda em paralelo
```

A regra da fase 1 é o que dá reprodutibilidade de verdade: **depois do
`resolver`, o build é offline por construção**. É o `apt update` / `apt install`
separados, e é o que o Cargo não tem (um `build.rs` pode ir à rede no meio da
compilação).

### As três fronteiras, e o que atravessa cada uma

**`ppack` → `pbuild`: duas arestas novas e um tipo de nó novo.** O `ppack` não
tem motor: ele acrescenta ao grafo que já existe a aresta **baixar** e a aresta
**verificar**. E traz um nó de tipo diferente de tudo que o grafo tinha: um
**arquivo cujo hash se conhece ANTES de existir**. Isso simplifica em vez de
complicar — se o conteúdo daquele hash já está no armazém, a aresta não roda, e
não há mtime nenhum para comparar. É o armazém endereçado por conteúdo que o
`plangc run` já mantém em `~/.cache/pscript`, servindo agora a dois donos.

**`ppack` → `plangc`: o compilador NUNCA ouve a palavra "versão".** A saída da
fase 1 é uma **árvore de diretórios mais um caminho de busca**. O compilador
resolve `import` procurando ali, como já faz com caminhos relativos, e não sabe o
que é um pacote, um lock ou um semver. É a fronteira que impede o erro do
`cabal`/`ghc` (o compilador aprendendo o que é uma versão) e o do `go build` (o
compilador virando o gerenciador). Um efeito prático: **testar um pacote local é
trocar um diretório**, sem publicar nada — o que a pesquisa lista como o ponto que
o pip erra há vinte anos (`editable installs`).

**`plangc` → `ppack`: a mesma resposta que ele já dá ao `pbuild`.** O hash de
interface serve ao `pbuild` para não recompilar e ao `ppack` para dizer se um
`patch` é honesto; o hash dos próprios bytes do compilador serve de chave de
sujeira e de **trava de toolchain no lock**. Um mecanismo, três consumidores — e
nenhum deles pede ao compilador uma decisão.

### O que ainda não tem resposta, e apareceu justamente ao cruzar os três

**2.7 A dependência de SISTEMA.** Um pacote P que embrulha SDL2 precisa dizer
`-lSDL2`, os `-D` que o `plangc` usa para pré-processar o header, e o
`pkg-config` que acha isso em cada máquina. Hoje isso está à mão no `Makefile`,
com vinte linhas de comentário sobre o macOS. Não é código, é declaração — e é
onde o Cargo usa `build.rs`, que decidimos não ter.

**2.11 O que o build de um pacote pode RODAR.** A 1.6 (argv, sem shell) e a 2.3
(só fonte) tiraram o script de instalação do caminho — mas se um pacote pode
declarar uma aresta com qualquer `argv`, o vetor voltou pela porta da frente com
outro nome. E o caso legítimo existe e está neste repositório: as tabelas Unicode
do runtime são **geradas** (`unicase.bin`, `unicat.bin`) e entram por `embed()`.
Então: um pacote pode declarar arestas com **ferramenta livre** (qualquer
programa), com **ferramenta da lista** (só `plangc` e `cc`), ou **nenhuma** (só
compilar o que existe, e quem gera commita o gerado, como nós fazemos)?

**2.4 O lock e o log do build: um arquivo ou dois?** O manifest do `plangc run`
já é os dois misturados — a chave do binário mais o hash de cada fonte lida.

**2.6 A quinta pergunta do protocolo** (doc-comments + API pública em JSON, os
pontos 1 e 3 da seção de documentação da pesquisa): entra agora, junto do hash de
interface, ou depois? Ela tem três consumidores esperando (sujeira, semver, doc
offline) e é a mesma travessia do compilador.

## 2.4, 2.6, 2.7 e 2.11 — DECIDIDAS (2026-08-22)

**2.11 — um pacote NÃO tem build próprio.** Um pacote é fonte, e o grafo dele é
derivado dos imports. Nenhuma aresta declarada, nenhuma ferramenta, nenhum
gerador. O vetor de `postinstall`/`setup.py`/`build.rs` não é confinado: **ele
não existe no vocabulário**. Quem precisa de codegen publica o resultado — que é
o que este repositório já faz com as tabelas Unicode do runtime
(`unicase.bin`/`unicat.bin`, geradas offline e comitadas) e com o `bootstrap/`.

**2.7 — a dependência de sistema é DECLARAÇÃO no manifesto, e `pkg-config` é um
dos resolvedores dela.**

E aqui há uma linha fina que vale escrever antes que ela se apague, porque a 2.11
e a 2.7 parecem se contradizer e não se contradizem:

> **O pacote declara O QUE; as nossas ferramentas decidem COMO.** Um pacote diz
> "preciso da lib `sdl2`". Quem chama o `pkg-config` é o `ppack`/`pbuild`, não o
> pacote — e **a lista de programas que as nossas ferramentas podem invocar é
> fixa** (`plangc`, `cc`, `pkg-config`), não extensível por um pacote. É por isso
> que 2.11 continua valendo: nada que venha de um pacote de terceiro decide o que
> é executado.

**2.4 — dois arquivos, um armazém.** O lock é humano, comitado e estável (o que
resolveu, de onde, com que hash, com que toolchain); o log do build é de máquina,
local e descartável (o que rodou, quando, quanto durou — a 1.7). Os dois apontam
para o **mesmo** armazém endereçado por conteúdo. A razão de não unificar é
simples: um vai para o git e o outro não.

**2.6 — a quinta resposta entra junto do hash de interface.** O compilador já vai
calcular a interface para dar o hash; devolver também a **lista** (símbolos,
assinaturas, doc-comments) custa a serialização e resolve três coisas de uma vez:
sujeira de build, semver **com diagnóstico** (não "mudou", e sim *o que* mudou), e
doc offline. É a diferença entre o modelo do docs.rs (doc no caminho da
publicação) e o do javadoc (doc como artefato opcional que alguém esquece).

Consequência de escopo, e é grande: **doc-comments passam a ser sintaxe
reconhecida pelo compilador** nas duas linguagens — o ponto 1 da seção de
documentação da pesquisa. Isso é uma decisão de LINGUAGEM, como as quatro da 1.5,
e precisa da sua bateria própria (qual a grafia, o que é exemplo testável, o que
entra no JSON).

### O pacote zero

Simetria que cai bem e que não é enfeite: o `bootstrap/` é o pacote zero do
**compilador** (o C gerado, comitado, que constrói o plangc numa máquina que não
tem plangc), e o **runtime do pscript** é o pacote zero da **linguagem** — seis
módulos e duas tabelas geradas, tudo comitado, sem build próprio, exatamente
como a 2.11 manda. Os dois já obedecem às regras que acabamos de escrever, sem
saber. É o melhor sinal de que as regras estão no lugar.

## 2.8 e 2.9 — DECIDIDAS (2026-08-22)

**2.8 — nome GLOBAL no repositório padrão, nome QUALIFICADO nos secundários.**
`json` é o `json` do repo padrão (o nosso, quando existir); `fulano/json` é o de
qualquer outro. O precedente exato é o Docker Hub (`nginx` vs `usuario/nginx`), e
ele traz um erro conhecido que vale evitar de propósito:

- **o problema dos nomes curtos** (o caso do podman, que virou debate de
  segurança): se o repositório padrão é *configurável*, um nome não qualificado
  significa "o que o SEU padrão disser" — e o mesmo `json` resolve para coisas
  diferentes em duas máquinas. **A nossa defesa já está decidida**: o lock grava
  o repositório resolvido e o hash, então um nome global é *fixado na primeira
  resolução*; e trocar o padrão com um lock existente é aviso, não silêncio.

E uma consequência que vem do fato 1 e que precisa estar escrita, porque é
contraintuitiva: **qualificar resolve QUEM PUBLICA, não coexistência.**
`oficial/json` e `fulano/json` continuam sendo, no link, dois conjuntos de
símbolos C com os mesmos nomes — o P não decora. A 2.2 (versão única no grafo)
continua valendo entre pacotes qualificados diferentes que exportem os mesmos
módulos: é erro de resolução, com mensagem.

**2.9 — SHA-256 e índice ASSINADO na v1.** O modelo apt completo: assina-se o
**índice**, e cada pacote herda integridade de uma assinatura só, verificada
contra o hash que o índice declara. Custa ~200 linhas de SHA-256 e ~500 de
Ed25519 em P, sem dependência nova — e é o que torna HTTP simples seguro, o que
aqui não é preferência: **não temos TLS** e, neste modelo, não precisamos.

Duas coisas que essa decisão traz junto e que ainda não têm resposta:

- **como a primeira chave chega** (o problema do chaveiro de distro): a chave
  pública do repo padrão vem embutida no `ppack` — o que é honesto e faz do
  binário do gerenciador a raiz de confiança. Chave de repo de terceiro é
  adicionada explicitamente pelo usuário, como `apt-key`/`pacman-key`.
- **o que exatamente é assinado**: o índice inteiro, ou o índice mais a lista de
  hashes dos tarballs? (No apt são dois arquivos justamente por isso: o `Release`
  assina os hashes dos `Packages`.) Vira a 2.12, e é detalhe de formato — não
  muda mecanismo.

## O que cabe dentro de um pacote (2026-08-22)

Suas palavras: *"o pacote P/PSCRIPT também pode incluir arquivos C. Mas o pacote
P não pode ter pscript; o PScript pode ter os 3."*

```
pacote C-em-P        P + C          — sem runtime
pacote P             P + C          — sem runtime
pacote pscript       pscript + P + C — arrasta os 6 módulos do runtime
```

**A hierarquia de conteúdo é exatamente a hierarquia de RUNTIME**, e isso não é
coincidência: C não tem runtime, P não tem runtime, pscript tem. Então o TIPO do
pacote é uma propriedade *verificável*, não uma convenção:

- um pacote declarado P que contenha um `.psc` é **erro**, não estilo — e o
  gerenciador pode dizer isso na publicação, não no build de quem consome;
- daí sai um invariante do grafo de dependências: **um pacote P só pode depender
  de pacotes P** (e do C dentro deles). O subgrafo P é sempre livre de runtime, e
  pode ser construído sem o runtime existir. É a promessa central do P, agora
  válida no nível de pacote e não só de arquivo.

**O que o C dentro de um pacote acrescenta, e onde isso mora.** C é portátil, mas
não é uniforme: um `.c` precisa de `-D`, `-I`, `-std`, e às vezes de um `-D` por
sistema operacional (o `Makefile` daqui tem vinte linhas de comentário sobre os
headers do SDL2 no macOS e os intrínsecos SIMD do Apple Silicon). Isso vai no
mesmo lugar da 2.7 — **declaração no manifesto** — e continua não sendo build
próprio (2.11): o pacote diz as flags, as nossas ferramentas rodam o `cc`.

Vale notar um caso que já existe e que passa a ter nome: `include <stdio.h>` num
pacote P faz o `plangc` **pré-processar** aquele header com um `cc` externo
(`--cpp`/`PLANGC_CPP`). Ou seja, mesmo um pacote sem um único `.c` pode precisar
de flags de pré-processador declaradas — é o que o alvo `pstudio` do `Makefile`
faz à mão hoje.

**E uma pergunta nova, que só aparece agora (2.13): quem compila o C de um
pacote?** O `plangc` **é** um front end de C completo — aceita `.c`/`.i`, tem
paridade de diagnósticos com o clang (155/155) e emite C89 ou QBE. Então há duas
respostas honestas, e elas dão ecossistemas diferentes.

## 2.13 — DECIDIDA: o C de um pacote é compilado pelo `plangc` (2026-08-22)

Ele **já é** um front end de C completo — paridade de diagnósticos com o clang
(155/155, com portão em `tests/clang-compare.sh`), 220/220 na c-suite, e emite
C89 ou QBE. Então o C que vem dentro de um pacote entra pelo nosso front end, e
isso compra três coisas que o `cc` do sistema não daria:

- **o mesmo hash de interface** vale para o `.h` daquele C, e a verificação
  automática de compatibilidade (fato 2) passa a cobrir o C do pacote também;
- **os nossos diagnósticos** alcançam código de terceiro — o `-Wall` de quem
  consome não para na fronteira do pacote;
- **C89 e QBE** ficam disponíveis para o pacote inteiro, não só para a parte em P.

O preço, dito com precisão: **o que o nosso front end não aceitar, não entra.** O
placar de hoje é 220/220 na c-suite com 7 skips deliberados (documentados em
`tests/…` como política GNU), e a máquina de referência é o clang. Um pacote que
use uma extensão que não ingerimos falha na publicação — o que é melhor do que
falhar na máquina de quem instala.

## A árvore de pacotes na pasta de build (E, decidida)

`build/pkg/<nome>-<versão>-<hash>/`, extraída uma vez do tarball verificado, e o
`plangc` recebe isso como caminho de busca. O hash no diretório é o que faz "a
mesma versão com conteúdo diferente" ser impossível de confundir — o furo que a
pesquisa aponta no `requirements.txt` — e é o que permite dois checkouts do mesmo
projeto coexistirem sem se contaminar.

## 2.12 — DECIDIDA (2026-08-22): dois modos de confiança

**Modo seguro (o padrão): índice assinado pelo REPO + cada versão assinada pelo
AUTOR.** As duas assinaturas dizem coisas diferentes, e é a diferença que importa:
a do repo diz *"este índice é meu"*, a do autor diz *"este tarball é meu"* — e com
a segunda **o operador do repositório não pode adulterar o que hospeda**. É a
procedência que o npm e o PyPI foram buscar depois do `event-stream`, e que a
pesquisa lista como problema que ninguém resolveu bem.

**Modo unsafe (explícito): instalar de origem desconhecida.** Suas palavras:
*"mas um modo unsafe pra instalar de qualquer origem desconhecida (e também
desenvolvimento)"*. É o que o `apt` tem (`--allow-unauthenticated`, repositório
sem chave) e o cargo **não** tem — e a falta disso no cargo é o que faz todo mundo
usar `path = "../foo"` e `[patch]` como gambiarra.

O que o modo unsafe **desliga** e o que ele **mantém**:

| | seguro | unsafe |
|---|---|---|
| assinatura do índice | exigida | dispensada |
| assinatura do autor | exigida | dispensada |
| **hash SHA-256 no lock** | **exigido** | **exigido** — sempre |
| aviso na saída de cada build | — | sim, e nomeando o pacote |
| gravado no lock | — | **sim**: um pacote unsafe fica marcado no lock, então entra em diff e em revisão |

A regra que mantém isso honesto: **o hash nunca é dispensado.** Sem assinatura,
perde-se saber *quem* publicou; não se perde saber que o conteúdo é o mesmo de
ontem. E "unsafe" aparece no lock — quem revisa um PR vê.

## O manifesto e o descritor — DECIDIDO: dois arquivos

- **manifesto, DECLARATIVO** — nome, versão, dependências, dependências de
  sistema (2.7), faixa de toolchain. É **dado**: resolver nunca executa nada;
- **descritor, PROGRAMA** (`build.psc`) — alvos e arestas. Existe só num projeto
  que constrói; **um pacote tem apenas o manifesto** (2.11).

O precedente é exato e vale citar: o **Zig começou com `build.zig` sozinho e teve
de acrescentar o `build.zig.zon`** declarativo — justamente porque resolução de
dependência não pode rodar código. Nós entramos já com os dois.

## Doc-comments — DECIDIDO: `"""docstring"""` nas duas linguagens

A 46.3 do pscript já decidiu docstring de verdade (string como primeira instrução
de `def`/`struct`/módulo, viva em runtime). O **P passa a ter a mesma grafia** —
e para isso ganha string tripla, que hoje ele não tem (o `LexSpec.triple_str` do
lexer compartilhado existe e está **desligado** para P: `selfhost/lexer.p:745`).

Em P a docstring é **dropada do binário por padrão** — a promessa de zero runtime
não admite uma `str` viva que ninguém pediu; ela vive no JSON de doc que o
compilador responde (2.6). Duas consequências para anotar na bateria da linguagem:

- **ligar `triple_str` no P** muda o lexer das duas linguagens no mesmo lugar, o
  que é bom (uma implementação) e exige cuidado (o P é a linguagem do seed);
- **o `.ph` continua sendo a interface** — então a docstring de uma função pública
  em P pode aparecer no `.ph` e no `.p`, e é preciso dizer qual vale (proposta: a
  do `.ph` vence, porque é a interface; a do `.p` documenta a implementação).

## Versão — DECIDIDO: só versão EXATA na v1

Cada dependência declara um número exato; atualizar é comando explícito
(`ppack up foo`). **Não há resolvedor na v1** — e com versão única no grafo (2.2),
um conflito é uma mensagem de erro legível ("A pede 1.2.0, B pede 1.3.0"), não uma
busca. O que isso custa, dito na cara: **correção de segurança não chega sozinha**
— quem publica um `1.2.1` depende de cada projeto subir à mão. O caminho de
crescimento existe e é aditivo: MVS (o mínimo do Go) entra depois sem mudar o
formato do lock, porque um número exato **é** um mínimo satisfeito.

## 1.5(c) — DECIDIDO: público é o que não é `static`

Quando um módulo pscript virar unidade de tradução, a interface é **derivada**: a
44.4 já usa `static` para privar um nome ao módulo, e essa regra passa a valer
também para fora. Sem sintaxe nova, e **a mesma regra do P** — uma regra a menos
na cabeça de quem escreve nas duas linguagens. O risco assumido é exportar por
esquecimento; o antídoto já está decidido e é automático: a **lista canónica da
API** (o hash de interface) mostra num diff tudo que passou a ser público.
