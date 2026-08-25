# pscript — inventário de recursos (v0.1)

Derivado das baterias de `DESIGN.md`. Cada recurso aponta a decisão que o criou, onde o
smallpt o exercita, e **em que pé está a implementação**.

O programa de validação da 52 é o smallpt. Ele existe em três formas no repositório, e
as três entram na bateria de testes nos três modos (C, QBE, C89):

| Arquivo | O que é |
|---|---|
| `examples/smallpt_core.psc` | o render em uma thread; grava o PPM |
| `examples/smallpt_workers.psc` | o mesmo render, uma thread por worker |
| `examples/smallpt_full.psc` | **o programa inteiro**: CLI, cena JSON, workers escrevendo num buffer compartilhado, PPM, estatísticas |
| `examples/smallpt.psc` | o ALVO original, escrito antes da implementação — continua sendo a referência do que falta |

Legenda do estado: **✅** implementado e com teste que prende; **◐** implementado em
parte (o que falta está dito); **⏳** decidido no design, ainda não implementado.

## Tipos e inferência

| Recurso | Decisão | Exercitado em | Estado |
|---|---|---|---|
| Inferência sem anotação (`x = 1`) | 2.1 | todo o programa | ✅ |
| `int`=`i64`, `float`=`f64` | 2.2 | tudo | ✅ |
| larguras exatas (`i8`…`u64`, `f32`) | 2.2, 65.14, 68.2 | `u64` no RNG (bate bit a bit com o Python) | ✅ literal adapta; alargamento implícito; estreitar confere; `%+ %- %*` mascaram |
| Tipo fixo por variável; `any` é o opt-in | 2.3 | — | ✅ |
| `any` checado na saída: `x as T` lança se errado | 11.3, 55.2 | `load_scene` (JSON→tipos) | ✅ |
| `any` como ponteiro para objeto com cabeçalho | 39.2 | JSON inteiro | ✅ |
| `any` e `def` separados | 29.3 | tabela de tone maps | ✅ |
| `def` sem assinatura, estreitado com `as` | 29.3, 29.4 | `Dict<str, def>` no teste `wide_def` | ✅ o valor carrega seu descritor; `as def(...)` confere e lança |
| `T?` não-nulo por padrão | 9.4 | `re.match` devolve `List<str>?` | ✅ |
| Narrowing por fluxo (`if x != None:` → `x: T`) | 43.1 | parse de `--dim` | ✅ (`if` e `while`) |
| Truthiness só de `bool` e `T?` | 40.1 | condições | ✅ |
| `??` | 43.2 | `sys.env.get(...)` | ✅ |
| `??=` | 43.2 | `coalesce_eq` | ✅ inclusive sobre elemento (`d[k] ??= v`), com o índice avaliado uma vez |
| Promoção int→float | 32.1 | aritmética da câmera | ✅ |
| `**` (int→int; float→float) | 47.3 | Schlick, gama | ✅ |
| Divisão Python: `/` float, `//` piso, `%` divisor | 39.1 | `amostras // 4` | ✅ (int e float) |
| Estouro de int lança | 7.2 | — | ✅ |
| Wrap explícito `%+ %- %*` | 54.1 | RNG | ✅ |

## Dados

