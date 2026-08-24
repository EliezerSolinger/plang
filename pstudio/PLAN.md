# pstudio e pcode — o plano

O que fazer, em que ordem, e o que cada passo deixa de pé. As DECISÕES estão em
`pstudio/DESIGN.md` (baterias 120-134); este arquivo é o caminho até elas, e é
para ser riscado à medida que se anda.

A regra de fatiamento é sua: **fases pequenas, cada uma verde e útil sozinha**.
Nenhuma fase acaba com o `verify` vermelho, e nenhuma acaba sem alguma coisa que
se possa usar. Foi assim que o `pforge` foi feito (F0–F9) e funcionou.

```
F0   os defeitos (text() quadrático, arquivo vazio, laço sem try) + portão de desempenho
F1   os nomes: pforge -> pforge, cai o lib_ e o ps/
F2   o corte: shell/ide/driver, o pcode nasce, a lista branca
F3   C como cidadão de primeira classe (realce pelos três lexers)
F4   o tema, pelas raízes (8 raízes -> ~30 papéis)
F5   os widgets sobem para o pui + busca no projeto + ir-para-definição
F6   a concha da IDE, os ícones, o .pstudio.json, o atlas alargado
F7   o painel de Build
F8   o PTY no runtime + o terminal
F9   o painel de Testes
F10  pacotes (tar avulso, URL, 0.x no semver) + o painel
F11  make install
```

---

## O ponto de partida, medido

**A acoplagem não está nos arquivos: está na `struct`.**

| onde | total | só da IDE |
|---|---|---|
| campos do `struct App` (`lib_app.psc:98`) | 52 | **21 (40%)** |
| comandos da paleta (`COMMANDS`, string com índices fixos) | 34 | 9 |
| `app.psc` | 721 linhas | **320 (44%)** |

Duas coisas jogam a favor, e as duas foram verificadas:

* **O portão já funciona.** `plangc --pkg-path packages --deps pstudio/app.psc`
  devolve **29 arquivos**, entre eles os quatro proibidos
  (`packages/pforge/lib_{build,graph,log,manifest}.psc`). Transitivo, e a falha
  nomeia o arquivo.
* **O `app_test.psc` (323 linhas) não exercita build nenhum.** Já é um teste puro
  da casca — vira o teste do `pcode` quase sem mexer. A parte de IDE está no
  `--selftest` do `app.psc`, que é o outro lado da mesma linha de corte.

---

## F0 — os defeitos, e o portão de desempenho

Antes de partir o editor em dois, arranjar o que ele tem de errado — é mais
barato num arquivo do que em três, e o portão nasce a medir uma melhoria real em
vez de um número inventado.

### F0.1 — `Buffer.text()` é quadrático

Monta o arquivo com `+=` num laço, e é chamado **em todo o `save`** e em **toda a
construção do índice de completamento**.

| linhas | `+=` em laço | `"\n".join` |
|---|---|---|
| 8 000 | **672 ms** | 0 ms |
| 32 000 | **16 972 ms** | 3 ms |
| 128 000 | — | 682 ms |

O nosso maior arquivo, `selfhost/ps_lower.p`, tem 11 076 linhas: congela mais de
um segundo em cada salvamento, hoje. A correcção é uma linha.

### F0.2 — um arquivo vazio nunca abre

`read_file` devolve `""` tanto para "vazio" como para "não consegui ler", e o
`open_file` (`lib_app.psc:263`) não os distingue: pede ao driver que releia, para
sempre, de 500 em 500 ms, sem mensagem. Verificado — `touch vazio.p` e
`--selftest` dão `tabs 0`, `no file`. Um `.png` aberto por engano cai no mesmo
laço, e se abrisse, salvar truncava-o.

`read_file` passa a devolver **`str?`**: `None` é falha (com o motivo na barra de
estado, e sem abrir aba), `""` é um arquivo vazio de verdade.

### F0.2b — três defeitos da mesma família, achados ao consertar

O `""` não era o único sítio onde a estrutura de dados mentia:

* **`reload_cur` lia o CACHE** — que é o que foi lido quando o arquivo abriu. Um
  reload existe precisamente porque o disco deixou de bater com isso, então
  "Reload File" e a recarga por mudança externa devolviam o texto VELHO. Passa a
  ser um pedido ao driver (`want_reload`), e o driver acha a aba **pelo caminho**,
  não por "a actual": entre pedir e ser servido passa uma volta do laço.
