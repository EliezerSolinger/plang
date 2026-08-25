# A adoção: usar o que construímos

Este arquivo responde a uma pergunta feita depois das duas listas (`PLAN.md`, a
NIO; `STDLIB.md`, a biblioteca): **agora que a linguagem tem tudo isso, quanto da
nossa própria base de código deveria mudar para usá-lo?**

A resposta curta é **pouco**, e isso é o resultado da medição — não uma desculpa
para não fazer. Vale a pena escrever por quê, porque a intuição diz o contrário.

---

## Por que a superfície é menor do que parece

**A migração mecânica já aconteceu, dentro das fases.** A F1 não acrescentou
`bytes` e foi embora: ela converteu os 81 sítios que usavam `List<u8>` no mesmo
passo. A S5 pôs o `Reader`/`Writer` e converteu quem lia à mão. Uma fase que
entrega uma peça e deixa a base velha não terminou — e nenhuma delas fez isso.

O que sobra é **adoção oportunista**: código que continua correcto, escrito antes
da peça existir, e que ficaria um pouco melhor com ela. É legítimo, é pequeno, e
é onde o risco de mexer supera o ganho com mais frequência do que se pensa.

---

## O que a medição diz

| oportunidade | achados | quantos são reais |
|---|---|---|
| hex escrito à mão | 9 | **3** — 4 são P (sem `bytes`) e 2 são inteiro→hex, que `.hex()` não faz |
| UTF-8 escrito à mão | 3 ficheiros | **4 sítios** — e 3 deles estavam ERRADOS |
| `/dev/urandom` à mão | 4 linhas | **1 sítio** — `packages/pforge/repo.psc` |
| datas formatadas à mão | 7 | **a conferir** |
| `os.listdir` que podia ser `scandir` | 27 | **a conferir um a um** |
| sondagem de `mtime` → `os.watch` | 16 | **0** — ver abaixo |
| `.find`/`.startswith`/`.split` → regex | 196 | **0** — ver abaixo |
| `print(` no pforge → `log` | 218 | **0** — ver abaixo |
| `if x != None:` aninhado → `and` | 3 | **0** — são testes desta rodada |

Tamanhos, para dar escala: `selfhost` 45.599 linhas, `pscript/runtime` 15.334,
`packages` 15.138, `pstudio` 10.891, `pforge/src` 3.948.

---

## Os três grandes que NÃO se fazem

Esta é a parte útil do plano. Os três itens de maior contagem são os três que
devem ficar como estão, e cada um por uma razão diferente.

### 1. O vigia não entra no `pforge dev` — duas razões independentes

**A 146.2**: o `os.watch` LEVANTA no macOS, e o próprio DESIGN já escreveu a
consequência — *"o `pforge dev` e o `check_external` do editor não têm vigia no
macOS até alguém escrever o FSEvents. Continuam a sondar, como sondam hoje."*
Quem compila neste projecto compila no macOS. Trocar seria entregar um `dev` que
não corre na máquina de quem o usa.

**E a razão que sobreviveria mesmo sem a primeira**: o `dev` vigia o **grafo** —
os ficheiros que a construção declarou ler. O `os.watch` vigia uma **árvore**.
Trocar um pelo outro faria o `dev` ver as gravações do editor, os temporários e o
próprio `build/` — que é exactamente o que o `cmd_dev` diz, por escrito, que
evita de propósito.

O que mudou foi só isto: o docstring do `cmd_dev` diz que inotify e kqueue
*"forçariam uma primitiva nova no runtime"*. Essa primitiva existe desde a F5. A
frase ficou falsa e **corrigi-la é o trabalho aqui** — não trocar o mecanismo. O
mesmo docstring já tinha previsto o desfecho certo: *"a primitiva entra por
baixo e este comando não muda."*

Os outros 15 achados de `mtime` nem sondagem eram: são a comparação de datas do
grafo de construção (`graph.psc`) e o "o ficheiro mudou debaixo de mim" do editor
(`shell.psc`). Nenhum dos dois é um vigia, e nenhum quer ser.

### 2. As 196 operações de string não viram regex

`.find`, `.startswith` e `.split` são mais rápidos e mais claros do que o padrão
equivalente. O motor da S2 foi escrito para o que **não** se resolve assim — e
trocar um `startswith` por `re.match("^...")` é uma regressão em legibilidade e
em tempo, disfarçada de modernização.

### 3. Os 205 `print` do `pforge/src/main.psc` não viram `log`

A saída de uma ferramenta de linha de comando é uma **interface**, não um fluxo
de registo. O `log` serve o que corre sem ninguém a olhar: níveis, campos,
destino configurável. Um `print` que escreve `built 12 targets in 0.4s` para uma
pessoa que está ali a ver não é um registo mal feito — é a outra coisa.

---

## O que se faz

Quatro fases pequenas. Cada uma é um commit, cada uma fecha com `verify-all` 8/8
nos três modos, e nada é empurrado sem pedido.

- [x] **A1 — o `csprng` no `repo.psc`.** Um sítio, e é literalmente aquilo para
  que o pacote foi escrito: `new_seed` abre o `/dev/urandom` e trata à mão a
  leitura curta. O pacote faz a mesma coisa com o tratamento feito uma vez só. A
  promessa do docstring (*"e de mais lado nenhum"*) mantém-se — é a mesma fonte.

