# pui headless: árvore, duas fases de layout (matemática Godot), hit-test,
# clique sintético em botão (sinal), scrollbar, input de linha e freelist.
include <stdio.h>
include <string.h>
import "../../pstudio/pui.ph"

clicks: i32 = 0
changes: i32 = 0
submits: i32 = 0

static def on_click(ctx: *void, id: i32, arg: i64):
    clicks += 1

static def on_change(ctx: *void, id: i32, arg: i64):
    changes += 1

static def on_submit(ctx: *void, id: i32, arg: i64):
    submits += 1

static def rect_of(ref ui: Ui, id: i32):
    r: PgRect = ui.rect_of(id)
    printf("[%d] %d,%d %dx%d\n", id, r.x, r.y, r.w, r.h)

static def key(ref ui: Ui, k: i32):
    ev: PgEvent = {0}
    ev.kind = PGE_KEY
    ev.key = k
    ui.input_event(&ev)

static def typed(ref ui: Ui, s: const *char):
    ev: PgEvent = {0}
    ev.kind = PGE_TEXT
    strcpy(ev.text, s)
    ui.input_event(&ev)

def main() -> int:
    ui: Ui
    ui.init(pg_font_default(1))

    # raiz: vbox [ label | hbox [ botão A | botão B(expande) ] | split ]
    root: i32 = ui.box(-1, True)
    lbl: i32 = ui.label(root, "titulo")
    row: i32 = ui.box(root, False)
    ba: i32 = ui.button(row, "A")
    bb: i32 = ui.button(row, "B")
    ui.set_expand(bb, True, False)
    sp: i32 = ui.split(root, False)
    ui.set_expand(sp, True, True)
    left: i32 = ui.panel(sp)
    ui.set_min(left, 40, 0)
    right: i32 = ui.panel(sp)
    ui.set_min(right, 40, 0)
    ui.split_set(sp, 80)

    ui.layout(240, 120)
    rect_of(ref ui, root)
    rect_of(ref ui, lbl)
    rect_of(ref ui, row)
    rect_of(ref ui, ba)
    rect_of(ref ui, bb)
    rect_of(ref ui, sp)
    rect_of(ref ui, left)
    rect_of(ref ui, right)

    # clique sintético no botão A: press + release dentro do rect
    ui.on_click(ba, on_click, None)
    r: PgRect = ui.rect_of(ba)
    ev: PgEvent = {0}
    ev.kind = PGE_MOUSE_DOWN
    ev.button = 1
    ev.x = r.x + 2
    ev.y = r.y + 2
    c1: bool = ui.input_event(&ev)
    ev.kind = PGE_MOUSE_UP
    c2: bool = ui.input_event(&ev)
    printf("click: handled=%d%d fired=%d focus_no_botao=%d\n",
           c1, c2, clicks, 1 if ui.focus_get() == ba else 0)
    printf("hit_split_handle=%d\n", 1 if ui.hit(80 + 2, 60) == sp else 0)

    # scrollbar: set/clamp/valor
    sb: i32 = ui.scrollbar(root, True)
    ui.scroll_set(sb, 1000, 100, 5000)   # clampa em 900
    printf("scroll=%lld\n", ui.scroll_value(sb))

    # input de linha: digitar, mover, apagar, submeter
    inp: i32 = ui.line_input(root)
    ui.on_changed(inp, on_change, None)
    ui.on_submit(inp, on_submit, None)
    ui.focus_set(inp)
    typed(ref ui, "olá")
    typed(ref ui, "!")
    key(ref ui, PGK_LEFT)
    key(ref ui, PGK_BACKSPACE)
    printf("input=[%s] changes=%d\n", ui.text_of(inp), changes)
    key(ref ui, PGK_RETURN)
    printf("submits=%d\n", submits)

    # desenha num fb pequeno só pra exercitar builders/replay (sem crash)
    fb: PgFb
    fb.init(240, 120)
    ui.layout(240, 120)
    ui.draw(ref fb)
    lit: i32 = 0
    for i in range(usize(fb.w) * usize(fb.h)):
        if fb.px[i] != ui.theme.bg:
            lit += 1
    printf("draw_lit=%d\n", 1 if lit > 100 else 0)
    fb.deinit()

    # visibilidade tira do layout e do hit-test
    ui.set_visible(row, False)
    printf("hidden_hit=%d\n", 1 if ui.hit(ui.rect_of(ba).x + 1, ui.rect_of(ba).y + 1) != ba else 0)
    ui.set_visible(row, True)

    # freelist: libera a linha e cria outro nó — reusa um id da subárvore
    ui.free_node(row)
    n2: i32 = ui.label(root, "novo")
    printf("reuse=%d\n", 1 if n2 in {row, ba, bb} else 0)

    ui.deinit()
    printf("pui-ok\n")
    return 0
