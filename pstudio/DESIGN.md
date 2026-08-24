# pstudio — Plang Studio

Editor de código GUI (estilo Sublime), escrito em **P puro**, no repo do plang.
Todas as decisões abaixo foram fechadas em sessão de desambiguação (2026-07-24).

## Identidade e escopo
- Pasta `pstudio/`, binário `pstudio`, "Plang Studio" na janela.
- **v0.1**: multi-abas + árvore de arquivos + command palette; editar/salvar
  com highlight de P; cursor/seleção/scroll; undo; multi-cursor (ctrl+d).
- Linux primeiro (SDL2 mantém as outras portas abertas).
- Atalhos Sublime básicos: ctrl+s/z/y/x/c/v, ctrl+p, ctrl+f, ctrl+w,
  ctrl+tab, ctrl+g, ctrl+d.

## Dependências
- **SDL2. Só.** (janela, input, clipboard, apresentação).
- Fonte: **atlas bitmap pré-gerados** de JetBrains Mono (OFL) — o gerador usa
  stb_truetype **apenas offline** em `pstudio/tools/`, nunca linkado no editor.
  Escala: um atlas base + vizinho-mais-próximo inteiro (2x, 3x).
  stb_truetype em runtime fica para depois (mesma API de atlas).
- **Sem libuv**: o loop do SDL é o único loop. Operações lentas vão a um mini
  work-queue em P (~300 linhas, pthreads) e voltam via SDL_PushEvent
  (semântica de completions). Backend local resolve síncrono.
- **100% P**: SDL via `include <SDL2/SDL.h>` (ingest do cfront). Se o ingest
  engasgar, **consertar o cfront primeiro** — SDL.h é teste de estresse do
  compilador.
- **SEM feature de interface na linguagem** (proposta e descartada): a
  heterogeneidade se resolve com enum + box (abaixo) e `match type`.

## Camadas

### 1. psys — sistema operacional (**virou stdlib do pscript na 111**: `os` e `path`)
- **VFS por interface de function pointers**; backend `local` no v0.1,
  `ssh/sftp` futuro (visão: **editar arquivos remotos**, editor roda local;
  transporte por subprocesso ssh/sftp via pipes — sem libssh2).
- **API de arquivo inteiro**: `read_all(path) -> bytes`,
  `write_all(path, bytes)` **atômico** (temp + rename), `list_dir`, `stat`.
  Interface já async-ready (completion); local pode ser síncrono.
- Processos (rodar plangc, capturar stdout/err), clock, env, paths.
- Mudança externa de arquivo: **stat ao focar** janela/aba — mtime mudou sem
  edições locais → recarrega; com edições → pergunta.

### 2. pgfx — plataforma gráfica
- SDL2 por dentro. Framebuffer nosso u32 ARGB em RAM →
  `SDL_UpdateTexture` → `SDL_RenderCopy` → `SDL_RenderPresent` (vsync).
- **Frame dirigido a eventos, um present por FRAME**: o loop bloqueia em
  `wait_event` (timeout de ~500ms para piscar o cursor) e então **drena** a
  fila com `poll_event` antes de desenhar uma única vez. Um present por
  *evento* seria fatal: o vsync segura ~16ms cada um enquanto o X entrega
  centenas de movimentos por segundo, e o arraste fica atrás do cursor
  (medido: 200 movimentos = 182ms de CPU assim, 1,9ms drenando). Editor
  parado = 0% CPU.
- **Repaint só quando algo sujou**: `Ui.needs_draw` é levantado por
  `queue_redraw`/`set_rect`/`layout`; mover o mouse sem efeito visual não
  custa frame nenhum (`set_text` com o mesmo texto também não suja).
- Rasterizador de software em P: rects, linhas, blit de glyphs do atlas com
  alpha, clip-rect por widget.

### 3. pui — toolkit (modelo Godot reimplementado)
- **Árvore em POOL LINEAR com índices** (estilo adjacency list clusterizada):

  ```python
  struct UINode:
      kind: WidgetKind
      parent: i32          # -1 = raiz
      first_child: i32     # -1 = folha
      next_sibling: i32    # ordem dos irmãos = ordem de desenho
      base: WidgetBase     # rect, min_size, dirty, flags — INLINE (walk quente
                           #   de layout/dano não dereferencia nada)
      data: *void          # payload específico (Button, CodeView...) —
                           #   tocado só no draw/input do próprio widget
  ```

  Handles são **WidgetId = i32** (nunca ponteiro para nó — o pool realoca);
  sinais/foco/captura guardam IDs. Reparent/insert O(1) pelos links; ordem
  DFS cacheada (recomputada só quando a estrutura muda) dá walk linear no
  draw. Subárvore morre desligando links; payloads têm `deinit` explícito.
- Dispatch por `match node.kind`. Sem herança, nunca; sem interfaces
  (proposta e descartada).
- **Layout em duas fases** (Godot): minimum size sobe, rect desce
  (containers Box/Split/Tab). O toolkit **não assume grade mono** — medição
  de texto é API genérica de fonte (a matemática da Godot); a fonte mono é
  detalhe da implementação atual. O CodeView pode explorar mono por dentro.
- **Draw retained**: cada widget mantém sua **lista de comandos** em cache;
  regrava só quando sujo (queue_redraw); pgfx faz replay na composição.
- **Sinais**: listas de `{fn pointer, *void ctx}` (connect/emit).
- **Input modelo Godot**: foco de teclado único (tab/click), mouse por
  hit-test descendo a árvore, **captura** no press até o release (drags).
- **Tema**: struct de cores/métricas consultado pelos widgets; preset dark
  (Monokai-like) compilado no v0.1; arquivo de config depois.
- **Gutters plugáveis** no CodeView (números, breakpoints, erros do build —
  mesma abstração, como o TextEdit da Godot).
- Referência: clone esparso da Godot no scratchpad (containers/code_edit).

