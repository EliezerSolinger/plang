"""smallpt in pscript — the whole program.

THIS IS THE VALIDATION PROGRAM of battery 52, in the form the language actually
has today: a path tracer that reads its options from the command line, renders
in parallel with one OS thread per worker, writes the image, and reports what
each worker did.

Everything it uses cites the battery that created it:

  * `record` with methods and `in self` — value types, no copy (52.1/56/57.1)
  * `enum` matched exhaustively, no `case _` (29.2)
  * workers: one `spawn`, one thread, one heap (35.1/18.1), the worker IS the
    channel (36.1), and the program waits for all of them (36.3)
  * a shared `buffer` for the pixels (19.4/52.3) — the one thing meant to be
    shared, malloc'd so it never moves under another thread
  * `shared` rows, synchronized by copy with a lock per variable (42.1/42.3)
  * `sys.argv` and `re.match` for the command line (48.3/41.2)
  * `json.parse` for an optional scene, read back with checked `as` (41.1/55.2)
  * files with `with`, which closes on every way out (48.1/19.4)
  * a lambda as the tone map, captured by value (28.1/19.2)
  * `assert` (46.4), `defer` (43.4), `T[N]`-free lists, options and `??` (43.2)

Deterministic: every worker seeds its own RNG from its id, so the same command
line gives the same image however the threads interleave.

Usage:
    smallpt_full [samples] [--dim WxH] [--out file.ppm] [--scene file.json]
"""

include <math.h>

import sys
import re
import json


# ---------------------------------------------------------------- vectors

record Vec:
    x: float
    y: float
    z: float

    def add(in self, b: Vec) -> Vec:
        return Vec(self.x + b.x, self.y + b.y, self.z + b.z)

    def sub(in self, b: Vec) -> Vec:
        return Vec(self.x - b.x, self.y - b.y, self.z - b.z)

    def scale(in self, k: float) -> Vec:
        return Vec(self.x * k, self.y * k, self.z * k)

    def mul(in self, b: Vec) -> Vec:
        return Vec(self.x * b.x, self.y * b.y, self.z * b.z)

    def dot(in self, b: Vec) -> float:
        return self.x * b.x + self.y * b.y + self.z * b.z

    def cross(in self, b: Vec) -> Vec:
        return Vec(self.y * b.z - self.z * b.y,
                   self.z * b.x - self.x * b.z,
                   self.x * b.y - self.y * b.x)

    def norm(in self) -> Vec:
        return self.scale(1.0 / sqrt(self.x * self.x + self.y * self.y + self.z * self.z))

    def maxc(in self) -> float:
        m = self.x
        if self.y > m:
            m = self.y
        if self.z > m:
            m = self.z
        return m


const BLACK = Vec(0.0, 0.0, 0.0)


enum Refl:
    DIFF
    SPEC
    REFR


record Ray:
    org: Vec
    dir: Vec


record Sphere:
    rad: float
    pos: Vec
    emit: Vec
    color: Vec
    kind: Refl


record Stat:
    wid: int
    rows: int
    rays: int


const EPS = 1e-4
const NC = 1.0
const NT = 1.5
const PI = 3.14159265358979323846


# ---------------------------------------------------------------- state

# A mutable module variable is the WORKER's own (42.2): every thread has its own
# generator, which is what makes the image reproducible.
rng_state: u64 = 88172645463325252

# `shared` is the other kind: synchronized by copy, one lock per variable (42.1)
shared rows_done: int = 0


def seed(s: int):
    """Each worker seeds from its id (52.4). The state is a real u64 now
    (68.2): `>>` on it is LOGICAL by construction and `%*` wraps, which is the
    whole contract xorshift64* asks for — the 53-bit mask this function used to
    need is gone with the reason for it."""
    global rng_state
    rng_state = u64(s) if s != 0 else u64(1)


def rnd() -> float:
    """xorshift64*, verbatim."""
    global rng_state
    x = rng_state
    x ^= x >> 12
    x ^= x << 25
    x ^= x >> 27
    rng_state = x
    return float((x %* 2685821657736338717) >> 11) * (1.0 / 9007199254740992.0)


def cornell() -> list<Sphere>:
    """smallpt's Cornell box, built in code."""
    return [
        Sphere(1e5, Vec(1e5 + 1.0, 40.8, 81.6), BLACK, Vec(0.75, 0.25, 0.25), DIFF),
        Sphere(1e5, Vec(-1e5 + 99.0, 40.8, 81.6), BLACK, Vec(0.25, 0.25, 0.75), DIFF),
        Sphere(1e5, Vec(50.0, 40.8, 1e5), BLACK, Vec(0.75, 0.75, 0.75), DIFF),
        Sphere(1e5, Vec(50.0, 40.8, -1e5 + 170.0), BLACK, BLACK, DIFF),
        Sphere(1e5, Vec(50.0, 1e5, 81.6), BLACK, Vec(0.75, 0.75, 0.75), DIFF),
        Sphere(1e5, Vec(50.0, -1e5 + 81.6, 81.6), BLACK, Vec(0.75, 0.75, 0.75), DIFF),
        Sphere(16.5, Vec(27.0, 16.5, 47.0), BLACK, Vec(0.999, 0.999, 0.999), SPEC),
        Sphere(16.5, Vec(73.0, 16.5, 78.0), BLACK, Vec(0.999, 0.999, 0.999), REFR),
        Sphere(600.0, Vec(50.0, 681.33, 81.6), Vec(12.0, 12.0, 12.0), BLACK, DIFF),
    ]