| Recurso | Decisão | Exercitado em | Estado |
|---|---|---|---|
| `record` = tipo de VALOR | 52.1, 56 | `Vec`, `Ray`, `Sphere`, `Stat` | ✅ |
| record aninhado em record | 21.1 | `Ray` contém `Vec` | ✅ |
| enum como campo de record | 29.2, 53.2 | `Sphere.kind` | ✅ |
| `struct` coletada, com métodos e mutação | 20.1 | iteradores | ✅ |
| `tuple` imutável, desempacotamento | 3.2, 38.2 | — | ✅ (de bytes puros) |
| `T[N]` array fixo (opt-in) | 33.4 | — | ✅ |
| `List<T>` tipado; literal infere | 27.3 | cena, workers, stats | ✅ |
| fatia de lista (cópia, clamp) | 17.3 | `sys.argv[1:]` | ✅ |
| `Dict<K,V>`; chave por conteúdo | 4.x, 38.1 | JSON, `sys.env` | ✅ |
| `Set` + `in`/`not in` | 8.1 | — | ✅ |
| `str` imutável; `len` em codepoints | 31.3, 3.4 | tudo, e o buffer do editor | ✅ com `ord`/`chr` (a porta entre caractere e codepoint); `x in s` (substring) e `for ch in s` ainda não |
| índice O(1) em `s[i]` e fatia | 7.1, 80.1b | `str_index` | ✅ ASCII direto (`nchars == len` já prova); não-ASCII ganha um índice de deslocamentos construído sob demanda e coletado com a string. NÃO é o PEP 393: guardar UCS-4 obrigaria a materializar UTF-8 em toda travessia (socket, arquivo, mensagem, fronteira), que é por que o próprio PEP guarda as duas formas |
| `s[i]` por caractere; índice negativo; fatia | 3.4, 31.4, 17.3 | parse de `--dim` | ✅ |
| Iteração pelo protocolo `has_next()`/`next()` | 40.3 | — | ✅ (sobre `struct` que implementa `Iterable`) |
| `==` conteúdo / `is` identidade | 22.2 | — | ✅ — e `<` `>` `<=` `>=` entre strings também comparam CONTEÚDO (comparavam ponteiro; achado do porte do editor) |
| enum igual ao P, `match` exaustivo | 29.2 | `match obj.kind:` | ✅ |
| Repr derivado (`Rect(x=1, y=2)`) | 44.3 | `repr` | ✅ record/struct/enum, aninhado, em `print`, `str()` e f-string; `to_str()` do tipo sobrepõe |

## Memória e GC

| Recurso | Decisão | Exercitado em | Estado |
|---|---|---|---|
| Coletor copiador (Cheney), bump alloc | 15.1, 23.1 | tudo que é coletado | ✅ |
| Shadow stack: frame de Henderson | 49.4, 17.1 | gerado | ✅ |
| Laço quente sem alocação | 52.1 | `radiance` inteira | ✅ |
| `with` para recurso determinístico | 4.4, 19.4, 68.4 | arquivo, buffer e `Closeable` seus | ✅ trait `Closeable` no prelúdio; cleanup roda com exceção pendente |
| typedesc por tipo do usuário | 50.2 | `struct` | ✅ (o compilador escreve o rastreio) |
| `nogc:` bloco sem coleta | 26 | `nogc` | ✅ com orçamento opcional (`nogc(64k):`) que LANÇA ao estourar; aninha por contador; `await` dentro é erro |
| Sem `__del__` | 4.4 | n/a | ✅ |

## Segurança

| Recurso | Decisão | Exercitado em | Estado |
|---|---|---|---|
| 4 eixos garantidos | 9.1 | o programa compila sem `unsafe` | ✅ |
| `unsafe` | 11-12 | — **medalha: o raytracer não precisa** | ⏳ precisa antes de um tipo PONTEIRO no pscript (é o que `unsafe` destrava); registrado no PLAN |
| Regra de fronteira: assinatura sem ponteiro = segura | 31.1, 45.5 | `sqrt`/`cos`/`sin`/`fabs` | ✅ |
| `import "x.ph"`: módulo P no mesmo build | 2.4, 75.3 | `pmodule` | ✅ o `.ph` é lido com o front-end do P, o `.p` irmão entra no build, e a baixada importa como P importa (a sema do P confere a chamada) |
| `const` record atravessa por REFERÊNCIA | 72.6 | `const_record` | ✅ tipo declarado no header (uma declaração só), lado P recebe `in` (const), argumento tem de ser um `const` de módulo — conferido no sítio da chamada |
| Falha pscript = exceção | 12.4 | try/catch | ✅ |

## Erros

