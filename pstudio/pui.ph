# pui.ph — pstudio's UI toolkit (Godot's model, reimplemented; DESIGN.md §3).
#
# The tree lives in a LINEAR POOL addressed by index: WidgetId = i32 (NEVER a
# pointer — the pool reallocates). Two-phase layout (minimum size bubbles up,
# rects flow down — the math of Godot's BoxContainer/SplitContainer). Retained
# draw: every widget keeps its own command list and rewrites it only when
# dirty. No inheritance and no interfaces: dispatch is `match kind`, and app
# widgets are WK_CUSTOM plus function pointers.
include <stddef.h>
import "pgfx.ph"   # PgEvent/PgFb types (does not pull SDL into the link)
import "../stl/vec.ph"

enum WidgetKind:
    WK_NONE
    WK_PANEL       # background rect; children stacked on the whole rect
    WK_BOX         # linear v/h container (BoxContainer's algorithm)
    WK_SPLIT       # two children + a draggable divider (SplitContainer)
    WK_LABEL
    WK_BUTTON
    WK_SCROLLBAR
    WK_INPUT       # single-line text input (palette, search)
    WK_CUSTOM      # app widget: driven by the node's function pointers

# a char literal cannot hold a codepoint above ASCII (in C that would be a
# multi-character constant), so the ones drawn by codepoint are named here
CP_ELLIPSIS: const u32 = 0x2026    # … elided text, collapsed block

# WidgetBase flags
UF_VISIBLE: const u32 = 1
UF_EXPAND_H: const u32 = 2    # horizontal SIZE_EXPAND (stretches in a horizontal BOX)
UF_EXPAND_V: const u32 = 4
UF_DIRTY: const u32 = 8       # the command list must be rewritten
UF_FOCUSABLE: const u32 = 16
UF_HOVER: const u32 = 32      # state computed by input (read-only)
UF_PRESSED: const u32 = 64

struct WidgetBase:
    rect: PgRect      # FINAL rect in screen coordinates (after layout)
    min_w: i32        # custom minimum size (0 = only what the kind computes)
    min_h: i32
    stretch: i32      # EXPAND weight inside a box (default 1)
    flags: u32
    cw: i32           # minimum COMPUTED by phase 1 (layout-internal)
    ch: i32
    bg: u32           # painted before anything else; 0 = transparent. Lets a
                      #   plain container carry a background (Godot needs a
                      #   PanelContainer for this) — no wrapper widget needed
    pad: i32          # left inset for text (label/button/input)

# a retained draw command (replayed at composition time)
enum CmdKind:
    CMD_RECT
    CMD_FRAME
    CMD_TEXT          # text (its own copy) at (x,y)
    CMD_GLYPH         # one codepoint at (x,y) — NO allocation (CodeView text)

struct Cmd:
    kind: CmdKind
    x: i32
    y: i32
    w: i32
    h: i32
    color: u32
    cp: u32           # CMD_GLYPH: codepoint
    text: *char       # CMD_TEXT: malloc'd (freed on rewrite/destroy)

# a signal: {fn, ctx} — arg depends on the signal (button: 0; scrollbar: new value)
struct UiSignal:
    fn: def(ctx: *void, id: i32, arg: i64)
    ctx: *void

declare Vec<Cmd>

struct UINode:
    kind: WidgetKind
    alive: bool
    parent: i32          # -1 = root/detached
    first_child: i32     # -1 = leaf
    next_sibling: i32    # sibling order = draw order (also the freelist link)
    base: WidgetBase     # INLINE: the layout walk never dereferences the payload
    data: *void          # per-kind payload (malloc; released in free_node)
    cmds: Vec<Cmd>       # RETAINED command list (rewritten only when dirty)
    # WK_CUSTOM: behavior comes from the app
    c_min: def(ui: *Ui, id: i32, out_w: *i32, out_h: *i32)
    c_build: def(ui: *Ui, id: i32)                      # rewrites the commands (cmd_*)
    c_input: def(ui: *Ui, id: i32, ev: *PgEvent) -> bool
    c_layout: def(ui: *Ui, id: i32, r: PgRect)          # lays out its own children
    c_free: def(ui: *Ui, id: i32)                       # releases the payload

# theme (a dark preset compiled in; a config file comes later)
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
    pad: i32          # inner padding (buttons and friends)
    sep: i32          # separation between BOX children
    handle: i32       # thickness of the SPLIT divider / scrollbar

declare Vec<UINode>

