# A stdlib do pscript — o plano

> Este ficheiro nasceu de `packages/runtimes-linguagens-nao-sistemas.md`, o
> levantamento dos nove runtimes não-de-sistemas e da interseção do que todos
> têm de fábrica. Ele responde à pergunta que esse levantamento faz: **o que é
> que a nossa stdlib vai ser, e o que é que vem na caixa.**
>
> As decisões abaixo foram tomadas pelo utilizador em **oito rondas de perguntas**
> (2026-08-24/25), pela regra 4 do `PLAN.md`. **Não ficou nada pendente** — o que
> começou por ficar em aberto (o dialecto do regex, o `bigint`, a capacidade do
> canal, o âmbito do canal) foi todo fechado nas rondas seguintes.
>
> Duas respostas não escolheram nenhuma das opções e **recusaram a pergunta**: a
> das categorias de erro (§4.2) e a do `bigint` (§5). São as duas decisões mais
> consequentes do ficheiro, e nenhuma delas estava nas minhas opções.
>
> Reserva a **bateria 145** no `DESIGN.md` para ligar a este ficheiro. Não é
> escrita lá directamente porque outro plano (o NIO, baterias 135–140) está a
> mexer no mesmo ficheiro ao mesmo tempo.

---

## 0. O índice das decisões

Oito rondas de perguntas. **Duas recusaram a pergunta em vez de escolher uma
opção, e são as duas mais consequentes do ficheiro.**

| # | decisão | onde |
|---|---|---|
| 1 | **metapacotes**: um metapacote INSTALA, não importa | §2 |
| 1 | escrever o que é viável (`compress` nosso); sistema só para o `tls` | §3 |
| 1 | **nenhum módulo inventa a sua concorrência** — zero threads, pools ou locks novos | §4.1 |
| 1 | `Channel`, `taskgroup` e `sched.stats()` entram; supervisor não | §4.1 |
| 2 | `datetime` no modelo do `java.time` — **o tipo diz se tem fuso** | §5 |
| 2 | computação de bits em laço apertado escreve-se em **P** | §3.1 |
| 2 | `Reader`/`Writer`: trait mínimo + funções livres | §5 |
| 2 | o metapacote data-se, os membros movem-se | §2 |
| 3 | ⚑ **o erro não é modelo de programação** — a pergunta foi recusada | **§4.2** |
| 3 | os métodos de conveniência do `File` **morrem** | §5 |
| 3 | `log` global (e a 42.2 torna-o um por worker, sem lock) | §5 |
| 3 | `test` por decorador `@test` | §5 |
| 4 | `tzdata`: o do sistema; o embebido é um pacote que se importa | §3 |
| 4 | `Channel` **não atravessa threads**; capacidade explícita, sem o caso zero | §4.1 |
| 4 | `assert` e `assert_eq` são **dois** | §5 |
| 5 | **motor de regex nosso** (RE2: tempo linear, sem retrocesso nem lookaround) | §5 |
| 5 | fica no runtime com o nome `re`; **a 105.4 REABRE** (entra o `casefold`) | §5 |
| 5 | a v1 não promete nada ainda — `0.x`, e o 1.0 sem pressa | §5 |
| 6 | o cliente HTTP leva as quatro peças (pool, redirecções, prazos, cookies+gzip) | §5 |
| 6 | `tls` verifica sempre; feixe do sistema; desligar tem nome feio | §5 |
| 6 | ⚑ **`bigint` é tipo da linguagem, não pacote** — a pergunta foi recusada | **§5** |
| 7 | `bigint`: tipo explícito, `int` promove, `/` dá float, a 7.2 fica intacta | §5 |
| 7 | o `psl` é pacote à parte, como o `tzdata` | §5 |
| 7 | o regex sai da S2 e vira **S2b** | §6 |
| 8 | **o P não tem plano de stdlib** — ganha uma como efeito lateral da regra dos bits | §3.1 |
| 8 | `datetime` lê três formatos (ISO-8601, `strftime`, RFC 7231) | §5 |
| 8 | `csprng` é pacote (ler `/dev/urandom` é um `open()`) | §5 |
| 8 | **`-Wmissing-doc`**: símbolo público da stdlib sem docstring é aviso | §5 |

**Nada disto está implementado.** É um plano.

---

## 1. Onde estamos, medido contra a interseção dos nove

A Parte 2 do levantamento lista **48 itens que os nove runtimes têm todos**.
Cruzados com o pscript de hoje:

### Temos, e alguns acima da média da tabela

| eixo | itens | estado |
|---|---|---|
| núcleo | 1–8 | ✅ — e o **FFI (5)** é o nosso melhor item da lista inteira: `include <math.h>` directo, `.ph` de P no mesmo build, `CStr`/`CBytes` sem cópia nem fixação. Nenhum dos nove tem isto tão barato |
| concorrência | 9–12 | ✅ — workers com heap e coletor próprios, async/await, timers sobre a fila de prazos, `os.run`/`spawn`/`spawn_pty` |
| dados | 13, 15, 17, 21 | ✅ — Unicode com tabela de categorias gerada (15.0.0) e `upper`/`lower` a sério, coleções em ordem de inserção, `pack`/`unpack` |
| rede | 26, 28, 30, 31 | ✅ — TCP sondado no mesmo `poll` do escalonador, DNS, HTTP/1.1 (202/202 do llhttp), URL (890/891 do WPT) |
| ficheiros e SO | 32–37, 39 | ✅ — `os`/`path` conferidos por varredura contra o `posixpath` do CPython |
| ferramental | 45, 47, 48 | ✅ — `pforge` com lock, `plangc --api` → `pforge doc`, doctest |

### Falta — e é uma lista curta e nomeável

| # | item | o que existe hoje |
|---|---|---|
| 14 | expressões regulares | **só `re.match`**. Sem `sub`, `split`, `findall`, `finditer`, `compile` |
| 16 | inteiro de precisão arbitrária | nada |
| 18 | data e hora | **só `time()` e `monotonic()`** — não há calendário, aritmética, formatação nem parse |
| 19 | fonte aleatória criptográfica | nada. O `pforge` abre `/dev/urandom` à mão (`repo.psc:654`) — o consumidor já existe |
| 20 | base64 e hexadecimal | nada |
| 22 | zlib/gzip/deflate | nada |
| 23 | hash | `sha2` é pacote em P. Sem SHA-1, MD5 nem CRC32 (e o `tar` vai precisar do último) |
| 24 | HMAC | nada |
| 25 | TLS | nada — **o maior buraco da lista** |
| 36 | ficheiros temporários | nada |
| 41 | logging estruturado | nada |
| 42, 43 | debugger e profiler | nada |
| 46 | asserções e runner de testes | há doctest e comparação de `.expected`; não há `assert_eq` com diferença legível |

E dois a meio:

- **27 — UDP:** planeado como F7 do plano do NIO. Não é desta lista.
- **40 — streams componíveis:** `File` e `Conn` têm `read`/`write`, mas não há
  `Reader`/`Writer` como traits. É o item que faz a stdlib encaixar em vez de
  ser dez ilhas, e depende do `bytes` da F0/F1 do plano do NIO.