### 4. core — edição (headless, testável sem janela)
- **Buffer: array de linhas** (Vec de linhas; trocável por piece table atrás
  da API de Buffer).
- **UTF-8 correto desde já**: bytes UTF-8, cursor/seleção por **codepoint**
  (reusar `selfhost/utf8.p`); glyph fora do atlas renderiza □. Sem grapheme
  clusters no v0.1.
- **Undo coalescido**: digitação contínua agrupa; quebra em
  espaço/enter/pausa (~700ms)/movimento. Ctrl+z desfaz "a palavra".
- **Multi-caret real no v0.1**: lista de carets desde o início; ctrl+d cria
  carets; digitação/backspace/setas aplicam em todos.
- **Highlight: relexa o ARQUIVO INTEIRO a cada edição**, reusando
  `selfhost/lexer.ph` (tokens reais de P). Simples primeiro; incremental por
  linha só se/quando doer (>50k linhas).

### 5. app — o editor
- **Linha de comando**: `pstudio [pasta|arquivos]` — pasta abre a árvore na
  raiz; arquivos abrem em abas (árvore no diretório comum); sem args = árvore
  no cwd. **Sem restauração de sessão no v0.1** (v0.2).
- Abas **na coluna do editor** (não numa faixa no topo geral): a árvore de
  arquivos ocupa a altura toda, como Sublime/VS Code. Cada aba tem marcador de
  sujo (`*`) que vira **botão × ao passar o mouse** (clique no × ou botão do
  meio fecha); fechar aba suja → **SDL_ShowMessageBox** nativo com
  salvar/descartar/cancelar — modal do pui só se o do SDL ficar curto.
- **Strings de interface em inglês** (o código e os comentários também, como no
  compilador); só este documento de design fica em português.
- Árvore de arquivos (VFS): **filtrada** (esconde dotfiles, .git, out/,
  tests/out) e **somente-leitura** no v0.1 (operações de arquivo = v0.2).
  Cabeçalho **FOLDERS** como a sidebar do Sublime — e ele é um **widget de
  verdade**: o painel da árvore é um box com fundo (`set_bg`) contendo
  [label FOLDERS | linhas], então quem decide onde as linhas começam é o motor
  de layout, não offsets escritos à mão (o rect do widget de linhas mapeia 1:1
  nelas). `set_bg`/`set_pad` no `WidgetBase` existem para isso: dão fundo e
  recuo a qualquer widget sem precisar de um wrapper tipo PanelContainer.
- Status bar: arquivo, linha:coluna, EOL.
- **Palette (ctrl+p)**: fuzzy de arquivos; `>` muda para comandos; `:` vai
  para linha. Um widget só, modelo Sublime.
- Busca no arquivo (ctrl+f) incremental (POSIX regex da libc para modo
  regex).
- **SEM sistema de build no v0.1** (decidido): nenhuma integração com plangc
  por ora. O gutter do CodeView nasce PLUGÁVEL (números de linha já usam a
  API), então erros/breakpoints plugam depois sem refactor.

### Edição de código (reaproveitando a matemática do CodeEdit da Godot)
- **Code folding por INDENTAÇÃO** (a regra do `can_fold_line`/`_fold_line`
  deles, que em P é a história inteira: sem `#region` e sem string/comentário
  multilinha). O custo real não é dobrar, é o **mapeamento linha↔tela**: com
  linhas escondidas, uma fileira da tela não é uma linha do buffer. Ele vive no
  `Buffer` (`visible_count`/`next_visible`/`to_visible`/`from_visible`) e o
  CodeView passa por ele nos SEIS lugares que convertem coordenada
  (desenho, `pos_from_xy`, `scroll_to_caret`, barras, `set_top`, largura
  máxima). Word wrap, quando vier, usa a mesma máquina.
  - invariante: `folded` ⇒ o bloco abaixo é exatamente o `hidden`. Qualquer
    edição crua que toque um cabeçalho **libera** o fold (`unfold_range` nos
    `raw_insert`/`raw_delete`), e um caret dentro do bloco é puxado para o
    cabeçalho ao dobrar.
  - fold aninhado **continua dobrado** ao abrir o externo (a Godot desfaz os
    dois e deixa o `folded` inconsistente).
  - gutter `▾`/`▸` **clicável** (o `Gutter` ganhou `click`, como os gutters da
    Godot); `…` marca o bloco recolhido; `ctrl+[`/`ctrl+]`, `ctrl+shift+[`/`]`
    e os comandos Fold/Unfold/Fold All/Unfold All na palette.
- **Comandos de linha** (mover, duplicar, apagar, juntar) e **toggle comentário**
  no `Buffer`, multi-caret e num único grupo de undo: cada caret gera um bloco
  de linhas, blocos que se tocam são fundidos, e o processamento é de baixo
  para cima. O comentário entra na MENOR indentação do bloco (marcadores
  alinhados) e sai quando todas as linhas já estão comentadas.
- **Guias de indentação**: régua de 1px em cada parada de tab dentro do recuo;
  linha em branco herda o recuo do vizinho menos profundo (a Godot não tem
  isso, e numa linguagem indentada ajuda mais que em C).
- **Auto-pares** `()[]{}""''`: abre o par, digitar o fechamento pula por cima,
  backspace entre um par vazio apaga os dois, seleção é envolvida. Uma quote
  logo depois de letra/dígito é apóstrofo, não par.

### Minimap, marcas e autocomplete
- **Minimap** desenhado a partir do HIGHLIGHT (não dos glifos), como a Godot:
  cada linha vira faixas de 2px coloridas por classe; janela translúcida marca
  o viewport; clique/arraste salta. Isso pediu **alpha no `fill_rect`** do
  rasterizador (cor com alpha < 255 agora mistura) — antes só o texto tinha.
