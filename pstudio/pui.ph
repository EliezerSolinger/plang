# pui.ph — toolkit de UI do pstudio (modelo Godot reimplementado; DESIGN.md §3).
#
# Árvore em POOL LINEAR com índices: WidgetId = i32 (NUNCA ponteiro — o pool
# realoca). Layout em duas fases (min size sobe, rect desce — matemática da
# BoxContainer/SplitContainer da Godot). Draw retained: cada widget guarda sua
# lista de comandos; regrava só quando sujo. Sem herança e sem interfaces:
# dispatch por `match kind`; widgets do app usam WK_CUSTOM + fn pointers.
include <stddef.h>
import "pgfx.ph"   # tipos PgEvent/PgFb (não puxa SDL no link)
import "../stl/vec.ph"

enum WidgetKind:
    WK_NONE
    WK_PANEL       # retângulo de fundo; filhos empilhados no rect inteiro
    WK_BOX         # container linear v/h (algoritmo da BoxContainer)
    WK_SPLIT       # dois filhos + divisor arrastável (SplitContainer)
    WK_LABEL
    WK_BUTTON
    WK_SCROLLBAR
    WK_INPUT       # entrada de texto de uma linha (palette, busca)
    WK_CUSTOM      # widget do app: usa os fn pointers do nó

# flags de WidgetBase
UF_VISIBLE: const u32 = 1
UF_EXPAND_H: const u32 = 2    # SIZE_EXPAND horizontal (estica no BOX h)
UF_EXPAND_V: const u32 = 4
UF_DIRTY: const u32 = 8       # lista de comandos precisa ser regravada
UF_FOCUSABLE: const u32 = 16
UF_HOVER: const u32 = 32      # estado calculado pelo input (leitura)
UF_PRESSED: const u32 = 64

struct WidgetBase:
    rect: PgRect      # rect FINAL em coordenadas de tela (pós layout)
    min_w: i32        # minimum size custom (0 = só o computado pelo kind)
    min_h: i32
    stretch: i32      # peso do EXPAND no box (default 1)
    flags: u32
    cw: i32           # min COMPUTADO pela fase 1 (interno ao layout)
    ch: i32

# comando de desenho retido (replay na composição)
enum CmdKind:
    CMD_RECT
    CMD_FRAME
    CMD_TEXT          # text (cópia própria) em (x,y)
    CMD_GLYPH         # 1 codepoint em (x,y) — SEM alocação (texto do CodeView)

struct Cmd:
    kind: CmdKind
    x: i32
    y: i32
    w: i32
    h: i32
    color: u32
    cp: u32           # CMD_GLYPH: codepoint
    text: *char       # CMD_TEXT: malloc'd (liberado ao regravar/destruir)

# sinal: {fn, ctx} — arg depende do sinal (botão: 0; scrollbar: valor novo)
struct UiSignal:
    fn: def(ctx: *void, id: i32, arg: i64)
    ctx: *void

declare Vec<Cmd>

struct UINode:
    kind: WidgetKind
    alive: bool
    parent: i32          # -1 = raiz/solto
    first_child: i32     # -1 = folha
    next_sibling: i32    # ordem dos irmãos = ordem de desenho (e freelist)
    base: WidgetBase     # INLINE: o walk de layout não dereferencia payload
    data: *void          # payload por kind (malloc; liberado em free_node)
    cmds: Vec<Cmd>       # lista de comandos RETIDA (regravada só quando suja)
    # WK_CUSTOM: comportamento vem do app
    c_min: def(ui: *Ui, id: i32, out_w: *i32, out_h: *i32)
    c_build: def(ui: *Ui, id: i32)                      # regrava cmds (cmd_*)
    c_input: def(ui: *Ui, id: i32, ev: *PgEvent) -> bool
    c_layout: def(ui: *Ui, id: i32, r: PgRect)          # container próprio
    c_free: def(ui: *Ui, id: i32)                       # libera o payload

# tema (preset dark compilado; arquivo de config fica p/ depois)
struct Theme:
    bg: u32
    panel: u32
    panel_hi: u32     # hover
    panel_lo: u32     # pressed / recessed
    border: u32
    text: u32
    text_dim: u32
    accent: u32
    sel: u32
    pad: i32          # padding interno (botões etc.)
    sep: i32          # separação entre filhos do BOX
    handle: i32       # espessura do divisor do SPLIT / scrollbar

declare Vec<UINode>

