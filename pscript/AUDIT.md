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
| 6.3 | `pscript run x.ps` + cache de compilação | **FALTA** — hoje é `plangc x.psc` mais o `cc`; não há subcomando `run` nem cache |
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

## O que precisa de DECISÃO sua (não implementei, não decidi)

**A. `print` de um contêiner.** Hoje `print([1, 2, 3])` é "str() of list<int> is
not compiled yet". A 44.3 decidiu o repr derivado de `struct`/`record`/`enum`,
e não falou de contêiner. O Python imprime `[1, 2, 3]` e `{'a': 1}` — o que
arrasta decisões (aspas nas strings de dentro, `{}` de dict versus de set, repr
de float dentro do contêiner). É promessa pública: fica para você.

**B. Tupla no pscript: terminar ou tirar.** A 3.2 diz primeira classe, a 38.2 diz
imutável, a 54.4 deu a sintaxe do tipo — e o que existe é o tipo e o literal
parseando, sem `len`, sem índice, sem `a, b = f()`. Do P as tuplas foram
REMOVIDAS a seu pedido; no pscript o estado é meio caminho, que é o pior dos
dois. As saídas são terminar (desempacotamento e retorno múltiplo, que é o que a
3.2 prometeu) ou tirar e ficar com `record` para retorno de duas coisas.

**C. A 4.2 e a 7.1 estão vencidas no papel.** O coletor é copiador e a string é
UTF-8 com índice sob demanda — as duas decisões certas, tomadas depois, em
baterias que não riscaram as linhas antigas. É edição de documento, não de
código, mas quem ler o DESIGN de cima para baixo lê o contrário do que roda.

**D. `pscript run` (6.3).** Decidido, não existe. Hoje se compila com `plangc` e
se linka com o `cc` à mão (é o que o `tests/psbuild.sh` faz). O subcomando e o
cache de compilação continuam abertos.