| Recurso | Decisão | Exercitado em | Estado |
|---|---|---|---|
| Um tipo de erro; msg + categoria + posição | 5.1, 15.2 | `catch e:` + `e.category == IO` | ✅ categorias com NOME (enum `Category` do prelúdio) |
| Chave ausente / índice fora / ÷0 / estouro lançam | 5.2, 32.2, 47.2, 7.2 | acessos | ✅ |
| `try`/`catch`/`finally` + `defer` + `with` | 43.4 | main | ✅ (`finally` via `defer`) |
| Exceção atravessa `await` (guardada na task) | 19.3 | falha de worker | ✅ |
| `assert` strippable | 46.4 | dimensões e amostras | ✅ (a flag de strip ainda não existe) |
| `raise error(msg, cat?)` / `raise e` | 54.3 | — | ✅ |

## Funções

| Recurso | Decisão | Exercitado em | Estado |
|---|---|---|---|
| Função como valor | 28.1, 29.5 | tone map | ✅ |
| `lambda` com captura POR VALOR | 28.2, 19.2 | tone map capturando `gamma` | ✅ |
| `sorted(xs)` | 28.4 | `sortkey` | ✅ ordem natural e `key=` (a chave é computada uma vez por elemento) |
| Decorador | 28.3 | `decorators` | ✅ `@deco` e `@deco(args)`; `@memo` com cache compartilhado (22.5) |
| Default avaliado por chamada | 44.1 | `defaults` | ✅ `def f(xs=[])` dá lista nova a cada chamada; nomeados também, em função e método |
| Construtor tipo-chamada, posicional + nomeado | 54.2 | `Vec(...)`, `Sphere(rad=...)` | ✅ |
| `in` (leitura por referência, sem cópia) | 55.4, 56 | `hit_sphere(in s, in r)` | ✅ |
| `*args` | 44.2 | `varargs` | ✅ `*xs: List<T>` na declaração e `f(*ys)` no sítio da chamada (a lista passa inteira, sem cópia) |
| Escopo de BLOCO nas duas linguagens | 64.1 | tudo | ✅ |
| `global` / `nonlocal` | 55.3 | RNG, `shared` | ✅ |
| walrus `:=` | 45.2 | — | ✅ |
| Genérico com limite de trait (`def f<T: X>`) | 66.3 | — | ✅ |
| `trait` + `implement ... for` + regra órfã | 66, 67 | — | ✅ |
| `dyn Trait` (despacho dinâmico) | 66.3 | — | ✅ |
| Tipo associado (`type Item`) | 66.4 | — | ✅ |
| Traits do sistema (Comparable/Iterable) | 60.3, 62.1, 67.4 | — | ✅ (Printable só no P) |
| Sobrecarga de operador | **FORA (52.2)** | métodos `add`/`scale`/… | — |

## Concorrência