- **44 — métricas do runtime:** só `gc.stats()`. O escalonador, o pool de
  threads e os workers não contam nada.

### O que a Parte 3 do levantamento diz sobre nós

A conclusão dele é que o denominador comum é *"um Unix decente + TCP + TLS +
hash + gzip + gestor de pacotes"*. **Temos tudo menos TLS, hash e gzip** — que
são precisamente os três que ninguém escreve à mão, e por isso os três que
precisavam de decisão.

**E o que declaradamente NÃO perseguimos**, dito aqui para não voltar a ser
perguntado: **Windows** (item 2 da interseção). Somos Linux e macOS. Um pacote
pode ser portado por quem quiser; a stdlib não promete.

---

## 2. A forma: metapacotes

> *"alguns metapacotes, um metapacote `stdlib` com tudo o que os outros
> metapacotes precisam (incluem várias coisas mas não são inseparáveis)"*

A 141.1 tinha cravado duas camadas: runtime (encapsula o SO, o coletor e os
descritores de tipo) e pacote (computação pura). A decisão de hoje acrescenta
uma terceira coisa, que não é uma camada mas um **agrupamento**:

| | o que é | como se instala | como se importa |
|---|---|---|---|
| **runtime** | `sys os net time gc json re math` + os tipos | não se instala — está lá | `import os` |
| **pacote** | uma preocupação, um `pack.json` | `pforge add codec` | `import <codec/base64>` |
| **metapacote** | um NOME para um conjunto de pacotes | `pforge add stdlib` | **não se importa** |

### A regra que faz isto funcionar: um metapacote INSTALA, não IMPORTA

Um metapacote não cria espaço de nomes nenhum. Ele traz os membros e sai da
frente — quem escreve continua a escrever `import <codec/base64>`, tenha
chegado lá pelo metapacote ou por `pforge add codec`.

É isso que torna verdadeira a cláusula *"não são inseparáveis"*: depender do
`base64` e não do `datetime` continua a ser possível e continua a ser a mesma
grafia. Se o metapacote fosse um módulo que reexporta, um programa que quisesse
uma coisa arrastaria as dez.

### A forma no `pack.json` — e o que falta ao manifesto

Boa notícia medida: **`root` já é opcional** (`packages/pforge/manifest.psc:230`,
e o `stl` é a razão de o ser). Portanto um metapacote é quase expressável hoje:

```json
{
  "name": "stdlib",
  "version": "0.1.0",
  "kind": "meta",
  "deps": { "algo": "0.1", "random": "0.1", "path": "0.1",
            "codec": "0.1", "datetime": "0.1", "log": "0.1", "test": "0.1" },
  "description": "o que qualquer programa quer ter à mão"
}
```

Falta-lhe **uma coisa só**: hoje `lang` é obrigatório e tem de ser `p` ou
`pscript` (`manifest.psc:228`), e um metapacote não tem código nenhum para ter
língua. Duas hipóteses, e a segunda é melhor:

- deixar `lang` mentir (`"lang": "pscript"` num pacote sem um `.psc`) — barato
  e sujo, e o `pforge` acabaria a tentar compilá-lo;
- **`"kind": "meta"`**, e o validador passa a exigir o oposto do que exige a um
  pacote normal: sem `root`, sem `lang`, sem `csources`, e `deps` **não vazias**
  (um metapacote sem membros é um erro, não um conjunto vazio).

**Fica de pé:** `pforge add stdlib` instala sete pacotes e o `pack.json` do
programa fica com uma linha; `pforge add codec` instala um e o programa que só
quer base64 não paga os outros seis.

### Os metapacotes propostos

| metapacote | membros | precisa de sistema? |
|---|---|---|
| **`stdlib`** | `algo`, `random`, `path`, `codec`, `datetime`, `log`, `test`, `csv` | não |
| **`crypto`** | `hash`, `hmac`, `csprng`, `ed25519` | não (o `csprng` lê `/dev/urandom`, que é um ficheiro) |
| **`web`** | `http`, `url`, `tls`, `psl` | **sim** — o `tls` (ver §3) |
| **`archive`** | `tar`, `compress` | não |

O `stdlib` é o que os outros três precisam, que é literalmente o que foi pedido:
o `http` quer `codec` (base64 do `Authorization`) e `datetime` (as datas dos
cabeçalhos); o `tar` quer `datetime` (os mtimes) e o `compress` quer `hash`
(CRC32). Nenhum deles quer o `csv`, e nenhum deles é obrigado a levá-lo — o
metapacote `stdlib` é a conveniência de quem escreve um programa, não uma
dependência que os outros metapacotes herdem em bloco.

### O versionamento: o metapacote data-se, os membros movem-se

> Decidido na segunda ronda.

`stdlib 0.4` é um **conjunto datado**: fixa `codec 0.2.1`, `datetime 0.3.0`, e
por aí — e é esse conjunto que é testado junto e publicado com o toolchain. Cada
membro tem versão própria, portanto **um bug no `base64` corrige-se sem lançar um
compilador**, e quem não quer o compilador novo leva na mesma a correcção.

É o Stackage do Haskell, e é literalmente o que um metapacote já é — a decisão
só lhe dá o nome certo. A alternativa (passo travado com o toolchain) dava zero
matriz de compatibilidade e cobrava uma vírgula do `csv` ao preço de um
lançamento inteiro.

**Consequência para o `pforge`:** as versões dentro do `deps` de um metapacote são
EXACTAS e não intervalos. Um conjunto curado que dissesse `">= 0.2"` não estaria
a curar nada.

### O que isto REVISA no plano do NIO

A fase **FS** do `PLAN.md` diz: *"o pacote `stdlib` recebe o que é computação
pura: `bisect`, `heapq`, `random` e a metade pura do `path`"* — um pacote
monolítico. Com a decisão de hoje, o destino muda:

| sai do runtime | vai para o pacote | reunido pelo metapacote |
|---|---|---|
| `bisect`, `heapq` | `algo` | `stdlib` |
| `random` | `random` | `stdlib` |
| `path.join/dirname/basename/normpath/abspath` | `path` | `stdlib` |
| `path.exists/isdir/isfile/getsize/getmtime*` | — junta-se ao `os` no runtime, como a FS já dizia | — |

**O trabalho é o mesmo** (o maior `sed` do plano, 140 chamadas `path.*` → `os.*`,
não muda); muda só o número de `pack.json` escritos no fim: três em vez de um,
mais o do metapacote. Quem executar a FS deve ler este ficheiro antes.

---

## 3. Sistema: escrever o que é viável

> Decisão: *"escrever o que é viável, sistema só onde não é."*