- **Marcas por linha** (`BufLine.mark`, bitmask): ● breakpoint (clique no
  gutter) e ◆ bookmark (ctrl+F2, F2/shift+F2 navega). Viajam com a linha nas
  edições e são o **segundo e terceiro clientes** do gutter plugável — a
  abstração deixou de ser promessa.
- **Autocomplete** (`complete.ph/.p`) alimentado pelo **lexer do compilador em
  modo tolerante**: funciona em buffer meio digitado e nunca sugere de dentro
  de string/comentário. Do fluxo de tokens ele recupera `def`, `struct` + seus
  membros, `x: T` (inclusive **parâmetros**) e os `import`s — indexando também
  os `.ph` importados. `x.`/`x->` lista os membros do tipo de `x`; **`self.`
  resolve pelo struct que contém o caret** (por indentação), não por adivinhação.
  Popup ancorado no caret (vira para cima quando não cabe), ctrl+espaço abre,
  setas navegam, enter/tab aceita.
  - o que NÃO é: um type checker. Tipagem de expressão completa precisa de
    parser tolerante + sema sobre o buffer; quando existir, entra atrás da
    mesma API de query.

### Comportamento de texto
- **TAB = 4 espaços** (soft tabs; backspace inteligente no início da linha);
  `\t` existente renderiza com largura 4.
- **EOL preservado por arquivo** (detecta LF/CRLF na abertura, mantém no
  save, mostra na status bar; buffer interno sempre LF).
- **Sem word wrap** no v0.1 — scroll horizontal.
- **Scrollbars internas ao CodeView** (padrão Godot: o TextEdit deles cria
  as barras como filhos internos que ele mesmo gerencia — copiar o desenho).
- **Clipboard multi-caret estilo Sublime**: copiar N seleções guarda N
  pedaços; colar com N carets distribui 1:1; para o clipboard do sistema
  (SDL) vai unido por \n.
- Defaults menores: caret de barra piscando ~500ms; **zoom = 7 tamanhos REAIS
  no atlas** (11/13/15/17/20/24/29px, começando em 17px). Escala inteira de
  bitmap foi descartada: 1x→2x dobra tudo de uma vez e fica inusável — cada
  passo agora é uma rasterização de verdade da fonte.

## Verificação
- `make verify` tem o passo **7/8**: compila e LINKA o editor inteiro (driver em
  P + runtime do pscript + as camadas em pscript) e roda o `--selftest` dele.
- A suíte `tests/pstudio` roda nos 3 modos (C/QBE/C89): dois testes do driver em
  P e quatro do editor em pscript, todos headless e com `.expected`.
- **SDL2 = dependência com skip gracioso**: sem libsdl2-dev o passo 7/8 avisa
  "skipped: no SDL2" e os testes headless rodam do mesmo jeito.
- Build: `plangc --out-dir out ...` (espelho; repo limpo).

## Ordem de construção — v0.1 COMPLETA
1. ✅ **psys** (VFS local + process + clock) + testes headless
2. ✅ **ingest do SDL2** no cfront (rendeu 10 correções no front end C)
3. ✅ **pgfx**: janela + framebuffer + atlas (gerador em pstudio/tools/)
4. ✅ **pui**: pool linear + containers + cmd lists + sinais + input + tema
5. ✅ **core**: buffer UTF-8 + carets + undo + highlight (lexer real)
6. ✅ **app v0.1**: CodeView com gutters, abas, árvore, palette, ctrl+f

## Como construir e rodar
```sh
sudo apt install libsdl2-dev            # única dependência
make pstudio                            # -> out/bin/pstudio
./out/bin/pstudio .                     # árvore no diretório atual
./out/bin/pstudio selfhost/sema.p       # abre arquivos em abas
```
Sem X/Wayland (servidor), o editor ainda pode ser inspecionado: `--shot`
renderiza UM frame e grava um PPM, e `--size LxA` escolhe a resolução:
```sh
SDL_VIDEODRIVER=dummy ./out/bin/pstudio --size 1000x620 --shot /tmp/e.ppm . core.p
```

## Estado da implementação (arquivos) — depois da 116

**O editor é pscript.** Em P sobrou o DRIVER: o que é pixel e ponteiro do começo
ao fim, e o lexer do compilador. A tabela é o mapa de quem faz o quê.

| arquivo | linguagem | o que é |
|---|---|---|
| `core.psc` | pscript | `Buffer`: linhas UTF-8, multi-caret, undo agrupado, busca, dobra, marcas |
| `ps/lib_pui.psc` | pscript | `Ui`: pool de nós, layout em 2 fases (Godot), listas de comando retidas, sinais, entrada |
| `highlight.psc` | pscript | o realce: spans por linha a partir dos tokens, e o comentário |
| `complete.psc` | pscript | o índice de completamento (declarações, membros, `self.`) |
| `codeview.psc` | pscript | o widget de edição: sarjetas, barras internas, minimapa, popup |
| `shell.psc` | pscript | abas, árvore, paleta, busca, atalhos, barra de estado |
| `app.psc` | pscript | o driver do editor: janela, tradução de evento, quadro, linha de comando |
| `shim.ph/.p` | **P** | a fronteira do SDL2: janela, evento, pixel, glifo, área de transferência — assinatura de ESCALARES (45.5) |
| `hl.ph/.p` | **P** | a fronteira do LEXER do compilador: o texto entra como `CStr`, os tokens voltam como números (113) |
| `pgfx.ph/.p` | **P** | SDL2: janela, textura streaming, eventos, diálogos |
| `pgfx_raster.ph/.p` | **P** | `PgRect`/`PgFont`/`PgFb`: rects, clip, blend, texto — headless |
| `font_atlas.ph/.p` | **P** | o atlas GERADO (ASCII + Latin-1 + pontuação, □ de fallback) |
| `tools/mkatlas.c` | C | o gerador do atlas (stb_truetype, offline; nunca linkado) |

