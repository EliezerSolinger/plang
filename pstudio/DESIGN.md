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

### 1. psys — sistema operacional (só OS)
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
- `make verify` ganha: **compilação gating do pstudio** (maior consumidor de
  P depois do compilador) + **suíte `tests/pstudio/*.p`** — programas P
  headless exercitando core/psys (buffer, undo, highlight, VFS local) com
  `.expected`, no formato das suítes atuais, rodando nos 3 modos (C/QBE/C89).
- **SDL2 = dependência com skip gracioso**: com libsdl2-dev presente a
  bateria compila o pstudio inteiro (gating); sem ele, avisa "skipped: no
  SDL2" — os testes headless de core/psys rodam SEMPRE (não dependem de SDL).
- Build: `plangc --out-dir out pstudio/...` (espelho; repo limpo).

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

## Estado da implementação (arquivos)
| arquivo | o que é |
|---|---|
| `psys.ph/.p` | VFS (backend local), processos, clock, paths |
| `font_atlas.ph/.p` | atlas GERADO (ASCII + Latin-1 + pontuação, □ de fallback) |
| `pgfx_raster.ph/.p` | `PgRect`/`PgFont`/`PgFb`: rects, clip, blend, texto — headless |
| `pgfx.ph/.p` | SDL2: janela, textura streaming, eventos, clipboard, diálogos |
| `pui.ph/.p` | `Ui`: pool de `UINode`, layout 2 fases, cmd lists, sinais, input |
| `core.ph/.p` | `Buffer`/`Highlight`: linhas UTF-8, multi-caret, undo, busca |
| `codeview.ph/.p` | o widget de edição: gutters plugáveis + scrollbars internas |
| `app.ph/.p` | abas, árvore, palette, busca, atalhos, loop de eventos |
| `main.p` | linha de comando (`--shot`, `--size`) |
| `tools/mkatlas.c` | gerador do atlas (stb_truetype, offline; nunca linkado) |

Testes: `tests/pstudio/*.p` — 6 programas headless (psys, raster, pgfx com
driver dummy, pui, core, e **app_flow**, que dirige o editor inteiro por
eventos sintéticos e compara um "screenshot" ASCII do frame).

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
| o shim escalar da bateria 71 (`pstudio/ps/shim.p`) | **fica, e é a fronteira**: janela, evento, pixel e glifo, com assinatura de escalares. É o que "totalmente em pscript" quer dizer num programa que fala SDL — a lógica inteira em pscript, e uma página de P a tocar o ponteiro |
| o realce, que usa o lexer DO COMPILADOR (`lex_ex`, core.p:1464) | **DECIDIDO (113)**: o lexer continua em P, num adaptador (`pstudio/ps/hl.p`) que recebe o texto inteiro como `CStr` e devolve os tokens como NÚMEROS. A lógica (classe, comentário, índice de completamento) fica em pscript. Um segundo lexer em pscript divergiria do do compilador, que é justamente o que o realce serve para mostrar |

O ganho não é estético: **o pstudio é o maior consumidor de P do projeto** (é o
que a bateria 7/8 do `verify-all` mede), e ele em pscript é o maior programa
gráfico em pscript que existe — com o coletor, os workers e o laço de eventos
sob carga real. E a camada de sistema, ao sair daqui para a stdlib, ganha um
segundo consumidor: o **pbuild** (ver `pbuild/DESIGN.md`, 1.1), que é justamente
o teste de que ela está no lugar certo.

O limite nomeado: **SDL, janela e teclado continuam aqui**. O que é do editor não
é stdlib de ninguém.

**Estado (2026-08-21).** Dois passos feitos:

  1. a bateria 111 do pscript tirou a camada de SISTEMA daqui e pôs na stdlib
     (`os` e `path`), com o `psys.p` como fonte do porte;
  2. a bateria 112 portou o `pui` — `pstudio/ps/lib_pui.psc`, com o teste
     headless imprimindo os MESMOS retângulos que o teste do pui em P;
  3. a bateria 113 respondeu a pergunta do REALCE e portou o resto do miolo: o
     lexer do compilador fica em P e atravessa por um adaptador de escalares
     (`pstudio/ps/hl.p`, aprovado por você), e com ele vieram `lib_hl.psc`,
     `lib_complete.psc` e `lib_cv.psc` — o `codeview` inteiro, imprimindo as
     mesmas sete linhas do teste de dobra do editor em P.

O que falta: o `app` (abas, árvore de arquivos, paleta de comandos, busca, laço
de eventos) e a troca do `make pstudio` para a versão em pscript. A camada de
sistema que o `app` vai querer — listar diretório, mtime — já está na stdlib
desde a 111.
