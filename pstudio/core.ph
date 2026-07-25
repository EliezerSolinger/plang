# core.ph — pstudio's text editing (HEADLESS: testable without a window).
#
# Buffer = an array of lines (UTF-8 bytes; caret/selection by CODEPOINT).
# Real multi-caret (ctrl+d) since v0.1. Coalesced undo: continuous typing is
# grouped and broken by space/enter/a pause (~700ms)/movement. Highlighting
# relexes the WHOLE FILE with the compiler's REAL lexer in tolerant mode
# (lex_ex).
#
# The containers are the project's STL (Vec<T>) — the compiler's own diet.
include <stddef.h>
import "../stl/vec.ph"

struct BufLine:
    text: *char       # UTF-8 bytes, NO \n, NUL-terminated (malloc)
    ncp: i32          # codepoints (cached for movement and layout)

struct Caret:
    line: i32         # 0-based
    col: i32          # CODEPOINT index within the line
    aline: i32        # selection anchor (== line/col when there is no selection)
    acol: i32
    goal: i32         # target column for vertical movement (-1 = use col)

enum EditOpKind:
    OP_INSERT
    OP_DELETE

struct EditOp:
    kind: EditOpKind
    line: i32         # where the edit starts (codepoints)
    col: i32
    text: *char       # the inserted/deleted text (may contain \n; malloc)

declare Vec<BufLine>
declare Vec<Caret>
declare Vec<EditOp>

struct UndoGroup:
    ops: Vec<EditOp>
    before: Vec<Caret>   # caret snapshot before the group
    after: Vec<Caret>    # and after it (for redo)

declare Vec<UndoGroup>

struct Buffer:
    lines: Vec<BufLine>
    carets: Vec<Caret>   # ALWAYS >= 1, sorted by position
    undo: Vec<UndoGroup>
    redo: Vec<UndoGroup>
    group_open: bool     # typing coalescence
    last_ms: i64
    crlf: bool           # EOL detected on load (preserved on save)
    dirty: bool
    version: u64         # bumped on every edit (highlight/draw watch it)

    # ---- lifetime ----
    def init(out self: Buffer)                    # one empty line, one caret
    def deinit(ref self: Buffer)
    def load(ref self: Buffer, data: const *char, len: usize)   # detects CRLF
    def save_text(ref self: Buffer, out len: usize) -> *char     # EOL preserved

    # ---- queries ----
    def nlines(in self: Buffer) -> i32
    def ncarets(in self: Buffer) -> i32
    def line_text(in self: Buffer, line: i32) -> const *char
    def line_cp(in self: Buffer, line: i32) -> i32       # codepoints in the line
    # byte offset of codepoint `col` within the line (for drawing/slicing)
    def col_byte(in self: Buffer, line: i32, col: i32) -> i32
    def has_sel(in self: Buffer) -> bool                 # does any caret have a selection?
    def sel_text(ref self: Buffer, k: i32) -> *char      # malloc'd; None when there is no selection
    def caret(ref self: Buffer, k: i32) -> *Caret
    # ordered bounds of caret k's selection (equal when there is none)
    def sel_range(in self: Buffer, k: i32, out l0: i32, out c0: i32, out l1: i32, out c1: i32)
    def range_text(ref self: Buffer, l0: i32, c0: i32, l1: i32, c1: i32) -> *char

    # ---- editing (applies to ALL carets; now_ms drives undo coalescing) ----
    def insert(ref self: Buffer, text: const *char, now_ms: i64)
    # one text PER CARET (Sublime-style multi-caret paste); n must be ncarets
    def insert_each(ref self: Buffer, texts: **char, n: i32, now_ms: i64)
    def backspace(ref self: Buffer, now_ms: i64)
    def delete_fwd(ref self: Buffer, now_ms: i64)
    def delete_sel(ref self: Buffer, now_ms: i64)        # selections only
    # replaces the range with text (used by indent/search); ends with one caret
    def replace_range(ref self: Buffer, l0: i32, c0: i32, l1: i32, c1: i32, text: const *char, now_ms: i64)

    # ---- movement (sel=True extends the selection; breaks the undo group) ----
    def move_h(ref self: Buffer, delta: i32, sel: bool)
    def move_v(ref self: Buffer, delta: i32, sel: bool)
    def move_word(ref self: Buffer, dir: i32, sel: bool)  # ctrl+arrows
    def home(ref self: Buffer, sel: bool)                 # smart: indent <-> column 0
    def end(ref self: Buffer, sel: bool)
    def move_to(ref self: Buffer, line: i32, col: i32)     # one caret at that position
    def select_range(ref self: Buffer, l0: i32, c0: i32, l1: i32, c1: i32)
    def select_all(ref self: Buffer)
    def collapse(ref self: Buffer)                         # one caret, no selection
    def add_caret(ref self: Buffer, line: i32, col: i32)   # alt+click
    def select_word_at(ref self: Buffer, k: i32) -> bool   # double click

    # ---- multi-caret (ctrl+d, Sublime's model) ----
    # with no selection: select the word under each caret; with a selection:
    # add a caret at the NEXT occurrence of the last caret's text (wrapping)
    def ctrl_d(ref self: Buffer)

    # ---- search ----
    # plain substring; wraps around. False when not found.
    def find(in self: Buffer, needle: const *char, from_line: i32, from_col: i32,
             forward: bool, out l: i32, out c: i32) -> bool
    # POSIX regex (libc): the editor's regex mode. Within a single line only.
    def find_re(in self: Buffer, pattern: const *char, from_line: i32, from_col: i32,
                forward: bool, out l: i32, out c0: i32, out c1: i32) -> bool

    # ---- undo ----
    def undo_step(ref self: Buffer) -> bool
    def redo_step(ref self: Buffer) -> bool
    def break_group(ref self: Buffer)             # movement/clicks break it
    def mark_saved(ref self: Buffer)              # after saving: clears dirty

# ---- highlighting (full relex with the compiler's lexer, tolerant) ----
HL_TEXT: const u8 = 0
HL_KW: const u8 = 1
HL_STR: const u8 = 2
HL_NUM: const u8 = 3
HL_COMMENT: const u8 = 4
HL_PUNCT: const u8 = 5

struct HlSpan:
    col: i32          # first codepoint
    len: i32          # length in codepoints
    cls: u8

declare Vec<HlSpan>

struct HlLine:
    spans: Vec<HlSpan>

declare Vec<HlLine>

struct Highlight:
    lines: Vec<HlLine>   # one per buffer line
    version: u64         # the buffer version this matches
    enabled: bool        # False = not a P file (no spans at all)

    def init(out self: Highlight, enabled: bool)
    def deinit(ref self: Highlight)
    # recomputes when version != b.version (whole file; cheap enough)
    def update(ref self: Highlight, ref b: Buffer)
    # class of codepoint `col` on that line (HL_TEXT when outside every span)
    def class_at(in self: Highlight, line: i32, col: i32) -> u8
