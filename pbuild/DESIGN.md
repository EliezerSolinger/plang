# pbuild — documento de decisões

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

E o nome: **pbuild**.

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

E o pbuild é o primeiro consumidor da sua ideia 1.5: se a linguagem disser quais
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

**Do lado do P**, a camada de SO já estava escrita — `pstudio/psys.p`, para o
editor: `vfs_read_all`, `vfs_write_all`, `vfs_list_dir`, `vfs_stat` (com mtime),
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
pstudio deixa de ser a casa deles: ele é a fonte de onde eles saem. O pbuild e o
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

| programa | o que ele cobra do pbuild |
|---|---|
| **o compilador** (`selfhost/*.p`, 38 312 linhas) | muitos módulos P numa ordem que importa, o header ao lado do `.p`, e a ESCADA de bootstrap (seed → s1 → s2 → out3) com ponto fixo — ou seja, um grafo em que a saída de uma etapa é a FERRAMENTA da seguinte |
| **o pstudio** (6 camadas + SDL) | um programa em pscript com módulos, dependência externa (`sdl2-config`), e um binário gráfico que ainda tem de rodar headless nos testes |
| **o runtime do pscript** (5 módulos, 109) | a lista que hoje está decorada em quatro harnesses |

O critério de pronto da v1 é literal: **`pbuild` constrói o que o `Makefile` e o
`tests/psbuild.sh` constroem hoje, e o `verify-all` passa 8/8 usando-o**. Não é
"um build de brinquedo que compila hello.c" — é o build deste repositório, que é
o mais difícil que existe à mão (o `verify-all` compila o compilador quatro vezes
e compara bytes).

Consequência boa: enquanto o pbuild não fizer isso, o `Makefile` continua sendo a
verdade. Os dois conviverão, e o dia em que o pbuild passar a escada é o dia em
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
menor que `ps_lower.p` sozinho: o pbuild não é um projeto grande, é um projeto
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
  que o pbuild deve copiar — não dois programas, dois modos de um.
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

## O balanço da independência (o que o pbuild tira do caminho)

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
arestas) ou o pbuild ganha uma primitiva própria.

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
| **jobserver** | protocolo de *job slots* do GNU make, para dividir o orçamento de paralelismo com um build pai (`jobserver.h`) | não agora; é o que se implementa no dia em que o pbuild rodar dentro de outro build |
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
`["cc","-c","a.c","-o","a.o"]` e o pbuild executa sem `/bin/sh`. O samurai usa
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
cresce; com isso, um `.psc` fica igual a um `.p` para o build, e o pbuild trata as
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
| **(b)** | hash de interface: recompilar quando a INTERFACE mudou | o compilador só precisa **dizer** o hash do `.h` que emitiu; o resto é do pbuild | compilador (1 linha de saída) + pbuild |
| **(c)** | pscript: o módulo vira uma TU (header gerado por módulo, público vs privado) | `ps_lower.p` inteiro, e o `psrt` | **maior das quatro; área do outro agente** |

Duas notas que a ordem deixa clara:

- **(a) e (d) são a mesma pergunta, uma em cada linguagem**: "o que atravessa um
  import?". Decidir as duas junto evita que o P responda uma coisa e o pscript
  outra — que é como o furo medido apareceu.
- **(b) não precisa de (a)**: ela vale já hoje, com as listas onde estão. É a
  única das quatro que rende os 18 s sem mexer em semântica de linguagem — o
  compilador só passa a imprimir o que já calculou.

## O protocolo: o que o compilador e o pbuild dizem um ao outro

Suas palavras: *"que legal, agora até mesmo o compilador e o pbuild vão se
conversar"*. Vale escrever a conversa, porque ela é curta — **quatro perguntas** —
e porque é aqui que se erra (linha 2 da tabela das outras linguagens: o build
crescendo dentro do compilador).

| o pbuild pergunta | o plangc responde | o que isso substitui |
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

1. **O compilador responde; o pbuild decide.** O que recompilar, em que ordem,
   com quantos processos, nunca é resposta do `plangc`. É o que separa isto de
   `ghc --make` e de `go build`, e é o que impede o cache do `plangc run` de
   virar um segundo sistema de build (hoje ele já é uma das seis listas).
2. **A resposta é a mesma, o transporte muda** (1.8): na mesma execução é uma
   chamada que devolve a estrutura; fora dela, uma linha por arquivo em stdout ou
   um JSON. O formato não é o mecanismo — foi essa confusão que deu ao ninja
   três formatos de arquivo para uma informação só.
