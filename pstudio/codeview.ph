# codeview.ph — o widget de edição do pstudio: um WK_CUSTOM que junta
# core (Buffer/Highlight) + pui (layout/comandos/input) + pgfx (fonte).
#
# Segue o TextEdit da Godot no essencial: as SCROLLBARS são filhos INTERNOS
# que o próprio widget cria e posiciona (c_layout), e os GUTTERS são
# plugáveis (números de linha hoje; breakpoints/erros depois, sem refactor).
include <stddef.h>
import "pui.ph"
import "core.ph"

# um gutter: coluna à esquerda do texto. `draw` preenche o texto da linha
# (buf de `cap` bytes) e devolve a cor; retorno False = célula vazia.
struct Gutter:
    width_cp: i32     # largura em CARACTERES (mono)
    ctx: *void
    draw: def(ctx: *void, cv: *CodeView, line: i32, out_text: *char, cap: usize, out_color: *u32) -> bool

MAX_GUTTERS: const i32 = 4

struct CodeView:
    buf: Buffer
    hl: Highlight
    path: *char       # None = sem arquivo (buffer solto)
    ui: *Ui           # dono (os callbacks recebem o mesmo ponteiro)
    id: i32           # id deste widget no pool
    vsb: i32          # scrollbar vertical (filho interno)
    hsb: i32          # horizontal
    top: i32          # primeira linha visível
    left: i32         # primeira COLUNA DE TELA visível (tabs expandidos)
    gutters: Gutter[MAX_GUTTERS]
    ngutters: i32
    caret_on: bool    # fase do piscar (o app alterna no timeout)
    mouse_sel: bool   # arrastando seleção
    mtime: i64        # mtime do arquivo na última leitura (mudança externa)
    # callback opcional: avisa o app que algo mudou (título/status bar)
    on_change: def(ctx: *void, cv: *CodeView)
    on_change_ctx: *void

# cria o widget (com scrollbars internas) e devolve o id
def cv_create(ref ui: Ui, parent: i32) -> i32
def cv_of(ref ui: Ui, id: i32) -> *CodeView     # payload do widget

struct CodeView:
    # ---- arquivo ----
    def load_file(ref self: CodeView, path: const *char) -> bool
    def save_file(ref self: CodeView) -> bool
    def reload(ref self: CodeView) -> bool       # relê do disco (descarta edições)
    def set_text(ref self: CodeView, text: const *char)   # buffer solto

    # ---- geometria (o app usa p/ status bar e para o palette) ----
    def text_rect(in self: CodeView) -> PgRect   # área do texto (sem gutter/barras)
    def gutter_w(in self: CodeView) -> i32       # largura total dos gutters (px)
    def visible_lines(in self: CodeView) -> i32
    def add_gutter(ref self: CodeView, g: Gutter)
    def line_numbers_gutter(ref self: CodeView)  # o gutter padrão (números)

    # ---- navegação ----
    def scroll_to_caret(ref self: CodeView)
    def set_top(ref self: CodeView, line: i32)
    def set_left(ref self: CodeView, col: i32)
    # coluna de TELA de (line, col) — expande tabs para TAB_WIDTH
    def screen_col(in self: CodeView, line: i32, col: i32) -> i32
    # inverso: coluna de codepoint mais próxima de uma coluna de tela
    def col_from_screen(in self: CodeView, line: i32, scol: i32) -> i32
    def pos_from_xy(in self: CodeView, x: i32, y: i32, out line: i32, out col: i32)

    # ---- edição (repassa ao buffer e cuida de scroll/dirty/relex) ----
    def changed(ref self: CodeView)              # invalida: relex + redraw
    def copy(ref self: CodeView) -> bool         # -> clipboard (multi-caret)
    def cut(ref self: CodeView, now_ms: i64) -> bool
    def paste(ref self: CodeView, now_ms: i64)
    def indent(ref self: CodeView, now_ms: i64)  # tab: 4 espaços ou bloco
    def unindent(ref self: CodeView, now_ms: i64)
    def newline(ref self: CodeView, now_ms: i64) # enter com auto-indent

    # ---- busca (usada pela barra de busca do app) ----
    # `re` = tratar needle como POSIX regex; move o caret e faz scroll
    def search(ref self: CodeView, needle: const *char, forward: bool, re: bool, from_caret: bool) -> bool

# clipboard multi-caret (estilo Sublime): N seleções guardam N pedaços; o
# clipboard do SISTEMA recebe tudo unido por \n. Vive no módulo (um só editor).
def cv_clip_clear()
def cv_clip_count() -> i32
