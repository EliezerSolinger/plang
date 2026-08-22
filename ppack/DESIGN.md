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
