# pgfx smoke test: runs under SDL_VIDEODRIVER=dummy (no display). It needs
# libsdl2 — the runner skips it with a notice when SDL is absent.
include <stdio.h>
import "../../pstudio/pgfx.ph"

def main() -> int:
    w: PgWindow
    if not w.open("smoke", 320, 200):
        printf("pgfx-skip (SDL unavailable)\n")
        return 0
    printf("open=%dx%d\n", w.fb.w, w.fb.h)
    w.fb.clear(0xFF101010)
    f: PgFont = pg_font_default(pg_font_default_size())
    w.fb.draw_text(in f, "pstudio", 8, 8, 0xFFE0E0E0)
    w.present()
    # drain the window's initial events; the timeout path must be reached
    ev: PgEvent
    ok: bool = True
    hit_timeout: bool = False
    for i in range(10):
        ok = w.wait_event(out ev, 60)
        if not ok or ev.kind == PGE_TIMEOUT:
            hit_timeout = ev.kind == PGE_TIMEOUT
            break
    printf("wait=%d timeout=%d\n", ok, hit_timeout)
    # did any text pixel actually land in the framebuffer?
    lit: i32 = 0
    for i in range(usize(w.fb.w) * usize(w.fb.h)):
        if w.fb.px[i] != 0xFF101010:
            lit += 1
    printf("lit=%d\n", 1 if lit > 50 else 0)
    w.close()
    printf("pgfx-ok\n")
    return 0