| peça | como entra | porquê |
|---|---|---|
| **`compress`** (inflate/deflate/gzip/zlib/CRC32) | **nosso**, em pscript | são ~800 linhas bem conhecidas e completamente especificadas (RFC 1950/1951/1952). Dá-nos gzip com zero dependências, e o binário continua a ser um ficheiro |
| **`tzdata`** | **o do sistema**, e o embebido é um pacote que se IMPORTA | Corrigido na quarta ronda — o primeiro rascunho dizia "sempre embebido" e não considerava a hipótese óbvia. O `datetime` lê `/usr/share/zoneinfo`: sempre actualizado pelo SO, zero bytes no binário. Quem precisa de um binário que corra num contentor vazio faz `pforge add tzdata`, e **a presença do pacote É a escolha** — não há duas fontes de verdade a disputar em silêncio. É o `import _ "time/tzdata"` do Go, e o nosso sistema de pacotes torna-o mais limpo do que lá. O gerador da tabela embebida é um `tools/gen_tzdata.py`, como o `tools/gen_unicode_cat.py` já é para o Unicode |
| **`tls`** | **dependência de sistema** (OpenSSL), declarada em `"system"` | escrever TLS é irresponsável. É o único dos três que quebra o binário estático, e é um preço que só paga quem o importa |

A regra em prosa, que é a 27.1 (*"a libc é o runtime"*) levada um passo à frente:
**dependemos do sistema para o que é perigoso escrever, não para o que é chato
escrever.** Um `deflate` chato é nosso; um handshake criptográfico não.

### 3.1 — E a língua em que se escreve: computação de bits é P

> Decidido na segunda ronda: *"em P, e o pscript alcança-os pelo contrato."*

Vale para os hashes, para o `inflate`/`deflate` e para o CRC32 — e a regra em
prosa é: **o que é aritmética num laço apertado sobre bytes escreve-se em P; o
que é estrutura, formato e decisão escreve-se em pscript.**

O argumento é um número que já foi medido. A 143.1 contou, no `url.psc`, que a
aritmética é **6,7 %** das chamadas ao runtime — o resto é `ps_str_concat`,
`ps_list_append`, `ps_dict_get`, que *são* o pscript e não o imposto dele. Mas um
hash não é um analisador de cadeias: é **100 % aritmética** num laço sobre bytes,
e portanto o que lá era desprezável aqui seria o custo todo.

**E o caminho de volta já existe e está provado**, o que é o que torna a decisão
barata em vez de uma cisão: a `struct Sha256` não tem ponteiro nenhum lá dentro,
logo é o caso `Foreign` trivial da 141.6; e a 66.1 permite escrever
`implement Hash for sha2.Sha256:` **do lado do pscript**, para um tipo que veio
de um `.ph` — foi para isto que ela foi decidida.

O preço, dito: **quem quiser ler ou corrigir o `deflate` tem de saber P.** É o
mesmo preço que o CPython paga (o `zlibmodule.c` é C) e por isso o mesmo que
toda a gente aceita, mas é um preço.

**E o efeito lateral que passa a ser dito: isto constrói uma stdlib do P sem lhe
chamar nada.** `hash`, `codec` (base64/hex é laço sobre bytes) e `compress` são
escritos em P por causa do desempenho — e ficam utilizáveis por quem escreve P
**sem custo nenhum**, porque um pacote P não tem runtime para carregar. O
`datetime`, o `csv` e o `algo` ficam em pscript porque são estrutura e não
aritmética.

Portanto **não há um plano para a stdlib do P**, e não faz falta: a regra dos
bits decide caso a caso, e o P acaba com um núcleo pequeno e sólido enquanto o
pscript fica com tudo. A hipótese recusada era escrever tudo em P com o pscript a
embrulhar — o P não tem `str`, `Dict` nem excepções, e um analisador de datas
escrito lá seria muito mais código a devolver erros por código de retorno.

**Consequência a dizer em voz alta:** enquanto o `tls` não existir, **não há
cliente HTTPS na caixa** — e hoje quase toda a rede é HTTPS. É a razão por que
o `tls` não fica para o fim da lista (§6, fase S7).

---

## 4. A regra da concorrência — a mais importante deste ficheiro

> **Nenhum módulo da stdlib inventa a sua própria concorrência.**
>
> Quem faz I/O é `async def` e estaciona no escalonador que já existe. Quem
> paraleliza usa `spawn` e workers. Quem partilha estado usa `shared` ou
> `shared dict`. **Zero threads escondidas, zero pools próprios, zero locks
> novos.**

É a diferença entre esta stdlib e a do Python, onde o `logging` tem lock
próprio, o `concurrent.futures` tem pool próprio e o `asyncio` é um segundo
mundo com uma cópia de cada coisa. Aqui o escalonador veio primeiro e a stdlib
nasce depois dele — é a única altura em que esta regra é barata.

Três consequências concretas, para não ficar em teoria:

- o **`log`** não tem lock: uma linha é uma linha porque o `print` já garante
  isso (107.2, `tests/print-atomic.sh`), e um logger que escreva por linhas
  herda a garantia em vez de a reconstruir;
- o **`test`** corre os casos em workers, com o `gather_map(…, at_most=n)` que
  já existe — não escreve um pool;
- o **`compress`** e o **`tls`** são `Reader`/`Writer` sobre o que já estaciona,
  e portanto são assíncronos sem saberem que são.

### 4.1 — O que falta ganhar nome (decidido)

**(a) `Channel<T>` — o canal independente do worker.**

Hoje o canal **É** o worker (36.1): `w.send`, `await w.recv`. Isso resolve
thread↔thread e não resolve task↔task: três tasks na mesma thread não têm como
passar valores umas às outras a não ser por `shared dict` — que é uma tabela
fora dos heaps, com lock, para um caso que não tem thread nenhuma.

A regra proposta, que evita a segunda maneira de dizer a mesma coisa:

> **O canal é entre TASKS; o worker é entre THREADS.**

Um `Channel<T>` fica dentro de um heap só. Isso torna-o barato de uma maneira
que o worker nunca poderá ser: **não serializa nada** — o valor não atravessa
heap nenhum, é o mesmo ponteiro, e o coletor já sabe percorrer a fila porque
ela é um objecto coletado como outro qualquer.

O vocabulário é o que já existe, de propósito:

| worker (hoje) | channel (proposto) |
|---|---|
| `w.send(v)` → `bool` | `await ch.send(v)` — estaciona se estiver cheio |
| `await w.recv()` | `await ch.recv()` |
| `w.close()` | `ch.close()` |
| `parent.open()` | `ch.open()` |

**Decidido na quarta ronda** (e a pergunta foi feita porque eu tinha decidido a
parte consequente sozinho): o canal **não atravessa threads**, e a capacidade é
explícita — `Channel<T>(n)`, **sem o caso zero**. O encontro à Go é a única forma
que obriga o emissor a estacionar mesmo havendo um receptor pronto, e é onde toda
a gente tropeça.

A alternativa recusada era um canal que atravessasse threads: passaria a haver
duas maneiras de mandar um valor para outra thread, e — pior — a barata (dentro
de um heap) deixaria de ser distinguível da cara (a que serializa) **pelo tipo**.

**(b) `taskgroup` — e a tua objeção, respondida.**

> *"a gente já não tem grupo de tarefas com gather (ou algo equivalente a
> `Promise.all`)?"*

Tens razão em 80% e vale a pena ser exacto, porque isso muda o tamanho da peça.
O que existe:

| nosso | JavaScript |
|---|---|
| `gather(t1, t2, …)` | `Promise.all` |
| `gather_settled` | `Promise.allSettled` |
| `first_ok` | `Promise.any` |
| `race` — e **cancela os perdedores** | `Promise.race` (que não cancela) |
| `gather_map(f, itens, at_most=n)` | não tem equivalente |

Portanto `Promise.all` **já temos**, e melhor. O que um grupo acrescenta são
três coisas que nenhuma delas tem:

1. **Criar tasks DENTRO do âmbito.** O `gather` recebe uma lista fixa no sítio
   da chamada. Não se acrescenta uma task a um `gather` a correr. Num grupo,
   `g.spawn(…)` pode estar dentro de um `for`, de um `if`, ou do corpo de uma
   task que já está no grupo.
2. **Nenhuma task sobrevive ao bloco.** Hoje uma task criada e não aguardada é
   drenada **no fim do PROGRAMA** (77.3), não no fim da função. Uma função que
   deixa escapar uma task deixa-a escapar durante toda a vida do processo, e o
   erro dela sai no stderr (107.4) em vez de sair no sítio de quem chamou.
3. **A primeira FALHA mata as irmãs.** O `race` cancela os perdedores mas fica
   com o primeiro RESULTADO; um grupo quer o contrário — o primeiro ERRO
   cancela o resto e sobe na fronteira do bloco.

E a peça é pequena porque não é um conceito novo: `with taskgroup() as g:`,
onde `g.spawn` cria uma task quente exactamente como hoje, a saída do `with`
faz o `gather` do que estiver aberto, e uma falha cancela as outras pelo mesmo
`cancel()` que o `race` já usa. **Zero maquinaria nova; uma garantia nova.**

Se ainda assim achares que não paga, diz — é a peça mais dispensável das três,
e é a única cujo valor é uma garantia e não uma capacidade.

**(c) `sched.stats()` — as métricas do escalonador.**

O item 44 da interseção, e o modelo já existe: o `gc.stats()` (bateria 110) faz
isto para o coletor. Um módulo `sched` no runtime, com `stats()` a devolver:

- tasks vivas, e **tasks estacionadas por RAZÃO** (prazo, descritor, `recv`,
  canal) — é este segundo número que transforma um travamento de adivinha em
  leitura;
- profundidade da fila de prazos;
- threads do pool ocupadas / totais;
- workers por estado (`RUNNING`/`DONE`/`ERROR`/`GONE`), que o `status()` já sabe
  um a um.

É barato — os contadores já existem por dentro do escalonador — e é o que faz
falta no dia em que um programa não acaba e ninguém sabe quem está à espera de
quê. O `pstudio` é o primeiro consumidor óbvio: um painel que mostra isto ao
vivo é meia tarde depois de os números existirem.

**(d) Supervisor com política de reinício — FORA, por agora.**

Não foi escolhido, e fica registado porquê para não voltar a aparecer como
esquecimento: as peças cruas existem (`w.error()`, `status()`, `alive()`, join
implícito), e uma árvore de supervisão à OTP é uma decisão de arquitectura de
serviço, não uma battery. Volta quando houver um serviço nosso a pedi-la.

### 4.2 — A segunda regra: o erro não é modelo de programação

> *"erros não são para entrar como parte do algoritmo. erros são exceções e não
> modelo de programação. é como se a linguagem já não fornecesse formas
> suficientes de se retornar um resultado, seja qual for ele."*

A pergunta que provocou isto era se o `enum Category` do prelúdio devia crescer
(`TIMEOUT`, `NOTFOUND`, `PERMISSION`) para a stdlib nova caber lá. **A resposta
recusa a pergunta, e a recusa está certa** — a pergunta assumia que quem apanha
um erro ramifica sobre a categoria para decidir o que fazer, e é essa suposição
que é o defeito.

> **A regra, que vale para todos os módulos deste plano:**
> **uma condição que faz parte do algoritmo DEVOLVE-SE; só o excepcional
> levanta.** Se quem chama vai ramificar sobre a categoria de um erro, a API está
> errada — a resposta devia ter vindo como VALOR.

**E a linguagem já se comporta assim** — foi conferido, não suposto:

| já existe | e devolve |
|---|---|
| `timeout(t, s)` | `True`/`False` (`tests/pscript/run/cancel_race.psc:12`). Um prazo que expira **não levanta** |
| `re.match(...)` | `List<str>?` — não casar não é um erro |
| `d.get(k, omissao)` | o valor ou a omissão; é o `d[k]` que levanta |
| `w.send(v)` | `bool` — mandar para um worker morto é uma resposta (45.3) |
| `path.exists(p)` | a pergunta tem resposta booleana; não se descobre por `catch` |
| `os.run(...)` | estado != 0 é **resultado e não excepção** (118) |

Portanto **`Category` não cresce.** E cada módulo novo herda uma obrigação
concreta em vez de uma taxonomia:

| módulo | o que DEVOLVE (parte do algoritmo) | o que LEVANTA (excepcional) |
|---|---|---|
| `codec` | `base64_decode(s) -> bytes?` — entrada de fora que não é base64 é um caso previsto, não um acidente | — |
| `datetime` | `parse(s, fmt) -> DateTime?` | um `strftime` com um especificador que não existe: isso é um erro de **programa** |
| `compress` | fim de stream, e quantos bytes saíram | um CRC que não bate a meio de um `.gz` — o ficheiro mentiu |
| `net`/`tls` | ligação recusada e prazo expirado são resultados | o handshake que falha depois de a ligação estar de pé |
| `hash` | nada — um hash não falha | — |
| `test` | — | a asserção que falha **levanta**, e é o caso certo: é literalmente excepcional |

**O que isto proíbe, dito para ser verificável:** nenhum módulo da stdlib pode
oferecer só a forma que levanta para uma condição que quem chama vai querer
tratar. Se levanta, tem de haver a pergunta — como o `d[k]` tem o `d.get`.

---

## 5. O inventário — o que cada pacote é

Módulos e nomes em inglês (regra 5). O que está entre parênteses é o módulo
dentro do pacote.

### `stdlib` — o metapacote da caixa