Proporção: **4200 linhas de pscript** por cima, **820 de P** por baixo.

Testes (`tests/pstudio/`): dois do driver em P (`pgfx_raster`, `pgfx_smoke` com
driver dummy) e quatro do editor em pscript, todos headless — `ps_core`
(buffer), `ps_pui` (toolkit e layout), `ps_cv` (o widget, com o lexer do
compilador do outro lado da fronteira) e `ps_app` (o editor INTEIRO: abas,
árvore, paleta, busca, dobra, pares, completamento, um quadro desenhado) — mais
o `--selftest` do binário completo, com SDL2.

### O que saiu na 116

`core.p`, `pui.p`, `codeview.p`, `complete.p`, `app.p`, `main.p` e `psys.p` com
os seus headers: **6448 linhas de P**, aposentadas depois de a paridade ter sido
medida método por método (115) e de os três buracos que ela achou terem sido
fechados. O `psys` não tem substituto em pstudio porque virou stdlib do pscript
na 111 (`os` e `path`).

---

## Migração total para pscript (decidido 2026-08-21)

Suas palavras: *"o pstudio temos que migrar ele totalmente para PScript e a parte
de sistema vai pra lib/runtime do PScript onde for possível"*.

O que isso quer dizer, camada por camada:

| hoje | depois |
|---|---|
| `psys.p` (P): arquivo, diretório, `stat`, `ps_run`, caminho, tempo | vira **stdlib do pscript** (um módulo `os`/`path`, implementado em P como `random` e `time` — 108.4). O pstudio passa a IMPORTAR, não a conter |
| `pgfx.p`, `pgfx_raster.p`, `font_atlas.p` (P) | **ficam em P**: são pixels e ponteiro do começo ao fim, e a 45.5 não deixa isso atravessar. Passam a ser o DRIVER, chamado só pelo shim |
| `pui.p`, `core.p`, `app.p`, `codeview.p`, `complete.p` (P) | pscript |
| o shim escalar da bateria 71 (`pstudio/shim.p`) | **fica, e é a fronteira**: janela, evento, pixel e glifo, com assinatura de escalares. É o que "totalmente em pscript" quer dizer num programa que fala SDL — a lógica inteira em pscript, e uma página de P a tocar o ponteiro |
| o realce, que usa o lexer DO COMPILADOR (`lex_ex`, core.p:1464) | **DECIDIDO (113)**: o lexer continua em P, num adaptador (`pstudio/hl.p`) que recebe o texto inteiro como `CStr` e devolve os tokens como NÚMEROS. A lógica (classe, comentário, índice de completamento) fica em pscript. Um segundo lexer em pscript divergiria do do compilador, que é justamente o que o realce serve para mostrar |

O ganho não é estético: **o pstudio é o maior consumidor de P do projeto** (é o
que a bateria 7/8 do `verify-all` mede), e ele em pscript é o maior programa
gráfico em pscript que existe — com o coletor, os workers e o laço de eventos
sob carga real. E a camada de sistema, ao sair daqui para a stdlib, ganha um
segundo consumidor: o **pforge** (ver `pforge/DESIGN.md`, 1.1), que é justamente
o teste de que ela está no lugar certo.

O limite nomeado: **SDL, janela e teclado continuam aqui**. O que é do editor não
é stdlib de ninguém.

**Estado (2026-08-21).** Dois passos feitos:

  1. a bateria 111 do pscript tirou a camada de SISTEMA daqui e pôs na stdlib
     (`os` e `path`), com o `psys.p` como fonte do porte;
  2. a bateria 112 portou o `pui` — `pstudio/lib_pui.psc`, com o teste
     headless imprimindo os MESMOS retângulos que o teste do pui em P;
  3. a bateria 113 respondeu a pergunta do REALCE e portou o resto do miolo: o
     lexer do compilador fica em P e atravessa por um adaptador de escalares
     (`pstudio/hl.p`, aprovado por você), e com ele vieram `lib_hl.psc`,
     `lib_complete.psc` e `lib_cv.psc` — o `codeview` inteiro, imprimindo as
     mesmas sete linhas do teste de dobra do editor em P.

  4. a bateria 114 portou o `app` — `lib_app.psc` (a lógica: abas, árvore,
     paleta, busca, atalhos) e `app.psc` (o driver: janela, eventos, quadro) —
     e o `make pstudio-ps` constrói o editor COMPLETO.

**A migração está feita, e a paridade está medida** (ver a seção seguinte). Em P sobrou o que a 45.5 não deixa atravessar: SDL
(`pgfx`, `pgfx_raster`, `font_atlas`, `shim.p`) e o lexer do compilador
(`hl.p`). É o que "totalmente em pscript" quer dizer num programa que fala com
uma placa de vídeo — a lógica inteira de um lado, duas páginas de P do outro.

## Paridade: o que o editor em P fazia, e onde está agora (bateria 115)

Sua condição para aposentar o editor em P: *"só quero garantir que o novo PScript
vai fazer tudo o que o velho fazia"*. Esta é a varredura, feita pelos HEADERS —
todo `def` público dos cinco arquivos de interface do editor em P, um por um,
contra o que existe em pscript. 197 métodos.

| camada | métodos em P | em pscript | o que mudou de forma |
|---|---|---|---|
| `core.ph` (Buffer, Highlight) | 67 | 67 | `init`/`deinit` viram `new_buffer()` e o coletor; `save_text` é `text()`; `col_byte` não existe porque índice é CODEPOINT (3.4); `line_ranges` é `line_span` |
| `pui.ph` (Ui) | 52 | 52 | `init`/`deinit` idem; `cmd_text_n` é `cmd_text` com uma fatia |
| `codeview.ph` (CodeView) | 50 | 50 | `load_file`/`save_file`/`reload` viram `load_text`/`text_to_save` (o I/O é do driver, 114.2); as três `*_gutter()` viram `add_gutter(GUT_*, largura)`; `cv_of` não existe porque `cv_create` devolve o objeto |
| `complete.ph` (Index) | 7 | 7 | `build` não lê arquivo: `imports_of` diz quais são e quem espera lê (113.3) |
| `app.ph` (App) | 21 | 21 | `init` é `new_app` + `wire`; `screenshot` é `--shot` pelo shim; `deinit` é o coletor |

