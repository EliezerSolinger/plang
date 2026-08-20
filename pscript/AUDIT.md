# Varredura da especificação — o que está implementado, e o que não está

Pedido seu, na bateria 88: *"alem disso veja se implementamos toda a
especificacao"*. Na hora, a resposta foi parcial: os corpora de fora mediram o
que eles medem (JSON, HTTP, URL) e os oráculos mediram o que o Python e o node
sabem responder. Nenhum dos dois lê o DESIGN. Este arquivo lê.

**Como funciona.** Uma linha por decisão numerada do `DESIGN.md`, com um
veredito conferido — não lido:

| marca | significado |
|---|---|
| **OK** | implementado, e há teste que reprova se sair do ar |
| **ok** | implementado, conferido à mão aqui, sem portão próprio |
| **REV** | revogada ou revisada por bateria posterior (a implementação segue a nova) |
| **FALTA** | decidida e NÃO implementada |
| **DIVERGE** | a implementação contradiz a decisão — bug, ou decisão a reabrir |

Uma linha **DIVERGE** ou **FALTA** que dá para fechar sem decisão nova é
fechada e a linha vira OK. As que precisam de decisão sua ficam listadas no fim,
como pergunta.

---

## Baterias 1 a 9 — identidade, tipos, dados, memória, erros, forma

| # | decisão | veredito |
|---|---|---|
| 1.1–1.4 | propósito, público, relação com o P, razão de existir | ok (não são código) |
| 2.1 | tipo inferido, sem anotar | **OK** — todo o corpus `tests/pscript/run` |
| 2.2 | `int` = `i64`, `float` = `f64`, larguras exatas disponíveis | **OK** |
| 2.3 | reatribuir com outro tipo é erro, salvo `any` | **OK** — `tests/pscript/bad/coerce` |
| 2.4 | `import` de `.ph` direto | **OK** — `tests/pscript/run/lib_*`, o porte do pstudio |
| 3.1 | `list` sem parâmetro é `list<any>` | **REV** pela 27.3 (literal homogêneo infere o elemento) |
| 3.2 | tuplas de primeira classe | **FALTA** (parcial: o TIPO `(int, int)` e o literal `(1, 2)` parseiam; `len`, índice e desempacotamento não existem) |
| 3.3 | contêineres próprios com cabeçalho de GC | **OK** — `PsList`/`PsDict`/`PsStr` no runtime |
| 3.4 | `s[3]` é o quarto CARACTERE | **OK** — conferido: `"áéíóu"[3]` é `ó` e `len` é 5 |
| 4.1 | literal sem anotação vira `list<any>` | **REV** pela 27.3 |
| 4.2 | coleta por rastreamento (mark-sweep) | **REV** — o coletor é COPIADOR (Cheney, semi-espaço), decidido nas baterias 15–17; a 4.2 nunca foi riscada |
| 4.3 | shadow stack explícita | **OK** — `ps_push_frame`, e o `gc-stress.sh` é o portão |
| 4.4 | `with` baixando para `defer` | **OK** — `tests/pscript/run/with_*`, `files`, `async_cleanup` |
| 4.4b | iteração de dict preserva ordem de inserção | **OK** — bateria 91, `dictorder.psc` + oráculo |
| 5.1 | um tipo de erro só, `try`/`catch e:` | **OK** — `errors.psc`; e `except` agora diz como se escreve |
| 5.2 | chave ausente e índice fora LANÇAM; `d.get(k, d)` não | **OK** — conferido |
| 5.3 | não existe `class` | **OK** — e agora o diagnóstico explica a decisão |
| 5.4 | fechamento com captura descartado | **OK** — `def` dentro de `def` é recusado com a razão |
| 6.1 | lambda sem ambiente | **OK** — `lambda.psc` |
| 6.2 | código solto no topo roda | **OK** — todo o corpus |
| 6.3 | `pscript run x.ps` + cache de compilação | **OK** — bateria 95 |
| 6.4 | indentação, lexer do P por `LexSpec` | **OK** |
| 7.1 | string de largura adaptativa (PEP 393) | **DIVERGE** — a string é UTF-8 inline com índice de offsets construído sob demanda (o `offs` do `PsStr`); mais simples que a 7.1 e resolve o mesmo problema, mas o DESIGN diz outra coisa |
| 7.2 | estouro de inteiro lança | **OK** — conferido, `9223372036854775807 + 1` lança |
| 7.3 | `1 + "2"` é erro | **OK** — mensagem manda escrever `str(x)`/`int(x)` |
| 7.4 | módulos reusam o do P | **OK** |
| 8.1 | f-string, comprehension, decorador e `set` entram | **OK** — as três comprehensions (lista, set, dict) fechadas nesta varredura |
| 8.2 | vive em `pscript/` no mesmo repo | **OK** |
| 8.3 | marco v0.1: pstudio reescrito em pscript | parcial — `make pstudio-ps` roda a lógica em pscript sobre um shim P (bateria 71) |
| 8.4 | suíte de `.psc` com saída esperada + testes de coletor | **OK** — `tests/pscript/run` + `gc-stress.sh` |
| 9.1 | quatro eixos de segurança de memória | **OK** — nulo (43.x/69), uso após liberação (coletor), cast que não reinterpreta (55.2), nada não-inicializado |
| 9.2 | a insegurança mora em P | **OK** |