| pacote | módulos | notas |
|---|---|---|
| `algo` | `bisect`, `heapq` | saem do runtime tal como estão (portados de `Lib/`, com oráculo passo a passo) |
| `random` | `random` | idem — MT19937, a mesma semente dá a mesma sequência do Python. **O CSPRNG não vem para aqui**: é `crypto`, porque lê do sistema |
| `path` | `path` | a metade pura. A metade de sistema junta-se ao `os` |
| `codec` | `base64`, `hex` | base64 com as quatro variantes que a vida cobra (padrão/URL-safe × com/sem `=`); `hex` nos dois sentidos |
| `datetime` | `instant`, `local`, `zoned`, `delta`, `format` | **o modelo do `java.time`** (decidido): `Instant` (um ponto na linha do tempo), `LocalDate`, `LocalDateTime` (sem fuso, de propósito — "às 9h" num horário), `ZonedDateTime`, `Duration` (segundos exactos) e `Period` (meses e dias, que **não** são segundos exactos). **O TIPO responde se tem fuso** — nenhuma função pode receber uma data sem fuso e fingir que tem, que é o bug mais documentado da stdlib do Python. São todos `record`, portanto valores, e isso é de graça aqui. **Lê e escreve três formatos** (ronda 8): **ISO-8601/RFC 3339** (`2026-08-25T14:30:00Z` e `PT2H30M`) — o único obrigatório, é o que qualquer JSON e qualquer log usa; **`strftime`/`strptime`**, os `%Y-%m-%d` que toda a gente decorou; e **as datas do HTTP (RFC 7231)**, incluindo os dois formatos obsoletos que a norma obriga a ACEITAR mesmo proibindo de gerar — sem isto o `http` escrevia o seu próprio analisador de datas, que é o começo de haver dois |
| `log` | `log` | **global** (decidido): `log.info("...", key=v)` sem passar nada. E a 42.2 é uma vantagem em vez de um acidente — uma global mutável é **privada do worker**, portanto cada worker tem o seu logger sem contenção e sem lock, e a regra do §4.1 cumpre-se sozinha. **O preço a documentar:** configurar (nível, destino) é por worker, ou herdado explicitamente na entrada dele — senão alguém vai perguntar porque é que o worker ignorou o `set_level`. Formato: `logfmt` por omissão e JSON por linha como opção, escrevendo para um `Writer` |
| `test` | `assert`, `runner` | **decorador `@test`** (decidido) — os decoradores já existem (`@deco` e `@deco(args)`), portanto não é recurso novo, e ganha-se o metadado de graça: `@test(skip="...")`, `@test(timeout=5)`, `@test(cases=[...])`. `assert_eq` com **diferença legível** é a razão de o pacote existir (um booleano não diz o que mudou), e o runner corre os casos com o `gather_map(…, at_most=n)` que já há. Convive com o que existe: o `.expected` continua a ser o teste de SAÍDA de um programa, e isto é o teste de uma FUNÇÃO |
| `csv` | `csv` | leitura e escrita RFC 4180, com o dialecto do Excel como opção. Está aqui porque é barato e porque só quatro dos nove o têm |

### `crypto`

| pacote | módulos | notas |
|---|---|---|
| `hash` | `sha2`, `sha1`, `md5`, `crc32` | **em P** (decidido), e o `sha2` já prova o caminho: a `struct Sha256` só tem escalares e arrays fixos (`h: u32[8]`, `buf: u8[64]`, `nbuf`, `total`) — **nenhum ponteiro para outro objecto**, que é exactamente o caso que a 141.6 diz ser fácil e o único que o `Foreign` resolve hoje. O trait `Hash` (`update`/`digest`) é declarado do lado do pscript pela 66.1 (`implement Hash for sha2.Sha256:`), que existe precisamente para isto |
| `hmac` | `hmac` | genérico sobre o trait `Hash`. É o primeiro uso a sério de um genérico com limite de trait fora dos testes |
| `csprng` | `csprng` | **pacote, e não runtime** (ronda 8, resolvendo uma incoerência minha): ler `/dev/urandom` é um `open()` — não encapsula ponteiro, buffer nem chamada de sistema crua, portanto não é o que a 141.1 manda para dentro. Fica ao lado do `hash` e do `hmac`, que é onde quem procura vai olhar. E **falha** se não houver `/dev/urandom` — nunca recua para o MT19937, porque um gerador previsível a fingir de seguro é pior do que não haver nenhum. O `pforge` (`repo.psc:654`) já escreveu esta função à mão e passa a importá-la |
| `ed25519` | `ed25519` | já existe, em P |

### `web`

> Chamava-se `net` num primeiro rascunho, e colidia com o módulo `net` do
> runtime (`import net` é o socket). Um metapacote com o nome de um módulo do
> runtime seria uma armadilha, e o nome mudou antes de existir.

| pacote | notas |
|---|---|
| `url` | já existe (890/891 do WPT) |
| `http` | já existe como máquina de estados + servidor. **Ganha um cliente com ligação** — e a sexta ronda escolheu as quatro peças dele, todas: **ligações reutilizadas** (keep-alive e pool por servidor — que pela regra do §4.1 são ligações estacionadas no escalonador, não um pool de threads novo), **redirecções** com limite (e sem reenviar o corpo num `POST` que virou `GET`, nem o `Authorization` para outro domínio), **prazos e nova tentativa** (o `timeout` que já devolve `True`/`False`, e recuo exponencial só para o que é seguro repetir), e **cookies + descompressão automática** (`Accept-Encoding: gzip`, portanto depende da S6) |
| `psl` | a **lista de sufixos públicos** da Mozilla (~10 000 linhas), que é o que impede um servidor em `evil.co.uk` de pôr um cookie para todo o `.co.uk`. Pacote à parte pela mesma razão do `tzdata`: é DADO que envelhece sozinho, com gerador próprio (`tools/gen_psl.py`) e versão própria. O cliente HTTP depende dele; quem só usa o parser não o carrega, e o preço fica visível na árvore de dependências em vez de escondido dentro de um módulo |
| `tls` | dependência de sistema (OpenSSL). Um `Reader`/`Writer` por cima do `Conn`, e por isso o cliente HTTPS sai quase de graça. **A confiança vem do sistema** (`SSL_CERT_FILE`/`SSL_CERT_DIR` e o caminho por omissão da distribuição), pela mesma razão do `tzdata`: uma autoridade revogada corrige-se com `apt upgrade` e não com uma recompilação nossa. **A verificação não se desliga por acidente** — não existe `verify=False`; existe um construtor com outro nome, `tls.insecure_client(…)`, que aparece num `grep`. É a jogada da 141.4 aplicada à segurança em vez de à memória: a promessa perigosa tem de estar visivelmente escrita |

### `archive`

| pacote | notas |
|---|---|
| `tar` | já existe |
| `compress` | inflate/deflate/gzip/zlib, nosso. Streaming, sobre `Reader`/`Writer` |

### Os streams: trait mínimo, funções livres — e os métodos MORREM

> Decidido nas rondas 2 e 3.

Sabendo que **os traits não têm método por omissão** (procurei; não há), a forma
é a do Go:

```
trait Reader:
    def read_into(self, b: View<u8>) -> int      # 0 = fim
trait Writer:
    def write_from(self, b: View<u8>) -> int
```

e mais nada. Tudo o resto são **funções livres** que recebem um `Reader`:
`read_all(r)`, `lines(r)`, `copy(r, w)`, `decode(r)`. Zero alteração na
linguagem, e a forma está provada há quinze anos.

**E os métodos de conveniência que hoje existem no `File` morrem.** `f.read_all()`,
`f.text()`, `f.readlines()` passam a ser `read_all(f)`, `text(f)`, `lines(f)`.
Uma única maneira de dizer cada coisa — a alternativa (método que delega para a
função) dava duas grafias com uma implementação, que é o que o Go realmente faz,
e foi recusada.