**E os três buracos de verdade que a varredura achou** — nenhum deles aparecia
por nome, os três apareceram por COMPORTAMENTO:

**115.1 A dobra não se soltava ao editar dentro dela.** O `core.p` chamava
`unfold_range` no início de `raw_insert` e `raw_delete`: uma edição que ALCANÇA um
bloco recolhido o solta, porque undo/redo alcança. O porte tinha deixado o
invariante atrás, e o efeito era linha com conteúdo novo que a vista nunca
mostrava. Portado, com o `unfold_enclosing` que ele usa (uma linha escondida sem
cabeçalho acima é revelada — nunca se deixa uma linha invisível).

**115.2 O zoom não fazia nada.** Os comandos 5/6/7 da paleta e o `ctrl+=`/`-`/`0`
caíam num ramo que só tratava 11..23. E o zoom precisa do DRIVER: o passo é uma
grade RASTERIZADA de verdade (11..29px), não um multiplicador. Entrou como as
outras funções de sistema — um campo `zoom_step` que o `app.psc` preenche —, e o
`shim` passou a expor o passo PADRÃO, para o reset cair no mesmo lugar que no
editor em P.

**115.3 O F2 não existia.** No editor em P ele é atalho SEM ctrl (F2 anda entre
marcadores, shift+F2 anda para trás, ctrl+F2 põe e tira a marca), e o meu
`key_shortcut` saía cedo quando não havia ctrl.

De passagem, três coisas menores: a linha de comando ficou a mesma do editor em P
(vários arquivos em abas, `--size LxA`, `--shot`, e diagnóstico para opção
desconhecida e caminho que não existe), o título da janela passou a acompanhar a
aba, e o `app_test.psc` cresceu para medir tudo isto — inclusive o clique de
sarjeta por PIXEL, que é o caminho que o teste em P exercita.

O que fica para você: **aposentar ou não o editor em P.** Ele são 8 mil linhas e
é o que o passo 7/8 do `verify-all` usa para medir a compilação de P; apagá-lo
tira essa medida. As duas versões convivem sem custo (`make pstudio` e
`make pstudio-ps`), então não há pressa nenhuma nessa decisão.

---

## O destino do pstudio — baterias 120-123 (2026-08-24)

Suas palavras: *"eu precisava mesmo é de uma IDE integrada com o ecossistema
igual um netbeans da vida, acho que faz mais sentido como sendo editor da
linguagem"* — e, na mesma sessão, *"vc poderia manter uma build dentro do
pstudio minimalista junto com o pstudio, na mesma pasta. um PCode ai se o
PStudio, ai teremos um zed e uma IDE, e também vai servir para provar
desacoplamento de componentes"*.

São **dois produtos na mesma pasta**, e o segundo existe por duas razões, não
uma: ele é o editor que você quer usar, e é a PROVA de que as camadas estão
mesmo separadas.

### 120 — a identidade

| decisão | o que fica dito |
|---|---|
| **IDE de verdade, painéis sempre visíveis** | Barra de ferramentas em cima, árvore à esquerda, outline à direita, dock de abas em baixo. O editor é UMA das áreas, não a tela toda. Quando o Zed e o NetBeans brigam, ganha o NetBeans — **no pstudio**. |
| **A espinha é o ciclo** `build → rodar → testar → falhou aqui` | Não é o diagnóstico vivo, não é o depurador, não é o navegador de pacotes. É o laço que se percorre cem vezes por dia. |
| **Sem depurador** | *"`print` e stack trace bastam"*. O investimento vai para tornar ISSO excelente — trace clicável, valores no erro — em vez de um depurador de verdade. Nada de informação de linha no C gerado, nada de protocolo de depuração, nada de parar o runtime. |
| **C é cidadão de primeira classe** | P, pscript e C com realce **e navegação**. O compilador lê os três; o editor pinta os três. Consequência: o tokenizador de C do `cfront` (hoje `private`, e `cfront.ph` só exporta `c_parse` e `cchar_val`) tem de sair com um modo tolerante, como o `lex_ex(..., tolerant=True)` do lado do P. |

### 121 — o corte, e a prova

**O `pcode` é um editor PURO: zero ecossistema.** Abas, árvore, paleta, busca,
realce, completamento, dobra, multi-cursor. Nada de build, teste, pacote ou
diagnóstico. É o seam mais limpo que havia, e é o que torna a prova forte.

```
pcode                          pstudio
  lib_shell ────────────┬──────  lib_shell
  lib_cv    ────────────┼──────  lib_cv
  lib_core  ────────────┼──────  lib_core
  lib_hl    ────────────┼──────  lib_hl
  lib_complete ─────────┼──────  lib_complete
  pui       ────────────┼──────  pui
  shim      ────────────┘        shim
                               + lib_ide     (os painéis)
                               + lib_build   (o motor pforge)
                               + lib_tests
                               + lib_pkg     (pacotes)
                               + packages/pforge
```

**O portão é o GRAFO.** Uma checagem pergunta ao `pforge` quais fontes o alvo
`pcode` lê — `--deps` já responde isso — e falha se aparecer um módulo da lista
proibida. É barato, é automático, e a mensagem diz qual `import` quebrou a regra.
Sem isso, em três meses o `pcode` linka a IDE inteira e ninguém nota.

O `lib_app` de hoje parte em dois: `lib_shell` (abas, árvore, paleta, busca,
atalhos — compartilhado) e `lib_ide` (painéis, build, testes, pacotes). A lista
de comandos da paleta (`COMMANDS`, hoje uma string com 33 entradas incluindo
`Build`, `Run`, `Clean` e os do manifesto) parte junto.

