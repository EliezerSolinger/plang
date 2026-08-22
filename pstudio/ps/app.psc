"""pstudio, em pscript: o programa.

Isto é o DRIVER, e nada mais: abre a janela, traduz o evento do shim para o
evento do toolkit, lê e escreve arquivo, fala com a área de transferência e
apresenta o quadro. A lógica inteira do editor — buffer, cursores, desfazer,
dobra, realce, completamento, abas, árvore, paleta, busca — mora nos módulos
`lib_*.psc` ao lado, e é por isso que ela roda inteira num teste headless
(`app_test.psc`).

A fronteira: `shim.p` é a mão que toca o SDL (45.5 — ponteiro não atravessa), e
`hl.p` é a que chama o lexer do compilador. Duas páginas de P; o resto é pscript.

Uso:
    pstudio [diretório-ou-arquivo]
    pstudio --selftest arquivo     # exercita o editor sem tela e sai
    pstudio --shot saída.ppm [dir] # um quadro em PPM (servidor sem X)

**Por que `import "shim.ph"` e não `include "shim.h"`:** a porta do `include` lê
o header com o C, e ali um `CStr` é ponteiro — que não atravessa (45.5). A porta
do `import` lê o `.ph` com o front end do P (75.3), e por ela passam as três
coisas de que este arquivo precisa: as funções de `CStr`, as constantes
`SHIM_*` e o `bool` como bool (pelo `include` ele chegaria como `int`, porque é
isso que o header emitido escreve).

**A costura que o async cobrou.** Ler e escrever arquivo no pscript é `await`
(76.2), e o `lib_app` é síncrono de propósito — um índice de completamento que
espera obrigaria todo chamador dele a esperar. Então o app PEDE e o driver
atende: `want_open` é o pedido de leitura (o driver lê e chama `open_file` outra
vez), e a escrita entra numa fila que o laço drena, com a falha indo para a barra
de estado. É o único lugar do editor onde a divisão custa algo, e está aqui — no
driver — em vez de espalhada.
"""
import "shim.ph"

import lib_pui as pui
import lib_app as appm
import sys
import time
import os
import path


cache: dict<str, str> = {}
pending: list<str> = []          # caminhos com escrita pendente (o texto está no cache)


async def read_file(p: str) -> str:
    try:
        with await open(p, "r") as f:
            return await f.text()
    catch e:
        return ""


async def flush_writes(app: appm.App):
    while len(pending) > 0:
        p = pending.pop()
        try:
            f = await open(p, "w")
            await f.write(cache[p])
            await f.close()
        catch e:
            app.want_msg = "could not write " + p


def read_cached(p: str) -> str:
    return cache[p] if p in cache else ""


def queue_write(p: str, text: str) -> bool:
    cache[p] = text
    pending.append(p)
    return True


# ---------- eventos: do shim para o toolkit ----------

def ev_from_shim(kind: int) -> pui.Event:
    k = pui.EV_NONE
    if kind == SHIM_KEY:
        k = pui.EV_KEY
    elif kind == SHIM_TEXT:
        k = pui.EV_TEXT
    elif kind == SHIM_MOUSE_DOWN:
        k = pui.EV_MOUSE_DOWN
    elif kind == SHIM_MOUSE_UP:
        k = pui.EV_MOUSE_UP
    elif kind == SHIM_MOUSE_MOVE:
        k = pui.EV_MOUSE_MOVE
    elif kind == SHIM_WHEEL:
        k = pui.EV_WHEEL
    elif kind == SHIM_RESIZE:
        k = pui.EV_RESIZE
    elif kind == SHIM_QUIT:
        k = pui.EV_QUIT
    return pui.Event(k, shim_ev_key(), shim_ev_mods(), shim_ev_cp(),
                     shim_ev_x(), shim_ev_y(), shim_ev_button(),
                     shim_ev_clicks(), shim_ev_wheel())


def painter() -> pui.Painter:
    """O pintor do editor: cinco chamadas do shim, e nada mais."""
    return pui.Painter(lambda x, y, w, h, c: shim_rect(x, y, w, h, c),
                       lambda x, y, w, h, c: shim_frame(x, y, w, h, c),
                       lambda x, y, w, h: shim_clip(x, y, w, h),
                       lambda: shim_clip_reset(),
                       lambda cp, x, y, c: shim_glyph(cp, x, y, c))


def now_ms() -> int:
    return int(time.monotonic() * 1000.0)


def wire(app: appm.App):
    """Liga o app ao sistema. Todas as funções do driver, num lugar."""
    app.read_file = lambda p: read_cached(p)
    app.write_file = lambda p, t: queue_write(p, t)
    app.mtime_of = lambda p: path.getmtime(p) if path.exists(p) else 0
    app.clip_get = lambda: shim_clip_get()
    app.clip_set = lambda s: shim_clip_set(s)
    app.confirm_close = lambda name: shim_confirm_close(name)
    app.confirm_reload = lambda name: shim_confirm_reload(name)
    app.set_title = lambda t: shim_title(t)
    app.zoom_step = lambda step: zoom(app, step)


def zoom(app: appm.App, step: int):
    """O passo do zoom é uma GRADE de verdade (11..29px rasterizados), não um
    multiplicador — por isso o índice é ABSOLUTO e o shim o prende na faixa. O
    toolkit recebe a célula nova e refaz o layout inteiro.

    `step == 0` volta ao passo PADRÃO — o mesmo que o editor em P usa, e por
    isso o shim o expõe em vez de o app adivinhar."""
    at = shim_zoom_at()
    want = shim_zoom_default() if step == 0 else at + step
    shim_zoom(want)
    app.set_cell(shim_cell_w(), shim_cell_h())
    app.dirty_ui = True


