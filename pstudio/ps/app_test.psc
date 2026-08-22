"""O EDITOR INTEIRO em pscript, sem teclado e sem tela (o gêmeo de
`tests/pstudio/app_flow.p`).

Ele monta um projeto pequeno em disco — com `os`/`path`, a camada de sistema da
111 — abre arquivos, digita, usa a paleta, a busca, as abas, a árvore, a dobra, o
comentário, os pares automáticos e o popup de completamento, e confere o estado a
cada passo. O desenho é exercido por um `Painter` que CONTA comandos em vez de
pintar pixel: sem driver, o caminho de código é o mesmo e o que se mede é que ele
roda inteiro.

O que difere do teste em P, e por quê: lá o "screenshot" é um mapa do
framebuffer, que precisa do rasterizador; aqui é a contagem dos comandos
retidos, que é o que existe deste lado da fronteira.
"""
import lib_pui as pui
import lib_app as appm
import lib_cv as cvm
import os
import path


D: str = "projps"

rects = 0
texts = 0
glyphs = 0


def count_rect(x: int, y: int, w: int, h: int, c: int):
    global rects
    rects += 1


def count_frame(x: int, y: int, w: int, h: int, c: int):
    global rects
    rects += 1


def count_glyph(cp: int, x: int, y: int, c: int):
    global glyphs
    glyphs += 1


def nothing4(x: int, y: int, w: int, h: int):
    pass


def nothing0():
    pass


async def wr(p: str, text: str):
    f = await open(p, "w")
    await f.write(text)
    await f.close()


async def build_project():
    if path.isdir(D):
        for nm in os.listdir(D):
            full = path.join(D, nm)
            if path.isdir(full):
                for nm2 in os.listdir(full):
                    os.remove(path.join(full, nm2))
                os.rmdir(full)
            else:
                os.remove(full)
        os.rmdir(D)
    os.makedirs(D + "/sub")
    await wr(D + "/hello.p", "def main() -> i32:\n    x: i32 = 42  # resposta\n    return x\n")
    await wr(D + "/util.ph", "def helper(a: i32) -> i32\n")
    await wr(D + "/sub/notas.txt", "uma nota\noutra nota\n")


await build_project()

u = pui.new_ui(8, 17)
app = appm.new_app(u, D)
# o "driver": aqui é síncrono e de mentira, o que é exatamente o ponto de ele
# ser injetado (no editor de verdade quem preenche isto é o `app.psc`)
saved: dict<str, str> = {}
app.read_file = lambda p: read_now(p)
app.write_file = lambda p, t: write_now(p, t)
app.mtime_of = lambda p: path.getmtime(p) if path.exists(p) else 0
app.clip_get = lambda: clip
app.clip_set = lambda s: set_clip(s)
app.confirm_close = lambda name: 1        # descartar, sem perguntar
app.confirm_reload = lambda name: True

clip = ""


def set_clip(s: str):
    global clip
    clip = s


def read_now(p: str) -> str:
    if p in saved:
        return saved[p]
    return ""


def write_now(p: str, t: str) -> bool:
    saved[p] = t
    return True


# o `read_file` do teste lê da tabela; os arquivos do projeto entram nela
saved[D + "/hello.p"] = "def main() -> i32:\n    x: i32 = 42  # resposta\n    return x\n"
saved[D + "/util.ph"] = "def helper(a: i32) -> i32\n"
saved[D + "/sub/notas.txt"] = "uma nota\noutra nota\n"

u.layout(1100, 720)
print("tree=" + str(len(app.entries)) + " indexed_files=" + str(len(app.files)))

app.open_file(D + "/hello.p")
print("tabs=" + str(len(app.tabs)) + " cur=" + str(app.cur) + " title=" + app.tabs[0].title)
cv = app.tabs[0].cv
print("lines=" + str(cv.buf.nlines()) + " hl=" + ("1" if cv.hl.enabled else "0") +
      " gutter=" + str(cv.gutter_w()))

# digitar no fim da linha 2
cv.buf.move_to(1, cv.buf.line_cp(1))
u.focus_set(cv.id)
app.feed(pui.Event(pui.EV_TEXT, 0, 0, ord("0"), 0, 0, 0, 0, 0))
print("typed=[" + cv.buf.line_text(1) + "] dirty=" + ("1" if cv.buf.dirty else "0"))
cv.buf.undo_step()
print("undo=[" + cv.buf.line_text(1) + "]")
cv.buf.redo_step()
print("redo=[" + cv.buf.line_text(1) + "]")

# um segundo cursor
cv.buf.add_caret(2, 0)
print("carets=" + str(cv.buf.ncarets()))

# a paleta de arquivos
app.palette_open(appm.PAL_FILES)
u.set_text(app.palinput, "notas")
app.palette_filter()
print("palette=" + ("1" if u.is_visible(app.palette) else "0") +
      " top=" + (app.palitems[0].label if len(app.palitems) > 0 else "<vazio>"))
