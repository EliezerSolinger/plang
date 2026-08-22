# pgfx.p — the SDL2 implementation of the graphics platform (see pgfx.ph).
# The ONLY file in pstudio that talks to SDL directly.
include <SDL2/SDL.h>
include <stdlib.h>
include <string.h>
import "pgfx.ph"

# SDL macros vanish on ingest — stable values from the SDL2 ABI:
SDL_INIT_VIDEO_V: const u32 = 0x20                 # SDL_INIT_VIDEO
SDL_WINDOWPOS_CENTERED_V: const i32 = 0x2FFF0000   # SDL_WINDOWPOS_CENTERED

private def sdl_mods() -> i32:
    m: i32 = i32(SDL_GetModState())
    r: i32 = 0
    if (m & i32(KMOD_SHIFT)) != 0:
        r |= PGM_SHIFT
    if (m & i32(KMOD_CTRL)) != 0:
        r |= PGM_CTRL
    if (m & i32(KMOD_ALT)) != 0:
        r |= PGM_ALT
    return r

struct PgWindow:
    private def make_texture(ref self: PgWindow) -> bool
    private def translate(ref self: PgWindow, e: *SDL_Event, out ev: PgEvent) -> bool

    def open(out self: PgWindow, title: const *char, width: i32, height: i32) -> bool:
        self.win = None; self.ren = None; self.tex = None; self.is_open = False
        self.fb.px = None; self.fb.w = 0; self.fb.h = 0
        self.fb.clip = pg_rect(0, 0, 0, 0)
        if SDL_Init(SDL_INIT_VIDEO_V) != 0:
            return False
        self.win = SDL_CreateWindow(title, SDL_WINDOWPOS_CENTERED_V, SDL_WINDOWPOS_CENTERED_V,
                                    width, height, SDL_WINDOW_RESIZABLE)
        if self.win == None:
            SDL_Quit()
            return False
        self.ren = SDL_CreateRenderer(self.win, -1,
                                      SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC)
        if self.ren == None:
            self.ren = SDL_CreateRenderer(self.win, -1, 0)   # fallback: software renderer
        if self.ren == None:
            SDL_DestroyWindow(self.win)
            SDL_Quit()
            return False
        self.fb.init(width, height)
        self.is_open = True
        if not self.make_texture():
            self.close()
            return False
        SDL_StartTextInput()
        return True

    # (re)creates the streaming texture at the framebuffer's size
    private def make_texture(ref self: PgWindow) -> bool:
        if self.tex != None:
            SDL_DestroyTexture(self.tex)
        self.tex = SDL_CreateTexture(self.ren, SDL_PIXELFORMAT_ARGB8888,
                                     SDL_TEXTUREACCESS_STREAMING, self.fb.w, self.fb.h)
        return self.tex != None

    def close(ref self: PgWindow):
        if self.fb.px != None:
            self.fb.deinit()
        if self.tex != None:
            SDL_DestroyTexture(self.tex)
            self.tex = None
        if self.ren != None:
            SDL_DestroyRenderer(self.ren)
            self.ren = None
        if self.win != None:
            SDL_DestroyWindow(self.win)
            self.win = None
        if self.is_open:
            SDL_Quit()
        self.is_open = False

    def present(ref self: PgWindow):
        SDL_UpdateTexture(self.tex, None, self.fb.px, self.fb.w * i32(sizeof(u32)))
        SDL_RenderCopy(self.ren, self.tex, None, None)
        SDL_RenderPresent(self.ren)

    def set_title(ref self: PgWindow, title: const *char):
        SDL_SetWindowTitle(self.win, title)

    # translates one SDL_Event; PGE_NONE = uninteresting (keep waiting)
    private def translate(ref self: PgWindow, e: *SDL_Event, out ev: PgEvent) -> bool:
        ev.kind = PGE_NONE
        ev.key = 0; ev.mods = 0; ev.x = 0; ev.y = 0
        ev.button = 0; ev.clicks = 0; ev.wheel_y = 0
        ev.text[0] = '\0'
        t: u32 = e->type
        if t == u32(SDL_QUIT):
            ev.kind = PGE_QUIT
        elif t == u32(SDL_KEYDOWN):
            ev.kind = PGE_KEY
            ev.key = i32(e->key.keysym.sym)
            ev.mods = sdl_mods()
        elif t == u32(SDL_TEXTINPUT):
            ev.kind = PGE_TEXT
            strncpy(ev.text, e->text.text, sizeof(ev.text) - 1)
            ev.text[sizeof(ev.text) - 1] = '\0'
        elif t == u32(SDL_MOUSEBUTTONDOWN) or t == u32(SDL_MOUSEBUTTONUP):
            ev.kind = PGE_MOUSE_DOWN if t == u32(SDL_MOUSEBUTTONDOWN) else PGE_MOUSE_UP
            ev.x = e->button.x
            ev.y = e->button.y
            ev.button = i32(e->button.button)
            ev.clicks = i32(e->button.clicks)
            ev.mods = sdl_mods()
        elif t == u32(SDL_MOUSEMOTION):
            ev.kind = PGE_MOUSE_MOVE
            ev.x = e->motion.x
            ev.y = e->motion.y
            ev.mods = sdl_mods()
        elif t == u32(SDL_MOUSEWHEEL):
            ev.kind = PGE_WHEEL
            ev.wheel_y = e->wheel.y
            SDL_GetMouseState(&ev.x, &ev.y)
            ev.mods = sdl_mods()
        elif t == u32(SDL_WINDOWEVENT):
            we: u8 = e->window.event
            if we == u8(SDL_WINDOWEVENT_SIZE_CHANGED):
                nw: i32 = e->window.data1
                nh: i32 = e->window.data2
                self.fb.resize(nw, nh)
                self.make_texture()
                ev.kind = PGE_RESIZE
                ev.x = nw
                ev.y = nh
            elif we == u8(SDL_WINDOWEVENT_FOCUS_GAINED):
                ev.kind = PGE_FOCUS_GAINED
            elif we == u8(SDL_WINDOWEVENT_FOCUS_LOST):
                ev.kind = PGE_FOCUS_LOST
            elif we == u8(SDL_WINDOWEVENT_EXPOSED):
                # the window needs a repaint: a present handles it without waking the app
                self.present()
        return ev.kind != PGE_NONE

    def wait_event(ref self: PgWindow, out ev: PgEvent, timeout_ms: i32) -> bool:
        ev.kind = PGE_TIMEOUT
        ev.text[0] = '\0'
        deadline: u32 = SDL_GetTicks() + u32(timeout_ms if timeout_ms > 0 else 0)
        while True:
            e: SDL_Event
            got: i32 = 0
            if timeout_ms <= 0:
                got = SDL_WaitEvent(&e)
                if got == 0:
                    return False   # fatal SDL error (without a timeout it cannot expire)
            else:
                now: u32 = SDL_GetTicks()
                if now >= deadline:
                    ev.kind = PGE_TIMEOUT
                    return True
                got = SDL_WaitEventTimeout(&e, i32(deadline - now))
                if got == 0:
                    ev.kind = PGE_TIMEOUT
                    return True
            if self.translate(&e, out ev):
                return True
            # irrelevant event: keep waiting within the same deadline

    def poll_event(ref self: PgWindow, out ev: PgEvent) -> bool:
        ev.kind = PGE_NONE
        ev.text[0] = '\0'
        while True:
            e: SDL_Event
            if SDL_PollEvent(&e) == 0:
                return False
            if self.translate(&e, out ev):
                return True

    def confirm_close(ref self: PgWindow, filename: const *char) -> i32:
        btns: SDL_MessageBoxButtonData[3]
        memset(btns, 0, sizeof(btns))
        btns[0].flags = u32(SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT)
        btns[0].buttonid = 0
        btns[0].text = "Save"
        btns[1].buttonid = 1
        btns[1].text = "Discard"
        btns[2].flags = u32(SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT)
        btns[2].buttonid = 2
        btns[2].text = "Cancel"
        msg: char[512]
        snprintf(msg, sizeof(msg), "%s has unsaved changes.", filename)
        data: SDL_MessageBoxData = {0}
        data.flags = u32(SDL_MESSAGEBOX_WARNING)
        data.window = self.win
        data.title = "Plang Studio"
        data.message = msg
        data.numbuttons = 3
        data.buttons = btns
        hit: i32 = 2
        if SDL_ShowMessageBox(&data, &hit) != 0:
            return 2   # on error, act as cancel (never lose data)
        return hit

    def confirm_reload(ref self: PgWindow, filename: const *char) -> bool:
        btns: SDL_MessageBoxButtonData[2]
        memset(btns, 0, sizeof(btns))
        btns[0].flags = u32(SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT)
        btns[0].buttonid = 1
        btns[0].text = "Reload"
        btns[1].flags = u32(SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT)
        btns[1].buttonid = 0
        btns[1].text = "Keep my edits"
        msg: char[512]
        snprintf(msg, sizeof(msg), "%s changed on disk and has local edits.", filename)
        data: SDL_MessageBoxData = {0}
        data.flags = u32(SDL_MESSAGEBOX_INFORMATION)
        data.window = self.win
        data.title = "Plang Studio"
        data.message = msg
        data.numbuttons = 2
        data.buttons = btns
        hit: i32 = 0
        if SDL_ShowMessageBox(&data, &hit) != 0:
            return False
        return hit == 1

def pgfx_clipboard_set(text: const *char):
    SDL_SetClipboardText(text)

def pgfx_clipboard_get() -> *char:
    if SDL_HasClipboardText() == SDL_FALSE:
        return None
    s: *char = SDL_GetClipboardText()
    if s == None:
        return None
    r: *char = None
    if s[0] != '\0':
        r = malloc(strlen(s) + 1)
        strcpy(r, s)
    SDL_free(s)
    return r