async def serve_requests(app: appm.App):
    """Atende o que o app pediu e não podia fazer: ler arquivo, escrever, e a
    mensagem de falha."""
    if len(app.want_open) > 0:
        p = app.want_open
        app.want_open = ""
        cache[p] = await read_file(p)
        app.open_file(p)
    await flush_writes(app)
    if len(app.want_msg) > 0:
        app.u.set_text(app.status, app.want_msg)
        app.want_msg = ""
        app.dirty_ui = True


async def open_arg(app: appm.App, arg: str):
    if path.isfile(arg):
        cache[arg] = await read_file(arg)
        app.open_file(arg)


# ---------- o laço ----------

async def run(app: appm.App) -> int:
    blink = now_ms()
    while app.running:
        # UM evento bloqueando (o timeout faz o cursor piscar), depois DRENA a
        # fila: o `present` é por QUADRO, não por evento. Com vsync cada present
        # segura ~16ms, e um por evento de movimento deixa o arraste atrás do
        # cursor (medido no editor em P: 200 movimentos = 182ms assim, 1ms
        # drenando).
        kind = shim_wait(appm.BLINK_MS)
        app.now_ms = now_ms()
        if kind == SHIM_TIMEOUT or kind == SHIM_NONE:
            blink = app.tick(app.now_ms, blink)
        elif kind == SHIM_FOCUS:
            app.check_external()
        elif kind == SHIM_QUIT:
            app.try_quit()
        elif kind == SHIM_RESIZE:
            app.u.layout(shim_width(), shim_height())
            app.u.queue_redraw_tree(app.root)
            app.dirty_ui = True
        else:
            app.feed(ev_from_shim(kind))
        while app.running:
            k2 = shim_poll()
            if k2 == SHIM_NONE:
                break
            app.now_ms = now_ms()
            if k2 == SHIM_QUIT:
                app.try_quit()
            elif k2 == SHIM_RESIZE:
                app.u.layout(shim_width(), shim_height())
                app.u.queue_redraw_tree(app.root)
                app.dirty_ui = True
            elif k2 == SHIM_FOCUS:
                app.check_external()
            else:
                app.feed(ev_from_shim(k2))
        await serve_requests(app)
        if app.dirty_ui or app.u.needs_draw:
            shim_clear(app.u.theme.bg)
            app.u.draw(painter(), shim_width(), shim_height())
            shim_present()
            app.dirty_ui = False
    return 0


# ---------- o auto-teste: o editor inteiro, sem tela ----------

async def selftest(arg: str) -> int:
    u = pui.new_ui(8, 17)
    app = appm.new_app(u, path.dirname(arg) if len(path.dirname(arg)) > 0 else ".")
    wire(app)
    app.read_file = lambda p: read_cached(p)
    u.layout(900, 500)
    await open_arg(app, arg)
    print("tabs", len(app.tabs))
    cv = app.cur_cv()
    if cv == None:
        print("no file")
        return 1
    print("lines", cv.buf.nlines())
    app.now_ms = now_ms()
    app.feed(pui.Event(pui.EV_TEXT, 0, 0, ord("X"), 0, 0, 0, 0, 0))
    print("typed", cv.buf.line_text(0))
    cv.buf.undo_step()
    print("undone", cv.buf.line_text(0))
    app.palette_open(appm.PAL_COMMANDS)
    u.set_text(app.palinput, ">fold all")
    app.palette_filter()
    print("palette", len(app.palitems), app.palitems[0].label if len(app.palitems) > 0 else "-")
    app.palette_accept()
    print("folded", cv.buf.visible_count())
    n = app.u.build_all()
    print("drawn", "yes" if n > 20 else "no")
    await serve_requests(app)
    print("selftest ok")
    return 0


# ---------- a entrada ----------

async def main_run() -> int:
    args = sys.argv
    if len(args) > 1 and args[1] == "--selftest":
        return await selftest(args[2] if len(args) > 2 else "")
    # 115: a mesma linha de comando do editor em P — vários arquivos em abas,
    # `--size LxA`, `--shot img.ppm`, e diagnóstico para o que não existe
    shot = ""
    files: list<str> = []
    dir = ""
    win_w = 1100
    win_h = 720
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--shot" and i + 1 < len(args):
            shot = args[i + 1]
            i += 2
            continue
        if a == "--size" and i + 1 < len(args):
            wh = args[i + 1].split("x")
            if len(wh) == 2:
                win_w = int(wh[0])
                win_h = int(wh[1])
            i += 2
            continue
        if a.startswith("--"):
            print("pstudio: unknown option '" + a + "'")
            return 2
        if path.isdir(a):
            if len(dir) == 0:
                dir = path.normpath(a)
        elif path.isfile(a):
            files.append(a)
            if len(dir) == 0:
                dir = path.dirname(a)
        else:
            print("pstudio: '" + a + "' does not exist")
        i += 1
    if len(dir) == 0:
        dir = "."
    if not shim_open(win_w, win_h):
        print("could not open a window (SDL). Is DISPLAY set?")
        return 1
    u = pui.new_ui(shim_cell_w(), shim_cell_h())
    app = appm.new_app(u, dir)
    wire(app)
    u.layout(shim_width(), shim_height())
    for fp in files:
        await open_arg(app, fp)
    app.update_status()
    if len(shot) > 0:
        shim_clear(u.theme.bg)
        u.draw(painter(), shim_width(), shim_height())
        shim_present()
        ok = shim_shot(shot)
        shim_close()
        print("shot", "ok" if ok else "failed")
        return 0 if ok else 1
    rc = await run(app)
    shim_close()
    return rc


sys.exit(await main_run())