---

## O que esta varredura FECHOU

**As três comprehensions.** A 8.1 prometeu comprehension e `set`; o que existia
era comprehension de LISTA, e as outras duas formas do Python não eram um erro
honesto:

  * `{x for x in xs}` **devolvia uma lista** — com as duplicatas que a chave
    de set existe para tirar. Silenciosamente: contagem certa para o
    contêiner errado, que é pior que recusar. O parser jogava fora QUAL
    fecho terminou a comprehension, então as duas formas de chave viravam a
    mesma coisa.
  * `{k: v for x in xs}` não parseava.
  * `[i for i in range(n)]` — a comprehension mais comum que existe — dizia
    "unknown function 'range'", porque `range` só era reconhecido no `for`
    statement. Agora é reconhecido pela FORMA nos dois lugares, que é o mesmo
    motivo: não há objeto range para guardar.
  * `[c for c in s]` sobre string também não ia; agora vai, e itera
    caracteres (72.3).

Portão: `tests/pscript/run/comprehension.psc` e o par do oráculo
`tests/oracle/py/collections`, que compara as três contra o Python.

**Nove diagnósticos que explicam uma decisão em vez de acusar um token.** Cada
palavra do Python que esta linguagem decidiu NÃO ter chegava ao parser como
identificador comum e saía como "expected end of line, found identifier" — que
não diz nada a quem veio do Python. Agora: `class` (5.3), `def` dentro de `def`
(5.4), `yield` e a expressão geradora (não há gerador), `del` (o dict remove com
`d.remove(k)`), `except` (aqui é `catch`), `else` de laço, comparação em cadeia
(`0 <= i < n`, que lida da esquerda para a direita compararia bool com número) e
desempacotamento de atribuição. Cada uma é reconhecida pelo que VEM DEPOIS, então
`del = 3` continua sendo uma variável chamada `del` — e isso tem teste.

Portão: onze programas em `tests/pscript/bad/py_*`.

---

## Baterias 10 a 72 — o que a varredura conferiu (segunda passada)

Aqui a varredura passou a conferir por PROVA: um programa que exercita a
decisão, compilado e rodado. O que está OK abaixo foi visto funcionando.

