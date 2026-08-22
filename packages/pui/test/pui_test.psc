"""pui em pscript, headless: a árvore, as duas fases do layout, o hit-test, o
sinal do botão, a barra, a entrada de uma linha e o freelist.

É o gêmeo de `tests/pstudio/pui_layout.p`, que faz o mesmo com o pui em P — e o
ponto do teste é que **as oito linhas de retângulo são idênticas**: a matemática
do Godot portada não pode ter escorregado num arredondamento. A célula da fonte
(8 x 17) é passada de fora, que é como o toolkit em pscript não precisa de
janela para ser medido.

Duas linhas DIFEREM de propósito, e por que:
  * `changes=5` (em P, 3): o evento de texto do shim carrega UM codepoint, não
    uma cadeia, então `olá` são três eventos. É a fronteira de escalares (45.5),
    não uma diferença de comportamento.
  * `draw_cmds` em vez de `draw_lit`: sem framebuffer não há pixel para contar,
    e o que se conta é o que o desenho retido produziu — que é a medida mais
    direta do mesmo caminho de código.
"""
import <pui> as ui


clicks = 0
changes = 0
submits = 0

u = ui.new_ui(8, 17)


def bump_click():
    global clicks
    clicks += 1


def bump_change():
    global changes
    changes += 1


def bump_submit():
    global submits
    submits += 1


def show(id: int):
    r = u.rect_of(id)
    print("[" + str(id) + "] " + str(r.x) + "," + str(r.y) + " " + str(r.w) + "x" + str(r.h))


def key(k: int):
    u.input_event(ui.Event(ui.EV_KEY, k, 0, 0, 0, 0, 0, 0, 0))


def typed(s: str):
    for ch in s:
        u.input_event(ui.Event(ui.EV_TEXT, 0, 0, ord(ch), 0, 0, 0, 0, 0))


def mouse(kind: ui.EvKind, x: int, y: int, button: int) -> bool:
    return u.input_event(ui.Event(kind, 0, 0, 0, x, y, button, 1, 0))


# raiz: vbox [ label | hbox [ botão A | botão B(expande) ] | split ]
root = u.box(-1, True)
lbl = u.label(root, "titulo")
row = u.box(root, False)
ba = u.button(row, "A")
bb = u.button(row, "B")
u.set_expand(bb, True, False)
sp = u.split(root, False)
u.set_expand(sp, True, True)
left = u.panel(sp)
u.set_min(left, 40, 0)
right = u.panel(sp)
u.set_min(right, 40, 0)
u.split_set(sp, 80)

u.layout(240, 120)
show(root)
show(lbl)
show(row)
show(ba)
show(bb)
show(sp)
show(left)
show(right)

# clique sintético no botão A: aperta e solta dentro do retângulo dele
u.on_click(ba, lambda id, arg: bump_click())
r = u.rect_of(ba)
c1 = mouse(ui.EV_MOUSE_DOWN, r.x + 2, r.y + 2, 1)
c2 = mouse(ui.EV_MOUSE_UP, r.x + 2, r.y + 2, 1)
print("click: handled=" + ("1" if c1 else "0") + ("1" if c2 else "0") + " fired=" + str(clicks) + " focus_on_button=" + ("1" if u.focus_get() == ba else "0"))
print("hit_split_handle=" + ("1" if u.hit(80 + 2, 60) == sp else "0"))

# a barra: define, prende, lê
sb = u.scrollbar(root, True)
u.scroll_set(sb, 1000, 100, 5000)      # prende em 900
print("scroll=" + str(u.scroll_value(sb)))

# a entrada de uma linha: digita, move, apaga, envia
inp = u.line_input(root)
u.on_changed(inp, lambda id, arg: bump_change())
u.on_submit(inp, lambda id, arg: bump_submit())
u.focus_set(inp)
typed("olá")
typed("!")
key(ui.K_LEFT)
key(ui.K_BACKSPACE)
print("input=[" + u.text_of(inp) + "] changes=" + str(changes))
key(ui.K_RETURN)
print("submits=" + str(submits))

# o desenho retido: relayout e constrói tudo, contando os comandos
u.layout(240, 120)
print("draw_cmds=" + ("1" if u.build_all() > 10 else "0"))

# esconder um widget o tira do layout e do hit-test
u.set_visible(row, False)
print("hidden_hit=" + ("1" if u.hit(u.rect_of(ba).x + 1, u.rect_of(ba).y + 1) != ba else "0"))
u.set_visible(row, True)

# freelist: libera a linha e cria outro nó — ele reusa um id da subárvore
u.free_node(row)
n2 = u.label(root, "novo")
print("reuse=" + ("1" if n2 == row or n2 == ba or n2 == bb else "0"))
print("pui-ok")
