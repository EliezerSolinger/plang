include <stdio.h>
import "../../pstudio/pgfx_raster.ph"

# renders the region as ASCII art: '#' a text pixel, '+' the frame,
# '.' the rect's fill, ' ' the cleared background — readable AND deterministic
private def dump(ref fb: PgFb, r: PgRect):
    for y in range(r.y, r.y + r.h):
        for x in range(r.x, r.x + r.w):
            c: u32 = fb.px[usize(y) * usize(fb.w) + usize(x)]
            ch: char = ' '
            if c == 0xFF303030:
                ch = '.'
            elif c == 0xFF00FF00:
                ch = '+'
            elif c != 0xFF101010:
                ch = '#'
            putchar(i32(ch))
        putchar(i32('\n'))

def main() -> int:
    fb: PgFb
    fb.init(40, 22)
    fb.clear(0xFF101010)
    fb.fill_rect(pg_rect(1, 1, 38, 20), 0xFF303030)
    fb.frame_rect(pg_rect(1, 1, 38, 20), 0xFF00FF00)

    f: PgFont = pg_font_default(pg_font_default_size())
    printf("cell=%dx%d base=%d adv=%d lh=%d\n",
           f.cell_w, f.cell_h, f.baseline, f.char_w(), f.line_h())
    printf("w(abc)=%d w(áé□)=%d w3(abcdef)=%d\n",
           f.text_width("abc"), f.text_width("áé□"), f.text_width_n("abcdef", 3))

    end: i32 = fb.draw_text(in f, "Hi!", 4, 3, 0xFFFFFFFF)
    printf("end=%d\n", end)
    # clip: nothing may land outside this rect
    fb.clip_set(pg_rect(4, 4, 8, 8))
    fb.fill_rect(pg_rect(0, 0, 100, 100), 0xFFFF0000)
    fb.clip_reset()
    dump(ref fb, pg_rect(0, 0, 40, 22))

    # rect helpers
    i: PgRect = pg_rect(0, 0, 10, 10).intersect(pg_rect(5, 5, 10, 10))
    printf("isect=%d,%d,%d,%d in=%d out=%d empty=%d\n", i.x, i.y, i.w, i.h,
           i.contains(5, 5), i.contains(10, 10),
           pg_rect(0, 0, 0, 5).is_empty())
    fb.deinit()
    return 0