* **`Buffer.load` era quadrático para arquivos CRLF** — tirava os `\r` com `+=`
  num laço sobre o arquivo inteiro. `replace` e `split` no lugar.
* **`Buffer.find` e `find_all` comparavam coluna a coluna**, alocando uma fatia
  por coluna: meio milhão de alocações para varrer um arquivo de 11 000 linhas,
  50 ms onde uma varredura nativa leva um. `find` no lugar.

E dois no realce, que a medição destapou:

* a passagem dos comentários **percorria os codepoints de todas as linhas** —
  35 dos 48 ms de uma tecla. Nove linhas em dez não têm `#`, e perguntar isso de
  uma vez é uma varredura em C;
* `update` **realocava uma lista por linha** a cada relexagem — onze mil
  alocações por tecla. Agora reusa quando a contagem de linhas não muda;
* e o relex saiu do `changed()` (por EDIÇÃO) para o `build` (por QUADRO): entre
  dois quadros pode haver várias edições, e só a última ia ser vista.

### F0.3 — o laço de eventos não tem `try`

Em pscript, estouro de inteiro e índice fora de faixa LEVANTAM. Um defeito de
aritmética de coluna mata o processo e leva o que não foi salvo.

```python
while app.running:
    kind = shim_wait(BLINK_MS)
    try:
        app.feed(ev_from_shim(kind))
    catch e:
        save_all_to_draft(app)        # zero perda, mesmo sem autosave
        app.want_msg = "erro interno: " + e.message
        log_trace(e)                  # build/pstudio/crash.log
        # o laço CONTINUA
```

### F0.4 — o portão de desempenho

Nenhum teste media tempo, e é por isso que o quadrático viveu até hoje. Tectos
**absolutos**, sobre um arquivo grande de verdade:

```
tests/pstudio/perf_test.psc   (selfhost/ps_lower.p, 11 076 linhas)

  abrir                            <  200 ms
  salvar (text())                  <   50 ms
  índice de completamento          <  200 ms
  uma tecla (edição + relexagem)   <   16 ms   (60 fps)
  busca no arquivo                 <   50 ms

# falha com o número medido, não com "lento":
#   FAIL salvar: 1 340 ms, tecto 50 ms
```

O portão é construído com **`-O2`, que é como o editor sai**. Medir velocidade num
binário não optimizado mede o binário errado: o lexer do compilador sozinho custa
15 ms sobre onze mil linhas a `-O0` e 9 ms a `-O2`, e uma tecla tem dezasseis.

O que a F0 mediu, antes e depois:

| | antes | depois |
|---|---|---|
| salvar (`text()`) | 1 340 ms | < 50 |
| uma tecla (edição + relexagem) | 78 ms | < 16 |
| abrir | 202 ms | < 200 |
| busca no arquivo | 51 ms | < 50 |
| abrir com CRLF | quadrático | < 200 |

**A promessa de tamanho:** 50 mil linhas confortáveis — com folga sobre qualquer
código-fonte. Acima disso o editor avisa e abre **só leitura**, sem índice nem
realce, que é o que se quer de um log de 200 MB.

**Fica de pé:** o editor de hoje, sem os três defeitos, e com um portão que
impede o quarto.

---

## F1 — os nomes, num commit só

Nada de funcionalidade. É o momento mais barato que vai existir: **463
referências em 45 arquivos** hoje, e cada fase daqui para a frente acrescenta
mais.

### F1.1 — `pforge` vira `pforge`

O binário faz build **e** pacotes; o nome dizia metade. Uma forja faz coisas a
partir de matéria-prima, e "forge" carrega também o sentido de onde o código
mora.

```
build/bin/pforge        ->  build/bin/pforge
pforge/ + pforge/       ->  pforge/            (os 8 documentos, na raiz dela)
pforge/src/*.psc        ->  pforge/src/*.psc   (pforge.psc -> main.psc)
packages/pforge/       ->  packages/pforge/
```

