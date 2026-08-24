# pforge — o MOTOR: documento de decisões

(o gerenciador de pacotes tem o seu, em `pforge/PACOTES.md`)

Sistema de build do plang, escrito **em pscript**. **Nada aqui está decidido**
até você decidir — este arquivo começa com o insight que originou o projeto e com
a medição do que já existe; as perguntas ficam no fim, numeradas, do mesmo jeito
que em `pscript/DESIGN.md`.

---

## O insight (2026-08-21), nas suas palavras

> *"já que ele gera C precisamos de um sistema de build próprio que lide com
> compilação C, e o que mais me vem a memoria é o Meson + Ninja. a linguagem vala
> por exemplo usa essa combinação. se a gente reimplementasse o mesmo sistema
> usando o pscript já teríamos workers e asyncs para lidar com isso. (...) não
> precisamos por enquanto na primeira versão reimplementar o parse da linguagem
> do ninja, por exemplo daria para usar um json por enquanto, mas seria o mesmo
> mecanismo. e o meson é a mesma coisa, talvez fosse uma biblioteca pscript e aí
> usaríamos a própria linguagem pscript para usar o mecanismo. outra coisa a se
> pensar é talvez ajustar a linguagem para a definição de módulos/TU ficar
> explícita na linguagem e facilitar a composição do sistema de build. (...) usar
> as ferramentas do nosso runtime e do idioma no lugar de chamar tudo do sistema
> operacional igual as implementações em C puro fazem."*

Referências que você levantou, as duas por serem legíveis:

- **muon** — Meson reimplementado em C · https://github.com/muon-build/muon
- **samurai** — Ninja reimplementado em C · https://github.com/michaelforney/samurai

E o nome: **pforge**.

## Por que o projeto existe

Hoje o build do plang são três coisas que não se conhecem: `tests/psbuild.sh`
(compila um `.psc` mais o runtime), o `Makefile` (o compilador e o pstudio) e as
listas de módulos espalhadas dentro de `tests/run.sh`. A bateria 109 mediu o
preço disso: dividir o runtime em cinco módulos obrigou a editar **quatro**
harnesses, e um deles (o caminho do `plangc run`) fica dentro do compilador.

Um grafo de build de verdade resolve isso — e é o maior programa possível para
dar de comer ao pscript, que é o outro motivo de fazê-lo em pscript e não em
shell.

## O que ele compila (2026-08-21)

**As três linguagens do projeto, não só C.** Suas palavras: *"o pbuild também vai
compilar o pscript e P"*. Então o alvo não é "chamar `cc`": é chamar **`plangc`**
para `.p` e `.psc` e **`cc`** (ou o QBE mais o assembler) para o C que sai — e
saber que o segundo depende do primeiro.

Isso muda o desenho de duas formas, e as duas para melhor:

- **A regra do grafo não é "compile um arquivo", é "rode este comando"** — que é
  exactamente o que o Ninja faz. `plangc` é só mais uma ferramenta, com as suas
  entradas e saídas.
- **O grafo tem uma etapa que GERA arquivos**: um `.psc` produz um `.c`, e o `.c`
  produzido é entrada da etapa seguinte. É o caso que o Ninja chama de saída
  implícita mais `depfile`, e é o que já obriga hoje os harnesses a saber a lista
  de módulos do runtime de cor (109). Aqui isso passa a estar escrito num lugar.

E o pforge é o primeiro consumidor da sua ideia 1.5: se a linguagem disser quais
arquivos formam uma unidade, o grafo deixa de repetir a lista.

## Os dois mecanismos, e o que cada um é

| | o que faz | o análogo | como fica aqui |
|---|---|---|---|
| **executor** | lê um grafo de alvos com comandos e dependências, decide o que está velho, roda em paralelo, respeita a ordem | Ninja / samurai | um programa pscript que lê o grafo e usa **workers** para rodar os comandos |
| **descritor** | descreve o projeto (alvos, fontes, flags) e GERA o grafo | Meson / muon | uma **biblioteca pscript**: o arquivo de build é um programa pscript que a usa |

O ponto do insight é que os dois são o **mesmo mecanismo** de sempre, e que a
primeira versão pode trocar a linguagem de entrada por **JSON** sem mudar
mecanismo nenhum: o grafo é um `dict` e o pscript já lê json (41.1).

## O que JÁ EXISTE para construir em cima (medido, não suposto)

**Do lado do pscript** (o que um build precisa e o que a linguagem tem hoje):

| precisa | existe? |
|---|---|
| ler e escrever arquivo | ✅ `open`/`read`/`text`/`readlines`/`write`/`close`, com `await` (48.1/76.2) |
| json | ✅ `json.parse`/`json.stringify` (41.1) |
| rodar N comandos em paralelo | ✅ `spawn` de worker (35.1) e `gather`/`race`/`at_most` (79.4) |
| esperar I/O sem parar o resto | ✅ o laço com epoll/kqueue/poll (102) e o `recv` estacionado (74.1) |
| hash de conteúdo | ✅ `ps_hash_bytes` no runtime (não exposto à linguagem) |
| listar diretório | ✅ `os.listdir` (111), e ORDENADO |
| `stat`: existe? mtime? tamanho? | ✅ `path.exists`/`isdir`/`isfile`/`getmtime`/`getsize` (111) |
| criar diretório (`mkdir -p`) | ✅ `os.makedirs` (111); `os.mkdir` para um só |
| apagar / renomear arquivo | ✅ `os.remove`/`os.rmdir`/`os.rename` (111) |
| **RODAR UM PROCESSO** (status + saída) | ❌ — é a 1.2, e é sua |
| caminho: juntar, dirname, basename, normalizar | ✅ `path.join`/`dirname`/`basename`/`normpath`/`abspath` (111) |
| variáveis de ambiente | ✅ `sys.env` |
| argumentos | ✅ `sys.argv` |

**Do lado do P**, a camada de SO já estava escrita — era o `pstudio/psys.p` do
editor (que saiu na 116, depois de virar stdlib): `vfs_read_all`, `vfs_write_all`, `vfs_list_dir`, `vfs_stat` (com mtime),
`ps_run(cmd, out output) -> i32` (roda e captura), `ps_millis`, `ps_path_join`,
`ps_path_dirname`, `ps_path_basename`. Ou seja: **o trabalho não é descobrir como
fazer, é decidir onde isso mora e como o pscript o alcança.** *(Feito na bateria
111 do pscript, menos rodar processo: `os` e `path` são módulos da stdlib, em P,
no runtime — `pscript/runtime/psrt_os.p`.)*

## O que precisa de decisão sua

**1.1 Onde mora a camada de SO que falta — DECIDIDO (2026-08-21).** Vai para a
**lib/runtime do pscript**, onde for possível. Suas palavras: *"o pstudio temos
que migrar ele totalmente para PScript e a parte de sistema vai pra lib/runtime
do PScript onde for possível"*.

Ou seja: `os.listdir`, `os.stat`, `os.mkdir`, `os.remove`, `os.rename`,
`os.run` e `path.join`/`dirname`/`basename` nascem como módulos da stdlib do
pscript (implementados em P, como `random` e `time` — 108.4), e o `psys.p` do
pstudio deixou de ser a casa deles: ele foi a FONTE de onde eles saíram, e o
arquivo já não existe (116). O pforge e o
pstudio passam a usar a MESMA camada, que é o teste de que ela está no lugar
certo — dois consumidores diferentes, um deles gráfico e o outro paralelo.

**Estado (2026-08-21): FEITO** na bateria 111 do pscript, menos `os.run` (que é a
1.2, abaixo). O que existe: `os.listdir`, `os.mkdir`, `os.makedirs`, `os.remove`,
`os.rmdir`, `os.rename`, `os.getcwd`, e `path.join`/`dirname`/`basename`/
`normpath`/`abspath`/`exists`/`isdir`/`isfile`/`getsize`/`getmtime`. As contas
sobre o nome são o `posixpath` do CPython conferido por varredura (mil caminhos);
não tem `chdir` de propósito (o cwd é do processo e um worker é uma thread).

O "onde for possível" tem um limite nomeado: o que é do EDITOR (SDL, janela,
teclado) não é da stdlib de ninguém e continua no pstudio.

**1.2 Como um processo é rodado — DECIDIDO (2026-08-21): task com `await`;
ver "As decisões desta rodada", no fim.** O `ps_run` do pstudio é síncrono e captura a
saída num buffer. Um build quer **N processos ao mesmo tempo**, cada um com
status e saída, e o modelo natural aqui é `await`:

  a) `await os.run(["cc", "-c", "a.c"])` — uma task, e o paralelismo vem de
     `gather`/`at_most` (o pool de I/O da 76.3 executa o `waitpid`);
  b) um worker por comando (`spawn`), que é o que o insight sugere;
  c) as duas, com (a) por cima de (b).

**1.3 O grafo na v1.** JSON, como você propôs — e aí falta decidir o **esquema**
(alvos, regras, entradas, saídas, `depfile` do `cc -MD`?), porque é ele que
define o que o executor entende. A linguagem do Ninja entra depois, quando o
esquema estiver provado.

