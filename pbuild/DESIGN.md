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

**1.2 Como um processo é rodado.** O `ps_run` do pstudio é síncrono e captura a
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

**1.4 O que decide "está velho".** mtime (como o Ninja) ou hash de conteúdo (como
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