app.palette_accept()
print("tabs=" + str(len(app.tabs)) + " cur=" + app.tabs[app.cur].title +
      " hl_txt=" + ("1" if app.tabs[app.cur].cv.hl.enabled else "0"))

# a paleta de comandos
app.palette_open(appm.PAL_COMMANDS)
u.set_text(app.palinput, ">zoom in")
app.palette_filter()
print("cmds=" + str(len(app.palitems)) + " top=" + app.palitems[0].label)
app.palette_close()

# ir para a linha
app.select_tab(0)
app.palette_open(appm.PAL_GOTO)
u.set_text(app.palinput, ":3")
app.palette_filter()
app.palette_accept()
print("goto=" + str(cv.buf.caret(0).line + 1))

# a busca
app.find_open()
u.set_text(app.findinput, "42")
app.find_changed()
print("find1=" + str(cv.buf.caret(0).line) + ":" + str(cv.buf.caret(0).col))
u.set_text(app.findinput, "return")
app.find_changed()
print("find2=" + str(cv.buf.caret(0).line) + ":" + str(cv.buf.caret(0).col))
app.find_close()

# clicar numa aba
tb = u.rect_of(app.tabbar)
u.input_event(pui.Event(pui.EV_MOUSE_DOWN, 0, 0, 0, tb.x + 4, tb.y + 4, 1, 1, 0))
u.input_event(pui.Event(pui.EV_MOUSE_UP, 0, 0, 0, tb.x + 4, tb.y + 4, 1, 1, 0))
print("clicked_tab=" + str(app.cur))

# a árvore: expandir o diretório
for i in range(len(app.entries)):
    if app.entries[i].is_dir:
        app.tree_toggle(i)
        break
print("tree_expanded=" + str(len(app.entries)))

# dobra, marca e comentário, pelos comandos
app.select_tab(0)
cv = app.tabs[0].cv
cv.buf.move_to(0, 0)
print("can_fold0=" + ("1" if cv.buf.can_fold(0) else "0"))
app.run_command(11)
print("fold: folded0=" + ("1" if cv.buf.is_folded(0) else "0") +
      " visible=" + str(cv.buf.visible_count()))
app.run_command(11)
print("unfold: folded0=" + ("1" if cv.buf.is_folded(0) else "0") +
      " visible=" + str(cv.buf.visible_count()))
cv.buf.move_to(1, 0)
app.run_command(20)
print("bookmark: mark=" + str(cv.buf.mark_of(1)))
app.run_command(14)
print("comment: 1=[" + cv.buf.line_text(1) + "]")
app.run_command(14)
print("uncomment: 1=[" + cv.buf.line_text(1) + "]")
app.run_command(17)
print("dup: lines=" + str(cv.buf.nlines()))

# pares automáticos
cv.buf.move_to(1, cv.buf.line_cp(1))
app.feed(pui.Event(pui.EV_TEXT, 0, 0, ord("("), 0, 0, 0, 0, 0))
print("pair: 1=[" + cv.buf.line_text(1) + "] col=" + str(cv.buf.caret(0).col))
app.feed(pui.Event(pui.EV_TEXT, 0, 0, ord(")"), 0, 0, 0, 0, 0))
print("skip: 1=[" + cv.buf.line_text(1) + "] col=" + str(cv.buf.caret(0).col))

# o popup de completamento
cv.buf.move_to(0, 7)
cv.complete_open()
print("popup: open=" + ("1" if cv.cmp_open else "0") + " hits=" + str(len(cv.cmp_hits)))
if cv.cmp_open and len(cv.cmp_hits) > 0:
    print("first=" + cv.index.sym(cv.cmp_hits[0]).name)
cv.complete_close()

# a área de transferência, pelo atalho (ctrl+c e ctrl+v)
cv.buf.select_range(cvm.core.Span(2, 0, 2, cv.buf.line_cp(2)))
app.feed(pui.Event(pui.EV_KEY, ord("c"), 2, 0, 0, 0, 0, 0, 0))
print("clip=[" + clip + "]")

# a barra de estado
app.update_status()
print("status=[" + u.text_of(app.status) + "]")

# UM QUADRO: o desenho retido inteiro, com um pintor que conta
p = pui.Painter(count_rect, count_frame, nothing4, nothing0, count_glyph)
u.draw(p, 1100, 720)
print("draw: rects>200=" + ("1" if rects > 200 else "0") + " glyphs>300=" + ("1" if glyphs > 300 else "0"))

# salvar e fechar
app.save_cur()
print("saved=" + ("1" if len(saved[D + "/hello.p"]) > 0 else "0") +
      " dirty=" + ("1" if cv.buf.dirty else "0"))
while len(app.tabs) > 0:
    app.close_tab(0)
print("tabs=" + str(len(app.tabs)))
print("app-ok")
