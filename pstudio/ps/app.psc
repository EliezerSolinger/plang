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
    pstudio --build [alvo]         # constrói o projeto, sem tela (o motor é
                                   #   biblioteca: corre DENTRO do editor)
    pstudio --run <alvo>           # ... e lança o programa (o play, sem tela)
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

import <pui> as pui
import lib_app as appm
# F6: o motor de build é uma BIBLIOTECA, e o editor importa-a. É isto que faz o
# build correr no laço de eventos da UI em vez de num processo à parte.
import <pbuild/lib_build.psc> as B
import <pbuild/lib_graph.psc> as G
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


# ---------- o BUILD, no mesmo laço de eventos (F6) ----------
#
# O motor é uma BIBLIOTECA (`packages/pbuild`), não um processo: o editor
# importa-o e corre o build como uma tarefa no mesmo escalonador que trata o
# teclado. O grafo é um `dict` na memória — não há nada a serializar, nem um
# fluxo de texto a analisar do outro lado (1.8).
#
# O que o editor ganha com isso, e que um `ppack build` num terminal não dá: o
# ESTADO. Ele sabe qual aresta está a correr, quantas faltam, e o que cada uma
# disse — e pode desenhá-lo onde quiser.

private def on_edge_start(app: appm.App, id: int, o_que: str):
    app.build_feitas += 0
    app.build_msg = "[" + str(app.build_feitas) + "/" + str(app.build_total) + "] " + o_que
    app.dirty_ui = True


private def on_edge_end(app: appm.App, id: int, st: int, saida: str, ms: int):
    app.build_feitas += 1
    if st != 0:
        # a PRIMEIRA falha é a que interessa: as seguintes são quase sempre
        # consequência dela, e a barra de estado tem uma linha
        if len(app.build_erro) == 0:
            app.build_erro = saida.strip()
            # ... e a POSIÇÃO dela, que é o que transforma uma mensagem numa
            # navegação: o editor abre o arquivo e põe o cursor no sítio
            app.marcar_erro(saida)
    app.build_msg = "[" + str(app.build_feitas) + "/" + str(app.build_total) + "]"
    app.dirty_ui = True


async def serve_build(app: appm.App):
    """O pedido de build do app, atendido aqui. Ele não constrói: PEDE."""
    if app.want_stop_run:
        app.want_stop_run = False
        if app.run_pid > 0:
            os.kill(app.run_pid)
            app.build_msg = "parei o programa (pid " + str(app.run_pid) + ")"
            app.run_pid = 0
            app.dirty_ui = True
    if app.want_clean:
        app.want_clean = False
        n = 0
        if path.isdir("build"):
            for nome in sorted(os.listdir("build")):
                if nome == "pkg":
                    continue          # o que veio de fora fica (a vassoura do ppack)
                d = path.join("build", nome)
                if path.isdir(d):
                    n += rmtree(d)
        app.build_msg = "limpo: " + str(n) + " arquivo(s)"
        app.dirty_ui = True
        return
    if not app.want_build_on or app.build_busy:
        return
    alvo = app.want_build
    app.want_build_on = False
    app.build_busy = True
    app.build_erro = ""
    app.build_feitas = 0
    app.build_total = 0
    app.build_msg = "a montar o grafo..."
    app.dirty_ui = True
    g = await grafo_do_projeto(app)
    if g == None:
        app.build_busy = False
        app.dirty_ui = True
        return
    # os alvos, para a paleta `!`: o editor não sabe o que um projeto constrói
    alvos_v: list<str> = []
    for nd in g.nodes:
        if nd.gen >= 0:
            alvos_v.append(nd.p)
    app.build_targets = sorted(alvos_v)
    rep = B.Rep(lambda t: set_total(app, t),
                lambda i, w: on_edge_start(app, i, w),
                lambda i, st, o, ms: on_edge_end(app, i, st, o, ms),
                lambda ok, f: set_done(app, ok, f),
                lambda m: set_erro(app, m))
    tl: list<str> = [alvo] if len(alvo) > 0 else []
    ok = await B.build(g, "build/log/build.log", tl, B.Opts(os.nproc(), 1, False, False), rep)
    app.build_busy = False
    # o PLAY: construiu, agora corre. O programa anterior sai primeiro — ele
    # está a usar o binário que a construção acabou de reescrever —, e sai por
    # SIGTERM, que é um pedido: um `SIGKILL` não o deixa fechar o que abriu.
    if app.want_run:
        app.want_run = False
        if app.run_pid > 0:
            os.kill(app.run_pid)
            esperas = 0
            while os.alive(app.run_pid) and esperas < 100:
                await sleep(0.05)
                esperas += 1
            app.run_pid = 0
        if ok:
            prog = alvo if len(alvo) > 0 else primeiro_executavel(app)
            if len(prog) > 0 and path.isfile(prog):
                app.run_pid = os.spawn([prog if prog.startswith("/") else path.join(os.getcwd(), prog)])
                app.build_msg = "a correr " + path.basename(prog) + " (pid " + str(app.run_pid) + ")"
            else:
                app.build_msg = "construiu, mas não sei o que correr — use `Build Target…`"
    app.dirty_ui = True