**1.4 O que decide "está velho" — DECIDIDO (2026-08-21): os seis testes do
ninja, lidos na fonte; ver "O ninja DE VERDADE", no fim.** mtime (como o Ninja) ou hash de conteúdo (como
o Bazel)? A tabela acima diz que os dois são alcançáveis; o Ninja usa mtime mais
um log de comandos, e é o que samurai reimplementa.

**1.5 A definição de módulo/TU na linguagem.** Sua ideia de tornar isso explícito
no pscript/P para o build compor melhor. Hoje uma unidade de tradução é *"um
arquivo passado ao compilador"*, e as listas vivem nos harnesses (109 mostrou o
custo). Isto é uma decisão de LINGUAGEM e precisa de bateria própria — provavelmente
depois de 1.3, para o formato do grafo informar o que a linguagem precisa dizer.

## Como ele se valida (2026-08-21)

Suas palavras: *"podemos usar o pstudio e também o próprio compilador do plang
como validação do pbuild"*. São os dois programas certos, e por razões
diferentes:

| programa | o que ele cobra do pforge |
|---|---|
| **o compilador** (`selfhost/*.p`, 38 312 linhas) | muitos módulos P numa ordem que importa, o header ao lado do `.p`, e a ESCADA de bootstrap (seed → s1 → s2 → out3) com ponto fixo — ou seja, um grafo em que a saída de uma etapa é a FERRAMENTA da seguinte |
| **o pstudio** (6 camadas + SDL) | um programa em pscript com módulos, dependência externa (`sdl2-config`), e um binário gráfico que ainda tem de rodar headless nos testes |
| **o runtime do pscript** (5 módulos, 109) | a lista que hoje está decorada em quatro harnesses |

O critério de pronto da v1 é literal: **`pforge` constrói o que o `Makefile` e o
`tests/psbuild.sh` constroem hoje, e o `verify-all` passa 8/8 usando-o**. Não é
"um build de brinquedo que compila hello.c" — é o build deste repositório, que é
o mais difícil que existe à mão (o `verify-all` compila o compilador quatro vezes
e compara bytes).

Consequência boa: enquanto o pforge não fizer isso, o `Makefile` continua sendo a
verdade. Os dois conviverão, e o dia em que o pforge passar a escada é o dia em
que ele substitui.

## O que este projeto NÃO vai fazer

Chamar o SO para tudo, como as implementações em C fazem por não terem outra
coisa. Onde o nosso runtime tem a ferramenta — worker em vez de `fork`, task em
vez de `select` à mão, `dict`/`json` em vez de parser próprio — usa-se a nossa. É
o mesmo princípio da 108.4 (a stdlib fica em P) visto do outro lado: o que já
existe não se reescreve, e o que falta se acrescenta no lugar certo.

---

## As duas referências, LIDAS (2026-08-21)

Clonadas e lidas: `michaelforney/samurai` inteiro, `muon-build/muon` na parte
que interessa (bootstrap, backend, o samurai que ele carrega dentro).

### samurai — 4 306 linhas, e o MOTOR são 1 546

| parte | arquivos | linhas |
|---|---|---|
| **o motor** | `graph.c` `build.c` `deps.c` `log.c` | **1 546** |
| a LINGUAGEM do ninja | `parse.c` `scan.c` `env.c` | 921 |
| periferia | `htab` `tree` `util` `os-posix` `samu` `tool` | 1 505 |

O primeiro número que muda uma decisão: trocar a linguagem do ninja por JSON
economiza **921 das 4 306 linhas e não toca no motor** — o insight estava certo,
e agora está medido em vez de suposto. E o motor inteiro (1 546 linhas de C) é
menor que `ps_lower.p` sozinho: o pforge não é um projeto grande, é um projeto
*preciso*.

### O que o motor faz, mecanismo por mecanismo

1. **Nó = arquivo, aresta = comando.** O nó guarda `mtime`, o `logmtime` (o que
   o log diz), o `hash` do comando que o produziu e a lista de arestas que o
   usam. A aresta guarda entradas/saídas com três faixas — normais, implícitas,
   *order-only* — e dois contadores, `nblock` e `nprune`.

2. **"Está velho" NÃO é mtime — são três testes** (`build.c:isdirty`): a saída
   falta; a saída é mais velha que a entrada mais nova; **o hash do COMANDO
   difere do gravado no log**. Ou seja: o ninja *já* usa hash — não do conteúdo
   dos arquivos, e sim da linha de comando, que é o que pega "mudei uma flag" e
   o que o nosso `psbuild.sh` hoje não pega de jeito nenhum.

3. **`restat` e a PODA — o mecanismo que vale ouro aqui.** Depois que o comando
   roda, refaz-se o `stat` da saída; se o mtime não mudou, os consumidores são
   **podados** em vez de executados (`shouldprune` + `nodedone(prune)`, umas 40
   linhas em cima daqueles dois contadores). É exatamente o nosso caso: o
   `plangc` regenerando C **byte-idêntico** tem de NÃO disparar os 18 s de `cc`.
   O fixed point da escada já vive disso — só que hoje conferido à mão, no
   `diff -rq` do `verify-all`.

4. **O escalonador é um `poll()`**: um pipe por job mais um *self-pipe* para
   sinais; cada job é `posix_spawn` de `/bin/sh -c <comando>`; a saída de cada
   job é acumulada num buffer e despejada **inteira** quando ele termina — é
   assim que o ninja não costura as linhas de dois jobs concorrentes, o mesmo
   problema que a nossa 107 achou no `print` de workers.

5. **A fila é uma PILHA** (LIFO): o último agendado é o primeiro a rodar, e o
   samurai grava `0\t0` no lugar da duração — não a guarda nem para depois. O
   README dele diz que no ninja a ordem depende do endereço que o `malloc`
   devolveu; isso valia para o ninja de 2018 e **não vale mais** — ver a seção
   do ninja de verdade, abaixo, que é onde este ponto se resolve.

6. **Pools** (`pool = linker_pool`, `console`) para o que não pode ir em
   paralelo — uma fila secundária dentro da aresta, sete linhas em `queue()`.

### muon — 76 583 linhas, e a lição não é o tamanho

- **O `bootstrap.sh` são 15 linhas**: `c99 -Iinclude src/amalgam.c -o
  muon-bootstrap`. E `src/amalgam.c` são 181 `#include "x.c"`. É o **mesmo
  modelo do nosso `bootstrap/selfhost/*.c`**: um arquivo, um c99, nenhuma
  ferramenta. Quem quer independência chega neste desenho por conta própria.
- **O samurai vive DENTRO do muon** (`src/external/samurai/`, subcomando `muon
  samu`, `samu_main(wk, ...)` chamado em processo): **um binário é o descritor E
  o executor**, e não existe dependência de um `ninja` instalado. É o desenho
  que o pforge deve copiar — não dois programas, dois modos de um.
- `toolchains.c` são **1 679 linhas de conhecimento de compilador** (qual flag é
  `-c`, `-o`, `-MD`, `-MF`, por toolchain, por máquina). É aqui que mora o custo
  de um Meson, não no grafo. Nós precisamos de **duas** ferramentas — `plangc` e
  `cc` — e uma delas é nossa.

## A medição desta máquina (8 núcleos), construindo o compilador

| etapa | tempo |
|---|---|
| `plangc` gerando o C dos 34 fontes P (uma invocação) | **0,47 s** |
| `cc -O2` dos 19 `.c` num comando só — o que o `Makefile` faz hoje | **18,0 s** |
| `cc -c` por TU, 8 em paralelo, mais o link | **5,0 s** |
| o maior TU sozinho (`ps_lower.c`, 10 562 linhas) | **4,96 s** |
| link dos 19 `.o` | 0,06 s |

Três consequências:

- **97 % do build é `cc`**, não o nosso compilador. O ganho não vem de gerar C
  mais rápido; vem de `-c` por TU e paralelo (3,6×) e de não recompilar o que
  não mudou — hoje mexer numa linha de `util.p` custa os 18 s inteiros.
- **O paralelismo satura em ~4 workers**: 5,0 s de parede contra 4,96 s do
  `ps_lower.c` sozinho. **O caminho crítico é UM arquivo.** Daí o ponto 5 acima
  doer: com fila LIFO, começar o `ps_lower.c` por último põe 5 s no fim do
  build. O que cada um dos três faz a respeito está na seção seguinte — e a
  resposta não é a que eu tinha escrito aqui.
- O `restat` do ponto 3 é o que transforma "regenerei o C" em "não recompilei
  nada": 0,47 s em vez de 18 s.

## O balanço da independência (o que o pforge tira do caminho)

| hoje | tamanho |
|---|---|
| shell (`tests/*.sh`, `tests/*/run.sh`, `reseed.sh`) | **1 941 linhas** |
| `Makefile` | 130 linhas |
| utilitários externos que os harnesses chamam | `sed` 33, `head` 30, `diff` 26, `grep` 21, `env` 18, `timeout` 9, `tail` 9, `sort` 6, `find` 3, `cmp` 2, `awk` 1 — mais `bash` e `make` eles mesmos |
| ferramentas de verdade (não substituíveis) | `cc`, `qbe`, `pkg-config`, e os oráculos `python3`/`node`/`clang` |

