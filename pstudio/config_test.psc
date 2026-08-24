"""`.pstudio.json`, without a disk.

`parse` takes the TEXT, so everything a configuration file can be wrong about is
a string in this file. That is the whole reason it takes the text: a config
parser tested through the filesystem gets tested on the two files somebody
thought of, and this one is tested on the ones that ruin somebody's morning.

The rule being measured, over and over: **nothing here fails, and nothing here is
silent.** Every case below takes the default AND leaves a note.
"""
import config as cfg


CMDS: list<str> = ["Save", "Quit", "Find", "Build", "Toggle Theme"]


def show(c: cfg.Config):
    print("  tree=" + str(c.tree_w) + " outline=" + str(c.outline_w) +
          " dock=" + str(c.dock_h) +
          " open=" + ("T" if c.tree_open else "F") +
          ("T" if c.outline_open else "F") + ("T" if c.dock_open else "F") +
          " target=[" + c.target + "]")
    for n in c.notes:
        print("  ! " + n)


# ---- nothing at all is the default, and says nothing ----
d = cfg.default_config()
print("empty:")
show(cfg.parse("", CMDS))
print("keys by default=" + str(len(d.keys)))

# ---- a file somebody wrote by hand ----
print("good:")
show(cfg.parse("{\n" +
    "  \"layout\": {\"tree_w\": 300, \"dock_h\": 150, \"dock_open\": true},\n" +
    "  \"target\": \"build/bin/pcode\",\n" +
    "  \"keys\": {\"ctrl+shift+b\": \"Build\", \"f2\": \"Toggle Theme\"}\n" +
    "}", CMDS))

# ---- and the bindings it changed, without touching the others ----
g = cfg.parse("{\"keys\": {\"ctrl+shift+b\": \"Build\", \"ctrl+s\": \"\"}}", CMDS)
print("bound=[" + (g.keys["ctrl+shift+b"] if "ctrl+shift+b" in g.keys else "-") + "]" +
      " removed=" + str("ctrl+s" not in g.keys) +
      " kept=" + str(len(g.keys)) + " of " + str(len(d.keys)))

# ---- everything that can be wrong ----
print("not json:")
show(cfg.parse("{ this is not json", CMDS))
print("not an object:")
show(cfg.parse("[1, 2, 3]", CMDS))
print("wrong types:")
show(cfg.parse("{\"layout\": {\"tree_w\": \"wide\", \"dock_open\": 1}, \"target\": 7}", CMDS))
print("layout is not an object:")
show(cfg.parse("{\"layout\": \"left\"}", CMDS))
print("out of range:")
show(cfg.parse("{\"layout\": {\"tree_w\": -5, \"outline_w\": 99999}}", CMDS))
print("names nobody knows:")
show(cfg.parse("{\"colour\": \"blue\", \"layout\": {\"tree_wide\": 3}}", CMDS))
print("keys nobody can press, and commands nobody has:")
show(cfg.parse("{\"keys\": {" +
    "\"ctrl+nonsense\": \"Save\"," +
    "\"shift+ctrl+s\": \"Save\"," +
    "\"ctrl+ctrl+s\": \"Save\"," +
    "\"ctrl+A\": \"Save\"," +
    "\"f13\": \"Save\"," +
    "\"ctrl+b\": \"Deploy To Production\"," +
    "\"ctrl+g\": 42}}", CMDS))

# ---- the names round trip: what `key_name` writes, `key_valid` accepts ----
bad = 0
for pair in [[ord("s"), 2], [ord("s"), 3], [cfg.K_TAB, 2], [cfg.K_UP, 3],
             [cfg.K_F1 + 1, 0], [cfg.K_F1 + 11, 1], [ord("/"), 2], [ord("["), 3],
             [ord("="), 2], [cfg.K_PAGEDOWN, 6], [ord("q"), 15]]:
    nm = cfg.key_name(pair[0], pair[1])
    if len(nm) == 0 or not cfg.key_valid(nm):
        print("  BAD " + str(pair[0]) + "/" + str(pair[1]) + " -> [" + nm + "]")
        bad += 1
print("names round trip=" + str(bad == 0))
print("ctrl+shift+s=[" + cfg.key_name(ord("s"), 3) + "] f12=[" +
      cfg.key_name(cfg.K_F1 + 11, 0) + "] alt+up=[" + cfg.key_name(cfg.K_UP, 4) + "]")
# a key with no name is not a shortcut, and that is how an unbound key stays harmless
print("nameless=[" + cfg.key_name(1073742048, 2) + "]")

# ---- and a whole config survives being written and read back ----
c2 = cfg.parse("{\"layout\": {\"tree_w\": 333, \"dock_open\": true}, \"target\": \"x\"," +
               " \"keys\": {\"ctrl+shift+b\": \"Build\", \"ctrl+s\": \"\"}}", CMDS)
t = cfg.to_text(c2)
c3 = cfg.parse(t, CMDS)
same = (c3.tree_w == c2.tree_w and c3.outline_w == c2.outline_w and
        c3.dock_h == c2.dock_h and c3.tree_open == c2.tree_open and
        c3.outline_open == c2.outline_open and c3.dock_open == c2.dock_open and
        c3.target == c2.target and len(c3.keys) == len(c2.keys))
for k in c2.keys:
    if k not in c3.keys or c3.keys[k] != c2.keys[k]:
        same = False
print("round trip=" + str(same) + " notes on reread=" + str(len(c3.notes)))
print("what it writes:")
print(t)
print("config-ok")