### 122 — pacotes, terminal, painel, projeto

**Pacote de terceiro entra como TAR AVULSO, e também por URL directo.** Suas
palavras: *"porque não um tar sem um repo definido? mesmo que entre como
usuário"*. O tarball JÁ é o pacote — traz o `pack.json` dentro. Hasheia-se o que
chegou, grava-se no lock com `repo` = de onde veio e `unsafe: true` se ninguém
assinou, e abre-se em `build/pkg/` como qualquer outro. O `.sig` ao lado verifica
se existir.

```sh
pforge add ./foo-0.1.0.tar
pforge add https://algum.site/foo-0.1.0.tar
```

O que se perde é a **busca** e a **lista de versões** (que é o que `search` e
`up` usam) — exactamente o que um JAR também perde. O que **não** se perde é o
hash, e é isso que faz o tar avulso ser mais honesto que uma dependência por
caminho, que não tem hash nenhum e aponta para a sua pasta. A `struct Locked` já
tem os sete campos que isto precisa.

Isto não contraria a especificação, completa-a: `repos` sempre foi uma **lista**
(`REPOSITORIO.md` §3.3, *"A ordem é a de busca"*), e o §3.3 já previa o pacote
avulso — *"E um pacote solto também: `ppack add exp@0.1.0 --unsafe`"*. O que
faltava era a entrada por arquivo e por URL.

**O terminal é PTY de verdade**, e a primitiva vai para o **runtime do pscript**
(`os.spawn_pty`, como o `os.run` foi), não para o driver do pstudio. Assim o
`pforge dev` e qualquer programa pscript ganham, e a primitiva ganha um segundo
consumidor — que é o teste de que ela está no lugar certo. O widget ANSI
(cores, cursor, redimensionar, scrollback) vive no pstudio.

**O terminal desenha-se SOZINHO, fora do `pui`** — um `WK_CUSTOM` com acesso
directo ao `shim`. Foi a única questão de pesquisa que havia (uma grelha 80×24
com fundo por célula são 3 840 comandos por quadro contra os ~50 do codeview), e
a resposta fecha-a sem mexer no modelo de desenho.

**O painel de baixo na v1:** `Build`, `Terminal/Saída` e `Testes`. Problemas fica
para a v2 — o sublinhado no editor já avisa. Build sobe sozinha ao começar,
Terminal sobe ao rodar, Testes sobe **só ao falhar**: uma suíte verde não deve
roubar a tela.

**O pstudio EXIGE projeto; o pcode abre qualquer pasta.** É mais um eixo de
desacoplamento e não só cultura: o `pcode` nem sabe o que é um projeto.

### 123 — a ordem, e duas regras

**A ordem: o corte primeiro.** Partir o `lib_app`, nascer o alvo `pcode`, e o
portão do grafo — antes de qualquer widget novo. Descobre CEDO se as camadas
estão mesmo desacopladas, que é a pergunta cuja resposta ruim custa mais tarde; e
cada widget que nascer depois já nasce do lado certo.

**A aba de Testes entra na v1 afinal.** Ela vem quase de graça: o
`pforge test --json` já emite um evento por caso com `{"what": "suíte: caso",
"status", "ms", "output"}`, e o `tally` já parte o rótulo em suíte e caso
(`pforge.psc:102`). Sem ela a espinha escolhida ficaria com uma vértebra a menos.

O nome do editor mínimo é **`pcode`** — binário `build/bin/pcode`, janela
"PCode".

#### Regra do `pui`

> *"tudo o que for reutilizável e não for específico do programa vai pra pui,
> assim como qualquer lib de ui"*

Não é uma escolha para estes três widgets: é a regra permanente. O que fica no
`pstudio` é o que só faz sentido numa IDE.

#### Regra do tema

> *"criar uma estrutura de variáveis que juntas formam o tema, como se fosse uma
> espécie de variáveis raiz de bootstrap; você altera elas e consegue trocar
> todos os temas, porque todas as camadas abaixo não usam cores diretamente mas
> referências como cor primária"*

**Nenhuma camada usa cor directa.** Oito raízes geram ~30 papéis por derivação, e
qualquer papel pode ser sobreposto à mão:

