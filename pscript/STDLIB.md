# A stdlib do pscript — o plano

> Este ficheiro nasceu de `packages/runtimes-linguagens-nao-sistemas.md`, o
> levantamento dos nove runtimes não-de-sistemas e da interseção do que todos
> têm de fábrica. Ele responde à pergunta que esse levantamento faz: **o que é
> que a nossa stdlib vai ser, e o que é que vem na caixa.**
>
> As decisões abaixo foram tomadas pelo utilizador em 2026-08-24 (regra 4 do
> `PLAN.md`). O que está marcado **PENDENTE** não foi decidido e segue com a
> saída conservadora.
>
> Reserva a **bateria 145** no `DESIGN.md` para ligar a este ficheiro. Não é
> escrita lá directamente porque outro plano (o NIO, baterias 135–140) está a
> mexer no mesmo ficheiro ao mesmo tempo.

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
| **`net`** | `http`, `url`, `tls` | **sim** — o `tls` (ver §3) |
| **`archive`** | `tar`, `compress` | não |

O `stdlib` é o que os outros três precisam, que é literalmente o que foi pedido:
o `http` quer `codec` (base64 do `Authorization`) e `datetime` (as datas dos
cabeçalhos); o `tar` quer `datetime` (os mtimes) e o `compress` quer `hash`
(CRC32). Nenhum deles quer o `csv`, e nenhum deles é obrigado a levá-lo — o
metapacote `stdlib` é a conveniência de quem escreve um programa, não uma
dependência que os outros metapacotes herdem em bloco.

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
| **`tzdata`** | **nosso**, como DADO embebido | a base de fusos é uma tabela, não um programa. `embed()` (63.1) mete-a no binário, e um gerador (`tools/gen_tzdata.py`) refá-la — exactamente como o `tools/gen_unicode_cat.py` já faz para as categorias do Unicode. É pacote SEPARADO do `datetime`, porque muda ao ritmo do mundo e não ao nosso |
| **`tls`** | **dependência de sistema** (OpenSSL), declarada em `"system"` | escrever TLS é irresponsável. É o único dos três que quebra o binário estático, e é um preço que só paga quem o importa |

A regra em prosa, que é a 27.1 (*"a libc é o runtime"*) levada um passo à frente:
**dependemos do sistema para o que é perigoso escrever, não para o que é chato
escrever.** Um `deflate` chato é nosso; um handshake criptográfico não.

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

**PENDENTE:** capacidade zero (encontro, à Go) ou capacidade mínima 1. A saída
conservadora é **capacidade explícita, `Channel<T>(n)`, sem o caso zero** —
o encontro é a única forma que obriga o emissor a estacionar mesmo quando há
um receptor pronto, e é o caso que mais tropeça em quem chega.

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
| `datetime` | `date`, `time`, `datetime`, `delta`, `format` | calendário gregoriano proléptico, aritmética, `strftime`/`strptime`. **Sem fuso** — o fuso é o `tzdata`, por cima |
| `log` | `log` | níveis, campos estruturados, saída para qualquer `Writer`. Sem lock (§4) |
| `test` | `assert`, `runner` | `assert_eq` com **diferença legível** (é a razão de existir — um booleano não diz o que mudou), e o runner corre em workers |
| `csv` | `csv` | leitura e escrita RFC 4180, com o dialecto do Excel como opção. Está aqui porque é barato e porque só quatro dos nove o têm |

### `crypto`

| pacote | módulos | notas |
|---|---|---|
| `hash` | `sha2`, `sha1`, `md5`, `crc32` | o `sha2` já existe **em P** e continua em P — é computação de bits, e o P faz isso melhor. Um trait `Hash` (`update`/`digest`) une-os |
| `hmac` | `hmac` | genérico sobre o trait `Hash`. É o primeiro uso a sério de um genérico com limite de trait fora dos testes |
| `csprng` | `csprng` | `/dev/urandom`, e **falha** se não houver — nunca recua para o MT19937. O `pforge` (`repo.psc:654`) já escreveu esta função à mão e passa a importá-la |
| `ed25519` | `ed25519` | já existe, em P |

### `net`

| pacote | notas |
|---|---|
| `url` | já existe (890/891 do WPT) |
| `http` | já existe como máquina de estados + servidor. **Ganha um cliente com ligação**, que é o que falta para ser o item 29 da interseção |
| `tls` | dependência de sistema (OpenSSL). Um `Reader`/`Writer` por cima do `Conn`, e por isso o cliente HTTPS sai quase de graça |

### `archive`

| pacote | notas |
|---|---|
| `tar` | já existe |
| `compress` | inflate/deflate/gzip/zlib, nosso. Streaming, sobre `Reader`/`Writer` |

### Fica no runtime (e porquê)

