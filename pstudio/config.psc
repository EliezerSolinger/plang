"""`.pstudio.json` — the one file the IDE remembers between runs.

The rule that shaped this file, in the words that decided it: *"fica no arquivo
de config que o usuário já tem por projeto"*. So it is **one** file, at the root
of the project, next to `pack.json`, and it is meant to be COMMITTED: the panes
a team works with, the target they build, and the keys they bound are project
decisions, not machine ones.

**`pcode` does not read it.** If it is sitting there, `pcode` walks past it —
zero I/O at startup is half of what makes it fast, and an editor that opens any
folder has no project to read a project file from.

---

**Nothing here fails.** A configuration file that refuses to load is a
configuration file that locks somebody out of their own editor at the worst
moment. So every problem takes the default *and says so*:

    .pstudio.json:  keys.ctrl+q is not a command, ignored

The notes go to the status bar. Silence would be worse than the error — a key
that quietly does nothing is a bug somebody spends an afternoon on.

**And nothing here touches the disk.** `parse` takes the TEXT, so the whole file
is testable without a filesystem, and the reading stays with the driver, which
is the only thing allowed to await.
"""
import json


# ---------- what is remembered ----------

struct Config:
    """The IDE's half of the layout, plus the two things that are decisions
    rather than measurements: the target, and the keys."""
    # the panes, in pixels — what a split's divider was left at
    tree_w: int
    outline_w: int
    dock_h: int
    # ... and whether they are there at all
    tree_open: bool
    outline_open: bool
    dock_open: bool
    # the target `Build` builds with no argument. "" = ask the graph.
    target: str
    # ... and the one `Run Tests` builds. "" = look for the convention, which is
    # a node of the graph whose path ends in `/stamp/test`. A project that names
    # its suite something else says so here, once.
    test: str
    # "ctrl+s" -> "Save". The command table made shortcuts data (F2); this is
    # what makes them EDITABLE data.
    keys: Dict<str, str>
    # what was wrong with the file, in the order it was found. Empty = clean.
    notes: List<str>


def default_config() -> Config:
    """The layout the editor opens with when there is no file, and the keys it
    has always had. Every one of these is also what a bad value falls back to,
    which is why they are in one function and not spread through the parser.

    All four zones are OPEN by default. An IDE that started with three of them
    collapsed would look like an editor, and somebody would have to find the
    command that turns each one on before knowing it existed."""
    return Config(220, 240, 200, True, True, True, "", "", default_keys(), [])


def default_keys() -> Dict<str, str>:
    """Every shortcut the editor has, as data.

    This is the table `key_shortcut` reads, and it is the whole reason the F2
    command table exists: a shortcut is a NAME of a command, so rebinding one is
    editing a string and binding a new one costs nothing.

    The names are normalised the way `key_name` writes them: lower case,
    modifiers in the order ctrl, shift, alt, gui, and the key last."""
    return {
        "ctrl+s": "Save",
        "ctrl+shift+s": "Save All",
        "ctrl+w": "Close Tab",
        "ctrl+q": "Quit",
        "ctrl+p": "Open File...",
        "ctrl+shift+p": "Command Palette",
        "ctrl+g": "Go To Line",
        "ctrl+shift+f": "Find in Project",
        "ctrl+shift+t": "Run Tests",
        "ctrl+f": "Find",
        "ctrl+b": "Toggle File Tree",
        "ctrl+z": "Undo",
        "ctrl+shift+z": "Redo",
        "ctrl+y": "Redo",
        "ctrl+a": "Select All",
        "ctrl+c": "Copy",
        "ctrl+x": "Cut",
        "ctrl+v": "Paste",
        "ctrl+d": "Add Caret Below",
        "ctrl+shift+d": "Duplicate Line",
        "ctrl+k": "Delete Line",
        "ctrl+j": "Join Lines",
        "ctrl+/": "Toggle Comment",
        "ctrl+[": "Fold",
        "ctrl+]": "Unfold",
        "ctrl+shift+[": "Fold All",
        "ctrl+shift+]": "Unfold All",
        "ctrl+=": "Zoom In",
        "ctrl+-": "Zoom Out",
        "ctrl+0": "Zoom Reset",
        "ctrl+tab": "Next Tab",
        "ctrl+shift+tab": "Previous Tab",
        "ctrl+shift+up": "Move Line Up",
        "ctrl+shift+down": "Move Line Down",
        "f2": "Next Bookmark",
        "shift+f2": "Previous Bookmark",
        "ctrl+f2": "Toggle Bookmark",
        "f12": "Go To Definition",
    }


# ---------- naming a key ----------
#
# One function writes the name and the parser reads it, so a name that round
# trips is the only kind that exists. Anything a person can type into the JSON
# that this cannot produce is a note in the status bar rather than a binding.

