# shim.p — the P side of the boundary (see shim.ph).
#
# It owns exactly one window and one font grid, because that is all a scalar
# handle can address without inventing a table nobody asked for. Everything
# here is a thin call into pgfx, which is the code the P editor already uses:
# the point of the port is to REPLACE the logic above this line, not to write
# a second rasterizer.
include <string.h>
import "shim.ph"
import "../pgfx.ph"
import "../pgfx_raster.ph"
import "../psys.ph"

static W: PgWindow
static F: PgFont
static OPEN: bool = False
static EV: PgEvent
static ZOOM: i32 = 0

def shim_open(w: i32, h: i32) -> bool:
    if OPEN:
        return True
    if not W.open("pstudio (pscript)", w, h):
        return False
    ZOOM = pg_font_default_size()
    F = pg_font_default(ZOOM)
    OPEN = True
    return True

def shim_close():
    if OPEN:
        W.close()
        OPEN = False

def shim_present():
    if OPEN:
        W.present()

def shim_width() -> i32:
    return W.fb.w if OPEN else 0

def shim_height() -> i32:
    return W.fb.h if OPEN else 0

# ---- events ----
# The kind is the return value and the details stay here, read one accessor at
# a time: a struct would have to cross as a pointer, and a pointer does not
# cross (45.5).
def shim_poll() -> i32:
    if not OPEN:
        return SHIM_NONE
    if not W.poll_event(out EV):
        return SHIM_NONE
    match EV.kind:
        case PGE_QUIT:
            return SHIM_QUIT
        case PGE_KEY:
            return SHIM_KEY
        case PGE_TEXT:
            return SHIM_TEXT
        case PGE_MOUSE_DOWN:
            return SHIM_MOUSE_DOWN
        case PGE_MOUSE_UP:
            return SHIM_MOUSE_UP
        case PGE_MOUSE_MOVE:
            return SHIM_MOUSE_MOVE
        case PGE_WHEEL:
            return SHIM_WHEEL
        case PGE_RESIZE:
            return SHIM_RESIZE
        case _:
            return SHIM_NONE

def shim_ev_key() -> i32:
    return EV.key

def shim_ev_mods() -> i32:
    return EV.mods

# the FIRST codepoint of what was typed: an editor inserts one character per
# event, and SDL already resolved the layout and the IME
def shim_ev_cp() -> i32:
    i: usize = 0
    return i32(pg_utf8_step(&EV.text[0], ref i)) if EV.text[0] != '\0' else 0

def shim_ev_x() -> i32:
    return EV.x

def shim_ev_y() -> i32:
    return EV.y

def shim_ev_button() -> i32:
    return EV.button

def shim_ev_clicks() -> i32:
    return EV.clicks

def shim_ev_wheel() -> i32:
    return EV.wheel_y

# ---- drawing ----
def shim_clear(color: i32):
    if OPEN:
        W.fb.clear(u32(color))

def shim_rect(x: i32, y: i32, w: i32, h: i32, color: i32):
    if OPEN:
        W.fb.fill_rect(pg_rect(x, y, w, h), u32(color))

def shim_frame(x: i32, y: i32, w: i32, h: i32, color: i32):
    if OPEN:
        W.fb.frame_rect(pg_rect(x, y, w, h), u32(color))

def shim_clip(x: i32, y: i32, w: i32, h: i32):
    if OPEN:
        W.fb.clip_set(pg_rect(x, y, w, h))

def shim_clip_reset():
    if OPEN:
        W.fb.clip_reset()

def shim_glyph(cp: i32, x: i32, y: i32, color: i32) -> i32:
    if not OPEN:
        return 0
    return W.fb.draw_glyph(in F, u32(cp), x, y, u32(color))

# ---- the font grid ----
def shim_cell_w() -> i32:
    return F.cell_w if OPEN else 8

def shim_cell_h() -> i32:
    return F.cell_h if OPEN else 16

def shim_baseline() -> i32:
    return F.baseline if OPEN else 12

def shim_zoom(step: i32):
    n: i32 = pg_font_steps()
    s: i32 = 0 if step < 0 else (n - 1 if step >= n else step)
    ZOOM = s
    F = pg_font_default(s)

def shim_zoom_steps() -> i32:
    return pg_font_steps()

def shim_zoom_at() -> i32:
    return ZOOM

def shim_millis() -> i64:
    return ps_millis()