| Recurso | Decisão | Exercitado em | Estado |
|---|---|---|---|
| `spawn(fn, args)` = thread com heap e coletor próprios | 35.1, 18.1 | os workers do render | ✅ |
| Worker É o canal (`w.send` / `await w.recv`) | 36.1 | `Stat` de cada worker | ✅ |
| Mensagem POD por memcpy; o resto SERIALIZADO | 34.3, 74.2 | `workers_full`, `deep_messages` | ✅ bytes por memcpy; `str`, `List`, `Set`, `Dict` e `struct` atravessam como GRAFO — escritos de um lado, reconstruídos no heap de quem recebe, com guarda de ciclo (um objeto repetido chega como UM objeto; um que contém a si mesmo chega). O compilador deixa um `PsShape` por tipo; o runtime tem o formato |
| `await os.run(argv, env=, cwd=, stdout=)` -> `proc` | 118 | o motor do pforge | ✅ sem shell (o `execvp` recebe o vetor), stderr junto do stdout, status != 0 é resultado e não exceção, 128+sinal, `waitpid` no pool; `os.nproc` e `path.getmtime_ns` junto |
| HTTP/1.1 escrito em pscript | 77.2, 78.1 | `http_server`, `lib_http` | ✅ parser incremental (linha, cabeçalhos, content-length, chunked) com as recusas do llhttp; servidor e clientes no mesmo processo |
| Texto atravessa a fronteira (`CStr`/`CBytes`) | 81, 83, 84, 85, 86 | `text_boundary` | ✅ par {ponteiro, tamanho} que não aloca; ida sem cópia, volta com cópia e UTF-8 conferido; `in s: CStr` passa o endereço |
| `str.lower()` / `str.upper()` | — | `lib_http` | ✅ ASCII (caixa Unicode depende de língua) |
| Socket e DNS (`net`) | 77.1 | `net_socket` | ✅ `net.listen/connect/lookup`, `accept/read/write/close/port`; accept/read/write POLLED no mesmo `poll` do escalonador, connect e DNS no pool |
| Limpeza dentro de `async def` | 50.1, 80.2 | `async_cleanup` | ✅ `defer`, `with` e `finally` armam um bit no frame e rodam em toda saída de verdade — nunca numa suspensão (era bug: rodavam ao estacionar) |
| `try`/`catch` dentro de `async def` | 50.1 | `aio_files` | ✅ o guarda salta para o estado do catch |
| `gather_settled` / `first_ok` / `gather_map` | 79.4 | `async_sugar` | ✅ o limite de concorrência é `gather_map(f, itens, at_most=n)`, sobre os ITENS: com começo quente um limite no `gather` chegaria depois de todas começarem |
| `async def` como VALOR | 28.1, 35.3 | `async_sugar` | ✅ o símbolo por trás é a função de partida, que já devolve uma task |
| Bloco `async:` e `async lambda` | 78.3 | `async_sugar` | ✅ os dois viram `async def` cujos parâmetros são a captura; o lambda assíncrono é um lambda comum que chama esse `async def`, então a máquina de estados e o ambiente de captura continuam separados |
| `aprint`, `sys.out`, `sys.err` | 78.2 | `async_sugar` | ✅ `print` segue síncrono; `close()` num stream padrão é no-op |
| I/O de ARQUIVO pelo pool de threads | 76.1, 76.3 | `aio_files` | ✅ um pool por processo, preguiçoso (N=núcleos, teto 8, `PSCRIPT_POOL`); a thread do pool só toca o item malloc'ado e a libc, e quem constrói o valor no heap é o escalonador de quem pediu |
| Todo I/O é aguardável | 76.2, 79.1, 79.2 | `aio_files`, `files` | ✅ `await open/read(n)/read_all/text/readlines/write/close`; `read(n)` dá até n bytes e vazio é fim; `text()` valida UTF-8 |
| Método `async def` | 50.1 | `aio_files`, `pstudio/ps` | ✅ é função com receptor: `self` mora no frame como qualquer parâmetro |
| Entrada de worker `async def` | 76.1 | `smallpt_full` | ✅ a thread tem escalonador próprio e dirige a própria entrada, como o topo |
| `try`/`catch` dentro de `async def` | 50.1 | `aio_files` | ✅ o guarda salta para o estado do catch, então erro nascido DEPOIS de suspender ainda é pego. `with`/`defer`/`finally` em volta de await: ainda não |
| Laço drena no fim; `await` cede sempre | 77.3, 78.4 | `loop_drain` | ✅ task órfã termina; awaits que sempre acham resposta pronta intercalam |
| `await w.recv()` ESTACIONA | 74.1, 18.4 | `recv_parks` | ✅ receber é uma task sem passo, como o timer: o escalonador espera nos DESCRITORES das filas (pipe por direção) com o prazo mais próximo como timeout, então mensagem e relógio convivem |
| `send` para worker morto devolve `bool` | 45.3 | — | ✅ |
| `async`/`await`; task quente; await no topo | 17.4, 35.3, 39.4 | `cancel_race` | ✅ e o `await sleep()` ESTACIONA: duas tasks se intercalam de verdade (antes o timer parava a thread e uma rodava inteira antes da outra) |
| `gather` | 35.3 | — | ✅ |
| `interval` + `await t.tick()`; `sleep`; `timeout` | 48.2, 51.1 | `interval`, `cancel_race` | ✅ os três, sobre a fila de deadlines do escalonador; `timeout` cancela o perdedor |
| `status(id)` | 37.3 | `timers` | ✅ RUNNING/DONE/ERROR/GONE |
| Erro de worker vira estado + mensagem | 37.4, 68.8 | `w.error()` no teste de timers | ✅ o pai colhe o `Error` completo; colher silencia o stderr do join |
| Join implícito de todos os workers; `detach` | 36.3 | `workers_full` | ✅ espera todos por padrão; `w.detach()` marca o descartável — nada é morto no meio |
| Global mutável = privado do worker | 42.2 | RNG por worker | ✅ |
| `shared` var (lock por variável, composto atômico) | 42.1, 42.3 | `shared`, `workers_full` | ✅ número, `record` e `str` (a escada de cópia da 42.1 inteira) |
| `shared dict` (ETS) | 42.1 | `shared_dict` | ✅ tabela fora dos heaps, lock próprio, chave/valor na escada de cópia (str inclusive) |
| Buffer compartilhado | 19.4, 52.3 | o framebuffer, `workers_full` | ✅ e o CABEÇALHO saiu do heap coletado: outra thread segura esse ponteiro, e um coletor que move não pode ser dono dele |
| Vista tipada do buffer (`view_f64()`) | 18.3 | `views` | ✅ `view_f64/f32/i64/i32/u8` — mesma memória, sem cópia; a vista não cresce |
| `Channel<T>(n)` entre TAREFAS | 147, S3 | `chan` | ✅ anel de capacidade explícita (sem o encontro à Go), `await ch.send`/`await ch.recv`, `open()`, `len()`, `close()`. Não serializa nada — o valor que sai é o mesmo ponteiro que entrou — e não é sondado: um `send` que acha um receptor parado escreve no quadro dele e põe-no nos prontos. `recv()` dá `T?`, e None é o fim (147.1) |
| `with taskgroup() as g:` | 147.4, S3 | `taskgroup` | ✅ `g.spawn(t)` dentro de `for`/`if`; a saída espera por todas, e a primeira FALHA cancela as irmãs. Não recolhe valores (isso é o `gather`): as três garantias são sobre TEMPO DE VIDA. Só existe dentro de um `with` — fora dele não há bloco a que nada possa sobreviver |
| `sched.stats()` | S3 | `taskgroup` | ✅ `Dict<str, int>` com `ready`, `parked` e as quatro razões (`parked_deadline`/`_message`/`_descriptor`/`_pool`), o pool e os workers por estado. É o item 44 da interseção, e apanhou um defeito no primeiro dia (147.7) |
| `transfer` / `race` / cancelamento cooperativo | 18.2, 37.2, 36.4 | `cancel_race`, `workers_full` | ✅ `t.cancel()` LANÇA no próximo passo da task (o `defer` desenrola); `race` fica com o primeiro e cancela o resto; `transfer` entrega os bytes e invalida a referência de quem enviou |