const K_RETURN: int = 13
const K_ESCAPE: int = 27
const K_BACKSPACE: int = 8
const K_TAB: int = 9
const K_SPACE: int = 32
const K_DELETE: int = 127
const K_RIGHT: int = 1073741903
const K_LEFT: int = 1073741904
const K_HOME: int = 1073741898
const K_END: int = 1073741901
const K_UP: int = 1073741906
const K_DOWN: int = 1073741905
const K_PAGEUP: int = 1073741899
const K_PAGEDOWN: int = 1073741902
const K_F1: int = 1073741882      # F1..F12 are contiguous in SDL


def named_keys() -> Dict<str, int>:
    """The keys that are not a character. A dict and not a chain, because it is
    read in both directions — the writer needs the name and the parser the
    number."""
    return {
        "enter": K_RETURN, "escape": K_ESCAPE, "backspace": K_BACKSPACE,
        "tab": K_TAB, "space": K_SPACE, "delete": K_DELETE,
        "right": K_RIGHT, "left": K_LEFT, "home": K_HOME, "end": K_END,
        "up": K_UP, "down": K_DOWN, "pageup": K_PAGEUP, "pagedown": K_PAGEDOWN,
    }


def key_name(key: int, mods: int) -> str:
    """An event as the string the table is keyed by. `mods` is the toolkit's:
    1=shift 2=ctrl 4=alt 8=gui.

    Returns "" for a key that has no name — which the caller reads as "this is
    not a shortcut", and is what makes an unbound function key harmless."""
    base = ""
    if key >= K_F1 and key <= K_F1 + 11:
        base = "f" + str(key - K_F1 + 1)
    elif key >= 33 and key < 127:
        base = chr(key).lower()
    else:
        for nm, k in named_keys().items():
            if k == key:
                base = nm
                break
    if len(base) == 0:
        return ""
    out = ""
    if (mods & 2) != 0:
        out += "ctrl+"
    if (mods & 1) != 0:
        out += "shift+"
    if (mods & 4) != 0:
        out += "alt+"
    if (mods & 8) != 0:
        out += "gui+"
    return out + base


def key_valid(name: str) -> bool:
    """Whether a string from the JSON is a name `key_name` could have written.

    It is deliberately the same question and not a second grammar: a binding
    that cannot be produced by a keypress is a binding that would never fire, and
    telling somebody so at load time beats letting them wonder."""
    seen_ctrl = False
    seen_shift = False
    seen_alt = False
    seen_gui = False
    rest = name
    while True:
        cut = rest.find("+")
        # "ctrl++" is ctrl and the plus key: a "+" at the very end of the part
        # is the KEY, not a separator
        if cut < 0 or cut == len(rest) - 1:
            break
        part = rest[:cut]
        if part == "ctrl":
            if seen_ctrl or seen_shift or seen_alt or seen_gui:
                return False        # out of order, or twice
            seen_ctrl = True
        elif part == "shift":
            if seen_shift or seen_alt or seen_gui:
                return False
            seen_shift = True
        elif part == "alt":
            if seen_alt or seen_gui:
                return False
            seen_alt = True
        elif part == "gui":
            if seen_gui:
                return False
            seen_gui = True
        else:
            return False
        rest = rest[cut + 1:]
    if len(rest) == 0:
        return False
    if len(rest) == 1:
        c = ord(rest)
        return c >= 33 and c < 127 and (chr(c).lower() == rest)
    if rest[0] == "f" and len(rest) <= 3:
        n = 0
        for ch in rest[1:]:
            if ch < "0" or ch > "9":
                return False
            n = n * 10 + (ord(ch) - 48)
        return n >= 1 and n <= 12
    return rest in named_keys()


# ---------- reading it ----------

private def note(c: Config, what: str):
    c.notes.append(".pstudio.json: " + what)


# Every reader has the same shape, and it is the shape of the rule: `as` RAISES
# when the type is not the one asked for, so the catch is where "wrong type"
# turns into a note and the default. There is no `isinstance` in this language
# and there does not need to be — the cast IS the question.

private def want_int(c: Config, o: Dict<str, any>, key: str, dflt: int, lo: int, hi: int) -> int:
    if key not in o:
        return dflt
    nonlocal n
    try:
        n = o[key] as int
    catch e:
        note(c, key + " should be a number, using " + str(dflt))
        return dflt
    if n < lo or n > hi:
        note(c, key + "=" + str(n) + " is outside " + str(lo) + ".." + str(hi) +
                ", using " + str(dflt))
        return dflt
    return n


private def want_bool(c: Config, o: Dict<str, any>, key: str, dflt: bool) -> bool:
    if key not in o:
        return dflt
    try:
        return o[key] as bool
    catch e:
        note(c, key + " should be true or false, using " + ("true" if dflt else "false"))
        return dflt