```python
record Roots:
    surface:    int   # every background: panel, gutter, bar
    on_surface: int   # every foreground: text, icons
    primary:    int   # accent, focus ring, selection, links
    danger:     int   # errors, breakpoints, failing tests
    warning:    int   # warnings, folds, modified
    ok:         int   # success, comments
    string:     int   # string literals
    keyword:    int   # keywords and types

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
discordar. Hoje isto está violado em dois sítios que a arrumação tem de alcançar:
`theme_dark()` tem 13 campos concretos, e o `lib_cv.psc` tem **onze literais de
cor** espalhados — as cinco de sintaxe (`hl_color`, linha 46), as das marcas e da
dobra, e o fundo do próprio widget (linha 412).

### O que falta ao `pui` — o levantamento

Cada linha sai de uma decisão acima. O achado central é que **a barra de abas, a
árvore e a paleta não são widgets do `pui`**: são três `WK_CUSTOM` desenhados à
mão dentro do `lib_app`. O `WK_CUSTOM` foi o escape certo — é por causa dele que
o editor existe. Mas a IDE precisa da mesma lista desenhada à mão **seis vezes**,
e aí deixa de ser escape e passa a ser dívida.

| # | precisa | de qual decisão | o `pui` tem | falta |
|---|---|---|---|---|
| **A** | dock com abas de painel, colapsar, tamanhos guardados | 120, 122 | `SPLIT` de 2 vias com arrasto | a tira de abas do painel, o colapso, e o layout persistido (a decisão "sem sessão v0.1" cai aqui) |
| **B** | lista e árvore virtualizadas: selecção, teclado, expandir, ícone e cor por linha | Build, Testes, Pacotes, Outline + as três de hoje | nada | o widget. **Seis consumidores** — é o item que mais se repete |
| **C** | camada flutuante: menu, tooltip, modal com formulário | toolbar `[alvo ▾]`, hover de doc, "Adicionar pacote…" | o popup de completamento, preso ao rect do codeview | o conceito de "acima de tudo, recortado à janela". **Um mecanismo serve os três** |
| **D** | terminal | 122 | — | resolvido: fica FORA do `pui` (`WK_CUSTOM` com acesso ao `shim`) |
| **E** | barra de ferramentas com ícones | 120 | `BUTTON` só com texto | `▶ ⟳ ■` não estão no atlas (que tem `▸ ▾ ● ◆ ▪ ✓ ✗ ← →`). Barato: acrescentar codepoints ao `mkatlas.c` e regerar |
| **F** | temas | regra do tema | `Theme` já é struct | as raízes, a derivação, e trazer as 11 cores do `lib_cv` para dentro |
| **G** | travessia de foco por teclado | painéis só servem se der para sair deles sem rato | `focus_set`/`focus_get` | o `pui` **define `K_TAB` e nunca o trata**. Sem anel de foco, "ctrl+1 vai à árvore" não existe |
| **H** | barra de progresso | `[3/105]` numa IDE é uma barra | — | trivial (é um `RECT`), mas não existe |

Três leituras de custo: **B e C já foram escritos** — mal, três vezes, dentro do
`lib_app`; o trabalho é promover, não inventar, e promover deixa o `lib_shell`
mais fino, o que **fortalece a prova de desacoplamento**. **D deixou de ser
risco** por decisão. E **E, F, G e H somados são menos trabalho que B sozinho**.

---

## O caminho — baterias 124-130 (2026-08-24)

As 120-123 decidiram O QUÊ. Estas decidem COMO, e o plano fase a fase está em
`pstudio/PLAN.md`.

### 124 — o seam

**A acoplagem não está nos arquivos, está na `struct`:** 21 dos 52 campos do
`App` são da IDE, 9 dos 34 comandos, e 320 das 721 linhas do `app.psc`.

`Ide` **TEM** um `Shell` — composição, e a dependência anda num sentido só. Os
comandos viram **tabela de dados** (`record Command {name, run, when}`), o que
mata de passagem a string `COMMANDS` com 34 entradas de índice fixo e o
`run_command` que é um `switch` de 34 casos.

Recusado, e porquê: um campo `ide: any?` dentro do `Shell` seria mudança mínima,
mas o módulo da IDE continuaria a ser **linkado** para o tipo existir —
separação de tempo de execução, não de ligação, e o portão falharia com razão.

O driver sai para um componente próprio: janela, eventos, pintor, quadro, zoom,
cache de arquivos e a CLI comum são iguais nos dois binários.

**O portão é por LISTA BRANCA:** o `pcode` lê exactamente 26 arquivos, e
qualquer `import` novo falha até ser aprovado. É a única forma que não envelhece.
Corre no `make verify`; os dois binários entram no `make` por omissão.

### 125 — os nomes

> *"não é idiomático chamar coisas de lib, sem elas serem libs mesmo... esses
> são componentes do pstudio e não libs"*

O prefixo `lib_` nasceu na migração, quando `core.p` e a versão em pscript
coexistiam. A 116 aposentou os `.p` e o prefixo ficou órfão; a pasta `ps/`
("pscript") tem quatro arquivos em P dentro. Cai tudo, e cai também no
`packages/pforge`, onde `lib_x` é redundante porque o pacote já é a lib.

Os três `WK_CUSTOM` (abas, árvore, paleta) **promovem-se ao `pui` e o editor
passa a usar os novos** — não ficam duas listas no mesmo programa.

**C entra cedo, logo depois do corte, e vai para a CASCA** — realce é do editor,
e os dois binários ganham.

### 126-127 — os ícones

> *"vamos usar bitmaps mesmo que escalem mal. ícones vetoriais irá vir muito
> mais pra frente"*

**Alfa 8-bit, tingido por um papel do tema.** Exactamente como um glifo: o
`draw_glyph` (`pgfx_raster.p:154`) já blita uma célula de opacidade com
`blend(dst, color, a)`. O ícone é a mesma função com largura e altura próprias —
e obedece à regra do tema de graça, porque a cor vem sempre de um papel.

A cadeia é a que a fonte já tem, com outro gerador:

```
icons.png  ->  tools/mkicons.c (stb_image.h, offline)  ->  icons.bin
           ->  embed_bytes("icons.bin")                ->  um binário só