## O porte do editor (bateria 71)

O pstudio foi portado para pscript em `pstudio/` — buffer, aplicação e
desenho em pscript, com janela/eventos/pixels em P atrás de uma fronteira só de
escalares. Roda e está no gate (headless e com SDL dummy). Ver
`pstudio/README.md`.

| Recurso | Decisão | Exercitado em | Estado |
|---|---|---|---|
| método enxerga variável de módulo | 42.2 | `method_globals` | ✅ (era bug: passagens fora de ordem) |
| assinatura resolvida antes de qualquer chamada | 41.3 | `modules` | ✅ (era bug: resolvia ao checar o corpo) |
| tipo do campo como contexto do valor | 54.2 | o editor inteiro | ✅ |
| `ord` / `chr` | — | `ordchr`, o desenho de todo glifo | ✅ **a confirmar por você** (não havia decisão; sem eles o porte parava) |

## A caixa (`stdlib`, `crypto`) — as fases S0–S4

| pacote | fase | portão | Estado |
|---|---|---|---|
| `codec` — base64 (as 4 variantes) e hex | S2 | `codec/test` | ✅ descodificar aceita os dois alfabetos e com ou sem `=`; recusa bits a sobrar num resto, que é como duas entradas dariam o mesmo valor |
| `hash` — CRC32, SHA-1, MD5 (em P) | S2 | `hash/test` | ✅ vectores oficiais, e o ficheiro diz de si próprio o que vale: o CRC32 é uma soma de verificação e os outros dois estão PARTIDOS — estão ali para LER o que já existe |
| `hmac` — HMAC-SHA256 (em P) | S2 | `hmac/test` | ✅ RFC 4231, e `hmac_equal` compara em tempo que não depende de ONDE os dois diferem. Genérico sobre um trait `Hash`: **atrás da 141.6** (148.1) |
| `csprng` — `/dev/urandom` | S2 | `tests/pscript/run/tempfile` | ✅ e **falha em vez de recuar** para o MT19937 |
| `os.tempdir/tempfile/tempdir_new` | S2 | `tempfile` | ✅ as duas últimas CRIAM, com `O_EXCL` e 0600 (0700 no directório): devolver um nome que ainda não existe é a corrida do `mktemp` |
| `datetime` — o modelo do `java.time` | S4 | `datetime/test` | ✅ o TIPO responde se tem fuso; `Duration` é exacto e `Period` não é; ISO 8601/RFC 3339, os TRÊS formatos de data do HTTP, `strftime`/`strptime`. 85 comparações contra o CPython, incluindo antes da epoch e a era de 2400 |
| `tz` — os fusos, lidos do SISTEMA | S4 | `tz/test` | ✅ TZif (RFC 8536) de `/usr/share/zoneinfo`, com a regra POSIX do rodapé para lá do fim do ficheiro. Não traz cópia: as regras mudam várias vezes por ano (149.2). Oráculo: o `zoneinfo` do CPython em 6 fusos × 6 instantes |
| metapacotes `stdlib` e `crypto` | S0 | `tests/pkg/meta` | ✅ `"kind": "meta"`: instala, não importa |
| `algo`, `random`, `path` como pacotes | S1 | — | ⏳ **ADIADA por decisão medida** — ninguém os consome fora dos testes (ver a adenda do `STDLIB.md`) |

