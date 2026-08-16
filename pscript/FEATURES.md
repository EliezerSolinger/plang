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
| `def` sem assinatura, estreitado com `as` | 29.3, 29.4 | `dict<str, def>` no teste `wide_def` | ✅ o valor carrega seu descritor; `as def(...)` confere e lança |
| `T?` não-nulo por padrão | 9.4 | `re.match` devolve `list<str>?` | ✅ |
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
| `list<T>` tipado; literal infere | 27.3 | cena, workers, stats | ✅ |
| fatia de lista (cópia, clamp) | 17.3 | `sys.argv[1:]` | ✅ |
| `dict<K,V>`; chave por conteúdo | 4.x, 38.1 | JSON, `sys.env` | ✅ |
| `set` + `in`/`not in` | 8.1 | — | ✅ |
| `str` imutável; `len` em codepoints | 31.3, 3.4 | tudo, e o buffer do editor | ✅ com `ord`/`chr` (a porta entre caractere e codepoint); `x in s` (substring) e `for ch in s` ainda não |
| largura adaptativa / cache UTF-8 | 7.1, 14.1 | — | ◐ hoje UTF-8 com contagem de codepoints no cabeçalho, que É a forma de cache da 51.2; a largura adaptativa continua adiante |
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
| `*args` | 44.2 | `varargs` | ✅ `*xs: list<T>` na declaração e `f(*ys)` no sítio da chamada (a lista passa inteira, sem cópia) |
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
| Mensagem POD por memcpy; o resto SERIALIZADO | 34.3, 74.2 | `workers_full`, `deep_messages` | ✅ bytes por memcpy; `str`, `list`, `set`, `dict` e `struct` atravessam como GRAFO — escritos de um lado, reconstruídos no heap de quem recebe, com guarda de ciclo (um objeto repetido chega como UM objeto; um que contém a si mesmo chega). O compilador deixa um `PsShape` por tipo; o runtime tem o formato |
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
| `transfer` / `race` / cancelamento cooperativo | 18.2, 37.2, 36.4 | `cancel_race`, `workers_full` | ✅ `t.cancel()` LANÇA no próximo passo da task (o `defer` desenrola); `race` fica com o primeiro e cancela o resto; `transfer` entrega os bytes e invalida a referência de quem enviou |

## O porte do editor (bateria 71)

O pstudio foi portado para pscript em `pstudio/ps/` — buffer, aplicação e
desenho em pscript, com janela/eventos/pixels em P atrás de uma fronteira só de
escalares. Roda e está no gate (headless e com SDL dummy). Ver
`pstudio/ps/README.md`.

| Recurso | Decisão | Exercitado em | Estado |
|---|---|---|---|
| método enxerga variável de módulo | 42.2 | `method_globals` | ✅ (era bug: passagens fora de ordem) |
| assinatura resolvida antes de qualquer chamada | 41.3 | `modules` | ✅ (era bug: resolvia ao checar o corpo) |
| tipo do campo como contexto do valor | 54.2 | o editor inteiro | ✅ |
| `ord` / `chr` | — | `ordchr`, o desenho de todo glifo | ✅ **a confirmar por você** (não havia decisão; sem eles o porte parava) |

## Módulos e stdlib

| Recurso | Decisão | Exercitado em | Estado |
|---|---|---|---|
| Namespace: `import x` / `from x import y` / `as` | 41.3 | — | ✅ (por renomeação; visibilidade do Python) |
| `static` = privado do módulo | 44.4 | — | ✅ |
| `include <h>` direto (C sem ponteiro = seguro) | 45.5, 7.4 | `include <math.h>` | ✅ |
| Docstring Python | 46.3 | módulos e defs | ✅ |
| `json.parse -> any` | 41.1, 68.6 | `--scene arquivo.json` | ✅ número segue o Python: literal inteiro vira int |
| Regex POSIX (ERE) | 41.2 | `--dim 800x600` | ✅ |
| `open()` + `with` | 48.1 | cena e PPM | ✅ (síncrono; o pool da 38.4 falta) |
| `sys.argv` / `sys.env` / `sys.exit` / `sys.time` | 48.3 | CLI inteira | ✅ |
| f-string com spec | 45.1 | tudo | ✅ |
| Comprehension | 8.1 | — | ✅ |
| `embed`/`embed_bytes` (comptime) | 63.1, 63.5 | `embed` | ✅ nas duas línguas; no pscript o binário vira `static` + memcpy, então um megabyte de fonte custa um megabyte de DADO |
| `pack`/`unpack` binário | 59, 62.4 | `packing` | ✅ denso, campos na ordem da declaração, **ordem de bytes por parâmetro** (LE por padrão, `BE` quando pedido); tamanho é o contrato |
| Template em arquivo | 63.2, 75.2 | `template` | ✅ `render("x.tpl")` (buracos contra o escopo) e `render("x.tpl", {"nome": quem})` (buracos são as CHAVES do literal, resolvidos em tempo de compilação, valores de tipos diferentes, chave faltando/sobrando é erro). Não existe modo com header: a 75.2 fechou por aqui |
| Import de `.ph` de P | 2.4 | — | ⏳ falta decidir como o módulo P entra no BUILD do programa pscript |

## O que o smallpt completo NÃO usa, e por quê

`unsafe` e `nogc` (o programa não precisa — é o resultado desejado, não lacuna); import
de `.ph` (o pstudio cobre o outro lado); `?.` (não há cadeia opcional honesta aqui);
`finally` (o `defer` cobriu); `transfer`/`timeout`/`race`; fatia com passo; decorador;
float como chave. O que falta para o `smallpt.psc` ORIGINAL rodar sem adaptação está
listado no `PLAN.md` como **F2b**: `interval`/`sleep`, `sorted(key=)`, `*args` geral e
`status(id)`.
