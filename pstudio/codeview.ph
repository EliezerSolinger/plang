# codeview.ph — pstudio's editing widget: a WK_CUSTOM that ties together
# core (Buffer/Highlight) + pui (layout/commands/input) + pgfx (the font).
#
# It follows Godot's TextEdit where it matters: the SCROLLBARS are INTERNAL
# children the widget creates and positions itself (c_layout), and the GUTTERS
# are pluggable (line numbers today; breakpoints/errors later, no refactor).
include <stddef.h>
import "pui.ph"
import "core.ph"
import "complete.ph"

# a gutter: a column to the left of the text. `draw` fills in the line's text
# (a buffer of `cap` bytes) and returns the color; False = empty cell. `click`
# is optional: a gutter that reacts to the mouse (folding, breakpoints) gets
# the line that was clicked and returns True when it consumed the click.
struct Gutter:
    width_cp: i32     # width in CHARACTERS (mono)
    ctx: *void
    draw: def(ctx: *void, cv: *CodeView, line: i32, out_text: *char, cap: usize, out_color: *u32) -> bool
    click: def(ctx: *void, cv: *CodeView, line: i32) -> bool

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
    index: Index      # completion index, rebuilt lazily from the buffer
    cmp_open: bool    # the completion popup is showing
    cmp_hits: Vec<i32>
    cmp_sel: i32
    cmp_top: i32      # first row shown in the popup
    cmp_col: i32      # column where the word being completed starts
    cmp_owner: *char  # struct whose members are listed (the `x.` case)
    minimap: bool     # the overview strip on the right (Godot's TextEdit)
    minimap_drag: bool
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
    def minimap_rect(in self: CodeView) -> PgRect  # empty when the strip is off
    def toggle_minimap(ref self: CodeView)
    def gutter_w(in self: CodeView) -> i32       # total gutter width (px)
    def visible_lines(in self: CodeView) -> i32
    def add_gutter(ref self: CodeView, g: Gutter)
    def line_numbers_gutter(ref self: CodeView)  # the default gutter (line numbers)
    def fold_gutter(ref self: CodeView)          # ▾/▸ markers, click toggles
    def marks_gutter(ref self: CodeView)         # ● breakpoint / ◆ bookmark

    # ---- navigation ----
    # the buffer line drawn at screen row `row` (0 = the top of the view), and
    # the row a line is drawn at (-1 when it is folded away). Every screen
    # coordinate goes through these — the buffer holds the visible-line map.
    def line_at_row(in self: CodeView, row: i32) -> i32
    def row_of_line(in self: CodeView, line: i32) -> i32
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

    # ---- folding / line commands (the keys and the palette call these) ----
    def toggle_fold_at_caret(ref self: CodeView)
    def fold_all(ref self: CodeView)
    def unfold_all(ref self: CodeView)
    def toggle_comment(ref self: CodeView, now_ms: i64)
    def toggle_bookmark(ref self: CodeView)
    def goto_mark(ref self: CodeView, forward: bool)   # jumps between bookmarks
    def move_lines(ref self: CodeView, dir: i32, now_ms: i64)
    def duplicate_lines(ref self: CodeView, now_ms: i64)
    def delete_lines(ref self: CodeView, now_ms: i64)
    def join_lines(ref self: CodeView, now_ms: i64)

    # ---- completion (index built from the compiler's lexer) ----
    def complete_open(ref self: CodeView)     # ctrl+space, and after `.`/`->`
    def complete_close(ref self: CodeView)
    def complete_accept(ref self: CodeView, now_ms: i64) -> bool
    def complete_refresh(ref self: CodeView)  # re-filter after each keystroke

    # ---- search (driven by the app's find bar) ----
    # `re` = treat needle as a POSIX regex; moves the caret and scrolls
    def search(ref self: CodeView, needle: const *char, forward: bool, re: bool, from_caret: bool) -> bool

# multi-caret clipboard (Sublime style): N selections keep N pieces, while the
# SYSTEM clipboard gets them joined by \n. Module state (one editor per process).
def cv_clip_clear()
def cv_clip_count() -> i32