## Módulos e stdlib

| Recurso | Decisão | Exercitado em | Estado |
|---|---|---|---|
| Namespace: `import x` / `from x import y` / `as` | 41.3 | — | ✅ (por renomeação; visibilidade do Python) |
| `private` = privado do módulo | 44.4 | — | ✅ (era `static`; a palavra ficou só para o método estático) |
| `include <h>` direto (C sem ponteiro = seguro) | 45.5, 7.4 | `include <math.h>` | ✅ |
| Docstring Python | 46.3 | módulos e defs | ✅ |
| `json.parse -> any` | 41.1, 68.6 | `--scene arquivo.json` | ✅ número segue o Python: literal inteiro vira int |
| Regex POSIX (ERE) | 41.2 | `--dim 800x600` | ✅ |
| `open()` + `with` | 48.1 | cena e PPM | ✅ (síncrono; o pool da 38.4 falta) |
| `sys.argv` / `sys.env` / `sys.exit` / `sys.time` | 48.3 | CLI inteira | ✅ |
| `math` (22 funções + `pi`/`e`/`tau`/`inf`/`nan`) | 103.1 | `stdmod`, `rng` | ✅ é a libm direta; `floor`/`ceil`/`trunc` devolvem **int** como no Python, `inf`/`nan` vêm do runtime (literal de C quebra o QBE) |
| `random` (MT19937) | 103.2 | `stdmod`, `rng` | ✅ **portado** de `_randommodule.c` + `Lib/random.py`: a mesma semente dá a MESMA sequência do Python, comparada número por número no oráculo. `seed`/`random`/`getrandbits`/`randint`/`randrange`/`uniform`/`gauss`/`expovariate`/`choice`/`shuffle` |
| `time.time` / `time.monotonic` | 103.2 | `stdmod` | ✅ dois relógios: parede (`CLOCK_REALTIME`) e monotônico (todos os prazos do laço) |
| `None if c else v` (um lado ausente) | 112.7 | `optref` | ✅ o resultado é `T?` — antes os dois lados tinham de ter o MESMO tipo, e escrever "pode faltar" numa expressão era impossível |
| Prova de não-nulo, cinco formas | 114 (43.1) | `narrow`, `narrowing` | ✅ `if x != None:`, a GUARDA (`if x == None: return` e o resto da função), o `else` de um `== None`, `x != None and x.f`, `x == None or x.f`, e cada ramo de um `elif`. Sempre em LOCAL — campo pede análise de fluxo sobre campos. **E uma condição prova TODAS as suas partes**: `if a != None and b != None:` estreita as duas (carregava um nome só até a S3 o cobrar). O que não prova continua a não provar — `or` com `!=` e `and` com `==` estão no corpus `bad` |
| Função em CAMPO, chamada direto | 112.2 | `fnfield` | ✅ `x.f(a)` quando `f` é campo de tipo função (28.1: valor vive em contêiner). Campo OPCIONAL sai para uma variável primeiro — a prova de não-nulo é sobre LOCAL (43.1), e a mensagem diz como |
| `os` / `path` (camada de sistema) | 111.1 | `syslayer`, `paths` | ✅ `os.listdir` (ORDENADO, 111.5) `mkdir`/`makedirs`/`remove`/`rmdir`/`rename`/`getcwd`; `path.join`/`dirname`/`basename`/`normpath`/`abspath`/`exists`/`isdir`/`isfile`/`getsize`/`getmtime` — o `posixpath` do CPython conferido por varredura (mil caminhos). Sem `chdir` (o cwd é do processo, o worker é thread); rodar processo é a 1.2 do pforge |
| `bisect` / `heapq` | 106.3 | `algos` | ✅ **portados** de `Lib/bisect.py` e `Lib/heapq.py`: o oráculo compara o ARRAY do heap passo a passo com o do Python. int, float e str |
| `sorted` ESTÁVEL nos três caminhos | 106.1 | `algos` | ✅ merge sort nosso com detecção de corridas; `qsort` deixava a estabilidade por conta da libc (a do macOS não é estável) |
| f-string com spec | 45.1 | tudo | ✅ |
| f-string **no P**, só em argumento de variádica | 65.2/119.1 | — | ✅ resolvida em compilação: vira formato + argumentos, sem alocar |
| `lambda` **no P**, sem captura | 65.4/119.2 | `lambda` | ✅ levantada para função `private` do topo; tipos vêm do contexto |
| Comprehension | 8.1 | — | ✅ também `for i, v in ...` (104) |
| `enumerate` / `zip` / `reversed` / desempacotar | 104.1 | `iterate`, `seqsugar` | ✅ AÇÚCAR sobre o laço de índice (não são valores); statement e comprehension |
| `sum` / `any` / `all` / `round` / `divmod` / `min`-`max` de lista | 104.2 | `toolkit` | ✅ bordas do Python: `all([])` é True, `round` é meio-para-o-par e devolve int, `min([])` levanta |
| Métodos de lista: `pop`/`extend`/`clear`/`copy`/`index`/`count`/`remove`/`sort`, `+`, `*` | 104.3 | `toolkit` | ✅ `xs += ys` estende NO LUGAR, como no Python |
| Métodos de dict: `pop`/`setdefault`/`update`/`clear`/`copy` | 104.3 | `toolkit` | ✅ |
| Set: `discard`/`update`/`clear`/`copy` e `\|` `&` `-` `^` `<=` `<` `>=` `>` | 104.3 | `toolkit` | ✅ ordem do resultado é a de INSERÇÃO (91.1), não a do hash |
| Métodos de str: `count`/`rfind`/`index`/`rindex`/`find(sub,start)`/`split()`/`splitlines`/`removeprefix`/`removesuffix`/`strip(chars)`/`ljust`/`rjust`/`center`/`zfill` | 104.3 | `toolkit` | ✅ índice em CARACTERES; `center` com a regra torta do CPython |
| `isalpha`/`isdigit`/`isdecimal`/`isnumeric`/`isalnum`/`isspace`/`isupper`/`islower`/`istitle`, `title`/`capitalize`/`swapcase` | 105 | `unicat`, `unicase2` | ✅ tabela de CATEGORIAS gerada do Python (`tools/gen_unicode_cat.py`, 27 KB, Unicode 15.0.0); oráculo varre TODO ponto de código. `casefold` fora (105.4) |
| `embed`/`embed_bytes` (comptime) | 63.1, 63.5 | `embed` | ✅ nas duas línguas; no pscript o binário vira `static` + memcpy, então um megabyte de fonte custa um megabyte de DADO |
| `pack`/`unpack` binário | 59, 62.4 | `packing` | ✅ denso, campos na ordem da declaração, **ordem de bytes por parâmetro** (LE por padrão, `BE` quando pedido); tamanho é o contrato |
| Template em arquivo | 63.2, 75.2 | `template` | ✅ `render("x.tpl")` (buracos contra o escopo) e `render("x.tpl", {"nome": quem})` (buracos são as CHAVES do literal, resolvidos em tempo de compilação, valores de tipos diferentes, chave faltando/sobrando é erro). Não existe modo com header: a 75.2 fechou por aqui |
| Import de `.ph` de P | 2.4 | — | ⏳ falta decidir como o módulo P entra no BUILD do programa pscript |

