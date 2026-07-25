# app_flow: o EDITOR INTEIRO exercitado sem teclado nem display (SDL dummy).
# Monta um projeto pequeno, abre arquivos, digita, usa palette/busca/abas e
# faz um "screenshot" ASCII do frame — regressão de layout e de desenho.
include <stdio.h>
include <stdlib.h>
include <string.h>
import "../../pstudio/app.ph"
import "../../pstudio/psys.ph"

static def wr(path: const *char, text: const *char):
    v: Vfs = vfs_local()
    vfs_write_all(in v, path, text, strlen(text))

# mapa grosso do framebuffer: 1 caractere por célula de 16x24 px
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
        printf("app-skip (SDL indisponivel)\n")
        return 0
    printf("janela=%dx%d\n", app.win.fb.w, app.win.fb.h)
    printf("arvore=%d arquivos_indexados=%d\n", app.entries.len, app.files.len)

    # abre pela árvore: 1ª entrada é o dir "sub", depois os arquivos
    app.open_file("proj/hello.p")
    printf("abas=%d cur=%d titulo=%s\n", app.tabs.len, app.cur, app.tabs.data[0].title)
    cv: *CodeView = app.cur_cv()
    printf("linhas=%d hl=%d gutter=%d\n", cv->buf.nlines(), cv->hl.enabled, cv->gutter_w())

    # digita no fim da linha 2 (o CodeView tem o foco)
    cv->buf.move_to(1, cv->buf.line_cp(1))
    typed(ref app, "0")
    printf("digitado=[%s] dirty=%d\n", cv->buf.line_text(1), cv->buf.dirty)

    # ctrl+z desfaz, ctrl+y refaz (atalho global)
    keyp(ref app, i32('z'), PGM_CTRL)
    printf("undo=[%s]\n", cv->buf.line_text(1))
    keyp(ref app, i32('y'), PGM_CTRL)
    printf("redo=[%s]\n", cv->buf.line_text(1))

    # ctrl+d duas vezes: palavra + próxima ocorrência
    cv->buf.move_to(2, 12)
    keyp(ref app, i32('d'), PGM_CTRL)
    keyp(ref app, i32('d'), PGM_CTRL)
    printf("carets=%d\n", cv->buf.ncarets())
    cv->buf.collapse()

    # palette de arquivos: filtra por "not" (proj/sub/notas.txt)
    keyp(ref app, i32('p'), PGM_CTRL)
    typed(ref app, "not")
    printf("palette=%d topo=%s\n", app.palitems.len,
           app.palitems.data[0].label if app.palitems.len > 0 else "-")
    keyp(ref app, PGK_RETURN, 0)          # abre o selecionado
    printf("abas=%d cur=%s hl_txt=%d\n", app.tabs.len, app.tabs.data[app.cur].title,
           app.cur_cv()->hl.enabled)

    # palette de comandos: ">zoom in"
    keyp(ref app, i32('p'), PGM_CTRL)
    typed(ref app, ">")
    typed(ref app, "zoomin")
    printf("cmds=%d topo=%s\n", app.palitems.len,
           app.palitems.data[0].label if app.palitems.len > 0 else "-")
    keyp(ref app, PGK_RETURN, 0)
    printf("zoom=%d cell=%d\n", app.zoom, app.ui.font.char_w())
    app.set_zoom(1)

    # ir para linha via ":" (palette)
    app.select_tab(0)
    keyp(ref app, i32('g'), PGM_CTRL)
    typed(ref app, "3")
    keyp(ref app, PGK_RETURN, 0)
    printf("goto=%d\n", app.cur_cv()->buf.caret(0)->line + 1)

    # busca incremental (ctrl+f) + próxima ocorrência
    keyp(ref app, i32('f'), PGM_CTRL)
    typed(ref app, "i32")
    c0: *Caret = app.cur_cv()->buf.caret(0)
    printf("find1=%d:%d\n", c0->line, c0->acol)
    app.find_step(True)
    c1: *Caret = app.cur_cv()->buf.caret(0)
    printf("find2=%d:%d\n", c1->line, c1->acol)
    app.find_close()

    # abas: clique na segunda aba pela barra
    tb: PgRect = app.ui.rect_of(app.tabbar)
    click(ref app, tb.x + 5, tb.y + tb.h / 2)
    printf("aba_clicada=%d\n", app.cur)

    # árvore: clica no diretório (expande) e conta entradas
    tr: PgRect = app.ui.rect_of(app.tree)
    click(ref app, tr.x + 20, tr.y + app.ui.font.line_h() / 2)
    printf("arvore_expandida=%d\n", app.entries.len)

    # status bar e screenshot do frame
    app.update_status()
    printf("status=[%s]\n", app.ui.text_of(app.status))
    app.ui.draw(ref app.win.fb)
    shot(ref app, pg_rect(0, 0, 480, 240))

    # ctrl+s grava; o arquivo no disco tem que refletir a edição
    app.select_tab(0)
    keyp(ref app, i32('s'), PGM_CTRL)
    v: Vfs = vfs_local()
    n: usize
    data: *char = vfs_read_all(in v, "proj/hello.p", out n)
    printf("salvo=%d dirty=%d\n", 1 if strstr(data, "resposta0") != None else 0,
           app.cur_cv()->buf.dirty)
    free(data)

    # fecha as abas (nenhuma suja: sem diálogo)
    while not app.tabs.is_empty():
        app.close_tab(app.tabs.len - 1)
    printf("abas=%d\n", app.tabs.len)

    app.deinit()
    ps_run("rm -rf proj", out sh)
    free(sh)
    printf("app-ok\n")
    return 0