A biblioteca muda pela mesma razão que o binário: **4 dos 11 módulos** são do
gerenciador de pacotes (`manifest`, `lock`, `repo`, `pkg`), não do motor.

### F1.2 — cai o `lib_` e cai o `ps/`

O prefixo nasceu na migração, quando `core.p` e a versão em pscript coexistiam.
A 116 aposentou os `.p` e ele ficou órfão. A pasta `ps/` ("pscript") tem quatro
arquivos em P dentro — mente duas vezes.

```
pstudio/core.psc      ->  pstudio/core.psc
pstudio/codeview.psc        ->  pstudio/codeview.psc
pstudio/highlight.psc        ->  pstudio/highlight.psc
pstudio/complete.psc  ->  pstudio/complete.psc
pstudio/{shim,hl}.{p,ph}  ->  pstudio/{shim,hl}.{p,ph}
packages/pforge/lib_graph.psc -> packages/pforge/graph.psc   (e os outros dez)
```

`lib_app.psc` e `app.psc` não são renomeados aqui — são **partidos** na F2.

**Fica de pé:** exactamente o que existe hoje, com os nomes certos. O `verify`
verde é o único critério.

---

## F2 — o corte, e a prova

A primeira fase de arquitectura não acrescenta funcionalidade nenhuma. Ela
responde a pergunta cuja resposta ruim custa mais caro depois: **as camadas são
mesmo separáveis?**

### F2.1 — a `struct` parte-se por COMPOSIÇÃO

A casca não sabe que a IDE existe. A dependência anda num sentido só.

```python
record Command:
    name: str
    run:  def(Shell)
    when: (def(Shell) -> bool)?      # apagado quando falso

struct Shell:
    tabs, tree, palette, find, ...   # 31 campos, todos do editor
    commands: list<Command>
    def add_commands(self, cs: list<Command>)

struct Ide:
    sh: Shell                        # composição — nunca um campo dentro de Shell
    want_build: str
    build_msg: str
    ...                              # os 21 campos, do lado deles
```

A tabela mata duas dívidas que já existem: a string `COMMANDS` com 34 entradas de
índice fixo, e o `run_command` que é um `switch` de 34 casos sobre um `int`.

### F2.2 — o driver sai para um componente

```
pstudio/
  driver.psc     ~330   janela, eventos, pintor, quadro, zoom, cache, CLI
  shell.psc      ~900   abas, árvore, paleta, busca, atalhos
  ide.psc        ~640   painéis, build, testes, pacotes
  pcode.psc       ~60   main: driver + shell
  pstudio.psc     ~60   main: driver + shell + ide
```

### F2.3 — o portão, por LISTA BRANCA

Não é lista de proibidos — é a lista do que é permitido, e qualquer `import` novo
falha até ser aprovado. É a única forma que não envelhece.

```
o `pcode` lê EXACTAMENTE 26 arquivos:

  pstudio/pcode.psc  driver.psc  shell.psc  codeview.psc  core.psc
  pstudio/highlight.psc  complete.psc
  pstudio/shim.p  shim.ph  hl.p  hl.ph
  pstudio/pgfx.p  pgfx.ph  pgfx_raster.p  pgfx_raster.ph
  pstudio/font_atlas.p  font_atlas.ph  font_atlas.bin
  packages/pui/pui.psc
  packages/stl/cstr.p  cstr.ph  vec.ph
  selfhost/lexer.p  lexer.ph  plang.ph  ast.ph
```

A mensagem de falha diz **qual arquivo entrou e não estava na lista**. Corre no
`make verify`, ao lado do passo que já compila e corre o auto-teste do editor.

### F2.4 — os testes seguem o corte

`app_test.psc` vira `shell_test.psc` e mede o `pcode`. Nasce `ide_test.psc` com
um driver de mentira: pede build, o falso motor responde, o painel mostra, o erro
navega. Cada binário mantém o seu `--selftest` com SDL dummy.

**FEITA.** `build/bin/pcode` (964 KB) e `build/bin/pstudio` (1185 KB), os dois no
`make`. O portão diz **26 arquivos contra 31**, e o auto-teste do `pcode` imprime
`commands 25` contra os 34 do `pstudio` — a mesma prova, por dentro do binário.

Três coisas que o corte obrigou e que não estavam previstas:

* **`PAL_BUILD` e `PAL_TEXT` eram modos da paleta que só a IDE usava** — "um
  alvo do grafo" e "o nome de uma dependência" dentro de um widget que não tem
  nada que ver com isso. Viraram `PAL_LIST` e `PAL_ASK`: quem abre fornece a
  lista (ou nenhuma) e uma função para a resposta. Três campos genéricos no
  lugar de cinco específicos.
* **Um módulo pscript não pode ter estado** (um módulo importado é um conjunto
  de definições, não um programa). O `cache`, a fila de escritas e o contador de
  socorros do driver viraram um `struct Driver` — o que é a pressão certa: eram
  três globais que ninguém via.
* **Não há tipo para uma função `async`**, então o driver não pode receber "o que
  mais servir" como callback — e importar a IDE para a chamar é exactamente o
  que o portão proíbe. O laço virou um PASSO, e cada `main` escreve as três
  linhas à volta. A do meio é a única diferença entre os dois binários.

---

## F3 — C como cidadão de primeira classe

Vai para a **casca**: realce é do editor, e os dois binários ganham. Cedo porque
é a fase que mexe no compilador, e trabalho no compilador é melhor cedo que tarde.

O lexer de C existe — `Cx.tokenize`, `private` dentro de `selfhost/cfront.p:89`,
com o seu `enum CtKind`. O `cfront.ph` exporta duas coisas (`c_parse` e
`cchar_val`), e o `c_parse` exige C **já pré-processado**, que um buffer de editor
nunca está.

1. Expor o tokenizador no `cfront.ph` com um **modo tolerante** — o equivalente do
   `lex_ex(..., tolerant=True)` que o lado do P tem desde sempre.
2. `hl.ph` ganha um segundo ponto de entrada, com as mesmas classes escalares.
3. `is_p_file(path)` vira `lang_of(path)` e devolve qual lexer usar.
4. O `#` do pré-processador ganha classe própria (a decisão de comentário já é do
   lado pscript, em `highlight.psc`).

Fica para depois, e porquê: **navegação e completamento em C.** Em P uma
declaração é marcada por palavra-chave (`def`, `struct`, `enum`) e o índice varre
tokens; em C uma definição de função não tem palavra nenhuma a marcá-la
(`static unsigned crc32_bytes(const char *d, unsigned n)`) — exige parse, e o
parse exige o pré-processador.

**FEITA.** O `pcode` pinta os `.c`, `.h` e `.i` com o lexer do próprio
compilador. `#include` como palavra-chave, `/* */` e `//` como comentário,
`0xEDB88320u` como número, `int` como palavra-chave e `main` como texto — e um
`.md` abre cru, porque não há compilador para ele e uma cor inventada seria um
segundo realce sem ninguém por trás.

O modo tolerante **já existia**: todos os `fatal_at` do tokenizador do C estavam
atrás de `self->strict`, que é como os headers do sistema são ingeridos. Faltava
só classificar em vez de comer — um campo `display: bool` no `Cx`, e duas
espécies de token (`CT_COMMENT`, `CT_PP`) que o parser nunca vê porque nunca as
pede. **Um tokenizador com uma flag, e não dois**: um segundo, escrito para
exibir, ia divergir, e no dia em que divergisse as cores deixavam de querer
dizer o que o compilador quer dizer.