**O preço, medido em trabalho:** é um `sed` por todo o `pforge`, o `pstudio` e o
corpus de testes. **Junta-se ao que a F1 do plano do NIO já vai fazer** (`read(n)`
a morrer, `read_into`/`read_all` a nascer) — é a mesma passagem pelos mesmos
ficheiros, e fazer as duas em movimentos separados seria pagar duas vezes.

**O preço em leitura, dito porque é real:** `await read_all(f)` lê-se pior do que
`await f.read_all()`, e a I/O é das coisas mais escritas que há.

### `assert` e `assert_eq` são DOIS, e a regra diz porquê

> Decidido na quarta ronda.

O `assert` da linguagem é **removível em release** (46.4, o `-O`). O `assert_eq`
do pacote `test` **nunca** pode ser removido. Não são a mesma palavra:

> **O `assert` fala com o programador do módulo** — é um contrato interno, *"isto
> não pode acontecer"*, e some em release porque já foi verificado.
> **O `assert_eq` fala com quem lê o relatório** — é a razão de o processo
> existir.

Um `pforge test -O` que compilasse uma suíte que não verifica nada e dissesse que
passou seria o pior defeito possível numa bateria de testes. Nomes diferentes
para coisas diferentes não é duplicação — e a alternativa (uma palavra só)
obrigava a proibir o `-O` nos testes, que é uma regra escondida à espera de
morder alguém.

### A documentação passa a ter portão: `-Wmissing-doc`

> Decidido na oitava ronda.

**Um símbolo público sem docstring é um AVISO do compilador**, ligado nos
pacotes da stdlib e no `pforge` (e disponível para quem o quiser no seu). Sai
quase de graça: o sistema de `-W` já existe e tem paridade com o clang (155/155,
`tests/clang-compare.sh`), e o `plangc --api` já sabe quem é público.

Passa a ser impossível publicar uma função da stdlib sem uma frase — e como o
doctest já corre, **um exemplo nessa frase é um teste**.

A barra mais alta (exigir também um doctest em cada símbolo) foi recusada com a
razão: para muita função — `hmac_final`, `read_into` — um exemplo honesto não
cabe em duas linhas, e o resultado seriam exemplos de encomenda, que são piores
do que nenhum.

### Fica no runtime (e porquê)

`sys os net time gc json re math` + `sched` (novo) + os tipos (`str`, `List`,
`Dict`, `Set`, `bytes`, `Buffer`, `View`, `Mapping`) + `Channel` e `taskgroup`.

A regra é a da 141.1 e a segunda cláusula dela: encapsula o SO, o coletor ou os
descritores de tipo → runtime; **e** o que um programa não pode tolerar que
falte. Um programa que escreve `[]` não tolera uma dependência; um que faz
`spawn` também não, e é por isso que o `Channel` e o `taskgroup` são runtime e
não pacote — mexem no escalonador.

### O `re` ganha um motor NOSSO — decidido, e é a peça maior deste plano

> Decidido na quinta ronda, contra a minha recomendação (eu propunha ERE agora e
> motor depois). Fica registado que foi a opção mais ambiciosa das três.

**O `regcomp`/`regexec` da libc (`psrt_std.p:562`) é substituído por um autómato
de Thompson escrito por nós.** Nascem também as funções que faltavam — `sub`,
`split`, `findall`, `finditer`, `compile` — mas essas eram a parte fácil.

**A correcção que a pergunta seguinte teve de fazer, porque eu tinha vendido mal
a opção:** um motor de tempo linear **não pode** ter retrocesso (`\1`) nem
lookaround (`(?=…)`). É matemática, não é esforço — o autómato não guarda o texto
que já casou. Eu tinha listado o lookahead como algo que se ganhava. Não se ganha.

**Escolhido com isso na mesa: o dialecto do RE2.**

| ganha-se | perde-se |
|---|---|
| `\d` `\w` `\s` `\b`, não-guloso (`*?`), grupos com nome, `\p{L}` e as classes de Unicode | retrocesso (`\1`) |
| **garantia de tempo linear** — nenhuma entrada consegue travar o programa | lookahead e lookbehind |

A garantia é o argumento a sério, e é de coerência: uma linguagem que promete
quatro eixos de segurança de memória (9.1) e depois oferece um regex que uma
cadeia de entrada consegue parar está a prometer com uma mão e a tirar com a
outra. `(a+)+b` contra sessenta `a` pára um PCRE; não pára este.

É o motor do Go, o `regex` do Rust e o RE2 do Google — nenhum dos três tem
retrocesso, e a lista do que isso impede na prática é curta.

### Onde o motor vive: **no runtime, com o nome `re`**

Pela primeira cláusula da 141.1, um motor nosso é computação pura e devia sair
para um pacote. **Decide a segunda cláusula, e não a primeira:** *"um programa
que escreve `[]` não pode depender de um pacote existir, ser encontrado, ser
instalado e estar na versão certa"*. Regex é dessa espécie.

Portanto `import re` continua a não ter caminho, o compilador continua a validar
os nomes, e **nenhum programa que existe hoje muda uma linha** — a libc é
substituída por dentro. O `re` era runtime por embrulhar o `regex.h`; passa a
ser runtime por ser infra-estrutura. A razão muda, o sítio não.

### Unicode no motor — e a **105.4 REABRE**

`.` casa um **codepoint**, coerente com o `s[i]` da 3.4 e o `len` em codepoints.
`\d`, `\w`, `\s` e `\p{L}` usam a tabela de categorias que **já existe** (27 KB,
Unicode 15.0.0, gerada por `tools/gen_unicode_cat.py` e conferida por um oráculo
que varre todo o ponto de código).

E o `(?i)` é **Unicode completo**, o que obriga a uma coisa que estava decidida em
sentido contrário:

> **A 105.4 (`casefold` FORA) fica REVISTA por esta decisão.** Entra a tabela de
> *case folding* (mais uns ~20 KB gerados pelo mesmo caminho), porque é ela que
> faz `(?i)` casar `İ` com `i` e `ß` com `ss`. Quem actualizar o `AUDIT.md` deve
> marcar a 105.4 como **REV**.

A alternativa (`(?i)` só em ASCII) tinha sido a minha recomendação, precisamente
para não mexer numa decisão anterior. Foi recusada.

### O que a v1 promete: **nada ainda, e é de propósito**

> Decidido na quinta ronda: *"enquanto for 0.x, tudo pode mudar; e não há pressa
> para o 1.0."*

A stdlib nasce em `0.x` e não promete compatibilidade. Liberdade total para
corrigir desenho enquanto o desenho ainda está a ser descoberto — que é
exactamente onde estamos, e é honesto dizê-lo em vez de fingir estabilidade.

**O risco, dito porque é conhecido:** quem publica `0.x` durante anos acaba com
toda a gente a depender daquilo que prometeu não garantir. O Go esperou pelo 1.0
e depois nunca mais partiu nada, e foi essa decisão que fez a stdlib dele valer.
Portanto o 1.0 não tem pressa, **mas tem de existir** — e a altura de o declarar
é quando os consumidores de dentro (`pforge`, `pstudio`, o compilador) deixarem
de pedir mudanças de forma.

