# app_flow: the WHOLE EDITOR exercised without a keyboard or a display (the
# SDL dummy driver). It builds a small project, opens files, types, uses the
# palette/search/tabs and takes an ASCII "screenshot" of the frame — a
# regression test for both layout and drawing.
include <stdio.h>
include <stdlib.h>
include <string.h>
import "../../pstudio/app.ph"
import "../../pstudio/psys.ph"

static def wr(path: const *char, text: const *char):
    v: Vfs = vfs_local()
    vfs_write_all(in v, path, text, strlen(text))

# coarse map of the framebuffer: one character per 16x24 px cell
static def shot(ref app: App, r: PgRect):
    fb: *PgFb = &app.win.fb
    for cy in range(r.y, r.y + r.h, 24):
        for cx in range(r.x, r.x + r.w, 16):
            hits: i32 = 0
            for y in range(cy, cy + 24):
                for x in range(cx, cx + 16):
                    if y >= fb->h or x >= fb->w:
                        continue
                    if fb->px[usize(y) * usize(fb->w) + usize(x)] != app.ui.theme.bg:
                        hits += 1
            putchar(i32(' ') if hits == 0 else (i32('.') if hits < 60 else i32('#')))
        putchar(i32('\n'))

static def click(ref app: App, x: i32, y: i32):
    ev: PgEvent = {0}
    ev.kind = PGE_MOUSE_DOWN
    ev.button = 1
    ev.clicks = 1
    ev.x = x
    ev.y = y
    app.ui.input_event(&ev)
    ev.kind = PGE_MOUSE_UP
    app.ui.input_event(&ev)

static def typed(ref app: App, s: const *char):
    ev: PgEvent = {0}
    ev.kind = PGE_TEXT
    strcpy(ev.text, s)
    app.ui.input_event(&ev)

static def keyp(ref app: App, k: i32, mods: i32):
    ev: PgEvent = {0}
    ev.kind = PGE_KEY
    ev.key = k
    ev.mods = mods
    if not app.key_shortcut(&ev):
        app.ui.input_event(&ev)

def main() -> int:
    sh: *char
    ps_run("rm -rf proj && mkdir -p proj/sub", out sh)
    free(sh)
    wr("proj/hello.p", "def main() -> i32:\n    x: i32 = 42  # resposta\n    return x\n")
    wr("proj/util.ph", "def helper(a: i32) -> i32\n")
    wr("proj/sub/notas.txt", "texto simples\nsegunda linha\n")

    app: App
    if not app.init("proj"):
        printf("app-skip (SDL unavailable)\n")
        return 0
    printf("window=%dx%d\n", app.win.fb.w, app.win.fb.h)
    printf("tree=%d indexed_files=%d\n", app.entries.len, app.files.len)

    # open through the tree: the 1st entry is the "sub" dir, then the files
    app.open_file("proj/hello.p")
    printf("tabs=%d cur=%d title=%s\n", app.tabs.len, app.cur, app.tabs.data[0].title)
    cv: *CodeView = app.cur_cv()
    printf("lines=%d hl=%d gutter=%d\n", cv->buf.nlines(), cv->hl.enabled, cv->gutter_w())

    # type at the end of line 2 (the CodeView has focus)
    cv->buf.move_to(1, cv->buf.line_cp(1))
    typed(ref app, "0")
    printf("typed=[%s] dirty=%d\n", cv->buf.line_text(1), cv->buf.dirty)

    # ctrl+z undoes, ctrl+y redoes (global shortcut)
    keyp(ref app, i32('z'), PGM_CTRL)
    printf("undo=[%s]\n", cv->buf.line_text(1))
    keyp(ref app, i32('y'), PGM_CTRL)
    printf("redo=[%s]\n", cv->buf.line_text(1))

    # ctrl+d twice: the word, then the next occurrence
    cv->buf.move_to(2, 12)
    keyp(ref app, i32('d'), PGM_CTRL)
    keyp(ref app, i32('d'), PGM_CTRL)
    printf("carets=%d\n", cv->buf.ncarets())
    cv->buf.collapse()

    # file palette: filter by "not" (proj/sub/notas.txt)
    keyp(ref app, i32('p'), PGM_CTRL)
    typed(ref app, "not")
    printf("palette=%d top=%s\n", app.palitems.len,
           app.palitems.data[0].label if app.palitems.len > 0 else "-")
    keyp(ref app, PGK_RETURN, 0)          # open the selected entry
    printf("tabs=%d cur=%s hl_txt=%d\n", app.tabs.len, app.tabs.data[app.cur].title,
           app.cur_cv()->hl.enabled)

    # command palette: ">zoom in"
    keyp(ref app, i32('p'), PGM_CTRL)
    typed(ref app, ">")
    typed(ref app, "zoomin")
    printf("cmds=%d top=%s\n", app.palitems.len,
           app.palitems.data[0].label if app.palitems.len > 0 else "-")
    keyp(ref app, PGK_RETURN, 0)
    printf("zoom=%d cell=%d\n", app.zoom, app.ui.font.char_w())
    app.set_zoom(1)

    # go to line via ":" (palette)
    app.select_tab(0)
    keyp(ref app, i32('g'), PGM_CTRL)
    typed(ref app, "3")
    keyp(ref app, PGK_RETURN, 0)
    printf("goto=%d\n", app.cur_cv()->buf.caret(0)->line + 1)

    # incremental search (ctrl+f) + next occurrence
    keyp(ref app, i32('f'), PGM_CTRL)
    typed(ref app, "i32")
    c0: *Caret = app.cur_cv()->buf.caret(0)
    printf("find1=%d:%d\n", c0->line, c0->acol)
    app.find_step(True)
    c1: *Caret = app.cur_cv()->buf.caret(0)
    printf("find2=%d:%d\n", c1->line, c1->acol)
    app.find_close()

    # tabs: click the second tab on the bar
    tb: PgRect = app.ui.rect_of(app.tabbar)
    click(ref app, tb.x + 5, tb.y + tb.h / 2)
    printf("clicked_tab=%d\n", app.cur)

    # tree: click the directory (expands it) and count the entries
    tr: PgRect = app.ui.rect_of(app.tree)
    click(ref app, tr.x + 20, tr.y + app.ui.font.line_h() / 2)
    printf("tree_expanded=%d\n", app.entries.len)

    # status bar and a screenshot of the frame
    app.update_status()
    printf("status=[%s]\n", app.ui.text_of(app.status))
    app.ui.draw(ref app.win.fb)
    shot(ref app, pg_rect(0, 0, 480, 240))

    # ctrl+s saves; the file on disk must reflect the edit
    app.select_tab(0)
    keyp(ref app, i32('s'), PGM_CTRL)
    v: Vfs = vfs_local()
    n: usize
    data: *char = vfs_read_all(in v, "proj/hello.p", out n)
    printf("saved=%d dirty=%d\n", 1 if strstr(data, "resposta0") != None else 0,
           app.cur_cv()->buf.dirty)
    free(data)

    # close the tabs (none dirty: no dialog)
    while not app.tabs.is_empty():
        app.close_tab(app.tabs.len - 1)
    printf("tabs=%d\n", app.tabs.len)

    app.deinit()
    ps_run("rm -rf proj", out sh)
    free(sh)
    printf("app-ok\n")
    return 0
