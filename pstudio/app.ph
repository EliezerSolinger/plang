# app.ph — the editor itself: tabs, file tree, command palette, search and the
# event loop. Layer 5 of DESIGN.md.
include <stddef.h>
import "pui.ph"
import "codeview.ph"
import "../stl/vec.ph"
import "../stl/str.ph"

struct Tab:
    cv: i32           # the CodeView's id (it owns the buffer)
    title: *char      # the file's basename (malloc)

struct TreeEntry:
    path: *char       # full path (malloc)
    name: *char       # displayed name (malloc)
    depth: i32
    is_dir: bool
    expanded: bool

enum PalMode:
    PAL_FILES         # fuzzy file search (the default)
    PAL_COMMANDS      # the '>' prefix
    PAL_GOTO          # the ':' prefix

struct PalItem:
    label: *char      # displayed text (malloc)
    payload: *char    # file path / command id (malloc)
    score: i32

declare Vec<Tab>
declare Vec<TreeEntry>
declare Vec<PalItem>

struct App:
    ui: Ui
    win: PgWindow
    root: i32         # root panel (stacks the layout and the palette)
    tabbar: i32
    tree: i32
    split: i32
    editors: i32      # vertical box: [cvhost | find bar]
    cvhost: i32       # the box hosting the CodeViews (the find bar sits below)
    findbar: i32
    findinput: i32
    status: i32
    palette: i32
    palinput: i32
    tabs: Vec<Tab>
    cur: i32          # active tab (-1 = none)
    tab_hover: i32    # tab under the cursor (-1 = none)
    tab_hover_x: bool # the cursor is over that tab's ×
    entries: Vec<TreeEntry>
    tree_top: i32
    root_dir: *char
    palmode: PalMode
    palitems: Vec<PalItem>
    palsel: i32
    paltop: i32
    files: Vec<PalItem>   # the project's file index (scanned once)
    find_re: bool         # regex search mode (a query starting with '/')
    zoom: i32             # 1x/2x/3x
    running: bool
    dirty_ui: bool        # a frame must be presented

    def init(out self: App, dir: const *char, w: i32 = 1100, h: i32 = 720) -> bool
    # renders ONE frame and writes a PPM (P6) — since the editor needs X to
    # run, this is how the drawing is inspected on a headless server
    def screenshot(ref self: App, path: const *char) -> bool
    def deinit(ref self: App)
    def run(ref self: App) -> i32

    # ---- tabs ----
    def open_file(ref self: App, path: const *char)
    def close_tab(ref self: App, i: i32)
    def select_tab(ref self: App, i: i32)
    def cur_cv(ref self: App) -> *CodeView    # None when there is no tab
    def save_cur(ref self: App)
    def update_status(ref self: App)

    # ---- file tree ----
    def tree_scan(ref self: App)
    def tree_toggle(ref self: App, i: i32)

    # ---- palette ----
    def palette_open(ref self: App, mode: PalMode)
    def palette_close(ref self: App)
    def palette_filter(ref self: App)
    def palette_accept(ref self: App)

    # ---- search ----
    def find_open(ref self: App)
    def find_close(ref self: App)
    def find_step(ref self: App, forward: bool)

    def set_zoom(ref self: App, z: i32)
    # handles a key as a GLOBAL SHORTCUT (ctrl+…, palette navigation);
    # True = consumed, so it never reaches the widget tree
    def key_shortcut(ref self: App, ev: *PgEvent) -> bool