struct Ui:
    nodes: Vec<UINode>
    free_head: i32    # freelist (chained through next_sibling)
    root: i32
    focus: i32        # keyboard focus (exactly one, Godot's model)
    capture: i32      # mouse captured from press until release
    hover: i32
    theme: Theme
    font: PgFont
    lay_w: i32        # size of the last layout (to relayout after changes)
    lay_h: i32
    needs_draw: bool  # something got dirty since the last draw() — the loop
                      #   checks this instead of repainting on every event

    # ---- lifetime ----
    def init(out self: Ui, font: PgFont)
    def deinit(ref self: Ui)
    def node(ref self: Ui, id: i32) -> *UINode   # an INVALID id is the caller's bug
    def new_node(ref self: Ui, kind: WidgetKind, parent: i32) -> i32  # appended as the last child
    def free_node(ref self: Ui, id: i32)         # the whole subtree
    def reparent(ref self: Ui, id: i32, new_parent: i32)

    # ---- constructors ----
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

    # ---- properties ----
    def set_expand(ref self: Ui, id: i32, h: bool, v: bool)
    def set_min(ref self: Ui, id: i32, w: i32, h: i32)
    def set_stretch(ref self: Ui, id: i32, weight: i32)
    def set_bg(ref self: Ui, id: i32, color: u32)   # 0 = transparent
    def set_pad(ref self: Ui, id: i32, px: i32)     # left inset for text
    def set_visible(ref self: Ui, id: i32, vis: bool)
    def is_visible(ref self: Ui, id: i32) -> bool
    def set_focusable(ref self: Ui, id: i32, f: bool)
    def set_text(ref self: Ui, id: i32, text: const *char)   # label/button/input
    def text_of(ref self: Ui, id: i32) -> const *char        # label/button/input
    def set_rect(ref self: Ui, id: i32, r: PgRect)           # for c_layout
    def data_of(ref self: Ui, id: i32) -> *void              # a custom widget's payload
    def rect_of(ref self: Ui, id: i32) -> PgRect
    def queue_redraw(ref self: Ui, id: i32)                  # marks it dirty
    def queue_redraw_tree(ref self: Ui, id: i32)             # the whole subtree

    # ---- signals ----
    def on_click(ref self: Ui, id: i32, fn: def(ctx: *void, id: i32, arg: i64), ctx: *void)
    def on_scroll(ref self: Ui, id: i32, fn: def(ctx: *void, id: i32, arg: i64), ctx: *void)
    def on_changed(ref self: Ui, id: i32, fn: def(ctx: *void, id: i32, arg: i64), ctx: *void)
    def on_submit(ref self: Ui, id: i32, fn: def(ctx: *void, id: i32, arg: i64), ctx: *void)
    def on_cancel(ref self: Ui, id: i32, fn: def(ctx: *void, id: i32, arg: i64), ctx: *void)

    # ---- split / scrollbar / input ----
    def split_set(ref self: Ui, id: i32, offset: i32)        # divider position
    def split_offset(ref self: Ui, id: i32) -> i32
    # scrollbar: total = content, page = visible, value = position (clamped)
    def scroll_set(ref self: Ui, id: i32, total: i64, page: i64, value: i64)
    def scroll_value(ref self: Ui, id: i32) -> i64
    def input_clear(ref self: Ui, id: i32)

    # ---- focus ----
    def focus_set(ref self: Ui, id: i32)
    def focus_get(ref self: Ui) -> i32

    # ---- frame ----
    def layout(ref self: Ui, w: i32, h: i32)     # both phases over the whole tree
    def relayout(ref self: Ui)                   # repeats with the last size
    def draw(ref self: Ui, ref fb: PgFb)         # rewrites dirty widgets, replays with clipping
    def input_event(ref self: Ui, ev: *PgEvent) -> bool   # True = consumed
    def hit(ref self: Ui, x: i32, y: i32) -> i32 # topmost widget at that point

    # ---- builder API (used inside c_build) ----
    def cmd_rect(ref self: Ui, id: i32, r: PgRect, color: u32)
    def cmd_frame(ref self: Ui, id: i32, r: PgRect, color: u32)
    def cmd_text(ref self: Ui, id: i32, x: i32, y: i32, text: const *char, color: u32)
    def cmd_text_n(ref self: Ui, id: i32, x: i32, y: i32, text: const *char, nbytes: usize, color: u32)
    def cmd_glyph(ref self: Ui, id: i32, x: i32, y: i32, cp: u32, color: u32)
    # `text` clipped to `max_w` pixels, ending in `…` when it does not fit.
    # Returns the width actually drawn, so a caller laying out columns knows
    # where the next one may start. Anything drawing text it did not measure
    # should come through here: clipping the widget only hides the overflow,
    # it still paints over whatever the box was supposed to frame.
    def cmd_text_fit(ref self: Ui, id: i32, x: i32, y: i32, text: const *char, max_w: i32, color: u32) -> i32
