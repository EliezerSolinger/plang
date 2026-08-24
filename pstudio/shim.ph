# shim.ph — the window, the keyboard and the pixels, as SCALARS.
#
# pscript cannot take a pointer across the boundary (45.5): a signature with
# one in it does not cross, and that is the rule that keeps the sandbox worth
# something. SDL2 is nothing BUT pointers, so the driver stays here, in P,
# and what crosses is what a number can say — a handle, a key code, a colour,
# one codepoint at a time.
#
# The editor's LOGIC lives on the other side, in pscript: buffer, carets, undo,
# search, layout, key bindings. This file is the hand that holds the screen.
include <stddef.h>
import <stl/cstr.ph>

# ---- the window ----
def shim_open(w: i32, h: i32) -> bool
def shim_close()
def shim_present()                        # push the frame to the screen
def shim_width() -> i32
def shim_height() -> i32

# ---- events ----
# One call takes the next event and returns its KIND (0 = the queue is empty);
# the details are read with the accessors below. Two calls instead of a struct
# because a struct would be a pointer, and a pointer does not cross.
SHIM_NONE: const i32 = 0
SHIM_QUIT: const i32 = 1
SHIM_KEY: const i32 = 2
SHIM_TEXT: const i32 = 3
SHIM_MOUSE_DOWN: const i32 = 4
SHIM_MOUSE_UP: const i32 = 5
SHIM_MOUSE_MOVE: const i32 = 6
SHIM_WHEEL: const i32 = 7
SHIM_RESIZE: const i32 = 8
SHIM_TIMEOUT: const i32 = 9      # the wait expired (this is what blinks the caret)
SHIM_FOCUS: const i32 = 10       # the window took focus (time to look at the disk)

def shim_poll() -> i32
# 114: ONE event, blocking for up to `ms` milliseconds. Returns SHIM_TIMEOUT when
# it expired — this is how the editor's loop blinks the caret without spinning.
def shim_wait(ms: i32) -> i32
def shim_ev_key() -> i32                  # SDL keycode
def shim_ev_mods() -> i32                 # 1=shift 2=ctrl 4=alt 8=gui
def shim_ev_cp() -> i32                   # SHIM_TEXT: the codepoint typed
def shim_ev_x() -> i32
def shim_ev_y() -> i32
def shim_ev_button() -> i32
def shim_ev_clicks() -> i32
def shim_ev_wheel() -> i32

# ---- drawing (colours are 0xAARRGGBB) ----
def shim_clear(color: i32)
def shim_rect(x: i32, y: i32, w: i32, h: i32, color: i32)
def shim_frame(x: i32, y: i32, w: i32, h: i32, color: i32)
def shim_clip(x: i32, y: i32, w: i32, h: i32)
def shim_clip_reset()
# one codepoint at (x, y) = the cell's top-left; returns the advance
def shim_glyph(cp: i32, x: i32, y: i32, color: i32) -> i32

# ---- the font grid ----
def shim_cell_w() -> i32
def shim_cell_h() -> i32
def shim_baseline() -> i32
def shim_zoom(step: i32)                  # pick another grid (a real raster)
def shim_zoom_steps() -> i32
def shim_zoom_at() -> i32
# the grid's DEFAULT step (the same one the editor in P uses on open and on reset)
def shim_zoom_default() -> i32

# ---- 114: what the app asks of the system, and only the driver can give ----
# The clipboard belongs to the SYSTEM, so it lives here; the text crosses as a
# `CStr` (81/84/85), borrowed on the way in and copied on the way out.
def shim_clip_set(in s: CStr)
def shim_clip_get() -> CStr
# the two modal questions: 0=save 1=discard 2=cancel; and reload yes/no
def shim_confirm_close(in name: CStr) -> i32
def shim_confirm_reload(in name: CStr) -> bool
def shim_title(in s: CStr)
# one frame as PPM, to inspect the drawing on a server with no X
def shim_shot(in p: CStr) -> bool