O pscript já tem no idioma o que substitui a maior parte dessa coluna do meio
(ler arquivo, hash, `dict`, comparar bytes, ordenar). O que falta continua sendo
**um**: rodar um processo (1.2).

## As decisões que a leitura ACRESCENTA

**1.6 `/bin/sh -c` ou `argv` direto?** O samurai roda todo comando como
`posix_spawn("/bin/sh", "-c", cmd)` — porque a linguagem do ninja guarda o
comando como UMA STRING, e então precisa de alguém para dividi-la, expandir
`&&`, `>` e `*`. Um grafo em JSON pode guardar `["cc","-c","a.c","-o","a.o"]` e
**executar sem shell nenhum** — é a diferença entre depender do `/bin/sh` e não
depender. O `ps_run` do editor hoje usa `popen`, que é shell. Custo do lado sem
shell: quem quisesse `a && b` ou `> arquivo` tem de dizê-lo como grafo (duas
arestas) ou o pforge ganha uma primitiva própria.

**1.7 Quem grava a duração.** Se o escalonador vai ordenar pelo custo (a
medição acima diz que vale 4 s em 5), o log tem de guardar quanto cada aresta
levou — o que o samurai deliberadamente não faz. É uma coluna a mais no log e um
`sort` na fila.

## O ninja DE VERDADE, não a reimplementação (2026-08-21)

Sua pergunta: *"vc viu o do samurai, vê o do ninja mesmo pra gente descobrir"*.
Clonado e lido, `ninja-build/ninja` na `1.14.0.git`. O samurai é fiel no que
reimplementa — e o que ele **não** reimplementa é onde estava a resposta.

### O escalonamento: eu estava errado, e o erro é útil

O ninja moderno **escalona por caminho crítico**. Não é uma pilha: é uma fila de
prioridade (`EdgePriorityQueue`, `graph.h:465`) ordenada pelo
`critical_path_weight` de cada aresta, calculado em `Plan::ComputeCriticalPath`
(`build.cc:479`) com uma ordenação topológica e uma propagação de trás para a
frente — o peso de uma aresta é o maior caminho dela até um alvo. Empate
desempata pelo `id_`, "que era historicamente como tudo era agendado" (o
comentário admite o passado que o README do samurai descreve).

**Mas o peso de cada aresta é `1`** — `EdgeWeightHeuristic` (`build.cc:473`)
devolve `0` para *phony* e `1` para todo o resto. Ou seja: o ninja ordena pelo
caminho crítico **em número de arestas**, não em tempo. E ele **tem** o tempo:
o `.ninja_log` grava `start_time` e `end_time` em ms por saída
(`build_log.h:63`) — o samurai grava `0\t0` no lugar. O dado está lá, e o
escalonador não olha para ele.

Isto é decisivo aqui, e não por elegância: **o nosso grafo é raso**. Os 19 TUs do
compilador têm todos o mesmo comprimento de caminho até o binário (gerar → `cc
-c` → link), então a heurística de peso 1 dá **empate em tudo** e cai no `id_` —
que é a ordem do arquivo. Com o `ps_lower.c` (4,96 s de 5,0 s) na posição errada
dessa ordem, ele começa por último e o build inteiro espera por ele. A correção
não é escrever um escalonador melhor que o do ninja: é **usar como peso a
duração da última vez, que o log já teria de guardar**. É uma coluna no log e um
`sort` na fila, e aqui vale ~4 s em 5.

### O "está velho" do ninja (a 1.4, na fonte)

`RecomputeOutputDirty` (`graph.cc:222`), na ordem em que ele decide:

1. a saída não existe → sujo;
2. se a aresta é `restat` e há registro no log, **ignora o mtime real da saída**
   e usa o mtime gravado (é assim que uma saída "limpa" numa corrida anterior não
   suja o mundo);
3. saída mais velha que a entrada mais nova → sujo;
4. **hash do comando** diferente do gravado → sujo (exceto se a aresta é
   `generator`);
5. mtime **gravado no log** mais velho que a entrada mais nova → sujo (pega o
   caso de uma corrida que escreveu a saída e morreu no meio);
6. não há registro no log e não é `generator` → sujo.

O samurai faz os mesmos seis testes. **Então a 1.4 está decidida com base na
fonte, não na cópia.**

### O que o ninja tem e o samurai não — e o que isso nos diz

| mecanismo | o que é | serve aqui? |
|---|---|---|
| **`dyndep`** | dependências que só existem **depois** que um passo rodou: a aresta declara um arquivo `dyndep` que outra aresta gera, e ele acrescenta entradas/saídas implícitas (`dyndep.h:30`). Foi feito para módulos de Fortran e C++ | é EXATAMENTE o nosso caso do `.psc` que puxa módulos P (75.3) e da lista do runtime |
| `validations` | "constrói isto também, mas não bloqueia" | não |
| **jobserver** | protocolo de *job slots* do GNU make, para dividir o orçamento de paralelismo com um build pai (`jobserver.h`) | não agora; é o que se implementa no dia em que o pforge rodar dentro de outro build |
| `restat` | (o samurai TEM) | sim, é o de sempre |

## As decisões desta rodada (2026-08-21) — SUAS

**1.2 — DECIDIDO: task com `await`, sobre o laço de eventos.**
`await os.run([...]) -> (status, saída)`. É o desenho do samurai traduzido para
o nosso idioma, e a tradução é literal: o pipe por job mais o `poll` deles é o
laço da 102; a saída acumulada e despejada **inteira** no fim é a resposta ao
`print` costurado da 107; o paralelismo é `gather_map(..., at_most=n)`, sobre os
itens (79.4). Um worker por comando fica de fora: seriam 19 heaps e 19 coletores
para esperar 19 `cc`.

**1.4 — DECIDIDO: como o ninja faz** — os seis testes de
`RecomputeOutputDirty` acima, com `restat` e o hash do **comando** no log. O
hash de conteúdo que o `plangc run` já usa não é jogado fora: ele é o que o
`restat` decide com mais precisão quando a saída é C gerado (mtime novo, bytes
iguais).

**1.6 — DECIDIDO: `argv` direto, sem shell.** O grafo guarda
`["cc","-c","a.c","-o","a.o"]` e o pforge executa sem `/bin/sh`. O samurai usa
`posix_spawn("/bin/sh","-c",cmd)` porque a linguagem do ninja guarda o comando
como UMA string e alguém tem de dividi-la; um grafo em JSON não tem esse
problema. Consequência assumida: `&&`, `>` e `*` não existem — quem os quer diz
como grafo. (E o `ps_run` do editor, que é `popen`, não é o modelo do `os.run`.)

**A forma — DECIDIDA: um binário, dois modos**, como o muon carrega o samurai
dentro de si (`muon samu`, `samu_main` chamado em processo). Não dois programas.
E o primeiro alvo é o **compilador**: o grafo JSON escrito à mão que roda a
escada, que é o caso medido (18 s → 5 s) e o mais difícil (a saída de uma etapa é
a FERRAMENTA da seguinte).

## 1.8 (nova, sua) — as ferramentas são NOSSAS: o grafo pode não passar por arquivo

Suas palavras: *"dependendo do caso conseguimos passar direto a informação de uma
ferramenta pra outra se a gente quiser pq são a mesma"*.

Isto é o achado que a leitura das três fontes deixa nítido, porque **os três
formatos de arquivo mais chatos do ninja existem só porque ele e o compilador são
estranhos um ao outro**:

| formato | por que existe | por que aqui pode não existir |
|---|---|---|
| `depfile` (`cc -MD`) | o `cc` não fala com o ninja; escreve `.d` no disco e o ninja o lê e apaga (`deps.c:depsparse`, ~170 linhas de parser de Makefile com escapes) | o `plangc` **é nosso**: ele já sabe a lista exata do que leu (a 109 e o manifest do `run`), e pode entregá-la sem passar por texto |
| `.ninja_deps` | um log binário com versão, IDs, checksum `~n` e registros de 2^19 bytes, só para não reparsear os `.d` | se a informação não vem em arquivo, não há log de arquivo para manter |
| `dyndep` | "as entradas só se sabem depois de rodar" precisa de um arquivo porque o passo que sabe é um processo separado | o passo que sabe pode ser **o mesmo processo** |

O limite honesto disso: **o `cc` continua sendo estranho**, então o `depfile` do
`-MD` continua necessário para o lado C — e é justamente o lado onde ele já
funciona e custa pouco. O que desaparece é o formato para o **nosso** lado.

**DECIDIDO (2026-08-21): memória quando é a mesma execução, arquivo quando não
é.** O descritor entrega o grafo ao executor como `dict` — nada de JSON no meio —
e um `--emit-graph` grava o JSON quando alguém quer ver, versionar ou rodar
depois. A lista do que o `plangc` leu vem dele direto, e o `.ninja_deps` deixa de
ter razão de existir: ele é um cache de um parser que aqui não roda.

O que essa escolha compra e o que ela cobra:

- o grafo continua **inspecionável** (o `--emit-graph` é o `-t graph`/`-t deps`
  dos outros), mas por pedido, não em todo build;