O que custou, e não estava previsto: o `cfront.p` usa `StrSet`, `StrMap<*Type>` e
`StrMap<i64>`, e os três eram **`implement`ados no `sema.p`** — 7 332 linhas que
um editor não tem uso nenhum para linkar. Foram para o `vecs.p`, que é a casa das
instanciações partilhadas entre front ends, e cujo cabeçalho já dizia isso
("neutral... o front end de C e os back ends usam estes Vecs sem depender do
parser do P"). O `pcode` cresceu **98 KB**, e a lista branca passou de 26 para 33
arquivos — com o argumento escrito dentro dela.

---

## F4 — o tema, pelas raízes

Antes dos widgets: cada widget que nascer com cor fixa dentro é dívida que se
paga dez vezes. Hoje isto está violado em dois sítios — `theme_dark()` tem 13
campos concretos, e o `codeview.psc` tem **11 literais de cor**.

```python
record Roots:
    surface, on_surface, primary, danger, warning, ok, string, keyword

def derive(r: Roots) -> Theme:
    return Theme(bg        = r.surface,
                 panel     = lighten(r.surface, 6),
                 panel_hi  = lighten(r.surface, 12),
                 panel_lo  = darken (r.surface, 4),
                 border    = darken (r.surface, 6),
                 text      = r.on_surface,
                 text_dim  = mix(r.on_surface, r.surface, 45),
                 selection = mix(r.primary,    r.surface, 70), ...)
```

Um tema novo são oito números; um tema afinado, oito mais os poucos que se
discordar — porque **sobrepor um papel vence a derivação**.

**FEITA.** `packages/pui/theme.psc`: oito raízes, trinta papéis, e **zero
literais de cor fora dele** — eram 21 no `codeview.psc` e 1 no `pui.psc`. Claro e
escuro, trocados pelo comando `Toggle Theme`.

A ideia que fez o tema claro funcionar sem fórmulas próprias: **`contrast(n)` — um
passo da página em direcção ao TEXTO**, e não "mais claro". Uma superfície
levantada é mais clara numa página escura e mais escura numa clara,
automaticamente, porque as duas direcções são a mesma frase.

Duas excepções, e são o motivo de a excepção estar escrita: uma **borda** e o
**minimapa** são sombras, e uma sombra é mais escura em qualquer página. Derivá-
las com `contrast` deu ao tema claro uma borda **mais clara que o próprio fundo**
— invisível, e só visível como defeito depois de alguém olhar para o tema claro.
Foi o teste de invariantes que o apanhou, não o `grep`.

O portão é duplo: `tests/theme.sh` (nenhum literal fora do `theme.psc`, e as oito
raízes continuam lá) e as invariantes no teste do `pui`, medidas nos DOIS temas —
o texto legível na página, a borda visível, o `hover` mais longe da página que o
painel, e duas classes de sintaxe nunca com a mesma cor.

De passagem, um defeito no `pui`: o botão usava `panel_hi` como base e tinha um
literal para o `hover` — três estados com quatro cores, e os papéis já diziam
qual era qual. O `pui` foi a **0.2.0**: mudar o `Theme` remove campos, e é o caso
que a F10 tem de resolver no `publish`.

---

## F5 — os widgets sobem para o `pui`

> *"tudo o que for reutilizável e não for específico do programa vai pra pui,
> assim como qualquer lib de ui"*

Promover **e reescrever** o que existe por cima deles — não ficam duas listas no
mesmo programa.

| widget | consumidores |
|---|---|
| **lista/árvore virtualizada** — selecção, teclado, expandir, ícone e cor por linha | árvore de arquivos, paleta, Testes, Pacotes, Outline, Problemas — **seis** |
| **tira de abas** | abas do editor, abas do painel de baixo |
| **camada flutuante** — recortada à janela, acima de tudo | menu do alvo, tooltip, modal, popup de completamento |

Entra junto o que só faz sentido aqui: **a travessia de foco por teclado.** O
`pui` define `K_TAB` (linha 215) e **nunca o trata** — sem anel de foco, painéis
não servem, porque não se sai deles sem rato.

E entram as duas funcionalidades que a lista virtualizada destranca, ambas na
CASCA — os dois binários ganham:

* **Busca no projeto inteiro.** Não existe: o `find_changed` busca só no buffer
  aberto. **Varre a cada busca, em tarefa assíncrona** — sem índice, sem
  invalidação, sem memória, com os resultados a aparecer à medida que chegam.
  Este repositório são ~58 mil linhas de fonte.
* **Ir-para-definição entre arquivos.** O `index.build(buf, [])` tem um parâmetro
  `extra: list<str>` documentado para isto e **sempre vazio**. Passa a ser um
  índice do projeto **sob demanda**: nada ao abrir, e ao pedir a definição de um
  símbolo desconhecido varre nesse momento e guarda.

**Risco assumido:** reescrever árvore/paleta/abas mexe em código que passa em
quatro testes headless. É por isso que esta fase vem DEPOIS do corte — com o
`pcode` de pé, uma regressão é visível num binário pequeno em vez de no meio da
IDE.

**Fica de pé:** o `pui` publicado passa a ter lista e árvore — o que qualquer
utilizador dele quer primeiro. E a `shell` fica mais fina, o que **fortalece a
prova de desacoplamento**: os dois objectivos empurram na mesma direcção.

---

## F6 — a concha da IDE, e os ícones

O layout escolhido, ainda vazio: barra de ferramentas em cima, árvore à esquerda,
editor ao centro, outline à direita, dock de abas em baixo. Vazio de propósito —
para descobrir cedo se o `SPLIT` de duas vias aninhado chega para quatro zonas, e
como é que um painel colapsa e volta.

### Os ícones

Alfa 8-bit tingido por um papel do tema — o `draw_glyph` (`pgfx_raster.p:154`) já
faz exactamente isso para os glifos, com `blend(dst, color, a)`. O ícone é a mesma
função com largura e altura próprias, **e obedece ao tema de graça**.

```
icons.png  ->  tools/mkicons.c (stb_image.h, offline)  ->  icons.bin
           ->  embed_bytes("icons.bin")                ->  um binário só
```

Os sete tamanhos saem **reduzidos do gerador**, não em tempo de execução: o editor
fica sem código de redução nenhum, e são ~105 KB ao lado dos 263 KB da fonte. O
`icons.png` são ~40 ícones de um conjunto livre (Lucide ou Feather, traço de 2px,
desenhados para 24px), rasterizados uma vez por ferramenta de fora e comitados —
o build não depende dela.

### O outline

Alimentado pelo **índice de completamento que já existe**: o `complete.psc` já
varre o buffer e recupera declarações a cada relexagem. O outline é essa lista
ordenada por posição em vez de por relevância — zero análise nova, e funciona no
arquivo por salvar.

### O estado

`.pstudio.json` na raiz do projeto, comitável, um arquivo só — layout, alvo
padrão e **atalhos**, que a tabela de comandos da F2 tornou dados. **O `pcode`
não lembra nada e tem atalhos fixos**: se houver um `.pstudio.json` na pasta, ele
ignora, porque zero I/O ao arrancar é metade do que o faz rápido.

Configuração inválida **nunca bloqueia e nunca cala**: usa o padrão e diz na
barra de estado (`.pstudio.json:12 — keys.ctrl+q desconhecido, ignorado`).

Entra aqui também o **atlas alargado**: JetBrains Mono tem cirílico e grego, são
~300 codepoints e o atlas passa de 263 KB para ~700 KB. CJK e emoji continuam
`□`, e isso fica DITO em vez de descoberto.

**Fica de pé:** a IDE tem a cara que vai ter. Os painéis dizem "vazio".

---

## F7 — o painel de Build

O motor já está dentro do editor — falta a cara. Progresso `[n/total]` como
**barra** e não como texto, a lista de arestas, o erro clicável, e o alvo
escolhido no menu da barra de ferramentas.

Sobe sozinho ao começar, e fica na falha. **Build é sempre explícito na v1**:
nada de reconstruir ao salvar nem de vigiar o disco.

**Fica de pé:** build → falhou aqui, a primeira metade da espinha.

---

## F8 — o PTY, e o terminal

A primitiva vai para o **runtime do pscript** (`os.spawn_pty`, como o `os.run`
foi), não para o driver do pstudio. Assim o `pforge dev` e qualquer programa
pscript ganham — e a primitiva ganha um segundo consumidor, que é o teste de que
ela está no lugar certo.

O widget ANSI (cores, cursor, redimensionar, scrollback, selecção) **desenha-se
fora do `pui`**: um `WK_CUSTOM` com acesso directo ao `shim`. Foi a única questão
de pesquisa que havia — uma grelha 80×24 com fundo por célula seriam 3 840
comandos por quadro contra os ~50 do codeview — e a decisão fecha-a sem mexer no
modelo de desenho.

O histórico tem **tecto em linhas, em anel circular** — um programa em laço não
come a memória toda, e o coletor copiador não paga o dobro por isso.

**Fica de pé:** `Run` roda o programa num terminal de verdade, com stdin.

---

## F9 — o painel de Testes

Vem quase de graça: o `pforge test --json` já emite um evento por caso com
`{"what": "suíte: caso", "status", "ms", "output"}`, e o `tally` já parte o
rótulo em suíte e caso. Falta a árvore, o tempo por caso, o diff, e clicar para ir
ao arquivo.

Sobe sozinho **só ao falhar**: uma suíte verde não deve roubar a tela.

**Fica de pé:** a espinha inteira — build → rodar → testar → falhou aqui.

---

## F10 — pacotes

Metade no `pforge`, metade painel.

```sh
pforge add ./foo-0.1.0.tar
pforge add https://algum.site/foo-0.1.0.tar
```

O tarball já É o pacote. Hasheia-se o que chegou, grava-se no lock com `repo` = de
onde veio e `unsafe: true` se ninguém assinou, e abre-se em `build/pkg/`. O `.sig`
ao lado verifica se existir. A `struct Locked` já tem os sete campos que isto
precisa; falta a entrada por arquivo e por URL.

No painel: a árvore de dependências (`pforge tree`/`why` com cara), adicionar,
subir versão, e ver o que um pacote exporta (`--api` já responde).

Entra aqui uma correcção que a F4 vai forçar antes: mudar o `Theme` **remove
campos** do `pui`, e com o mesmo `major` o nosso `publish` só aceita um `minor`
que acrescenta (`pforge.psc:1429`). **0.x passa a ser especial** — é o que o
semver diz e o que o Cargo faz — e o `publish` **aceita e AVISA**, para a
excepção ficar visível em cada publicação em vez de escondida na regra.

**Fica de pé:** *"incluir pacotes de terceiros no projeto, mais ou menos como
incluir jar nas ides java"* — com uma diferença a favor: o tar tem hash, e um JAR
no classpath não tem.

---

## F11 — instalar

`make install` com `PREFIX` (por omissão `/usr/local`): copia `plangc`, `pforge`,
`pcode` e `pstudio` para `$PREFIX/bin`. Unix simples, sem inventar formato — e
sem isto o `PATH` aponta para dentro de um checkout, e um `make clean-all` apaga
o editor que se estava a usar.

---

## O que NÃO está no plano, e porquê

| não entra | porquê |
|---|---|
| **depurador** | b120: *"`print` e stack trace bastam"*. Nada de informação de linha no C gerado, nada de protocolo, nada de parar o runtime. O investimento vai para o trace ser clicável e trazer valores. |
| **painel de Problemas** | v2. O sublinhado no editor já avisa; a lista do projeto inteiro é conveniência. |
| **diagnóstico vivo enquanto digita** | v2. `--parse-only` e `--diag-json` já respondem; é a fase mais fácil de acrescentar depois, e não estava na espinha. |
| **navegação e completamento em C** | exige parse, que exige o pré-processador. A F3 entrega o realce. |
| **ícones vectoriais** | *"irá vir muito mais pra frente"*. Bitmap agora, mesmo que escale mal. |
| **várias janelas** | um projeto por PROCESSO. Abrir outro é outro `pstudio`. |
| **estado no `pcode`** | ele abre qualquer pasta e não guarda nada. |

---

## Riscos, ditos antes de doerem

1. **A F1 toca em 45 arquivos.** Mecânico, mas 225 das referências estão em `.md`
   que citam decisões suas. Mitigação: prosa é reescrita à mão, nunca por regex —
   é a lição que a tradução para inglês custou dois erros a aprender.
2. **A F5 reescreve código testado.** Quatro suítes headless e os seus
   `.expected` mexem juntos. Mitigação: vem depois do corte, e cada widget entra
   com o teste do `pui` a medir as MESMAS oito linhas de rectângulo que o
   `pui_test` já mede.
3. **A F3 mexe no compilador.** Expor um tokenizador `private` com um modo novo
   pode desestabilizar o front end de C, que hoje passa 220/220 na c-testsuite.
   Mitigação: o modo tolerante é um caminho separado, e a suíte de C é portão do
   `verify`.
4. **A F8 mexe no runtime do pscript.** Um PTY é descritor, sinal e `poll` —
   perto do laço de I/O que o `pforge` usa. Mitigação: o segundo consumidor
   (`pforge dev`) é exactamente o que expõe um PTY mal feito.
5. **A lista branca vai irritar.** Um `import` legítimo novo no `pcode` falha o
   portão até alguém aprovar. É o preço, e é o ponto.
