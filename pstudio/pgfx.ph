# pgfx.ph — plataforma gráfica do pstudio (SDL2 por dentro; ver DESIGN.md).
# Janela + textura streaming: o app desenha no PgFb (pgfx_raster) e chama
# w.present(). Frame dirigido a eventos: w.wait_event bloqueia até o próximo
# evento ou timeout (piscar de cursor) — editor parado = 0% CPU.
include <stddef.h>
import "pgfx_raster.ph"

enum PgEventKind:
    PGE_NONE
    PGE_QUIT
    PGE_KEY            # tecla "de comando" (setas, atalhos com ctrl, enter...)
    PGE_TEXT           # texto digitado (UTF-8, já com layout/IME do SDL)
    PGE_MOUSE_DOWN
    PGE_MOUSE_UP
    PGE_MOUSE_MOVE
    PGE_WHEEL
    PGE_RESIZE
    PGE_FOCUS_GAINED
    PGE_FOCUS_LOST
    PGE_TIMEOUT        # wait_event expirou (usado p/ piscar o caret)

# modificadores (bitmask em PgEvent.mods)
PGM_SHIFT: const i32 = 1
PGM_CTRL: const i32 = 2
PGM_ALT: const i32 = 4

# teclas que o app trata (SDL_Keycode; os printáveis chegam como PGE_TEXT)
PGK_RETURN: const i32 = 13
PGK_ESCAPE: const i32 = 27
PGK_BACKSPACE: const i32 = 8
PGK_TAB: const i32 = 9
PGK_SPACE: const i32 = 32
PGK_DELETE: const i32 = 127
PGK_RIGHT: const i32 = 1073741903
PGK_LEFT: const i32 = 1073741904
PGK_DOWN: const i32 = 1073741905
PGK_UP: const i32 = 1073741906
PGK_PAGEUP: const i32 = 1073741899
PGK_PAGEDOWN: const i32 = 1073741902
PGK_END: const i32 = 1073741901
PGK_HOME: const i32 = 1073741898

struct PgEvent:
    kind: PgEventKind
    key: i32           # PGE_KEY: SDL_Keycode (PGK_*)
    mods: i32          # PGE_KEY/mouse: bitmask PGM_*
    text: char[32]     # PGE_TEXT: UTF-8 NUL-terminado
    x: i32             # mouse: posição; PGE_RESIZE: nova largura
    y: i32             # mouse: posição; PGE_RESIZE: nova altura
    button: i32        # PGE_MOUSE_*: 1=esq 2=meio 3=dir
    clicks: i32        # PGE_MOUSE_DOWN: 1=simples 2=duplo 3=triplo
    wheel_y: i32       # PGE_WHEEL: +cima/-baixo (linhas)

struct PgWindow:
    win: *void         # SDL_Window (opaco fora do pgfx.p)
    ren: *void         # SDL_Renderer
    tex: *void         # SDL_Texture streaming ARGB8888
    fb: PgFb
    is_open: bool

    # cria janela redimensionável + framebuffer; False se o SDL falhar
    def open(out self: PgWindow, title: const *char, width: i32, height: i32) -> bool
    def close(ref self: PgWindow)

    # sobe o framebuffer para a tela (UpdateTexture + RenderCopy + Present)
    def present(ref self: PgWindow)

    # espera o próximo evento até timeout_ms (<=0 = espera para sempre).
    # Trata WINDOW RESIZE internamente (realoca fb + textura) e AINDA devolve
    # PGE_RESIZE para o app relayoutar. False só em erro fatal do SDL.
    def wait_event(ref self: PgWindow, out ev: PgEvent, timeout_ms: i32) -> bool

    # pega o próximo evento SEM bloquear; False = fila vazia. O loop usa isto
    # para drenar tudo o que chegou e desenhar UMA vez por frame — com vsync,
    # um present por evento de movimento deixa o arraste atrás do cursor.
    def poll_event(ref self: PgWindow, out ev: PgEvent) -> bool

    # diálogo nativo (fechar aba suja): 0=salvar 1=descartar 2=cancelar
    def confirm_close(ref self: PgWindow, filename: const *char) -> i32
    # pergunta sim/não (recarregar arquivo mudado por fora): True = sim
    def confirm_reload(ref self: PgWindow, filename: const *char) -> bool
    def set_title(ref self: PgWindow, title: const *char)

# ---- clipboard (estado global do SDL: funções livres) ----
def pgfx_clipboard_set(text: const *char)
def pgfx_clipboard_get() -> *char       # malloc'd (free do chamador); None se vazio