private def primeiro_executavel(app: appm.App) -> str:
    """O alvo a correr quando ninguém disse qual: o primeiro `build/bin/` do
    grafo. É um palpite, e por isso a mensagem diz como se escolhe outro."""
    for t in app.build_targets:
        if "/bin/" in t:
            return t
    return ""


private def set_total(app: appm.App, t: int):
    app.build_total = t
    app.build_msg = str(t) + " aresta(s) a construir" if t > 0 else "nada a fazer"


private def set_done(app: appm.App, ok: bool, falhas: int):
    if ok:
        app.build_msg = "build ok (" + str(app.build_feitas) + " aresta(s))"
    else:
        app.build_msg = "build FALHOU: " + (app.build_erro if len(app.build_erro) > 0 else str(falhas) + " problema(s)")


private def set_erro(app: appm.App, msg: str):
    if len(app.build_erro) == 0:
        app.build_erro = msg


private async def grafo_do_projeto(app: appm.App) -> G.Graph?:
    """O grafo do projeto que está aberto.

    **O descritor é do PROJETO, e o editor não o conhece** — nem devia: ele abre
    qualquer árvore, e cada uma constrói-se à sua maneira. Quem conhece o
    descritor é o `ppack` desse projeto, então é a ele que se pergunta:
    `ppack graph` devolve o grafo em JSON e o editor corre-o com o MOTOR, que é
    biblioteca (`packages/pbuild`) e está aqui dentro.

    Isto é uma serialização, e a 1.8 preferia não a ter. A troca é deliberada e
    a favor: sem ela, o editor teria de embutir o descritor de cada projeto que
    abre — o que só funciona para UM projeto, que seria este. Com ela, o build
    corre no laço de eventos do editor (que é o que a F6 quer) para qualquer
    árvore que tenha um `ppack`. O custo é um JSON de alguns megabytes, lido uma
    vez por build."""
    pp = ""
    for cand in ["build/bin/ppack", "ppack"]:
        if cand == "ppack" or path.isfile(cand):
            pp = cand
            break
    tmp = path.join("build", "t", "editor-grafo.json")
    d = path.dirname(tmp)
    if len(d) > 0 and not path.isdir(d):
        os.makedirs(d)
    r = await os.run([pp, "graph"], stdout=tmp)
    if r.status() != 0:
        app.build_msg = "não consegui o grafo: " + r.output().strip()
        app.build_erro = app.build_msg
        return None
    f = await open(tmp, "r")
    txt = await f.text()
    await f.close()
    try:
        return G.from_json(txt)
    catch e:
        app.build_msg = "o grafo não se deixou ler: " + e.message
        return None


private def rmtree(d: str) -> int:
    n = 0
    for name in os.listdir(d):
        p = path.join(d, name)
        if path.isdir(p):
            n += rmtree(p)
        else:
            os.remove(p)
            n += 1
    os.rmdir(d)
    return n