def vec_from(v: any) -> Vec:
    """A JSON array of three numbers. `as` CHECKS (55.2): a document that says
    something else stops the program instead of rendering nonsense."""
    trio = v as list<any>
    return Vec(trio[0] as float, trio[1] as float, trio[2] as float)


def sphere_from(v: any) -> Sphere:
    m = v as dict<str, any>
    ks = m["kind"] as str
    kind = DIFF
    if ks == "spec":
        kind = SPEC
    elif ks == "refr":
        kind = REFR
    return Sphere(m["rad"] as float, vec_from(m["pos"]), vec_from(m["emit"]),
                  vec_from(m["color"]), kind)


async def load_scene(path: str) -> list<Sphere>:
    """JSON in, spheres out (41.1). Failure raises with the io category and the
    program says which file it could not read."""
    nonlocal text
    with await open(path, "r") as f:
        text = await f.text()
    doc = json.parse(text) as list<any>
    out: list<Sphere> = []
    i = 0
    while i < len(doc):
        out.append(sphere_from(doc[i]))
        i += 1
    return out


# ---------------------------------------------------------------- tracing

def hit_sphere(in s: Sphere, in r: Ray) -> float:
    op = s.pos.sub(r.org)
    b = op.dot(r.dir)
    det = b * b - op.dot(op) + s.rad * s.rad
    if det < 0.0:
        return 0.0
    det = sqrt(det)
    t = b - det
    if t > EPS:
        return t
    t = b + det
    if t > EPS:
        return t
    return 0.0


def nearest(spheres: list<Sphere>, in r: Ray) -> int:
    best = 1e20
    found = -1
    i = 0
    while i < len(spheres):
        t = hit_sphere(in spheres[i], in r)
        if t != 0.0 and t < best:
            best = t
            found = i
        i += 1
    return found


def radiance(spheres: list<Sphere>, in r: Ray, depth: int) -> Vec:
    """Recursive Monte Carlo. It does NOT allocate: `Vec` is a value (52.1), so
    the hot loop runs on the stack and the collector never fires inside it."""
    idx = nearest(spheres, in r)
    if idx < 0:
        return BLACK
    obj = spheres[idx]
    t = hit_sphere(in spheres[idx], in r)
    x = r.org.add(r.dir.scale(t))
    n = x.sub(obj.pos).norm()
    nl = n if n.dot(r.dir) < 0.0 else n.scale(-1.0)
    f = obj.color

    d2 = depth + 1
    if d2 > 5:
        p = f.maxc()
        if rnd() < p and d2 < 40:
            f = f.scale(1.0 / p)
        else:
            return obj.emit

    match obj.kind:
        case DIFF:
            r1 = 2.0 * PI * rnd()
            r2 = rnd()
            r2s = sqrt(r2)
            w = nl
            axis = Vec(0.0, 1.0, 0.0) if fabs(w.x) > 0.1 else Vec(1.0, 0.0, 0.0)
            u = axis.cross(w).norm()
            v = w.cross(u)
            d = u.scale(cos(r1) * r2s).add(v.scale(sin(r1) * r2s)).add(w.scale(sqrt(1.0 - r2))).norm()
            return obj.emit.add(f.mul(radiance(spheres, in Ray(x, d), d2)))
        case SPEC:
            d = r.dir.sub(n.scale(2.0 * n.dot(r.dir)))
            return obj.emit.add(f.mul(radiance(spheres, in Ray(x, d), d2)))
        case REFR:
            drefl = r.dir.sub(n.scale(2.0 * n.dot(r.dir)))
            refl = Ray(x, drefl)
            into = n.dot(nl) > 0.0
            nnt = NC / NT if into else NT / NC
            ddn = r.dir.dot(nl)
            cos2t = 1.0 - nnt * nnt * (1.0 - ddn * ddn)
            if cos2t < 0.0:
                return obj.emit.add(f.mul(radiance(spheres, in refl, d2)))
            sign = 1.0 if into else -1.0
            tdir = r.dir.scale(nnt).sub(n.scale(sign * (ddn * nnt + sqrt(cos2t)))).norm()
            re0 = ((NT - NC) * (NT - NC)) / ((NT + NC) * (NT + NC))
            c = 1.0 - (-ddn if into else tdir.dot(n))
            re = re0 + (1.0 - re0) * c * c * c * c * c
            tr = 1.0 - re
            pr = 0.25 + 0.5 * re
            if d2 > 2:
                if rnd() < pr:
                    return obj.emit.add(f.mul(radiance(spheres, in refl, d2).scale(re / pr)))
                return obj.emit.add(f.mul(radiance(spheres, in Ray(x, tdir), d2).scale(tr / (1.0 - pr))))
            both = radiance(spheres, in refl, d2).scale(re).add(radiance(spheres, in Ray(x, tdir), d2).scale(tr))
            return obj.emit.add(f.mul(both))
    return BLACK