Quando chegar, o mecanismo já está todo construído: decoradores para o
`@deprecated("usa X")`, e um sistema de `-W` compatível com o clang (155/155 de
paridade) para o compilador avisar com a posição e a alternativa.

### `bigint` — deixa de ser pacote e passa a ser TIPO DA LINGUAGEM

> *"BigInteger daria pra gente incluir na linguagem mesmo, mas não seria
> sobrecarga de operador, seria um operador de um tipo nosso né? do pscript"*

Eu tinha registado isto como bloqueado pela 52.2, e **estava errado a ler a
52.2**. O que ela recusou foi *sobrecarga* de operador — **o utilizador** dizer o
que `+` faz para o tipo dele, com o abuso conhecido de um `+` que faz uma chamada
de rede. Um tipo numérico **da própria linguagem**, cujo `+` o compilador conhece
porque o escreveu, não é sobrecarga: é o mesmo mecanismo que já faz `int + int`,
`float + float`, `str + str` e `List + List` (104.3).

Portanto:

| antes (errado) | agora |
|---|---|
| pacote `bigint`, grafia `a.add(b).mul(c)` | **tipo do runtime**, grafia `a + b * c` |

E o sítio decide-se sozinho pela segunda cláusula da 141.1: um tipo numérico da
linguagem não pode depender de um pacote existir, tal como o `str` não pode.

**As regras dele, decididas na sétima ronda:**

| regra | e a razão |
|---|---|
| **tipo explícito**: `x: bigint = 2`, `bigint("9"*40)` | um literal grande demais para `i64` faz o compilador **exigir** a anotação em vez de adivinhar |
| **`int` promove para `bigint`** como já promove para `float` (32.1) | não é regra nova: é a regra que a linguagem já tem, aplicada a mais um tipo |
| **`int` continua a levantar no transbordo** (7.2, intacta) | pedir precisão infinita é uma decisão, nunca um acidente — e um laço quente não pode começar a alocar sem que nada no código o diga |
| **`/` dá `float`** e perde precisão, como no Python; `//` é o exacto | coerência com a 39.1. E quando nem cabe num float, levanta — que é o que o CPython faz |

A hipótese recusada foi a do Python inteiro (`int` que cresce sozinho no
transbordo): revogava a 7.2 e tirava ao `smallpt` a aritmética de custo
previsível.

---

## 6. As fases

Ordenadas por dependência. Cada uma só fecha quando o portão dela tem teste que
prende, `make verify` deu 8/8 nos três modos, e o seed foi regenerado se o
compilador mudou (regra 2 do `PLAN.md`).

| | fase | depende de | fica de pé |
|---|---|---|---|
| **S0** | o **metapacote**: `"kind": "meta"` no manifesto, e o `pforge` a instalar o conjunto | — | `pforge add stdlib` traz sete pacotes; um `pack.json` de metapacote com `root` é recusado com a razão |
| **S1** | a **FS revista**: `algo`, `random`, `path` saem do runtime como três pacotes, reunidos pelo metapacote | S0, e a **FN** do plano do NIO (a regra dos nomes vem primeiro) | um programa que usa `bisect` declara-o; e `plangc` deixa de conhecer três nomes |
| **S2** | o **denominador comum barato**: `codec`, `crypto` (`hash`/`hmac`/`csprng`), `os.tempfile` | S0 | o `pforge` deixa de abrir `/dev/urandom` à mão; o `tar` tem o CRC32 que vai precisar |
| **S2b** | o **motor de regex** (Thompson/RE2), a tabela de `casefold`, e as funções novas do `re` | — (nada no plano depende dela) | `(a+)+b` contra sessenta `a` devolve em vez de parar o processo; e um corpus de conformidade próprio |
| **S3** | a **concorrência**: `sched.stats()`, `Channel<T>`, `taskgroup` — **as três confirmadas na sexta ronda** | — (é runtime, independente de tudo o resto) | três tasks na mesma thread passam valores sem `shared dict`; um bloco que sai não deixa task viva atrás de si; e um programa que não acaba diz quem está à espera de quê |
| **S4** | **`datetime`** + **`tzdata`** | S0 | formatar, parsear e somar um dia — e o gerador refaz a tabela de fusos |
| **S5** | os traits **`Reader`/`Writer`**, e a morte dos métodos de conveniência do `File` | **a F1 do plano do NIO** (a I/O a falar `bytes`) — é a MESMA passagem pelos mesmos ficheiros | ficheiro, socket e memória implementam os mesmos dois traits; uma função que copia um para o outro serve os três; e `f.read_all()` deixou de compilar em todo o lado |
| **S6** | **`compress`** | S5, e o `bytes` da F0 | `gzip` de um ficheiro grande sem o trazer inteiro para a memória |
| **S7** | **`tls`** | S5 | um cliente HTTPS na caixa — que é o que falta para a nossa rede não ser de brincar |
| **S8** | a **observabilidade**: `log`, `test` | S5 (o `log` escreve para um `Writer`), S3 (o `test` corre em workers) | um `assert_eq` que mostra o que mudou, e uma linha de log de doze workers que continua a ser uma linha |
| **S9** | o resto: `csv`, e o **`bigint`** (que é runtime, não pacote) | S0 | `a + b * c` com quatrocentos dígitos, e `int` a promover como promove para `float` |

**Porque é que o regex saiu da S2:** ele passou a ser a maior peça isolada do
plano (~1500 linhas, mais um corpus de conformidade, mais a tabela de
`casefold`), e a S2 era suposto ser a fase barata — a que desbloqueia
consumidores esta semana. **Nada no plano depende do regex**, portanto ele não
tem de prender nada atrás de si.

### A coordenação com o plano do NIO

Duas fases deste plano tocam o outro, e é melhor dizê-lo aqui do que descobri-lo
num conflito:

- a **S1 REVISA a FS** — o destino deixa de ser um pacote `stdlib` monolítico e
  passa a ser três pacotes mais um metapacote. O trabalho (o `sed` de
  `path.*` → `os.*`) não muda;
- a **S5 é a F1 vista deste lado** — quem fizer a I/O falar `bytes` deve
  aterrar os traits `Reader`/`Writer` no mesmo movimento, em vez de nós os
  acrescentarmos por cima depois. Não são duas peças.

---

## 7. O que NÃO entra, e porquê

| não entra | porquê |
|---|---|
| **Windows** | somos Linux e macOS. Um pacote pode ser portado; a stdlib não promete |
| **SQLite embebido** | só o Python (e o Bun) o têm. Não é denominador comum, e é uma dependência enorme |
| **XML** | nem o Node nem o Dart o têm de fábrica. Se aparecer um consumidor, é um pacote |
| **debugger e profiler** (42, 43) | são **ferramental**, não stdlib: a casa deles é o `pforge` e o `pstudio`. O `gc.stats()` + o `sched.stats()` da S3 são a versão pobre e honesta, e chegam para o que dói hoje |
| **parsing de argumentos de CLI** | o próprio levantamento diz que não é universal (o .NET, o Java e o Dart não o têm). Pode vir como pacote |
| **supervisor à OTP** | ver §4.1(d) — volta quando houver um serviço nosso a pedi-lo |
| **localização** (línguas, `%A`/`%B`, "há 3 minutos") | a formatação relativa foi posta de lado na ronda 8 junto com a decisão de não abrir localização. Sem língua só dá inglês, e inglês a fingir de universal é pior do que não haver |
| ~~**`bigint`**~~ | **entrou** — deixou de ser pacote e é tipo da linguagem, ver §5. O bloqueio que eu lhe tinha atribuído era uma leitura errada da 52.2 |