```

Os **sete tamanhos saem reduzidos do gerador**, não em tempo de execução: o
editor fica sem código de redução nenhum, e são ~105 KB ao lado dos 263 KB que a
fonte já embute. O `icons.png` vem de um conjunto livre (Lucide/Feather),
rasterizado uma vez por ferramenta de fora e comitado — o build não depende dela.

**~40 ícones desde já.** O outline é alimentado pelo **índice de completamento
que já existe** (`complete.psc` já varre declarações a cada relexagem) — zero
análise nova, e funciona no arquivo por salvar.

**Build é sempre explícito na v1**: nada de reconstruir ao salvar nem de vigiar o
disco.

### 128 — estado, testes, janelas

**`.pstudio.json` na raiz do projeto, comitável.** Um arquivo só.

**Os quatro testes headless de hoje viram do `pcode`** (o `app_test.psc` já não
toca em build nenhum), e a IDE ganha um `ide_test.psc` com um driver de mentira:
pede build, o falso motor responde, o painel mostra, o erro navega. Cada binário
mantém o seu `--selftest` com SDL dummy.

**Um projeto por PROCESSO.** Abrir outro é outro `pstudio`.

**O `pcode` não lembra nada** — nem tema, nem zoom, nem abas. Se houver um
`.pstudio.json` na pasta, ele ignora: aquilo é da IDE. Zero I/O ao arrancar é
metade do que o faz rápido.

### 129-130 — `pforge`

> *"a ideia inicialmente era, pbuild -> gerenciador de build ninja+meson |
> ppack -> análogo ao cargo e npm. se um executável apenas faz os dois e esse for
> o melhor design, o nome deveria englobar os dois conceitos em uma única
> palavra"*

Um binário é o padrão dominante e provado — `cargo`, `go`, `zig` e `npm` todos
constroem *e* buscam. A separação meson+ninja não é build-vs-pacotes, é
gerador-vs-executor, e a nossa já existe por dentro nos três modos (*resolve*,
*describe*, *execute*).

A palavra é **`pforge`**: uma forja faz coisas a partir de matéria-prima, e
"forge" também carrega o sentido de onde o código mora.

```
pforge/                      (hoje pforge/ + pforge/)
  DESIGN.md  ARQUITETURA.md  DECISOES.md  PLAN.md
  BATERIAS.md  LINKER.md  REPOSITORIO.md
  gerenciador-de-pacotes-ideal.md
  src/main.psc  build_plang.psc  engine_test.psc
      floor.psc  verdict.psc

packages/pforge/             o motor E o gerenciador, como biblioteca
  graph  build  log  targets  ninja  api  doctest      (o motor)
  manifest  lock  repo  pkg                            (os pacotes)

build/bin/pforge             o binário
```

A biblioteca muda de nome pela mesma razão que o binário: **4 dos 11 módulos são
do gerenciador de pacotes**, não do motor de build.

São **463 referências em 45 arquivos** (225 em `.md`, 141 em `.psc`, 52 em
`.sh`, 23 no `build.ninja`), e por isso a renomeação é a **F0** — tudo antes de
mais nada, num commit só, no momento mais barato que vai existir.

---

## O editor que EXISTE — baterias 131-134 (2026-08-24)

Ao medir o plano contra o código, apareceram três defeitos presentes e dois
buracos de funcionalidade que nenhuma decisão anterior cobria.

### Os três defeitos (viram a F0)

**1. `Buffer.text()` é quadrático.** Monta o arquivo com `+=` num laço. Medido:

| linhas | `+=` em laço | `"\n".join` |
|---|---|---|
| 8 000 | **672 ms** | 0 ms |
| 32 000 | **16 972 ms** | 3 ms |
| 128 000 | — | 682 ms |

E o `text()` é chamado **em todo o `save`** e em **toda a construção do índice de
completamento**. O nosso maior arquivo (`selfhost/ps_lower.p`, 11 076 linhas)
congela mais de um segundo em cada um.

**2. Um arquivo VAZIO nunca abre.** `read_file` devolve `""` tanto para "vazio"
como para "não consegui ler", e o `open_file` (`lib_app.psc:263`) não os
distingue: pede ao driver que releia, para sempre, de 500 em 500 ms, sem
mensagem. Verificado com `touch vazio.p` e `--selftest`: `tabs 0`, `no file`. Um
`.png` aberto por engano cai no mesmo laço — e se abrisse, salvar truncava-o.

→ `read_file` passa a devolver **`str?`**: `None` é falha, `""` é vazio.

**3. O laço de eventos não tem um único `try`** (`app.psc:412`). Em pscript,
estouro de inteiro e índice fora de faixa LEVANTAM — um defeito de aritmética de
coluna mata o processo.

→ `try` a envolver o tratamento de cada evento; **ao apanhar, tenta salvar os
buffers modificados** para rascunho antes de mostrar o erro. Transforma um
defeito em zero perda, mesmo tendo-se recusado o autosave.

### Os dois buracos

**Busca no projeto inteiro não existe** — `find_changed` busca só no buffer
aberto. Vai para a **CASCA**, e os dois binários ganham: é o que faz um Zed ser
um Zed. **Varre a cada busca, em tarefa assíncrona** — sem índice, sem
invalidação, sem memória; os resultados aparecem à medida que chegam. Este
repositório são ~58 mil linhas de fonte.

**Ir-para-definição entre arquivos não existe** — o `index.build(buf, [])` tem um
parâmetro `extra: list<str>` documentado para isto e sempre vazio. Passa a ser um
**índice do projeto construído sob demanda**: nada ao abrir, e ao pedir "ir para
definição" de um símbolo desconhecido varre nesse momento e guarda.

### As decisões menores

| assunto | decisão |
|---|---|
| **atalhos** | tabela de dados, configurável no `.pstudio.json`. O **`pcode` fica com atalhos fixos** — "zero I/O ao arrancar" é metade do que o faz rápido |
| **atlas** | cresce até onde a fonte alcança (cirílico e grego, ~300 codepoints, 263 KB → ~700 KB). **CJK e emoji ficam `□`**, e isso fica dito em vez de descoberto |
| **tamanho de arquivo** | **50 mil linhas confortáveis**; acima disso avisa e abre só leitura, sem índice nem realce |
| **trabalho por salvar** | nada — salvar é do utilizador. O `try` do laço é a rede |
| **semver do `pui`** | **0.x é especial**: com major 0, o minor pode quebrar (é o que o semver diz e o que o Cargo faz). O `publish` **aceita e AVISA** — a excepção fica visível em cada publicação |
| **instalar** | `make install` com `PREFIX` (por omissão `/usr/local`), e mais nada |
| **scrollback do terminal** | tecto de linhas, anel circular; as velhas caem |
| **`.pstudio.json` inválido** | ignora e **diz na barra de estado** — um editor nunca deve recusar-se a abrir por causa da configuração, nem calar |

### O portão de desempenho

Nenhum teste media tempo, e é por isso que o quadrático viveu até hoje. Tectos
**absolutos** sobre um arquivo grande de verdade:

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