private def want_str(c: Config, o: Dict<str, any>, key: str, dflt: str) -> str:
    if key not in o:
        return dflt
    try:
        return o[key] as str
    catch e:
        note(c, key + " should be text, ignored")
        return dflt


private def is_layout_key(k: str) -> bool:
    # a list at module level would be STATE, and a module holds none: an
    # imported module is a set of definitions, not a program to run
    if k == "tree_w" or k == "outline_w" or k == "dock_h":
        return True
    return k == "tree_open" or k == "outline_open" or k == "dock_open"


private def read_layout(c: Config, o: Dict<str, any>):
    if "layout" not in o:
        return
    nonlocal L
    try:
        L = o["layout"] as Dict<str, any>
    catch e:
        note(c, "layout should be an object, ignored")
        return
    c.tree_w = want_int(c, L, "tree_w", c.tree_w, 0, 4000)
    c.outline_w = want_int(c, L, "outline_w", c.outline_w, 0, 4000)
    c.dock_h = want_int(c, L, "dock_h", c.dock_h, 0, 4000)
    c.tree_open = want_bool(c, L, "tree_open", c.tree_open)
    c.outline_open = want_bool(c, L, "outline_open", c.outline_open)
    c.dock_open = want_bool(c, L, "dock_open", c.dock_open)
    for k in L:
        if not is_layout_key(k):
            note(c, "layout." + k + " is not a setting, ignored")


private def read_keys(c: Config, o: Dict<str, any>, commands: List<str>):
    if "keys" not in o:
        return
    nonlocal K
    try:
        K = o["keys"] as Dict<str, any>
    catch e:
        note(c, "keys should be an object, ignored")
        return
    names: List<str> = []
    for n in K:
        names.append(n)
    names = sorted(names)      # the notes come out in the same order every run
    for name in names:
        nonlocal cmd
        try:
            cmd = K[name] as str
        catch e:
            note(c, "keys." + name + " should be a command name, ignored")
            continue
        if not key_valid(name):
            note(c, "keys." + name + " is not a key, ignored")
            continue
        if len(cmd) == 0:
            # the one way to say "take this shortcut away", and it has to exist:
            # a default binding that somebody's window manager already ate would
            # otherwise be unremovable
            if name in c.keys:
                c.keys.remove(name)
            continue
        if cmd not in commands:
            note(c, "keys." + name + " = '" + cmd + "' is not a command, ignored")
            continue
        c.keys[name] = cmd


def parse(text: str, commands: List<str>) -> Config:
    """The TEXT of a `.pstudio.json`, and the commands that exist right now.

    `commands` is passed in rather than imported, because the set depends on
    which binary is running and on what registered itself — a config validated
    against a hard-coded list would go stale the day somebody adds a command."""
    c = default_config()
    if len(text.strip()) == 0:
        return c
    nonlocal o
    try:
        o = json.parse(text) as Dict<str, any>
    catch e:
        note(c, "is not a JSON object (" + e.message + ") — everything default")
        return c
    read_layout(c, o)
    c.target = want_str(c, o, "target", c.target)
    c.test = want_str(c, o, "test", c.test)
    read_keys(c, o, commands)
    for k in o:
        if k != "layout" and k != "target" and k != "keys" and k != "test":
            note(c, k + " is not a setting, ignored")
    return c


# ---------- writing it ----------

def to_text(c: Config) -> str:
    """What the IDE saves back.

    Only the keys that DIFFER from the defaults are written. A file listing all
    thirty-seven bindings would bury the one somebody changed, and would freeze
    today's defaults into every project that was ever opened."""
    out = "{\n"
    out += '  "layout": {\n'
    out += '    "tree_w": ' + str(c.tree_w) + ',\n'
    out += '    "outline_w": ' + str(c.outline_w) + ',\n'
    out += '    "dock_h": ' + str(c.dock_h) + ',\n'
    out += '    "tree_open": ' + ("true" if c.tree_open else "false") + ',\n'
    out += '    "outline_open": ' + ("true" if c.outline_open else "false") + ',\n'
    out += '    "dock_open": ' + ("true" if c.dock_open else "false") + '\n'
    out += '  },\n'
    out += '  "target": ' + json.stringify(c.target) + ',\n'
    out += '  "test": ' + json.stringify(c.test) + ',\n'
    base = default_keys()
    changed: List<str> = []
    for k in c.keys:
        if k not in base or base[k] != c.keys[k]:
            changed.append(k)
    for k2 in base:
        if k2 not in c.keys:
            changed.append(k2)        # removed on purpose: written as ""
    changed = sorted(changed)
    out += '  "keys": {'
    first = True
    for k3 in changed:
        val = c.keys[k3] if k3 in c.keys else ""
        out += ("" if first else ",") + "\n    " + json.stringify(k3) + ": " + json.stringify(val)
        first = False
    out += ("" if first else "\n  ") + "}\n"
    out += "}\n"
    return out