- o executor **não pode** assumir que existe um arquivo de grafo — então a sua
  entrada é a estrutura, e ler JSON é só um dos construtores dela. Isso mantém a
  porta aberta para a linguagem do ninja depois (1.3) sem tocar no motor;
- fica de fora, por ora, chamar o `plangc` como BIBLIOTECA no mesmo processo
  (seria mais rápido ainda, e amarraria as versões dos dois para sempre). O
  caminho decidido não impede: a fronteira passa a ser uma função que devolve a
  lista, e de onde ela vem — processo ou chamada — é detalhe dela.

---

# A 1.5, de frente: os módulos das duas linguagens (2026-08-21)

Sua pergunta: *"não sei se nosso sistema de módulos do pscript e do P estão
maduros o suficiente (...) será que falta algo, para melhorar o build também, na
definição das linguagens?"*

## O que os dois são hoje, MEDIDO

**P — o modelo do C, à letra.** A unidade de tradução é o arquivo (`x.p` → `x.c`),
a interface é um `.ph` escrito à mão (que o compilador traduz para `.h`), e
`import "x.ph"` traz **só a interface**. Medido: `plangc --out-dir T
selfhost/main.p`, com os seus 11 `import`, emite **`main.c` e nada mais**. Logo a
lista dos 19 módulos do compilador é externa à linguagem — e é por isso que ela
vive em cinco lugares, um deles dentro do próprio compilador.

A convenção que já existe e que ninguém escreveu: **`.ph` com um `.p` irmão é
módulo; `.ph` sem irmão é só declaração** (`stl/*.ph` são 10 e nenhum tem `.p`;
em `selfhost/` só `ast.ph`, `plang.ph` e `ps_ast.ph` não têm). É uma regra
mecânica, decidível, e hoje ela só existe na cabeça de quem escreve os harnesses.

**pscript — o programa inteiro é a unidade.** Os módulos com namespace (41.3) são
resolvidos por **renomeação** em compilação (`geom__area`), justamente porque "o
alvo é uma unidade de tradução só". Medido no porte do editor: `cv_test.psc`
fecha sobre cinco módulos (~3 900 linhas de pscript) e sai **um** `cv_test.c` de
**24 601 linhas** — uma invocação de `cc`, nada incremental, nada paralelo. O
editor em pscript está sendo escrito agora e esse número só cresce.

**E há um furo na fronteira dos dois, medido.** `import "hl.ph"` dentro de um
`.psc` puxa o módulo P direito **quando o arquivo compilado é aquele**: `plangc
lib_hl.psc` emite `hl.c`, `hl.h` e as dependências transitivas
(`selfhost/lexer.c`, `plang.h`, `ast.h`, headers da stl). Quando o mesmo
`import` está num módulo pscript **importado**, não sai nada — e o C gerado
continua com `#include "hl.h"`, então não compila. O `tests/run.sh` contorna
compilando `hl.p` + `lexer.p` + `util.p` + `utf8.p` à mão: a **sexta** lista.
*(Área em obra pelo outro agente — anotado como achado, não tocado.)*

## Como as outras linguagens resolvem isto, e o que cada uma erra

| modelo | quem | o que acerta | o erro que cobra caro |
|---|---|---|---|
| **cabeçalho + lista externa** | C, C++ pré-módulos, **P hoje** | compilação separada de verdade, ABI estável, o build pode ser qualquer coisa | o compilador não sabe o que é *o programa*; a lista é humana e se duplica (aqui: 6 lugares) |
| **o compilador É o build** | `ghc --make`, `gnatmake`, `javac`, `go build`, `swiftc` | a lista some: um arquivo raiz e o grafo se descobre | o build cresce DENTRO do compilador (paralelismo, cache, sujeira) e mesmo assim vem outro por cima depois — cabal, gprbuild, gradle |
| **crate/programa inteiro como TU** | Rust, Zig, Nim, **pscript hoje** | semântica simples, otimização global, sem ABI interna para manter | incrementalidade: Rust precisou de `codegen-units` **e** de compilação incremental interna, e uma linha ainda recompila a crate |
| **pacote = diretório, import = build** | Go | o grafo de imports **É** o grafo de build; sem arquivo de build no caso comum; cache por hash de conteúdo | rigidez (um pacote por diretório, ciclo proibido) e tudo que GERA código (`go:generate`) fica **fora** do grafo — que é exatamente o nosso `.psc`→`.c` e o `embed` |
| **interface compilada, com HASH** | Haskell `.hi`, OCaml `.cmi`, Delphi `.dcu`, Modula-2, Ada | se a **interface** não mudou, quem depende **não recompila** — o GHC compara o `.hi` por hash | obriga ordem à mão (OCaml faz o programador ordenar o link) e amarra o formato da interface à versão do compilador |
| **módulos sem contar ao build** | C++20, Fortran | — | a ordem só se descobre lendo o fonte: foi por isso que o ninja precisou de `dyndep`. É o erro a não repetir |
| **o build é um programa na linguagem** | Zig (`build.zig`), e o nosso descritor | o build fica no idioma, sem uma segunda linguagem | quando é o único jeito, não há grafo inspecionável por baixo — a nossa 1.8(b) já evita isso com o `--emit-graph` |

Duas leituras que valem mais que a tabela:

- **O acerto do Go não é o diretório, é a implicação**: `import` significa "isto
  faz parte do programa". Todo o resto (cache, paralelismo, `-p`) vem de graça
  depois. Nós temos a informação e não temos a implicação.
- **O acerto do GHC não é o `.hi`, é o HASH dele**: o critério de recompilar não
  é "o arquivo mudou", é "a interface mudou". É o `restat` do ninja ganho um
  nível acima — e a nossa medição diz que é justo aí que estão os 18 s, porque
  `vecs.ph` tem 9 dependentes e uma vírgula num comentário dele hoje
  recompilaria todos.

## O que fazer melhor, dado o que já temos (proposta, não decisão)

Quatro coisas, em ordem de valor por custo:

**(a) `import` passa a implicar o MÓDULO, não só a interface.** A regra já
existe de fato: `x.ph` com `x.p` irmão. Com ela, `plangc` sabe de um arquivo raiz
a lista completa, e as seis listas somem — inclusive a que está dentro do
compilador (`RT_SRCS`) e a que o harness escreve para o `hl.p`. **Não muda o C
emitido nem a ABI**: muda quem calcula a lista. E casa com a 1.8: a lista sai do
compilador por chamada, não por `depfile`.

**(b) Hash de interface.** O `.h` que sai de um `.ph` é comparado por conteúdo; se
não mudou, os dependentes não recompilam. É onde estão os 18 s, e é o mecanismo
que o `restat` do ninja implementa por acidente (o mtime igual) e o GHC de
propósito.

**(c) pscript: o módulo PODE ser uma TU.** A metade difícil já está feita — a
renomeação da 41.3 dá nome global único a tudo. Falta um header gerado por
módulo e dizer o que é público. Sem isso, o editor em pscript é uma TU que só
cresce; com isso, um `.psc` fica igual a um `.p` para o build, e o pforge trata as
duas linguagens do mesmo jeito.

**(d) Fechar o furo da fronteira**, que é uma pergunta de definição e não um bug
de implementação: **o que `import "x.ph"` significa quando está num módulo
importado?** Hoje: silêncio e um C que não compila.

**E o que NÃO fazer: crescer o build dentro do `plangc`** — o erro da linha 2 da
tabela. O cache do `plangc run` já é o embrião disso e já é uma das listas. O
compilador deve **responder** (o que li, qual o hash da interface) e não
**decidir** (o que recompilar, em que ordem, com quantos processos).

## 1.5 — DECIDIDO (2026-08-22): as quatro entram

Você escolheu **(a), (b), (c) e (d)** — a definição das duas linguagens muda por
causa do build, nas quatro frentes. Em ordem de dependência, com quem mexe onde:

| # | o que é | onde mexe | dono |
|---|---|---|---|
| **(a)** | `import` implica o módulo (regra do `.p` irmão) | resolução de módulo do P: `selfhost/main.p` (a lista de entradas) e a checagem do irmão | compilador — **conflita com o outro agente se ele estiver em `main.p`** |
| **(d)** | o que `import "x.ph"` significa dentro de um módulo pscript importado | `selfhost/ps_sema.p` / `ps_lower.p` | **é a área em obra do outro agente** |
| **(b)** | hash de interface: recompilar quando a INTERFACE mudou | o compilador só precisa **dizer** o hash do `.h` que emitiu; o resto é do pforge | compilador (1 linha de saída) + pforge |
| **(c)** | pscript: o módulo vira uma TU (header gerado por módulo, público vs privado) | `ps_lower.p` inteiro, e o `psrt` | **maior das quatro; área do outro agente** |

Duas notas que a ordem deixa clara:

- **(a) e (d) são a mesma pergunta, uma em cada linguagem**: "o que atravessa um
  import?". Decidir as duas junto evita que o P responda uma coisa e o pscript
  outra — que é como o furo medido apareceu.