| # | decisão | veredito |
|---|---|---|
| 10.x, 11.x, 12.1–12.2 | `unsafe` e a fronteira | **ok** — a regra da 31.1 é o que a sema aplica |
| 11.3 | sair de `any` é checado | **OK** — `xs[1] as int` sobre um str lança "this `any` holds str, not int" |
| 12.4 | falha em pscript é exceção, em C é crash | **OK** — bateria 94: o handler imprime a pilha do pscript e morre igual |
| 13.2–13.4 | caixa opaca, `char*` copia, NUL de cortesia | **ok** |
| 14.2 | gatilho por bytes E por objetos | **OK** — e proporcional ao vivo desde a 90.2 |
| 14.3 | arena com bump | **OK** |
| 14.1 | cache de UTF-8 pendurado na string | **REV** — a forma NATIVA é UTF-8 (51.2); o que existe é o índice de offsets, construído sob demanda |
| 15.1, 23.1 | copiador de semiespaço (Cheney) | **OK** — `gc-stress.sh` |
| 15.2 | erro com mensagem, categoria e posição | **OK** — a pilha entrou na bateria 94 |
| 15.3, 16.2, 6.3, 50.3 | `pscript run` com cache | **OK** — bateria 95: cache de conteúdo com manifesto, 2,9s a frio e 4ms depois |
| 16.4 | o runtime é fonte P compilada junto | **OK** — `tests/psbuild.sh` é a receita |
| 17.1, 34.1, 49.4 | shadow stack de ENDEREÇO, com faixa, frame por função | **OK** |
| 17.3 | `xs[2:5]` é cópia | **OK** |
| 17.4 | `async` entra; gerador fica fora | **OK** — e agora o `yield` diz isso |
| 18.1, 22.3, 35.x, 36.x | workers isolados, canal, join | **ok** — `spawn`, `send`/`recv`, `detach` |
| 18.4, 22.3, 36.2 | `epoll`/`kqueue`, NÃO `poll()` | **OK** — bateria 102, destravada pelo `const if` da 99. O `kqueue` não foi rodado (esta máquina é Linux) e o `poll` fica como caminho de terceira plataforma |
| 19.2, 20.3, 28.1–28.3 | função como valor, lambda, captura por valor, decorador | **OK** |
| 19.3, 22.4 | exceção guardada na task e relançada no await | **OK** — `tests/oracle/js/promise` |
| 20.x, 21.x, 52.1, 57.1, 58.2 | `struct` por origem, `record` valor com método | **OK** — `record` recusa método sem `in self`, com a razão |
| 22.2 | `==` conteúdo, `is` identidade | **OK** |
| 24.x, 25.x, 38.1 | chave por conteúdo, agregado mutável não é chave | **OK** |
| 26.x, 31.2 | `nogc:` com orçamento, `await` dentro é erro | **OK** — `nogc(65536):` roda; a grafia `64k` do texto não existe |
| 27.3 | literal homogêneo infere o elemento | **OK** |
| 29.x | tipo de função, `any` e `def` separados, `as def(...)` | **ok** |
| 32.1–32.3 | `int + float` promove, ÷0 lança, `id(x)` | **ok** |
| 33.3–33.4, 60.x | `T[N]` como tipo completo, `in` para atravessar | **ok** |
| 34.2 | rastro de pilha `em f (arq.psc)` | **OK** — bateria 94; a LINHA por frame não (custaria uma escrita por chamada), e a função sem frame só aparece com `-g` (bateria 100) |
| 39.1 | divisão do Python (`/` dá float, `//` piso) | **OK** — oráculo `py/arith` |
| 39.4 | top-level await | **OK** |
| 40.1 | truthiness só de bool e `T?` | **OK** — `if 1:` é recusado com a razão |
| 40.3, 62.1–62.3 | protocolo de iteração, `Iterable` com tipo associado | **OK** — `implements Iterable` + `type Item = int` roda |
| 41.x, 42.x | json, regex, namespace, `shared` | **OK** |
| 43.x | narrowing, `??`, `?.`, `?[i]`, `finally` | **OK** |
| 44.1–44.2 | default por chamada, `*args` com splat | **ok** |
| 44.3 | `print(rect)` mostra `Rect(x=1, y=2)` | **OK** — e `Printable.to_str()` sobrepõe; o repr de CONTÊINER entrou na bateria 97 |
| 45.1 | f-string com formato | **OK** |
| 45.2 | walrus e fatia com passo | **OK** — o walrus FECHADO nesta varredura (era "parsed but not compiled") |
| 46.4 | `assert` strippable por flag de build | **OK** — `-O`/`--no-assert`, bateria 93 |
| 47.1–47.3 | float como chave por bits, `1.0/0.0` lança, literais | **ok** |
| 47.4, 89.x | case Unicode com tabela embutida | **OK** — conferido contra o Python em 1.114.112 pontos |
| 48.1–48.3 | arquivo Python-like, `sleep`/`timeout`/`interval`, `sys` | **OK** |
| 49.1–49.3 | pipeline, exceção por flag, ctx explícito | **OK** |
| 50.1 | async retoma por `match(state)` | **OK** |
| 51.x | `interval` com `tick()`, `str` inline, float boxa | **OK** |
| 54.1 | `%+`/`%-`/`%*` modulares | **OK** — `x %* 2685821657736338717` roda |
| 54.2–54.3, 55.1–55.4 | construtor, `raise`, `as`, `in` | **OK** |
| 59.x, 62.4 | `pack`/`unpack` de record | **OK** |
| 61.1 | continuação só por parênteses | **OK** — `\` é recusado (a mensagem podia nomear a 61.1) |
| 61.3 | `const` em referência congela fundo | **OK** — bateria 96: const de módulo que precisa ser construído, e o congelamento fundo (append/escrita indexada recusados) |
| 61.4 | `for k in d`, `items`/`keys`/`values`, `x in list`, `"ab" in s` | **OK** — as três views FECHADAS nesta varredura |
| 33.4, 60.2 | `T[N]` local/parâmetro/campo, e `in` para atravessar | **OK** — quatro defeitos consertados (93 e 96b: o tamanho vindo de um `const` emitia array sem tamanho) (atribuição indexada era escrita selvagem, local com literal não compilava, `in` sobre array não compilava) |
| 49.2 | exceção por flag, checada por chamada | **OK** — bateria 94: o ZERO de um tipo coletado passou a ser objeto vazio, porque NULL no meio de uma expressão era segfault |
| 62.1 | `Comparable` para ordenação custom no `sorted` | **OK** — bateria 93 |
| 62.1 | `Sequence<T>` como tipo de parâmetro | **FALTA** — não parseia |
| 63.x | `embed`, `embed_bytes`, template com `render` | **OK** |
| 64.1 | escopo de BLOCO nas duas linguagens | **OK** |
| 65.10 | `const def` (função de comptime) | **FALTA** |
| 65.11 | comptime `is_defined`/`typestr`/`hasfield`/`__FILE__` | **OK** — bateria 93 |
| 65.12 | `out`/`ref` no pscript | **OK** — bateria 93, palavras contextuais |
| 66.x, 67.x, 72.5 | traits nominais, despacho pelos dois lados, regra órfã | **OK** |
| 68.x, 69.x | as levas "decidido e feito" | **OK** |
| 72.1–72.4, 72.6 | `ord`/`chr`, substring, `for ch in s`, constantes de C | **OK** |
| 87.2 | `Task<Task<T>>` não achata | **OK** — portão nesta varredura |
| 87.1 | trait `Awaitable` | **FALTA** — e o que falta é decidir `Poll`/`Waker`, não digitar |
| 88.x, 89.x, 90.x, 91.x | corpora, oráculos, Unicode, orçamento, ordem do dict | **OK** |

## O que esta varredura FECHOU na segunda passada

**`d.items()`, `d.keys()`, `d.values()` (61.4).** Não existiam — o dict tinha
`get` e `remove`. Agora `keys()` e `values()` devolvem uma LISTA em ordem de
inserção (uma cópia: uma vista dentro de um objeto que se move é ponteiro
interior, que é o que a 17.3 recusa), e `items()` existe só onde o Python o usa,
como o que um `for k, v in ...` percorre. Como VALOR ele teria de ser uma lista
de PARES, e a tupla está meio construída (3.2) — então a mensagem diz isso em
vez de prometer um tipo que ninguém consegue segurar.

**O walrus (45.2).** Estava "parsed but not compiled yet". O que faltava não era
o nó: era decidir o que fazer nos dois lugares onde hoistar muda o significado.

  * **Condição de laço.** A ligação hoistada cai na frente do `while`, então
    rodaria UMA vez onde a condição roda toda volta. Agora um `while` cuja
    condição hoista qualquer coisa vira `while True:` com a ligação e o teste
    DENTRO — e é isso que faz `while (line := next()) != "":` significar o que
    o Python significa. O mesmo conserto arrumou a comprehension em condição de
    laço, que era o mesmo defeito esperando.
  * **Operando preguiçoso** (braço de ternário, direita de `and`/`or`): RECUSADO,
    porque não há reescrita que preserve a preguiça e a ligação ao mesmo tempo.

**Dois defeitos que ele desenterrou, e que não eram do walrus:**

  1. **`for k in d:` dentro de um `async def` CRASHAVA.** O laço de dict
     declarava um local com o nome da variável, mas dentro de uma máquina de
     estados esse nome é CAMPO DO FRAME — então o corpo lia um campo que nada
     escreveu. O laço de string ao lado (`for ch in s`) estava certo desde
     sempre: honrava o frame. Agora os dois honram, e o de pares também.
  2. **Uma condição de `if` dentro de um `async def` DESCARTAVA o que ela
     hoistava.** O construtor de estados chamava o lowering da condição e nunca
     esvaziava o `pre`, então uma ligação (ou uma comprehension) na condição
     desaparecia em silêncio. `if (r := await f()) > 0:` testava um campo que
     nada tinha escrito.

Portões: `tests/pscript/run/dictviews.psc`, `tests/pscript/run/walrus.psc` (os
dois com metade async, que é onde os defeitos moravam), três programas em
`tests/pscript/bad/` para o que continua recusado, e o par do oráculo
comparando `items`/`keys`/`values` e o walrus contra o Python.

## O que precisa de DECISÃO sua (não implementei, não decidi)

**A. `print` de um contêiner — RESPONDIDA (bateria 97) e implementada.** Como o
Python, com aspas nas strings de dentro. Confere caractere por caractere contra
o Python no par `tests/oracle/py/collections`.

**B. Tupla no pscript — RESPONDIDA (terminar, bateria 98) e implementada, menos
a parte que é do coletor.** Índice, `len`, chave de dict, imutabilidade e `a, b =
1, 2` entraram (98.4). O que falta é a tupla que guarda uma referência (`(str,
int)`), que é o que `d.items()` como valor precisa — e é pergunta sobre o
coletor, não sobre a tupla. Fica o registro do que estava pela metade: A 3.2 diz primeira classe, a 38.2 diz
imutável, a 54.4 deu a sintaxe do tipo — e o que existe é o tipo e o literal
parseando, sem `len`, sem índice, sem `a, b = f()`. Do P as tuplas foram
REMOVIDAS a seu pedido; no pscript o estado é meio caminho, que é o pior dos
dois. As saídas são terminar (desempacotamento e retorno múltiplo, que é o que a
3.2 prometeu) ou tirar e ficar com `record` para retorno de duas coisas.

**C. A 4.2 e a 7.1 estão vencidas no papel.** O coletor é copiador e a string é
UTF-8 com índice sob demanda — as duas decisões certas, tomadas depois, em
baterias que não riscaram as linhas antigas. É edição de documento, não de
código, mas quem ler o DESIGN de cima para baixo lê o contrário do que roda.

**D. `epoll`/`kqueue` (18.4) — RESPONDIDA (o P ganhou `const if`, bateria 99) e
implementada (bateria 102).** Fica o registro do que estava travado: O loop chama `poll()`, que é textualmente o que a decisão recusou. Só
que escrever os dois back ends exige escolher entre eles no C EMITIDO — o seed é
gerado numa máquina e compilado noutra (você compila no macOS), então a escolha
não pode ser feita na hora de gerar. E o P não tem compilação condicional: não há
como emitir `#if defined(__APPLE__)`. As saídas são (a) o P ganhar uma forma de
condicional de plataforma, (b) ficar no `poll()` e riscar a 18.4, ou (c) um
terceiro mecanismo (uma tabela de ponteiros escolhida em tempo de execução, com
os dois compilados sempre — o que exige os dois headers presentes em todo lugar,
e não estão). É decisão sua, e por isso não escrevi nada.