async def serve_requests(app: appm.App):
    """Atende o que o app pediu e não podia fazer: ler arquivo, escrever, a
    mensagem de falha — e, desde a F6, o BUILD."""
    if len(app.want_open) > 0:
        p = app.want_open
        app.want_open = ""
        cache[p] = await read_file(p)
        app.open_file(p)
    await flush_writes(app)
    await serve_build(app)
    if len(app.build_msg) > 0:
        app.u.set_text(app.status, app.build_msg)
        app.dirty_ui = True
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
    # F6: o build pela paleta. O que se mede aqui é o PEDIDO — o driver atende
    # em `serve_requests`, e um build inteiro num autoteste levaria minutos.
    app.palette_open(appm.PAL_COMMANDS)
    u.set_text(app.palinput, ">build")
    app.palette_filter()
    print("build cmd", app.palitems[0].label if len(app.palitems) > 0 else "-")
    app.palette_accept()
    print("pediu build", app.want_build_on, "alvo", "(padrão)" if len(app.want_build) == 0 else app.want_build)
    app.want_build_on = False       # não se constrói o repositório num autoteste
    app.build_targets = ["build/bin/plangc_s2", "build/bin/ppack"]
    app.palette_open(appm.PAL_BUILD)
    u.set_text(app.palinput, "!ppack")
    app.palette_filter()
    print("alvos", len(app.palitems), app.palitems[0].label if len(app.palitems) > 0 else "-")
    app.palette_accept()
    print("pediu alvo", app.want_build)
    app.want_build_on = False
    # F6: o erro do build como POSIÇÃO. É o que transforma uma mensagem numa
    # navegação — e o formato é o mesmo que o compilador e o ppack já usam.
    achou = app.marcar_erro(arg + ":2:3: error: inventado para o teste\ncc: aviso qualquer\n")
    print("erro posicionado", achou, app.build_pos_lin, app.build_pos_col)
    print("foi para o erro", app.ir_para_erro())
    cvm2 = app.cur_cv()
    if cvm2 != None:
        print("marca de erro", cvm2.buf.mark_of(app.build_pos_lin - 1))
    cvx = app.cur_cv()
    if cvx != None:
        print("cursor em", cvx.buf.caret(0).line + 1)
    n = app.u.build_all()
    print("drawn", "yes" if n > 20 else "no")
    await serve_requests(app)
    print("selftest ok")
    return 0


async def modo_run(alvo: str) -> int:
    """`pstudio --run <alvo>` — o PLAY, sem tela: constrói e lança o programa,
    depois mata-o. Existe pela mesma razão que o `--build`: sem ele, "o play
    constrói e corre" é uma afirmação que só se confere olhando para a janela."""
    u = pui.new_ui(8, 17)
    app = appm.new_app(u, ".")
    app.want_build = alvo
    app.want_build_on = True
    app.want_run = True
    await serve_build(app)
    print(app.build_msg)
    vivo = app.run_pid > 0 and os.alive(app.run_pid)
    print("lançou", vivo)
    if app.run_pid > 0:
        app.want_stop_run = True
        await serve_build(app)
        n = 0
        while os.alive(app.run_pid) and n < 60:
            await sleep(0.05)
            n += 1
    return 0 if vivo else 1


async def modo_build(alvo: str) -> int:
    """`pstudio --build [alvo]` — o build DENTRO do editor, sem tela.

    Existe para provar (e para medir) o que a F6 promete: o motor é uma
    biblioteca que o editor importa, e o build corre no mesmo escalonador que
    trata o teclado. Sem isto, "o build corre no editor" seria uma afirmação que
    só se pode conferir olhando para uma janela.

    O que ele faz é exatamente o que a paleta faz: põe o pedido, e deixa o
    driver atendê-lo."""
    u = pui.new_ui(8, 17)
    app = appm.new_app(u, ".")
    app.want_build = alvo
    app.want_build_on = True
    await serve_build(app)
    print(app.build_msg)
    for t in app.build_targets[0:0]:
        print(t)
    print("alvos no grafo:", len(app.build_targets))
    # o status de saída é o do BUILD, não o do editor: quem chama isto num
    # script quer saber se construiu
    return 1 if len(app.build_erro) > 0 or app.build_msg.startswith("build FALHOU") else 0


# ---------- a entrada ----------

async def main_run() -> int:
    args = sys.argv
    if len(args) > 1 and args[1] == "--selftest":
        return await selftest(args[2] if len(args) > 2 else "")
    if len(args) > 1 and args[1] == "--build":
        return await modo_build(args[2] if len(args) > 2 else "")
    if len(args) > 1 and args[1] == "--run":
        return await modo_run(args[2] if len(args) > 2 else "")
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