# ---------------------------------------------------------------- the worker

async def render(wid: int, nworkers: int, width: int, height: int, spp: int,
           scene_path: str, fb: buffer) -> Stat:
    """One worker's share: the rows y = wid, wid+n, wid+2n, …

    It has its own heap and its own collector (18.1), and the scene is built
    HERE — nothing collected crosses between threads. The pixels go into the
    shared buffer, whose bytes never move (52.3)."""
    global rows_done
    seed(9781 + wid * 7919)
    spheres = cornell()
    if len(scene_path) > 0:
        spheres = await load_scene(scene_path)
    rays = 0
    rows = 0

    cam = Ray(Vec(50.0, 52.0, 295.6), Vec(0.0, -0.042612, -1.0).norm())
    cx = Vec(float(width) * 0.5135 / float(height), 0.0, 0.0)
    cy = cx.cross(cam.dir).norm().scale(0.5135)

    y = wid
    while y < height:
        col = 0
        while col < width:
            acc = BLACK
            sy = 0
            while sy < 2:
                sx = 0
                while sx < 2:
                    part = BLACK
                    s = 0
                    while s < spp:
                        r1 = 2.0 * rnd()
                        dx = sqrt(r1) - 1.0 if r1 < 1.0 else 1.0 - sqrt(2.0 - r1)
                        r2 = 2.0 * rnd()
                        dy = sqrt(r2) - 1.0 if r2 < 1.0 else 1.0 - sqrt(2.0 - r2)
                        d = cx.scale(((float(sx) + 0.5 + dx) / 2.0 + float(col)) / float(width) - 0.5)
                        d = d.add(cy.scale(((float(sy) + 0.5 + dy) / 2.0 + float(height - y - 1)) / float(height) - 0.5))
                        d = d.add(cam.dir)
                        ray = Ray(cam.org.add(d.scale(140.0)), d.norm())
                        part = part.add(radiance(spheres, in ray, 0).scale(1.0 / float(spp)))
                        rays += 1
                        s += 1
                    acc = acc.add(Vec(clamp01(part.x), clamp01(part.y), clamp01(part.z)).scale(0.25))
                    sx += 1
                sy += 1
            i = (y * width + col) * 3
            fb.set_f64(i, acc.x)
            fb.set_f64(i + 1, acc.y)
            fb.set_f64(i + 2, acc.z)
            col += 1
        rows_done += 1
        rows += 1
        y += nworkers
    st = Stat(wid, rows, rays)
    parent.send(st)
    return st


def clamp01(v: float) -> float:
    return 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)


# ---------------------------------------------------------------- the program

defer:
    print("done")

samples = 4
width = 32
height = 24
out_path = "smallpt.ppm"
scene_path = ""

args = sys.argv[1:]
i = 0
while i < len(args):
    a = args[i]
    if a == "--dim":
        i += 1
        m = re.match("^([0-9]+)x([0-9]+)$", args[i])
        # `!= None` is what PROVES it is there (43.1), and inside the branch the
        # option IS the list — no second check and no unwrap
        if m != None:
            width = int(m[1])
            height = int(m[2])
        else:
            print("bad --dim:", args[i])
            sys.exit(2)
    elif a == "--out":
        i += 1
        out_path = args[i]
    elif a == "--scene":
        i += 1
        scene_path = args[i]
    else:
        samples = int(a)
    i += 1

assert width > 0 and height > 0, "the image needs a size"
assert samples >= 4, "at least four samples"
spp = samples // 4

nworkers = int(sys.env.get("PSC_WORKERS", "4"))
print(f"smallpt {width}x{height}, {samples} samples/pixel, {nworkers} workers")

# the tone map is a function VALUE, and the lambda captures gamma BY VALUE (19.2)
gamma = 2.2
tone: def(float) -> float = lambda v: clamp01(v) ** (1.0 / gamma)

with buffer(width * height * 3 * 8) as fb:
    ws: list<Worker<Stat>> = []
    w = 0
    while w < nworkers:
        ws.append(spawn(render, (w, nworkers, width, height, spp, scene_path, fb)))
        w += 1

    stats: list<Stat> = []
    k = 0
    while k < len(ws):
        stats.append(await ws[k].recv())
        k += 1

    total_rays = 0
    j = 0
    while j < len(stats):
        total_rays += stats[j].rays
        j += 1
    print(f"rows {rows_done} rays {total_rays}")

    written = 0
    f = await open(out_path, "w")
    written += await f.write(f"P3\n{width} {height}\n255\n")
    p = 0
    while p < width * height * 3:
        r = int(255.0 * tone(fb.get_f64(p)) + 0.5)
        g = int(255.0 * tone(fb.get_f64(p + 1)) + 0.5)
        b = int(255.0 * tone(fb.get_f64(p + 2)) + 0.5)
        written += await f.write(f"{r} {g} {b}\n")
        p += 3
    await f.close()
    print(f"wrote {out_path} ({written} bytes)")
