# codeview.ph — pstudio's editing widget: a WK_CUSTOM that ties together
# core (Buffer/Highlight) + pui (layout/commands/input) + pgfx (the font).
#
# It follows Godot's TextEdit where it matters: the SCROLLBARS are INTERNAL
# children the widget creates and positions itself (c_layout), and the GUTTERS
# are pluggable (line numbers today; breakpoints/errors later, no refactor).
include <stddef.h>
import "pui.ph"
import "core.ph"

# a gutter: a column to the left of the text. `draw` fills in the line's text
# (a buffer of `cap` bytes) and returns the color; False = empty cell.
struct Gutter:
    width_cp: i32     # width in CHARACTERS (mono)
    ctx: *void
    draw: def(ctx: *void, cv: *CodeView, line: i32, out_text: *char, cap: usize, out_color: *u32) -> bool

MAX_GUTTERS: const i32 = 4

struct CodeView:
    buf: Buffer
    hl: Highlight
    path: *char       # None = no file (a detached buffer)
    ui: *Ui           # owner (the callbacks get this same pointer)
    id: i32           # this widget's id in the pool
    vsb: i32          # vertical scrollbar (internal child)
    hsb: i32          # horizontal
    top: i32          # first visible line
    left: i32         # first visible SCREEN COLUMN (tabs expanded)
    gutters: Gutter[MAX_GUTTERS]
    ngutters: i32
    caret_on: bool    # blink phase (the app toggles it on the timeout)
    mouse_sel: bool   # dragging a selection
    mtime: i64        # the file's mtime at the last read (external-change check)
    # optional callback: tells the app something changed (title/status bar)
    on_change: def(ctx: *void, cv: *CodeView)
    on_change_ctx: *void

# creates the widget (with its internal scrollbars) and returns the id
def cv_create(ref ui: Ui, parent: i32) -> i32
def cv_of(ref ui: Ui, id: i32) -> *CodeView     # the widget's payload

struct CodeView:
    # ---- file ----
    def load_file(ref self: CodeView, path: const *char) -> bool
    def save_file(ref self: CodeView) -> bool
    def reload(ref self: CodeView) -> bool       # re-reads from disk (discards edits)
    def set_text(ref self: CodeView, text: const *char)   # a detached buffer

    # ---- geometry (the app uses it for the status bar and the palette) ----
    def text_rect(in self: CodeView) -> PgRect   # the text area (without gutters/scrollbars)
    def gutter_w(in self: CodeView) -> i32       # total gutter width (px)
    def visible_lines(in self: CodeView) -> i32
    def add_gutter(ref self: CodeView, g: Gutter)
    def line_numbers_gutter(ref self: CodeView)  # the default gutter (line numbers)

    # ---- navigation ----
    def scroll_to_caret(ref self: CodeView)
    def set_top(ref self: CodeView, line: i32)
    def set_left(ref self: CodeView, col: i32)
    # SCREEN column of (line, col) — expands tabs to TAB_WIDTH
    def screen_col(in self: CodeView, line: i32, col: i32) -> i32
    # the inverse: the codepoint column nearest a screen column
    def col_from_screen(in self: CodeView, line: i32, scol: i32) -> i32
    def pos_from_xy(in self: CodeView, x: i32, y: i32, out line: i32, out col: i32)

    # ---- editing (forwards to the buffer, then scroll/dirty/relex) ----
    def changed(ref self: CodeView)              # invalidate: relex + redraw
    def copy(ref self: CodeView) -> bool         # -> clipboard (multi-caret)
    def cut(ref self: CodeView, now_ms: i64) -> bool
    def paste(ref self: CodeView, now_ms: i64)
    def indent(ref self: CodeView, now_ms: i64)  # tab: 4 spaces, or the whole block
    def unindent(ref self: CodeView, now_ms: i64)
    def newline(ref self: CodeView, now_ms: i64) # enter, with auto-indent

    # ---- search (driven by the app's find bar) ----
    # `re` = treat needle as a POSIX regex; moves the caret and scrolls
    def search(ref self: CodeView, needle: const *char, forward: bool, re: bool, from_caret: bool) -> bool

# multi-caret clipboard (Sublime style): N selections keep N pieces, while the
# SYSTEM clipboard gets them joined by \n. Module state (one editor per process).
def cv_clip_clear()
def cv_clip_count() -> i32
