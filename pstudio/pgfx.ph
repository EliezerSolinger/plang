# pgfx.ph — pstudio's graphics platform (SDL2 inside; see DESIGN.md).
# Window + streaming texture: the app draws into the PgFb (pgfx_raster) and
# calls w.present(). Event-driven frame: w.wait_event blocks until the next
# event or the timeout (caret blink) — an idle editor uses 0% CPU.
include <stddef.h>
import "pgfx_raster.ph"

enum PgEventKind:
    PGE_NONE
    PGE_QUIT
    PGE_KEY            # "command" key (arrows, ctrl shortcuts, enter...)
    PGE_TEXT           # typed text (UTF-8, already through SDL's layout/IME)
    PGE_MOUSE_DOWN
    PGE_MOUSE_UP
    PGE_MOUSE_MOVE
    PGE_WHEEL
    PGE_RESIZE
    PGE_FOCUS_GAINED
    PGE_FOCUS_LOST
    PGE_TIMEOUT        # wait_event timed out (drives the caret blink)

# modifiers (bitmask in PgEvent.mods)
PGM_SHIFT: const i32 = 1
PGM_CTRL: const i32 = 2
PGM_ALT: const i32 = 4

# keys the app handles (SDL_Keycode; printable ones arrive as PGE_TEXT)
PGK_RETURN: const i32 = 13
PGK_ESCAPE: const i32 = 27
PGK_BACKSPACE: const i32 = 8
PGK_TAB: const i32 = 9
PGK_SPACE: const i32 = 32
PGK_DELETE: const i32 = 127
PGK_RIGHT: const i32 = 1073741903
PGK_LEFT: const i32 = 1073741904
PGK_DOWN: const i32 = 1073741905
PGK_UP: const i32 = 1073741906
PGK_PAGEUP: const i32 = 1073741899
PGK_PAGEDOWN: const i32 = 1073741902
PGK_END: const i32 = 1073741901
PGK_HOME: const i32 = 1073741898
PGK_F1: const i32 = 1073741882
PGK_F2: const i32 = 1073741883
PGK_F3: const i32 = 1073741884

struct PgEvent:
    kind: PgEventKind
    key: i32           # PGE_KEY: SDL_Keycode (PGK_*)
    mods: i32          # PGE_KEY/mouse: bitmask PGM_*
    text: char[32]     # PGE_TEXT: UTF-8 NUL-terminado
    x: i32             # mouse: position; PGE_RESIZE: new width
    y: i32             # mouse: position; PGE_RESIZE: new height
    button: i32        # PGE_MOUSE_*: 1=left 2=middle 3=right
    clicks: i32        # PGE_MOUSE_DOWN: 1=single 2=double 3=triple
    wheel_y: i32       # PGE_WHEEL: +up/-down (in lines)

struct PgWindow:
    win: *void         # SDL_Window (opaque outside pgfx.p)
    ren: *void         # SDL_Renderer
    tex: *void         # streaming SDL_Texture, ARGB8888
    fb: PgFb
    is_open: bool

    # creates a resizable window + framebuffer; False if SDL fails
    def open(out self: PgWindow, title: const *char, width: i32, height: i32) -> bool
    def close(ref self: PgWindow)

    # pushes the framebuffer to the screen (UpdateTexture + RenderCopy + Present)
    def present(ref self: PgWindow)

    # waits for the next event up to timeout_ms (<=0 = wait forever). Handles
    # WINDOW RESIZE internally (reallocating fb + texture) and STILL returns
    # PGE_RESIZE so the app relayouts. False only on a fatal SDL error.
    def wait_event(ref self: PgWindow, out ev: PgEvent, timeout_ms: i32) -> bool

    # takes the next event WITHOUT blocking; False = the queue is empty. The
    # loop uses this to drain everything that arrived and draw ONCE per frame:
    # with vsync, one present per motion event leaves the drag behind the cursor.
    def poll_event(ref self: PgWindow, out ev: PgEvent) -> bool

    # native dialog (closing a dirty tab): 0=save 1=discard 2=cancel
    def confirm_close(ref self: PgWindow, filename: const *char) -> i32
    # yes/no prompt (reload a file changed on disk): True = yes
    def confirm_reload(ref self: PgWindow, filename: const *char) -> bool
    def set_title(ref self: PgWindow, title: const *char)

# ---- clipboard (SDL global state: free functions) ----
def pgfx_clipboard_set(text: const *char)
def pgfx_clipboard_get() -> *char       # malloc'd (caller frees); None if empty