---

## O que a varredura FECHOU na terceira passada (ver a bateria 93)

`sorted(xs, key=len)` (28.4) e `sorted` por `Comparable` (62.1), com o sort dos
índices trocado de inserção O(n²) para merge sort estável; o comptime da 65.11
(`__FILE__`, `__LINE__`, `__func__`, `__COUNTER__`, `is_defined`, `typestr`,
`hasfield`); o `-O`/`--no-assert` da 46.4, com o mecanismo de `<nome>.flags` que
dá portão a uma flag; `out`/`ref` da 65.12 como palavras contextuais; e três
defeitos do `T[N]` (33.4/60.2) que só apareceram porque alguém escreveu o teste:
atribuição indexada em array era escrita selvagem pelo caminho de lista, array
local com literal não compilava, e `in xs: T[N]` não compilava.

## O que está DECIDIDO, não implementado, e não precisa de decisão nova

Ordem de valor, na minha leitura — nenhum destes precisa de bateria, só de
trabalho:

1. **`Sequence<T>` como parâmetro (60.3/62.1)** — a trait do sistema que está
   declarada e não serve para o que foi declarada.
2. **`const def` (65.10)** — função avaliada em compilação.
3. ~~`const` de contêiner no topo do módulo (61.3)~~ — FECHOU na bateria 96.
4. **A LINHA por frame no rastro (34.2).** Hoje um frame diz a função e o
   arquivo; a linha exigiria uma escrita por instrução que contém chamada. É
   trabalho pequeno com custo mensurável, e vale medir antes.

O `epoll` saiu desta lista porque não é trabalho: é decisão (ver **D** abaixo).

Também registrado, achado ao conferir: `ps_type_str` imprime `int[]` para
`int[3]` — o tamanho do array não aparece na mensagem de erro.
