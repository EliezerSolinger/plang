# app.ph — o editor: abas, árvore de arquivos, command palette, busca e o
# loop de eventos. Camada 5 do DESIGN.md.
include <stddef.h>
import "pui.ph"
import "codeview.ph"
import "../stl/vec.ph"
import "../stl/str.ph"

struct Tab:
    cv: i32           # id do CodeView (dono do buffer)
    title: *char      # basename do arquivo (malloc)

struct TreeEntry:
    path: *char       # caminho completo (malloc)
    name: *char       # nome exibido (malloc)
    depth: i32
    is_dir: bool
    expanded: bool

enum PalMode:
    PAL_FILES         # fuzzy de arquivos (default)
    PAL_COMMANDS      # prefixo '>'
    PAL_GOTO          # prefixo ':'

struct PalItem:
    label: *char      # texto exibido (malloc)
    payload: *char    # caminho do arquivo / nome do comando (malloc)
    score: i32

declare Vec<Tab>
declare Vec<TreeEntry>
declare Vec<PalItem>

struct App:
    ui: Ui
    win: PgWindow
    root: i32         # painel raiz (empilha o layout e a palette)
    tabbar: i32
    tree: i32
    split: i32
    editors: i32      # box vertical: [cvhost | barra de busca]
    cvhost: i32       # box que hospeda os CodeViews (a busca fica embaixo)
    findbar: i32
    findinput: i32
    status: i32
    palette: i32
    palinput: i32
    tabs: Vec<Tab>
    cur: i32          # aba ativa (-1 = nenhuma)
    entries: Vec<TreeEntry>
    tree_top: i32
    root_dir: *char
    palmode: PalMode
    palitems: Vec<PalItem>
    palsel: i32
    paltop: i32
    files: Vec<PalItem>   # índice de arquivos do projeto (varredura única)
    find_re: bool         # busca em modo regex (query começando com '/')
    zoom: i32             # 1x/2x/3x
    running: bool
    dirty_ui: bool        # precisa apresentar o frame

    def init(out self: App, dir: const *char, w: i32 = 1100, h: i32 = 720) -> bool
    # renderiza UM frame e grava um PPM (P6) — como o editor não roda sem X,
    # é assim que se inspeciona/regride o desenho num servidor headless
    def screenshot(ref self: App, path: const *char) -> bool
    def deinit(ref self: App)
    def run(ref self: App) -> i32

    # ---- abas ----
    def open_file(ref self: App, path: const *char)
    def close_tab(ref self: App, i: i32)
    def select_tab(ref self: App, i: i32)
    def cur_cv(ref self: App) -> *CodeView    # None se não houver aba
    def save_cur(ref self: App)
    def update_status(ref self: App)

    # ---- árvore ----
    def tree_scan(ref self: App)
    def tree_toggle(ref self: App, i: i32)

    # ---- palette ----
    def palette_open(ref self: App, mode: PalMode)
    def palette_close(ref self: App)
    def palette_filter(ref self: App)
    def palette_accept(ref self: App)

    # ---- busca ----
    def find_open(ref self: App)
    def find_close(ref self: App)
    def find_step(ref self: App, forward: bool)

    def set_zoom(ref self: App, z: i32)
    # trata uma tecla como ATALHO GLOBAL (ctrl+…, navegação da palette);
    # True = consumido, não desce para a árvore de widgets
    def key_shortcut(ref self: App, ev: *PgEvent) -> bool