- **(b) não precisa de (a)**: ela vale já hoje, com as listas onde estão. É a
  única das quatro que rende os 18 s sem mexer em semântica de linguagem — o
  compilador só passa a imprimir o que já calculou.

## O protocolo: o que o compilador e o pforge dizem um ao outro

Suas palavras: *"que legal, agora até mesmo o compilador e o pbuild vão se
conversar"*. Vale escrever a conversa, porque ela é curta — **quatro perguntas** —
e porque é aqui que se erra (linha 2 da tabela das outras linguagens: o build
crescendo dentro do compilador).

| o pforge pergunta | o plangc responde | o que isso substitui |
|---|---|---|
| **"o que você leu?"** | a lista de fontes que entraram: imports transitivos, `.ph` irmãos, `embed()`, headers de `include <h>` | o `depfile` do `-MD` e o `.ninja_deps` inteiro, do nosso lado |
| **"qual o hash de cada interface que você emitiu?"** | um hash por `.h` gerado | a (b): o dependente não recompila quando a interface não mudou |
| **"o que você VAI emitir se eu te der isto?"** | a lista de saídas (`.c`, `.h`, `pmod_*.c`) | o `dyndep`: é a pergunta que o grafo precisa responder **antes** de a aresta rodar |
| **"quem você é?"** | o hash dos bytes do próprio compilador | a chave de sujeira que o `plangc run` já calcula (`main.p:551`) e guarda para si |

A terceira é a única com sutileza, e é a mesma que fez o ninja inventar o
`dyndep`: **o grafo precisa das arestas antes de o compilador rodar, e só o
compilador sabe.** A saída é uma **varredura** — resolver imports e parar, sem
sema e sem codegen. Medido, para saber se isso é barato: o front end sozinho
(`--parse-only`) custa **0,12 s** no maior arquivo do compilador e **menos de 1 s**
nos 34 fontes; a compilação C que ele destranca custa 18 s. Perguntar é de graça.

E as duas regras que mantêm essa conversa saudável:

1. **O compilador responde; o pforge decide.** O que recompilar, em que ordem,
   com quantos processos, nunca é resposta do `plangc`. É o que separa isto de
   `ghc --make` e de `go build`, e é o que impede o cache do `plangc run` de
   virar um segundo sistema de build (hoje ele já é uma das seis listas).
2. **A resposta é a mesma, o transporte muda** (1.8): na mesma execução é uma
   chamada que devolve a estrutura; fora dela, uma linha por arquivo em stdout ou
   um JSON. O formato não é o mecanismo — foi essa confusão que deu ao ninja
   três formatos de arquivo para uma informação só.

## 1.6b–1.6e — o modelo de `argv`, resolvido (2026-08-22)

A 1.6 disse "sem shell" e não disse o resto. Medido antes de decidir: os
harnesses de hoje usam **205 redirecionamentos, 154 pipes, 70 globs, 14 `cd`** e
2 comandos com variável na frente — mas a maior parte disso é **relatório do
harness**, não aresta de build: as arestas de verdade (`plangc -o`, `cc -o`,
`qbe -o`) não precisam de `>` nenhum.

**1.6b — argv LIVRE em qualquer lugar, com aprovação gravada no lock.** Uma
aresta pode invocar qualquer programa (este repositório precisa de `qbe`, e as
suítes usam `python3`/`node`/`clang` como oráculo — uma lista fixa deixaria tudo
isso fora do grafo). A primeira vez que um `argv` novo aparece, ele é mostrado e
aprovado, e a aprovação fica **no lock** — versionada, revisável em diff, e não
uma caixinha que alguém clica e esquece.

Como isso conversa com a 2.11 do pforge (*"pacote não tem build próprio"*): a
liberdade é do mecanismo, o portão é a aprovação, e **um pacote de terceiro
continua não declarando aresta nenhuma**. Um pacote declara O QUE precisa; as
nossas ferramentas decidem COMO. Se algum dia um pacote puder declarar uma
aresta, ela nasce precisando de aprovação registrada — o vetor do `postinstall`
não tem como voltar sem passar por um diff.

**1.6c — o executor já captura; a aresta diz onde gravar.** A 1.2 devolve
`(status, saída)` de cada comando e o samurai já guarda a saída em buffer para
não costurar linhas de jobs concorrentes. Então `> x` é um **campo da aresta**
(`stdout: x`) que o pforge escreve — sem shell, e sem mecanismo novo: ele já
existe por outros dois motivos.

