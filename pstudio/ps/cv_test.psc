"""O codeview portado, headless: dobra pela sarjeta, âncora da vista, dobra pelo
teclado — e o mesmo que `tests/pstudio/cv_fold_scroll.p` mede no editor em P.

As linhas impressas são as MESMAS, porque a conta é a mesma: 40 blocos de 4
linhas, a vista rolada para longe do cursor, e a regra que dobrar pela SARJETA
não rola (Godot/Sublime) enquanto dobrar pelo TECLADO traz o cursor à vista.

Sem janela: o toolkit recebe a célula da fonte (8 x 17) como parâmetro, e o
codeview não fala com driver nenhum — nem para arquivo (o texto entra por
`load_text`) nem para área de transferência (o app é que fala com o sistema).
"""
import <pui> as pui
import lib_cv as cvm


def make_src() -> str:
    parts: list<str> = []
    for i in range(40):
        parts.append("def f" + str(i) + "():")
        for j in range(3):
            parts.append("    line " + str(j) + " of " + str(i))
    return "\n".join(parts) + "\n"


u = pui.new_ui(8, 17)
root = u.box(-1, True)
cv = cvm.cv_create(u, root)
u.layout(600, 300)
cv.load_text("demo.p", make_src(), 0)

vis = cv.visible_lines()
print("lines=" + str(cv.buf.nlines()) + " visible_rows=" + str(vis))


# o meio da sarjeta de dobra (a segunda: marcas, dobra, números)
def fold_gutter_x() -> int:
    r = u.rect_of(cv.id)
    return r.x + cv.gutters[0].width_cp * u.cell_w + u.cell_w // 2


def click_fold(row: int):
    tr = cv.text_rect()
    y = tr.y + row * u.cell_h + u.cell_h // 2
    u.input_event(pui.Event(pui.EV_MOUSE_DOWN, 0, 0, 0, fold_gutter_x(), y, 1, 1, 0))
    u.input_event(pui.Event(pui.EV_MOUSE_UP, 0, 0, 0, fold_gutter_x(), y, 1, 1, 0))


# o cursor fica no topo do arquivo; a vista é rolada para baixo
cv.set_top(20)
print("top=" + str(cv.top) + " caret=" + str(cv.buf.caret(0).line))

# dobra um cabeçalho que está na tela, longe do cursor
hdr = cv.line_at_row(4)
while hdr % 4 != 0:
    hdr += 1
click_fold(cv.row_of_line(hdr))
print("folded=" + ("1" if cv.buf.is_folded(hdr) else "0") + " top=" + str(cv.top) + " (era 20) caret=" + str(cv.buf.caret(0).line))

# desdobrar pela sarjeta é igualmente quieto
before = cv.top
click_fold(cv.row_of_line(hdr))
print("unfold: top=" + str(cv.top) + " (era " + str(before) + ") folded=" + ("1" if cv.buf.is_folded(hdr) else "0"))

# `fold all` com a vista DENTRO de um bloco: o cabeçalho dele toma a primeira
# fileira — o caso em que a âncora tem de andar para trás de verdade
cv.set_top(cv.buf.to_visible(22))
inner = cv.top
cv.fold_all()
print("fold_all: inner=" + str(inner) + " -> top=" + str(cv.top) + " hidden(inner)=" + ("1" if cv.buf.is_hidden(inner) else "0") + " caret=" + str(cv.buf.caret(0).line))
cv.unfold_all()
print("unfold_all: top=" + str(cv.top))

# o comando de TECLADO é guiado pelo cursor de propósito: ele tem de trazer o
# cursor à vista (o cabeçalho em que ele cai), diferente da sarjeta
cv.buf.move_to(40, 0)
cv.set_top(0)
cv.toggle_fold_at_caret()
print("at_caret: top=" + str(cv.top) + " caret=" + str(cv.buf.caret(0).line) + " folded=" + ("1" if cv.buf.is_folded(40) else "0"))

# ---- o realce e o completamento, pelo adaptador do lexer (113) ----
cv.load_text("demo.p", "def soma(a: i32, b: i32) -> i32:\n    x: i32 = 42 + b   # conta\n    return x\n", 0)
# 1=palavra da linguagem, 0=texto comum, 3=número, 4=comentário (lib_hl)
print("hl: kw=" + str(cv.hl.class_at(0, 0)) + " ident=" + str(cv.hl.class_at(0, 4)) +
      " num=" + str(cv.hl.class_at(1, 13)) + " comment=" + str(cv.hl.class_at(1, 22)) +
      " fora=" + str(cv.hl.class_at(1, 19)))
cv.index.build(cv.buf, [])
hits = cv.index.query("so", "")
print("cmp: " + (cv.index.sym(hits[0]).name if len(hits) > 0 else "<nada>") +
      " detalhe=[" + (cv.index.sym(hits[0]).detail if len(hits) > 0 else "") + "]")
own = cv.index.owner_of("x")
print("owner_of(x)=" + own)
print("fold-scroll-ok")