---

## Adenda de execução — a S1 fica ADIADA, e a razão é medida (2026-08-25)

Escrita ao executar o plano, com o utilizador a dormir e com a instrução de
tomar a melhor decisão. **A S1 não foi feita**, e o que se segue é porquê — para
que ela seja retomada por escolha e não por esquecimento.

### O que a medição mostrou

**Ninguém consome `random`, `bisect` ou `heapq` fora dos testes.** Medido:

```
random.  → tests/oracle/py/rng.psc, tests/pscript/run/stdmod.psc, 4 casos `bad`
bisect. heapq. → tests/oracle/py/algos.psc, tests/pscript/run/algos.psc, 3 `bad`
```

Nem o `pforge`, nem o `pstudio`, nem um pacote publicado. Portanto o que a S1
entrega hoje é **coerência de arrumação, e nenhuma capacidade** — enquanto a S2,
a S3 e a S4 entregam coisas que a linguagem não tem de todo.

### E as duas metades da S1 são UMA decisão, não duas

A metade mecânica — as 148 chamadas `path.isfile`/`isdir`/`exists`/`getsize`/
`getmtime` a mudarem para `os.*` — parece independente e não é. A única razão
para ela existir é o `path` virar PACOTE: a metade de sistema não pode ir com
ele, porque encapsula chamadas ao sistema (141.1).

E ela tem um custo próprio que vale a pena dizer: **hoje nós casamos com o
Python** — `os.listdir` e `os.path.isdir` estão nos mesmos sítios que lá — e
mudar `path.isfile` para `os.isfile` DIVERGE. Fazer a metade mecânica sem a
outra seria mudança por mudar.

### O custo real da outra metade

`random` são ~143 linhas de P dentro do `psrt_std.p`, com o estado do
Mersenne Twister no contexto; `bisect`/`heapq` são ~100 sobre `PsList` com
chaves cruas. Levá-los para um pacote é **reescrevê-los em pscript** — e o
oráculo do `random` compara-o com o CPython bit a bit, portanto a reescrita é
verificável mas não é barata.

### O que fazer quando ela for retomada

A ordem certa é a que o próprio `STDLIB.md` dá: os pacotes primeiro
(`algo`, `random`, `path`), o metapacote a seguir — o `"kind": "meta"` da **S0
já está feito e testado** — e o `sed` das 148 chamadas por último, num commit
próprio, porque é o único pedaço que toca a árvore inteira.

---

## Adenda de execução — a S2, e a correcção que a medição obrigou (2026-08-25)

A S2 foi feita. O que aqui fica é o que **mudou** em relação ao que está escrito
acima, porque foi medido em vez de suposto. A bateria completa é a **148** do
`pscript/DESIGN.md`; isto é o resumo, no sítio onde a promessa original está.

### O `Hash` como trait não dá, e a §5 promete-o

A tabela do `crypto` diz que o `sha2` *"já prova o caminho"* e que o trait `Hash`
se escreve `implement Hash for sha2.Sha256:`. **Não dá.**

Medido em `selfhost/ps_sema.p`, na função `c_type`: o que atravessa a fronteira da
45.5 são escalares por nome, e mais nada. A excepção que funciona é o
`CStr`/`CBytes` da 84.1 — um ponteiro e um comprimento como VALOR — e é assim que
o `sha256_of(in data: CBytes) -> CStr` já é chamado do pscript hoje.

Logo: **o hash de um tiro atravessa; a `struct Sha256` não.** O trait `Hash` com
estado incremental precisa que ela tenha nome do lado de cima, que é exactamente
o `Foreign` que a **141.6** parou de propósito.

**O que a S2 entregou:** hashes de um tiro (`crc32`, `sha1`, `md5` no pacote novo
`hash`, ao lado do `sha2` que já existia) e um `hmac_sha256` **concreto e em P**,
onde o estado incremental do `sha2` está do mesmo lado e portanto é livre. Quando
a 141.6 andar, o `hmac` ganha um parâmetro de tipo e não perde nada.

### O `sha2` não muda de morada

A §5 lista um pacote `hash` com os módulos `sha2`, `sha1`, `md5`, `crc32`. Mas o
`sha2` **já é um pacote**, e o `pforge` depende dele pelo NOME — nos `pack.json`,
nas fixtures do lockfile e no descritor de build.

O metapacote existe precisamente para este caso: `crypto` reúne `sha2`, `hash`,
`hmac`, `csprng` e `ed25519` **sem obrigar nenhum deles a mudar de sítio**.

### Os temporários: `os.tempdir()`, `os.tempfile()`, `os.tempdir_new()`

Três perguntas, três funções, e as duas últimas **criam** — nunca devolvem um nome
que ainda não existe, que é a corrida do `mktemp`. Os nomes não são os do Python
(`mkstemp`, `mkdtemp`) de propósito: o de lá devolve um descritor E um nome, e o
nosso devolve só o nome.

---

## Adenda de execução — a S4, e o `tzdata` que passou a ser `tz` (2026-08-25)

A S4 foi feita: o pacote `datetime` com o modelo do `java.time`, e o `tz` no
lugar do `tzdata`. A bateria é a **149**; aqui fica o que MUDOU no que está
escrito acima.

### O `ZonedDateTime` não guarda o nome do fuso

Um `record` do pscript é bytes puros (58.2), portanto uma `str` não cabe lá
dentro. Isso obrigou a decidir — e a decisão é a certa por uma razão que não é a
da restrição: **um nome de fuso sem as REGRAS não vale nada.** O que ele precisa
de carregar para ser um ponto na linha do tempo é o DESLOCAMENTO, e é isso que
ele carrega.

### O `tzdata` LÊ O DO SISTEMA, e chama-se `tz`

A §5 punha-o como pacote com gerador próprio, ao lado do `psl`. **Revisto**, e o
argumento é o que a própria §5 usa para o `tls`: *"a confiança vem do sistema
(…) uma autoridade revogada corrige-se com `apt upgrade` e não com uma
recompilação nossa"*.

As regras de fuso mudam **várias vezes por ano**. Uma cópia nossa estaria errada
em produção antes de a tinta secar, e o sistema já tem a resposta certa em
`/usr/share/zoneinfo`, em TZif (RFC 8536).

O `psl` fica como está, e a diferença é exactamente essa: a lista de sufixos
públicos **não tem cópia do sistema**. Ou se traz, ou não se tem.

O nome muda para **`tz`** porque o que o pacote tem não é dado — é o leitor.
`TZDIR` sobrepõe-se ao caminho. E quando não há zoneinfo, **levanta**: nunca
recua para UTC.