**1.6d — glob só no DESCRITOR, com `os.listdir` ordenado; nunca na aresta.** O
descritor é um programa: ele lista o diretório e escreve a lista no grafo. A 111
fez o `os.listdir` ordenar de propósito ("um build e um editor querem a mesma
lista sempre"), então o grafo sai determinístico e auditável. Um padrão dentro da
aresta faria o hash do comando **mentir**: duas execuções com arquivos diferentes
no disco seriam builds diferentes com o mesmo grafo.

**1.6e — `env` e `cwd` declarados na aresta, e o `env` ENTRA no hash do comando.**
O executor os aplica no spawn do filho — seguro porque ali é processo, não thread
(a proibição de `chdir` da 111 vale para a stdlib dentro de um worker, não para
um filho). E o `env` no hash conserta um furo que o ninja tem de verdade: hoje,
trocar `CC=clang` por `CC=gcc` pode reaproveitar artefato silenciosamente, porque
o hash cobre a linha de comando e não o ambiente em que ela rodou.

---

# O caminho QBE, o linker e o "JIT" (2026-08-22)

Suas palavras: *"mais pra frente vamos incluir um linker aqui dentro também, pra
conseguir tornar isso mais parecido com um JIT, pq já temos o QBE aqui pra
compilar, e o pbuild deve saber compilar com qbe gerando qbe no lugar de C
também"* — e depois: *"vou anexar o qbe com o plangc sem passar pela linguagem QBE
em si, direto pela memória do processo (...) talvez passando a AST de um pro
outro, ainda não decidi"*.

## Medido nesta máquina: o caminho QBE já é 4× o caminho C

Construindo o compilador inteiro (19 módulos), tudo **serial**:

| etapa | tempo |
|---|---|
| `plangc --backend qbe` (19 × `.p` → `.ssa`) | 2,394 s |
| `qbe` (19 × `.ssa` → `.s`) | 1,710 s |
| `as` (19 × `.s` → `.o`) | 0,356 s |
| link (`cc` dos 19 `.o`) | 0,036 s |
| **total** | **4,50 s** |

Contra o caminho C: **18,5 s serial** (0,47 de geração + 18,0 de `cc`) e **5,0 s
com 8 núcleos**. Ou seja:

> **O caminho QBE serial (4,50 s) é mais rápido que o caminho C com oito núcleos
> (5,0 s), e 4× mais rápido que o C serial.** E ele paraleliza igual, por módulo.

O binário resultante foi verificado: `plangc_qbe` compila um programa e ele roda.
*(Nota de ruído: o `as` avisa "0xcbf29ce484222325 shortened to 0x84222325" —
conferido, é correto: o QBE emite constante de 64 bits como dois `movl`, um com
os 32 bits de baixo e outro com `>>32`. É aviso, não defeito; mas vai poluir o
log de qualquer build no caminho QBE.)*

## O que o linker interno compra — e o que ele NÃO compra

Honestamente: **o link já custa 0,036 s.** Um linker nosso não é uma decisão de
desempenho de build. O que ele compra é outra coisa, e é medida:

| `plangc run` de um `hello.psc` | tempo |
|---|---|
| **frio** (gera o programa, gera os 6 módulos do runtime, `cc`, link) | **3,32 s** |
| quente (confere o manifest e `exec`) | 0,006 s |

Os 3,32 s do frio são o que separa "isto é um script" de "isto é um compilador
que espera". No caminho QBE, com o QBE dentro do processo e o link dentro do
processo, esse número cai para a ordem de **décimos** — e aí `plangc run` deixa
de ser "compila e roda" e passa a ser o que você chamou de JIT. **É o caso de uso
do linker interno: latência de invocação, não tempo de build.**

E o que ele compra do lado da independência é nomeável com precisão. Hoje o
caminho QBE precisa de **três** ferramentas externas: `qbe`, `as` e o `cc` que
linka. O QBE dentro do processo tira uma; o linker interno tira a segunda; **o
`as` é a última que sobra** — e só sai se o QBE ganhar emissão de objeto ou se
escrevermos um assembler. Vale saber que `as` custa 0,356 s nos 19 módulos: é
questão de independência, nunca de velocidade.

## Anexar o QBE: as quatro formas, e o que cada uma custa

O QBE são ~18 mil linhas de C (com testes e o `minic`). Ele **não tem API**: é um
programa com estado global e um parser de texto (`parse.c`) que constrói `Fn`,
`Blk`, `Ins`. Então "anexar" tem quatro leituras, e elas não custam o mesmo:

| forma | o que muda | custo |
|---|---|---|
| **(1) processo separado, arquivo** (hoje) | nada | um `fork`+`exec` e dois arquivos por módulo |
| **(2) o C do QBE compilado pelo `plangc` e linkado dentro** | um binário só; ninguém precisa de `qbe` no PATH | o nosso front end de C tem de engolir o QBE — e ele já engole a c-suite (220/220), então é medível hoje |
| **(3) o IL vai por MEMÓRIA para o parser do QBE** | acaba o arquivo e o processo; o formato de texto continua | pequeno: o `parse.c` lê de um `FILE*`, e um buffer de memória serve |
| **(4) passar a AST/IR direto** (a sua ideia) | acaba também o texto | welda o nosso backend às estruturas internas do QBE, que mudam entre versões dele — é um FORK mantido por nós |

A minha recomendação, e o motivo é medido: **(2) + (3) compram quase tudo por
quase nada** — um binário só, sem arquivo e sem processo — e mantêm o QBE
*upstream*, atualizável. A (4) só se paga se o **parse** do texto for uma fatia
grande do 1,71 s do QBE, e ele é uma fração disso (o resto é SSA, alocação de
registrador, emissão). Ou seja: a (4) otimiza a menor parte do menor termo.

Vale dizer o que (4) tem de bom e que não é velocidade: passar IR estruturado
elimina uma classe de bug — o texto que a gente imprime e o QBE reparseia é uma
fronteira onde erro de grafia vira erro de compilação estranho. Se algum dia o
`.ssa` gerado divergir do que o QBE aceita, é (4) que fecha a porta.

## O que isso exige do pforge (e é uma regra, não um detalhe)

**O grafo NÃO pode ter o pipeline embutido.** Os dois caminhos têm formas
diferentes, e um deles muda de forma com a decisão acima:

```
caminho C     .p -> .c + .h -> .o -> bin      (tem header: depfile e restat valem)
caminho QBE   .p -> .ssa -> .s -> .o -> bin   (NÃO tem header nenhum)
QBE dentro    .p ------------> .o -> bin      (nem .ssa, nem .s)
QBE + linker  .p ------------------> bin      (uma aresta, zero arquivo intermediário)
```

Duas consequências:

- **as arestas são declaradas pelo descritor, por backend** — o executor não sabe
  o que é "compilar", só sabe rodar aresta. É o que o Ninja acerta e o que um
  build system com "regra de C embutida" erra;
- **no caminho QBE não existe `.h`, logo o `depfile` não existe** — e então o
  **hash de interface (1.5b) é o ÚNICO mecanismo de interface que sobra**. A
  decisão que tomamos para ganhar 18 s no caminho C é a que torna o caminho QBE
  incremental. As duas frentes convergem no mesmo mecanismo, o que é um bom sinal
  de que ele é o certo.

---

# 1.3 — o esquema do grafo, com as contas na mesa (2026-08-22)

Você pediu as vantagens e desvantagens de verdade. Elas dependem de dois números
que ninguém tinha medido, então medi primeiro.

## Quantas arestas tem o grafo DESTE repositório

| o que | quantidade |
|---|---|
| fontes P/pscript (compilador, runtime, pstudio) | 78 |
| programas de teste `.p`/`.psc` (cases, errors, pscript run/bad) | 393 |
| c-testsuite | 220 |
| p-suite | 192 |
| wacct (corpus de C válido) | 1 630 |
| **total de programas** | **~2 500** |

Cada programa é 2 a 3 arestas (gerar, compilar, rodar-e-comparar). O grafo real
deste repositório é da ordem de **6 000 arestas** — não 50, e não um milhão.

## Quanto custa LER um grafo de aresta gorda (medido, em pscript)

Programa de medição rodado com o `plangc run`: 2 000 arestas gordas, cada uma com
`argv` de 8 itens, 8 entradas, 1 saída, `env` e `restat`:

```
bytes:          583 571        (583 KB de JSON para 2 000 arestas)
gerar     (ms):       5
json.parse(ms):      13
percorrer (ms):       0        (2 000 arestas + 16 000 itens de argv)
```

Extrapolando para as ~6 000 arestas daqui: **~1,7 MB e ~40 ms**. Contra 0,47 s de
geração de C e 5 a 18 s de `cc`, **ler o grafo é ruído** — 0,2 % do build mais
rápido que existe aqui.

## As três formas, agora com consequência e não com gosto

### (1) Aresta gorda e autônoma

Cada aresta carrega tudo: `argv`, entradas (normais/implícitas/order-only),
saídas, `env`, `cwd`, `stdout`, `restat`, `generator`, `pool`.

- **o que TIRA do motor**: a expansão de variável com escopo — as 921 linhas de
  `parse.c`+`scan.c`+`env.c` do samurai — deixa de existir. O motor fica só com
  grafo, sujeira, escalonador e log (os 1 546 que eu medi);
- **fatoração**: acontece no descritor, que já decidimos ser um **programa**. Uma
  função pscript fatora repetição melhor que qualquer mecanismo de variável, e
  não precisa de regra de escopo nenhuma. Um segundo mecanismo de fatoração dentro
  do grafo seria abstração duplicada;
- **diff**: dois grafos se comparam linha a linha e a diferença é literal. No
  modelo de regras, mudar uma regra altera mil arestas **invisivelmente** — e é
  por isso que o ninja precisa do hash do comando no log para perceber;
- **legibilidade**: cada aresta se explica sozinha, e "por que isto rodou?" se
  responde lendo **um** objeto. O preço é a repetição visível: as mesmas flags
  aparecem 6 000 vezes;
- **custo medido**: 1,7 MB e 40 ms.

### (2) Regras + arestas, como o ninja

`rule cc: command = cc $ARGS -c $in -o $out`, e arestas que instanciam.

- **compacto**: o grafo cai para talvez 400 KB, e é agradável de ler à mão;
- **o que TRAZ para o motor**: expansão com escopo (variável de regra, de aresta,
  de arquivo) — as 921 linhas. E o samurai **divergiu do ninja de propósito**
  nessa ordem de resolução, com o README documentando a esquisitice do ninja
  (#1516). Ou seja: é a parte da referência onde as duas implementações não
  concordam entre si;
- **e um detalhe que muda tudo aqui**: com as nossas decisões (`argv` em vez de
  string de shell, `env` na aresta e no hash, `cwd`, `stdout`) uma regra teria de
  expandir para um **vetor de argumentos** — coisa que o ninja não faz, porque
  lá o comando é uma string para o `/bin/sh`. Seríamos obrigados a **inventar uma
  variante** do modelo, em vez de reusar um provado;
- **o que se perde**: a diffabilidade acima.

### (3) Aresta gorda com tabela de strings

Autonomia da (1), e as strings repetidas viram índices.

- **economiza**: talvez 1,7 MB → 400 KB, e alguns dos 40 ms;
- **custa**: o JSON deixa de ser legível a olho nu — que era **metade do motivo**
  de a v1 ser JSON — e passa a existir uma segunda representação (a tabela) para
  manter coerente;
- **veredicto honesto**: otimiza justo o que a medição diz ser grátis.

## A recomendação, e por que ela não fecha porta nenhuma

**(1), aresta gorda.** Ela é a única das três que *remove* mecanismo do motor em
vez de acrescentar, está alinhada com "o descritor é um programa", e o seu único
custo foi medido em 40 ms num grafo de 6 000 arestas.

E ela **não impede a linguagem do Ninja depois**: pela 1.8, a entrada do executor
é a **estrutura**, e ler JSON é apenas um dos construtores dela. Um dia, um front
end da linguagem do ninja expande regras **para arestas gordas** e o motor não
sabe a diferença — que é exatamente a ordem certa: primeiro o mecanismo provado,
depois o açúcar.

## 1.7 — DECIDIDA: a duração entra no log, e a fila ordena por ela

O ninja grava `start_time`/`end_time` por saída (`build_log.h:63`) e **não os usa
para ordenar**: ordena por caminho crítico em **número de arestas**
(`EdgeWeightHeuristic` devolve 1). No grafo raso deste repositório isso dá empate
em tudo, e o `ps_lower.c` — 4,96 s de um build de 5,0 s — pode ir por último.
Com a duração da última vez como peso, o ganho medido é de ~4 s em 5. É uma
coluna no log e um `sort` na fila.

## QBE — DECIDIDA: forma (2)+(3)

O C do QBE entra pelo **nosso** front end (um binário só; ninguém precisa de
`qbe` no PATH) e o IL vai por **buffer de memória** para o parser dele (sem
arquivo, sem processo), mantendo o QBE *upstream* e atualizável. A forma (4)
(passar IR estruturado) fica de fora por ora: ela otimiza o parse, que é fração
do menor termo (1,71 s), e cobraria um fork do QBE mantido por nós.

## E se em vez de JSON gerássemos NINJA? (sua pergunta, 2026-08-22)

> *"se ao invés de json realmente gerássemos um código ninja junto com o C, isso
> resolveria o bootstrap também?"*

**Resolve — mas não o bootstrap que parece.** Vale separar os dois, porque a
intuição acerta um e o outro já está resolvido:

**O bootstrap do COMPILADOR não precisa disso.** Ele é hoje um comando:
`cc bootstrap/selfhost/*.c -o plangc`. Nenhum sistema de build participa, e é a
forma mais forte que existe. Trocar o `Makefile` de 130 linhas por um
`build.ninja` comitado **troca `make` por `ninja`** — lateral, e `make` está em
mais máquinas. Zerar a ferramenta externa exigiria **vendorizar o samurai** (4 306
linhas de C, que o nosso próprio front end compila) — o que é uma decisão sobre
carregar código de terceiro, não sobre formato.

**O bootstrap do PBUILD é o que a sua ideia resolve, e resolve bem.** O pforge é
escrito em pscript: para construí-lo é preciso o `plangc` **e** o runtime — e se o
pforge fosse o único jeito de construir qualquer coisa, ele precisaria de si
mesmo. Com um `build.ninja` **gerado e comitado**, uma máquina limpa faz:

```
cc bootstrap/selfhost/*.c -o plangc      # o seed do compilador, como hoje
ninja      (ou samu)                     # constrói TUDO, inclusive o pforge
```

É o mesmo truque do seed de C, um nível acima: **o artefato gerado é comitado
para quebrar o ovo e a galinha.** Isso é bom o bastante para valer sozinho.

**E tem um bônus que eu conferi na fonte dos dois:** emitir ninja dá de graça
`-t compdb` (base de compilação em JSON, que é o que clangd e IDE consomem),
`-t graph` (graphviz), `-t query`, `-t targets` e `-t commands` — no ninja **e** no
samurai. Ferramental de inspeção que não custa uma linha nossa.

**O custo, e é o que decide a FORMA:** no ninja, o comando é uma **string
executada pelo `/bin/sh`**. Emitir ninja reimporta o shell, o aspeamento, o `>` e
o `env` — tudo o que a 1.6 tirou. Mas há uma assimetria que salva o desenho:

> **Gerar aspeamento é seguro; interpretar aspeamento é onde moram os bugs.**
> Se a nossa verdade é o `argv` (vetor exato), descer para ninja é mecânico e
> correto — nós sabemos exatamente onde cada argumento começa e termina. Se a
> verdade fosse o texto ninja, teríamos de **parsear** de volta, e herdaríamos
> junto a divergência documentada entre ninja e samurai na resolução de variável.

Então a resposta não é "JSON ou ninja", é uma ordem:

- **a verdade é a aresta gorda** (estrutura em memória; JSON quando pedido);
- **`--emit-ninja` é uma exportação** — e é ela que quebra o bootstrap do pforge,
  que dá o `compdb` de graça, e que permite **usar ninja/samu como executor
  enquanto o nosso não existe**.

Essa última linha é a consequência mais prática de todas: **a v1 do pforge pode
ser só o DESCRITOR.** É exatamente o caminho do Meson (que nunca teve executor) e
do muon (que emite ninja e carrega o samurai dentro). E é o recorte certo, porque
o descritor é a metade **específica deste repositório** — a que sabe a escada, as
seis listas e os cinco harnesses — enquanto o executor é a metade genérica, que já
está lida e medida (1 546 linhas).

## 1.3 — DECIDIDA (2026-08-22): aresta gorda é a verdade; ninja é exportação

A aresta carrega tudo — `argv`, entradas nas três faixas (normal, implícita,
order-only), saídas, `env`, `cwd`, `stdout`, `restat`, `generator`, `pool` — e o
motor fica sem uma linha de expansão de variável. A verdade é a **estrutura**
(JSON quando pedido, memória quando é a mesma execução — 1.8), e `--emit-ninja`
desce dela para o texto do ninja: aspeamento **gerado** por quem sabe onde cada
argumento começa, nunca interpretado.

O que a exportação continua valendo mesmo com o executor pronto na v1: o
`build.ninja` comitado quebra o ovo-e-galinha do pforge numa máquina limpa, e o
`-t compdb` de graça é o que clangd e IDE consomem.

## A v1 — DECIDIDA: descritor E executor

Independência desde o primeiro dia: construir este repositório não vai depender de
`make` nem de `ninja`. O executor é a metade genérica — e ela está lida, medida e
com desenho escolhido peça por peça:

| peça do executor | de onde vem o desenho |
|---|---|
| nó, aresta, três faixas de entrada, dois contadores (`nblock`/`nprune`) | `samurai/graph.h`, lido |
| os seis testes de sujeira | `ninja/src/graph.cc:222`, lido na fonte |
| `restat` e poda | `samurai/build.c:shouldprune` + `nodedone`, ~40 linhas |
| fila de prioridade por caminho crítico | `ninja/src/graph.h:465` — **com o nosso peso: a duração da última vez (1.7)** |
| laço de execução | `poll` sobre um pipe por job + self-pipe de sinal → aqui é o laço da 102 com `await os.run` (1.2) |
| saída inteira, sem costura | `samurai/build.c:jobdone` — e é o achado da 107 |
| log | duas colunas a mais que o samurai: duração e hash de `env` |
| `pool` | 7 linhas em `queue()` |

Nada aí é pesquisa. O que é específico deste repositório — e por isso o trabalho
de verdade — é o **descritor**: a escada `seed → s1 → s2 → out3` com ponto fixo,
as seis listas de módulos, os cinco harnesses, os dois backends, o pstudio com
SDL2 e os corpora de conformidade.

## O hash de interface — DECIDIDO: a lista canónica da API (2026-08-22)

O que se hasheia é a **lista de símbolos e assinaturas** que o compilador já vai
emitir pela 2.6 — sem comentário, sem formatação, com ordem estável. Duas
decisões convergem num artefato só, e a consequência prática é a que salva a
decisão anterior: **editar uma docstring no `.ph` não recompila os 9 dependentes
de `vecs.ph`.** É o comportamento do GHC — o `.hi` é comparado por hash de
interface, não de arquivo.

Detalhe que vale escrever porque é fino: o `.h` **continua** sendo entrada de
arquivo da aresta de `cc` (é o que o `cc` lê, e ele não sabe distinguir
comentário). Então mexer numa docstring **suja** a aresta de `cc` daquele módulo;
o que o hash de API evita é a **avalanche** — os outros nove módulos não são
tocados, e o `restat` corta o relink porque o `.o` sai idêntico.

## A API do descritor — DECIDIDA: alvos de alto nível (`executable()`)

O `build.psc` fala em alvos, no espírito do meson: `executable(...)`,
`library(...)`, e o caso comum fica curto.

E aqui vai o guarda-corpo, porque é justo onde o muon acumulou 1 679 linhas de
`toolchains.c` e onde o CMake se perdeu: **a inteligência de alvo mora na
BIBLIOTECA do descritor (pscript), não no motor.** O executor continua sabendo
uma coisa só — rodar aresta — e `executable()` é uma função pscript que devolve
arestas. Isso mantém o motor nos 1 546 linhas medidos, deixa o conhecimento de
toolchain num módulo que se lê e se testa como qualquer outro, e permite (se um
dia fizer falta) expor a aresta crua como escapatória **sem** mudar mecanismo.

## `static` → `private`: a migração (2026-08-22)

Sua decisão: *"vou substituir a keyword `static` pela keyword `private`, na
própria linguagem P e pscript. Primeiro deixa como alias, compila, e depois edita
o código trocando tudo por `private`... e depois remove [o `static`] de vez."*
*(Li a última frase como remover o `static`, não o `private` — se era o contrário,
me diga.)*

**Medido, para dimensionar:** `static` aparece **1 965 vezes** nos fontes P/pscript
(1 685 só em `selfhost/*.p`), mais **20 ocorrências** no corpus de testes e **1**
mensagem `.expected` que o cita.

**ESTADO OBSERVADO (2026-08-22, no meio desta investigação): a migração JÁ
COMEÇOU.** O lexer tem `{"private", TK_PRIVATE}` ao lado de `{"static",
TK_STATIC}` (`selfhost/lexer.p:24`) — o passo do alias —, os fontes estão sendo
convertidos (`private def`, `private const`; o `main.p` tem 10 `static`
restantes) e o `bootstrap/` foi regenerado (aparece modificado no git). Ou seja:
os passos 1 e 2 abaixo já aconteceram, e o que resta é terminar a conversão e
remover a grafia antiga.

**A sua ordem não é preferência, é obrigatória** — e é a escada que a impõe: o seed
comitado é o compilador que compila os fontes. Trocar os fontes antes de o seed
entender `private` quebra o degrau 1. Então:

1. **`private` como alias** de `static` no lexer (uma linha na tabela de
   palavras-chave — a mesma tabela serve P e pscript);
2. **regerar o seed**, para que o `bootstrap/` comitado aceite `private`;
3. **editar os 1 985 sítios** (fontes + testes + a mensagem);
4. **regerar o seed** outra vez;
5. **remover `static`** como grafia de privacidade.

**E a troca CONSERTA a sobrecarga, não só renomeia.** Em pscript, `static` quer
dizer duas coisas: privado (no topo) e **método estático** (dentro de um
`record`/`struct`). Depois da migração cada palavra tem um sentido só:

| grafia | sentido, depois |
|---|---|
| `private def f()` | privado ao módulo (nas duas linguagens) |
| `static def f()` | **método estático** (só dentro de struct, só pscript) |

**Duas coisas que a migração NÃO afeta**, e vale dizer para ninguém se assustar:

- **o C emitido continua usando `static`** — é a palavra do C, e ali ela é a
  verdade sobre ligação interna. Muda a linguagem de entrada, não a de saída;
- **o front end de C não é tocado**: ele tem lexer próprio (`Cx`/`CtKind`, em
  `cfront.p`), então `static` continua sendo `static` quando a entrada é `.c`/`.i`.

## Saída de comando — DECIDIDA: capturada por padrão, console quando pedido

O padrão é a 1.2 (guarda e despeja inteiro — o que impede a costura de linhas de
jobs concorrentes, o achado da 107). Uma aresta pode declarar que fala com o
**terminal**: sem captura e sozinha na vez. É o `console` pool do ninja, sete
linhas em `queue()`, e é o que `pforge run` e o pstudio precisam — um programa
gráfico não pode ter a saída represada.

## 1.5(c) — o header de um módulo pscript expõe o LAYOUT

Transparente, como o P já faz: o `.h` gerado carrega os campos e quem importa
acessa campo direto, sem chamada. Mantém a promessa de desempenho da 52.1
(`record` é tipo de VALOR) e mantém **uma** regra para as duas linguagens.

O preço, dito agora para não surpreender depois: **o layout entra na interface**,
então mudar um campo — mesmo um que ninguém de fora usa — muda o hash da API e
recompila os dependentes. É a fragilidade de ABI que o C tem, e nós a herdamos de
propósito. A porta de saída existe e é aditiva (marcar um tipo como opaco quando
a fronteira importar mais que o acesso direto), e não precisa ser decidida hoje.

## Compilação cruzada — DECIDIDA: entra na v1 (2026-08-22)

E ela ficou mais interessante do que eu tinha suposto, porque conferi o QBE:
`qbe -t ?` lista **seis alvos** — `amd64_sysv` (padrão), `amd64_apple`,
`amd64_win`, `arm64`, `arm64_apple`, `rv64`. Ou seja, os nossos dois back ends dão
duas histórias de cruzamento **complementares**:

| caminho | como cruza | o que precisa da máquina-alvo |
|---|---|---|
| **C** | manda o C (ou o C89) e compila lá | um `cc` do alvo — e o C é o formato mais portátil que existe |
| **QBE** | `-t <alvo>` emite o assembly do alvo aqui | um `as` e um `ld` do alvo (cross-binutils) |
| **QBE + o nosso linker** | idem | só um `as` do alvo |
| **QBE + linker + assembler nossos** | idem | **nada** |

Isso reordena um argumento que eu tinha dado: eu disse que o linker interno se
paga em **latência de invocação** (o JIT). Ele se paga mais em **cruzamento** —
cada peça nossa apaga uma exigência da máquina-alvo, e a última linha da tabela é
uma linguagem que cruza sem toolchain de terceiro nenhum. A latência é o ganho
diário; o cruzamento é o ganho estrutural.

O que a v1 tem de fazer, e é pequeno: **o alvo entra na chave de sujeira** (junto
com `argv`, `env` e o hash do compilador), para que artefato de um alvo nunca seja
confundido com o de outro. O trabalho de verdade não é o grafo, é o de sempre:
flags por alvo, `pkg-config` do alvo, e a declaração de dependência de sistema
(2.7) passando a ser por alvo.

## `pforge test` — DECIDIDO: suítes nomeadas

`pforge test cases modules pscript` — as mesmas oito suítes que o `tests/run.sh`
tem hoje, declaradas no descritor. É o que o `verify-all` precisa para chamar por
nome, e o que dá placar por grupo. (O piso de placar — `c-suite>=220`,
`wacct>=741` — fica como está por ora, no arreio; movê-lo para o descritor é
aditivo e não precisa de decisão hoje.)

## A pasta de build — DECIDIDA: `build/` com `pkg/ obj/ bin/ log/`

Nome óbvio, visível, fácil de apagar e de ignorar no git. Fica uma migração
nomeada: este repositório usa **`out/`** hoje (e o `plangc --out-dir` espelha a
raiz lá dentro, com os `.c` gerados incluindo `"../stl/x.h"` relativo ao próprio
diretório). O caminho é o descritor passar `--out-dir build/obj` e o `out/`
sumir — mas isso toca o `Makefile` e os cinco harnesses, então acontece **quando
o pforge substituir**, não antes.

## Falha, lock e `verify` — DECIDIDOS (2026-08-22)

**Falha: para na primeira, e `-k N` continua.** É o padrão do ninja e do samurai
(`maxfail = 1`), e a razão é boa: a primeira mensagem é quase sempre a causa, e as
seguintes são consequência dela.

Uma suposição que fica escrita porque decorre disso: **`pforge test` roda com `-k`
por padrão**, porque um placar só significa algo completo — 220/220 não se mede
parando no primeiro. Se você preferir que teste também pare na primeira, é uma
linha de política e me diga.

**Lock dessincronizado: o `pforge` atualiza sozinho e mostra o diff** do que
entrou, saiu ou mudou de hash. É o que o cargo faz e o que menos atrapalha o
trabalho do dia. (O oposto — `--frozen` como padrão — fica disponível como opção
para CI, sem ser o comportamento normal.)

**`verify-all` vira um ALVO do descritor: `pforge verify`.** A escada
`seed → s1 → s2 → out3`, o `diff` byte a byte, o ponto fixo do QBE, os placares
com piso e os oráculos passam a ser alvos e arestas declaradas — com paralelismo e
sujeira de graça. E isso é o **critério de pronto da v1** dito de outro jeito: se o
descritor consegue expressar a escada com ponto fixo, ele consegue expressar
qualquer build; se não consegue, não está pronto.

## Mais quatro decisões (2026-08-22)

**A stdlib e o runtime vêm COM a toolchain.** A versão do compilador é a versão do
runtime, e o argumento decisivo é técnico: o `ps_lower.p` emite chamadas para
funções `ps_*` com assinatura exata — um runtime de outra versão quebra a ABI
interna. E o hash dos bytes do compilador, que já está na chave de sujeira, cobre
o runtime de graça. É o modelo Go/Python (a stdlib vem junto), e fecha um laço: um
pacote nunca declara "runtime >= X", declara **faixa de toolchain** (2.7).

**`--explain` sim; linha de status que se atualiza, não.** O diagnóstico de sujeira
é o que tem valor técnico ("mais velho que a entrada X", "o comando mudou", "sem
registro no log" — as mensagens que li no samurai e no ninja); saída rolando é o
que serve em CI, onde `\r` vira lixo no log.

**`pforge dev`: reconstrói E reinicia o programa.** Não é um build que espera: é o
laço de edição. O `inotify` (Linux) e o `EVFILT_VNODE` do kqueue (macOS) entram no
laço de eventos que **já existe** (102) — é fonte de fd nova, não mecanismo novo.

**`pforge build --repro` constrói duas vezes e compara.** O `verify-all` já faz
isso à mão para o compilador (`diff -rq out2 out3` e o ponto fixo do QBE); virar
comando é pequeno e passa a valer para qualquer projeto.

E aqui uma medição que essa decisão pedia: **o C que geramos não tem data, nem
caminho absoluto, nem nada aleatório** — conferido nos 19 módulos. A única
ocorrência de `__DATE__` no C gerado é o compilador *implementando* o `__DATE__`
para entrada em C (`sema.c:8623`). O que nos dá o limite exato da promessa:
**o nosso P e pscript são reprodutíveis por construção; um pacote em C que use
`__DATE__`/`__TIME__` não é** — e a resposta padrão do mundo para isso
(`SOURCE_DATE_EPOCH`) é a que devemos adotar quando aparecer.


## Um achado da IMPLEMENTAÇÃO da F0 (2026-08-22)

Escrever a resposta 2 mostrou que a 1.5(b) tem **dois consumidores com
necessidades diferentes**, e que um deles já estava resolvido sem ninguém notar:

**No caminho C, o `restat` já entrega o ganho dos 18 s — sem hash de interface
nenhum.** O compilador emite `x.h` a partir de `x.ph`; se o `.h` sair
byte-idêntico, o `restat` do grafo poda os consumidores. E como o lexer descarta
comentário, editar comentário (ou docstring, quando ela chegar) **não muda o
`.h`** — logo não recompila ninguém. O mecanismo que a F2 traz por outro motivo
cobre este caso inteiro.

O que a lista canónica da API entrega, então, é o que o `.h` **não** pode dar:

| consumidor | por que precisa da LISTA e não do `.h` |
|---|---|
| `pforge publish` | dizer *o que* mudou entre duas versões (semver com diagnóstico), não só *que* mudou |
| doc (2.6) | símbolos e assinaturas como dado, para o JSON e para `pforge doc` |
| caminho **QBE** | ali **não existe header**: a lista é a única noção de interface que sobra |
| `pforge search` | achar por SÍMBOLO sem baixar o pacote |

E há um limite que ficou escrito no `api.ph` para ninguém supor demais: a lista
cobre a interface DECLARADA, não o **corpo** de uma função de header (`private
inline def` num `.ph`, que é a stl inteira). No caminho C isso não é buraco — o
`.h` carrega o corpo e o `restat` compara o `.h`. É a divisão certa: **a lista é
para semver e doc; o `.h` é do que a compilação depende.**