struct Ui:
    nodes: Vec<UINode>
    free_head: i32    # freelist (encadeada por next_sibling)
    root: i32
    focus: i32        # foco de teclado (um só, modelo Godot)
    capture: i32      # mouse capturado do press até o release
    hover: i32
    theme: Theme
    font: PgFont
    lay_w: i32        # tamanho do último layout (p/ relayout após mudanças)
    lay_h: i32

    # ---- ciclo de vida ----
    def init(out self: Ui, font: PgFont)
    def deinit(ref self: Ui)
    def node(ref self: Ui, id: i32) -> *UINode   # id INVÁLIDO é erro do chamador
    def new_node(ref self: Ui, kind: WidgetKind, parent: i32) -> i32  # último filho
    def free_node(ref self: Ui, id: i32)         # subárvore inteira
    def reparent(ref self: Ui, id: i32, new_parent: i32)

    # ---- construtores ----
    def panel(ref self: Ui, parent: i32) -> i32
    def box(ref self: Ui, parent: i32, vertical: bool) -> i32
    def split(ref self: Ui, parent: i32, vertical: bool) -> i32
    def label(ref self: Ui, parent: i32, text: const *char) -> i32
    def button(ref self: Ui, parent: i32, text: const *char) -> i32
    def scrollbar(ref self: Ui, parent: i32, vertical: bool) -> i32
    def line_input(ref self: Ui, parent: i32) -> i32
    def custom(ref self: Ui, parent: i32, data: *void,
               c_min: def(ui: *Ui, id: i32, out_w: *i32, out_h: *i32),
               c_build: def(ui: *Ui, id: i32),
               c_input: def(ui: *Ui, id: i32, ev: *PgEvent) -> bool,
               c_layout: def(ui: *Ui, id: i32, r: PgRect),
               c_free: def(ui: *Ui, id: i32)) -> i32

    # ---- propriedades ----
    def set_expand(ref self: Ui, id: i32, h: bool, v: bool)
    def set_min(ref self: Ui, id: i32, w: i32, h: i32)
    def set_stretch(ref self: Ui, id: i32, weight: i32)
    def set_visible(ref self: Ui, id: i32, vis: bool)
    def is_visible(ref self: Ui, id: i32) -> bool
    def set_focusable(ref self: Ui, id: i32, f: bool)
    def set_text(ref self: Ui, id: i32, text: const *char)   # label/button/input
    def text_of(ref self: Ui, id: i32) -> const *char        # label/button/input
    def set_rect(ref self: Ui, id: i32, r: PgRect)           # p/ c_layout
    def data_of(ref self: Ui, id: i32) -> *void              # payload do custom
    def rect_of(ref self: Ui, id: i32) -> PgRect
    def queue_redraw(ref self: Ui, id: i32)                  # marca sujo
    def queue_redraw_tree(ref self: Ui, id: i32)             # subárvore inteira

    # ---- sinais ----
    def on_click(ref self: Ui, id: i32, fn: def(ctx: *void, id: i32, arg: i64), ctx: *void)
    def on_scroll(ref self: Ui, id: i32, fn: def(ctx: *void, id: i32, arg: i64), ctx: *void)
    def on_changed(ref self: Ui, id: i32, fn: def(ctx: *void, id: i32, arg: i64), ctx: *void)
    def on_submit(ref self: Ui, id: i32, fn: def(ctx: *void, id: i32, arg: i64), ctx: *void)
    def on_cancel(ref self: Ui, id: i32, fn: def(ctx: *void, id: i32, arg: i64), ctx: *void)

    # ---- split / scrollbar / input ----
    def split_set(ref self: Ui, id: i32, offset: i32)        # posição do divisor
    def split_offset(ref self: Ui, id: i32) -> i32
    # scrollbar: total = conteúdo, page = visível, value = posição (clampado)
    def scroll_set(ref self: Ui, id: i32, total: i64, page: i64, value: i64)
    def scroll_value(ref self: Ui, id: i32) -> i64
    def input_clear(ref self: Ui, id: i32)

    # ---- foco ----
    def focus_set(ref self: Ui, id: i32)
    def focus_get(ref self: Ui) -> i32

    # ---- frame ----
    def layout(ref self: Ui, w: i32, h: i32)     # duas fases na árvore inteira
    def relayout(ref self: Ui)                   # repete com o último tamanho
    def draw(ref self: Ui, ref fb: PgFb)         # regrava sujos + replay c/ clip
    def input_event(ref self: Ui, ev: *PgEvent) -> bool   # True = consumido
    def hit(ref self: Ui, x: i32, y: i32) -> i32 # widget mais ao topo no ponto

    # ---- API p/ builders (usada nos c_build) ----
    def cmd_rect(ref self: Ui, id: i32, r: PgRect, color: u32)
    def cmd_frame(ref self: Ui, id: i32, r: PgRect, color: u32)
    def cmd_text(ref self: Ui, id: i32, x: i32, y: i32, text: const *char, color: u32)
    def cmd_text_n(ref self: Ui, id: i32, x: i32, y: i32, text: const *char, nbytes: usize, color: u32)
    def cmd_glyph(ref self: Ui, id: i32, x: i32, y: i32, cp: u32, color: u32)