`sys os net time gc json re math` + `sched` (novo) + os tipos (`str`, `List`,
`Dict`, `Set`, `bytes`, `Buffer`, `View`, `Mapping`) + `Channel` e `taskgroup`.

A regra é a da 141.1 e a segunda cláusula dela: encapsula o SO, o coletor ou os
descritores de tipo → runtime; **e** o que um programa não pode tolerar que
falte. Um programa que escreve `[]` não tolera uma dependência; um que faz
`spawn` também não, e é por isso que o `Channel` e o `taskgroup` são runtime e
não pacote — mexem no escalonador.

### O `re`, e a decisão que ele esconde — **PENDENTE**

Vão nascer `re.sub`, `re.split`, `re.findall`, `re.finditer` e `re.compile`,
e todos assentam no `regcomp`/`regexec` da libc que já lá está
(`psrt_std.p:562`). Isso fecha o item 14 da interseção **em funções**.

O que não fecha é o **dialecto**: POSIX ERE não tem não-guloso (`*?`), não tem
`\d`/`\w`/`\b`, não tem lookahead nem grupos com nome. O levantamento diz que
os nove estão *"quase todos sobre PCRE ou dialeto próximo"* — nós não estamos.

Duas saídas, e a segunda é cara: continuar com POSIX ERE e documentar a
diferença; ou escrever um motor nosso (um Thompson NFA dá o dialecto e dá
garantia de tempo linear, que o PCRE não dá — mas é um pacote inteiro).
**A saída conservadora, e o que segue por omissão: POSIX ERE, com as funções
novas, e a diferença dita na documentação.** Decide quando quiseres.

### `bigint` — **PENDENTE**, e a razão é a sintaxe

O item 16 é universal e o pacote é fácil de escrever. O que não é fácil é
**usá-lo**: não há sobrecarga de operador (`FORA`, 52.2), portanto seria
`a.add(b).mul(c)` e não `a + b * c`. Um bigint que se escreve assim é um bigint
que ninguém usa.

Ou se aceita a grafia por métodos, ou se reabre a 52.2 para um caso, ou fica
fora. **Segue fora da primeira leva**, com a pergunta registada.

---

## 6. As fases

Ordenadas por dependência. Cada uma só fecha quando o portão dela tem teste que
prende, `make verify` deu 8/8 nos três modos, e o seed foi regenerado se o
compilador mudou (regra 2 do `PLAN.md`).

| | fase | depende de | fica de pé |
|---|---|---|---|
| **S0** | o **metapacote**: `"kind": "meta"` no manifesto, e o `pforge` a instalar o conjunto | — | `pforge add stdlib` traz sete pacotes; um `pack.json` de metapacote com `root` é recusado com a razão |
| **S1** | a **FS revista**: `algo`, `random`, `path` saem do runtime como três pacotes, reunidos pelo metapacote | S0, e a **FN** do plano do NIO (a regra dos nomes vem primeiro) | um programa que usa `bisect` declara-o; e `plangc` deixa de conhecer três nomes |
| **S2** | o **denominador comum**: `codec`, `crypto` (`hash`/`hmac`/`csprng`), `os.tempfile`, e o `re` completo | S0 | o `pforge` deixa de abrir `/dev/urandom` à mão; o `tar` tem o CRC32 que vai precisar |
| **S3** | a **concorrência**: `Channel<T>`, `taskgroup`, `sched.stats()` | — (é runtime, independente de tudo o resto) | três tasks na mesma thread passam valores sem `shared dict`; e um programa que não acaba diz quem está à espera de quê |
| **S4** | **`datetime`** + **`tzdata`** | S0 | formatar, parsear e somar um dia — e o gerador refaz a tabela de fusos |
| **S5** | os traits **`Reader`/`Writer`** | **a F1 do plano do NIO** (a I/O a falar `bytes`) | ficheiro, socket e memória implementam os mesmos dois traits, e uma função que copia um para o outro serve os três |
| **S6** | **`compress`** | S5, e o `bytes` da F0 | `gzip` de um ficheiro grande sem o trazer inteiro para a memória |
| **S7** | **`tls`** | S5 | um cliente HTTPS na caixa — que é o que falta para a nossa rede não ser de brincar |
| **S8** | a **observabilidade**: `log`, `test` | S5 (o `log` escreve para um `Writer`), S3 (o `test` corre em workers) | um `assert_eq` que mostra o que mudou, e uma linha de log de doze workers que continua a ser uma linha |
| **S9** | o resto: `csv`; e `bigint` se a 52.2 for reaberta | S0 | — |

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
| **um motor de regex nosso** | PENDENTE, ver §5. A saída conservadora é ficar no POSIX ERE |
| **`bigint`** | PENDENTE, ver §5 — é a sintaxe que o bloqueia, não a matemática |