- [x] **A2 — o hex à mão vira `d.hex()`.** Os quatro sítios de pscript:
  `packages/csprng/csprng.psc` (o `token_hex` é uma reimplementação exacta),
  `pforge/src/main.psc:792`, `packages/pforge/targets.psc`,
  `packages/pforge/log.psc`. Os de P — `sha2.p`, `ed25519.p`, `psrt_os.p`,
  `psrt_val.p`, `hash`, `hmac` — **não**: P não tem `bytes`, e o runtime não pode
  chamar os métodos que ele próprio implementa.

- [x] **A3 — os codificadores de UTF-8 à mão viram `.encode()`.** A peça certa
  não era o `Decoder`: o que estava escrito à mão era o lado da CODIFICAÇÃO (o
  lado da descodificação já era `str(b[...])` desde a F1). Quatro sítios:
  `packages/tar/tar.psc` (o encoder completo, 17 linhas), e três que eram
  `u8(ord(ch))` por codepoint — o que **não é UTF-8, é Latin-1**, e calava-se com
  um acento: `packages/sha2/test/`, `packages/hash/test/` e
  `tests/pscript/run/http_server.psc`. Este é o achado da rodada. O `url.psc`
  **não**: o que lá está é percent-encoding conforme o WPT (890/891).

- [x] **A4 — `scandir` onde a ordem não importa: NENHUM.** A conferência
  respondeu sozinha. Dos 27 sítios, a maioria está escrita `sorted(os.listdir(…))`
  — o chamador PEDE determinismo, e o `scandir` é precisamente o que não o dá.
  Dos que sobram, o `targets.psc:977` documenta que depende da ordem (111). Trocar
  pouparia uma alocação num directório de meia dúzia de nomes e custaria a ordem.
  Fica como está.

- [x] **A5 — as datas à mão: NENHUM que valha.** Os sete são carimbos de segundos
  a irem para um log ou para um cabeçalho de `tar`, não formatação de datas.

E dois que a tabela de impacto da própria `PLAN.md` (§ F2/F6) tinha previsto, e
que já estavam feitos DENTRO das fases: o `terminal.psc` já usa o `Decoder` (F6),
e os sítios de `read_all` que a F2 apontou como candidatos a `mmap` precisam
mesmo dos bytes — vão para dentro de um membro de `tar` ou são devolvidos.

---

## O que isto muda no total

**Nove sítios**, em oito ficheiros, todos já cobertos pelas suítes. Não foi uma
refactorização da base de código — foi uma limpeza. E o número honesto vale mais
do que um plano grande: se a adoção fosse enorme, quereria dizer que as fases
entregaram peças e não as ligaram a nada, e não foi isso que aconteceu.

**O que a rodada achou que não estava à procura** — e é a razão pela qual valeu a
pena fazê-la mesmo sendo pequena: **três dos quatro codificadores de UTF-8
escritos à mão estavam errados.** Todos faziam `u8(ord(ch))` por codepoint, que é
Latin-1: dão o mesmo resultado em ASCII, e calam-se com um acento. Estavam em
testes (`sha2`, `hash`, `http_server`), portanto o que produziam era um vector de
teste silenciosamente errado para qualquer entrada não-ASCII. Nenhuma suíte podia
tê-los apanhado, porque o oráculo estava do mesmo lado do erro.

Isto é o mesmo padrão das seis falhas que os testes desta série já tinham
desenterrado: **o defeito aparece quando se escreve o teste, não quando se
escreve a funcionalidade.** Uma peça nova na linguagem não vale só pelo que
passa a fazer — vale por tornar visível o código que a fazia à mão, e mal.

---

## E o que a verificação achou por baixo

Correr o `make verify` para fechar esta rodada desenterrou **três dívidas que já
estavam em `HEAD`** e não tinham nada a ver com a adoção. Ficam registadas porque
a maneira como apareceram é a lição.

### A `build.ninja` estava por regenerar

O grafo comprometido não descrevia o `compress`, o `csv`, o `datetime`, o `log`,
o `ptest`, o `tz` nem os testes novos — todas as fases desta série o deixaram
para trás. O portão dizia-o em cada corrida (`pforge ninja build.ninja`), e a
correcção é uma linha. **Regenerar a `build.ninja` faz parte de fechar uma fase**,
tal como regenerar o seed.

### O `Run` do editor estava partido desde a F8, e o `Stop` também

A F8 mudou o PLAY para dentro do terminal: em vez de `os.spawn`, passou a ser
`run_in_terminal` → `serve_term` → `os.spawn_pty`. O que ninguém fez foi tirar o
`ide.run_pid`, que era o campo que o `os.spawn` escrevia.

A partir daí:

* o arreio `--run` perguntava `ide.run_pid > 0` e lia **0 para sempre** — o teste
  falhava em toda a corrida, e a mensagem (`launched False`) parecia um defeito
  do lançamento;
* e o **`Stop` matava o pid 0**, ou seja, não matava nada, em silêncio, sempre.

Um campo que ficou a mentir é pior do que um campo que desapareceu: o compilador
apanha o segundo e ninguém apanha o primeiro. O `run_pid` saiu, o `Stop` passa a
fechar o filho do terminal, e o `--run` passa a correr o `serve_term` — o mesmo
passo que a janela corre a cada quadro, que é a única maneira de o arreio testar
o que o utilizador usa.

**A ligação com esta rodada:** foi exactamente o mesmo defeito dos três
codificadores de Latin-1 — código que continuou a compilar e a passar depois de a
peça por baixo dele ter mudado. Não é uma classe que uma suíte verde apanhe.