## Worker e async ao mesmo tempo (varredura 107)

| Situação | Estado |
|---|---|
| Entrada do worker sendo `async def` (e `await parent.recv()` lá dentro) | ✅ |
| `recv` dentro de uma task (não no topo), com outras tasks andando | ✅ 74.1 |
| Dois esperando a MESMA fila | ✅ FIFO: quem esperou primeiro recebe primeiro (107.5) |
| O pai acaba sem mandar nada | ✅ o canal FECHA e o `recv` termina — travava para sempre (107.1) |
| Os dois esperando um ao outro | ✅ declarado como travamento, com a checagem de que TODA espera está presa (107.1) |
| `print` de N workers ao mesmo tempo | ✅ uma linha é uma linha; gate em `tests/print-atomic.sh` (107.2) |
| `for` dentro de `async def` sem `await` no corpo | ✅ **dava 0 em silêncio** (107.3) |
| Erro de task que ninguém aguarda | ✅ linha no stderr, com posição (107.4) |
| `timeout`/`race`/`cancel`/`gather` sobre um `recv` estacionado | ✅ |
| socket e arquivo dentro de worker; worker aninhado; 64 workers | ✅ |
| `shared` sob contenção (800 mil incrementos, 12 threads) | ✅ exato |
| Coletor em estresse com mensagens atravessando | ✅ |
| Como o receptor sabe que o canal ACABOU | ✅ predicado: `parent.open()` / `w.alive()`, e `w.close()` para o pai dizer que acabou de mandar (107.8) |

## O que o smallpt completo NÃO usa, e por quê

`unsafe` e `nogc` (o programa não precisa — é o resultado desejado, não lacuna); import
de `.ph` (o pstudio cobre o outro lado); `?.` (não há cadeia opcional honesta aqui);
`finally` (o `defer` cobriu); `transfer`/`timeout`/`race`; fatia com passo; decorador;
float como chave. O que falta para o `smallpt.psc` ORIGINAL rodar sem adaptação está
listado no `PLAN.md` como **F2b**: `interval`/`sleep`, `sorted(key=)`, `*args` geral e
`status(id)`.
