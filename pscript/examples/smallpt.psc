"""smallpt in pscript — global illumination path tracer, parallel via workers.

Idiomatic rewrite of Kevin Beason's smallpt (99 lines of C++,
kevinbeason.com/smallpt). THIS IS THE LANGUAGE VALIDATION PROGRAM (52): when it
compiles and runs, pscript is validated end to end. Every construct used cites
the DESIGN.md battery that created it; the full coverage matrix is FEATURES.md.

Usage:
    smallpt [samples] [--dim WxH] [--out file.ppm] [--scene file.json]
            [--tone gamma|linear|reinhard]

Deterministic: own RNG (xorshift64*) seeded per worker — the same command line
produces the same PPM on any machine, which makes this program testable by
expected output (8.4).
"""

include <math.h>                       # sqrt/cos/sin/fabs/M_PI direct (45.5)
import sys                             # argv/env/exit (48.3)
import json                            # parse -> any (41.1)
import re                              # POSIX ERE via libc (41.2)
from vec3 import Vec, BLACK, clamp01   # from-import (41.3); algebra is methods (57.1)
import vec3                            # qualified form too (41.3)


# ---------------------------------------------------------------- scene types

enum Refl:                             # enum like P's (29.2)
    DIFF
    SPEC
    REFR

record Ray:                            # record nesting a record (21.1)
    org: Vec
    dir: Vec

record Sphere:                         # enum is primitive, fits in a record (53.2)
    rad: float
    pos: Vec
    emit: Vec
    color: Vec
    kind: Refl

record Stat:                           # POD: crosses worker->main via memcpy (34.3)
    wid: int
    time: float
    rays: int


const EPS = 1e-4
const NC = 1.0                         # refractive index of air
const NT = 1.5                         # refractive index of glass

# smallpt's Cornell box: T[N] of records, const — every worker is born with it,
# nothing is sent (33.4, 42.2, 52.4). Type-call constructor with names (54.2).
const SCENE: Sphere[9] = [
    Sphere(rad=1e5,  pos=Vec(1e5 + 1.0, 40.8, 81.6),    emit=BLACK,              color=Vec(0.75, 0.25, 0.25), kind=DIFF),   # left wall
    Sphere(rad=1e5,  pos=Vec(-1e5 + 99.0, 40.8, 81.6),  emit=BLACK,              color=Vec(0.25, 0.25, 0.75), kind=DIFF),   # right wall
    Sphere(rad=1e5,  pos=Vec(50.0, 40.8, 1e5),          emit=BLACK,              color=Vec(0.75, 0.75, 0.75), kind=DIFF),   # back
    Sphere(rad=1e5,  pos=Vec(50.0, 40.8, -1e5 + 170.0), emit=BLACK,              color=BLACK,                 kind=DIFF),   # front
    Sphere(rad=1e5,  pos=Vec(50.0, 1e5, 81.6),          emit=BLACK,              color=Vec(0.75, 0.75, 0.75), kind=DIFF),   # floor
    Sphere(rad=1e5,  pos=Vec(50.0, -1e5 + 81.6, 81.6),  emit=BLACK,              color=Vec(0.75, 0.75, 0.75), kind=DIFF),   # ceiling
    Sphere(rad=16.5, pos=Vec(27.0, 16.5, 47.0),         emit=BLACK,              color=Vec(0.999, 0.999, 0.999), kind=SPEC),
    Sphere(rad=16.5, pos=Vec(73.0, 16.5, 78.0),         emit=BLACK,              color=Vec(0.999, 0.999, 0.999), kind=REFR),
    Sphere(rad=600.0, pos=Vec(50.0, 681.33, 81.6),      emit=Vec(12.0, 12.0, 12.0), color=BLACK,              kind=DIFF),   # light
]

const MATERIALS = {"diff", "spec", "refr"}     # set (8.1)


# ------------------------------------------------------------------ state

# Mutable global = PRIVATE to the worker (42.2): each worker has its own RNG.
rng_state: u64 = 88172645463325252

# shared = synchronized across workers, one lock per variable (42.1, 42.3)
shared rows_done = 0
shared times: Dict<int, float>         # ETS table: time per worker (42.1)


def seed(s: u64):
    global rng_state                   # assigning a global requires declaring (55.3)
    rng_state = s if s != 0 else 1

def rnd() -> float:
    """xorshift64* — the modular multiply uses the %* operator (54.1):
    the wrap is visible at the exact spot where it is intentional."""
    global rng_state
    x = rng_state
    x ^= x >> 12
    x ^= x << 25
    x ^= x >> 27
    rng_state = x
    return float((x %* 2685821657736338717) >> 11) * (1.0 / 9007199254740992.0)


# ------------------------------------------------------------------ intersection

private def intersect_sphere(in s: Sphere, in r: Ray) -> float:
    """Distance to the hit, or 0.0 if the ray misses.
    `in`: read by reference, no 104-byte Sphere copy (55.4/56)."""
    op = s.pos.sub(r.org)              # record method (57.1)
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

private def intersect(scene: List<Sphere>, in r: Ray) -> (float, int)?:
    """(distance, index) of the nearest hit, or None (9.4)."""
    best = 1e20
    found = -1
    for i, s in enumerate(scene):
        t = intersect_sphere(in s, in r)
        if t != 0.0 and t < best:
            best = t
            found = i
    if found < 0:
        return None
    return (best, found)               # tuple (3.2)


# ------------------------------------------------------------------ radiance

def max_of(*xs: List<float>) -> float:     # *args = sugar over list (44.2)
    m = xs[0]
    for v in xs:
        if v > m:
            m = v
    return m

def radiance(scene: List<Sphere>, in r: Ray, depth: int = 0) -> Vec:
    """Recursive Monte Carlo. Does NOT allocate: Vec is a value (52.1/56) —
    the whole hot loop runs on the stack and the collector never fires here."""
    hit = intersect(scene, in r)
    if not hit:                        # T? truthiness (40.1)
        return BLACK
    t, idx = hit                       # narrowing (43.1) + unpacking
    obj = scene[idx]
    x = r.org.add(r.dir.scale(t))      # chaining (57.1)
    n = x.sub(obj.pos).norm()
    nl = n if n.dot(r.dir) < 0.0 else n.scale(-1.0)
    f = obj.color

    depth += 1
    if depth > 5:
        # Russian roulette, with walrus (45.2)
        if rnd() < (p := max_of(f.x, f.y, f.z)):
            f = f.scale(1.0 / p)
        else:
            return obj.emit

    match obj.kind:                    # exhaustive over enum, no case _ (29.2, 55.3)
        case DIFF:
            r1 = 2.0 * M_PI * rnd()    # M_PI ingested from <math.h> (45.5)
            r2 = rnd()
            r2s = sqrt(r2)
            w = nl
            axis = Vec(0.0, 1.0, 0.0) if fabs(w.x) > 0.1 else Vec(1.0, 0.0, 0.0)
            u = axis.cross(w).norm()
            v = w.cross(u)
            d = (u.scale(cos(r1) * r2s)         # continuação: só parênteses (61.1)
                     .add(v.scale(sin(r1) * r2s))
                     .add(w.scale(sqrt(1.0 - r2)))
                     .norm())
            return obj.emit.add(f.mul(radiance(scene, in Ray(x, d), depth)))

        case SPEC:
            d = r.dir.sub(n.scale(2.0 * n.dot(r.dir)))
            return obj.emit.add(f.mul(radiance(scene, in Ray(x, d), depth)))

        case REFR:
            drefl = r.dir.sub(n.scale(2.0 * n.dot(r.dir)))
            refl = Ray(x, drefl)
            into = n.dot(nl) > 0.0
            nnt = NC / NT if into else NT / NC
            ddn = r.dir.dot(nl)
            cos2t = 1.0 - nnt * nnt * (1.0 - ddn * ddn)
            if cos2t < 0.0:            # total internal reflection
                return obj.emit.add(f.mul(radiance(scene, in refl, depth)))
            sign = 1.0 if into else -1.0
            tdir = (r.dir.scale(nnt)
                         .sub(n.scale(sign * (ddn * nnt + sqrt(cos2t))))
                         .norm())
            re0 = ((NT - NC) ** 2) / ((NT + NC) ** 2)      # ** (47.3)
            c = 1.0 - (-ddn if into else tdir.dot(n))
            re = re0 + (1.0 - re0) * c ** 5                # Schlick
            tr = 1.0 - re
            pr = 0.25 + 0.5 * re
            if depth > 2:
                if rnd() < pr:
                    return obj.emit.add(f.mul(radiance(scene, in refl, depth).scale(re / pr)))
                return obj.emit.add(f.mul(radiance(scene, in Ray(x, tdir), depth).scale(tr / (1.0 - pr))))
            both = (radiance(scene, in refl, depth).scale(re)
                        .add(radiance(scene, in Ray(x, tdir), depth).scale(tr)))
            return obj.emit.add(f.mul(both))


# ------------------------------------------------------------------ worker

struct Rows implements Iterable:
    """Iterator over this worker's rows (y = wid, wid+n, wid+2n, …).
    Collected struct with methods (20.1). `implements` (62.2) asserts the
    conformance the compiler would also infer structurally (30.1, 40.3);
    Rows is its own iterator (single-pass — fine here, 62.3)."""
    next_y: int
    step: int
    height: int

    def has_next(self) -> bool:
        return self.next_y < self.height

    def next(self) -> int:
        y = self.next_y
        self.next_y += self.step
        return y

def render(wid: int, n_workers: int, width: int, height: int, spp: int,
           scene: List<Sphere>, fb: Buffer):
    """Worker body (35.1): own heap, collector and RNG. Writes into the shared
    framebuffer (52.3) and counts rows in the shared var (42.1)."""
    global rows_done
    seed(u64(9781 + wid * 2654435761))         # deterministic per worker (52.4)
    px = fb.view_f64()                         # typed view, no copy (18.3)
    start = sys.time()
    rays = 0

    cam = Ray(Vec(50.0, 52.0, 295.6), Vec(0.0, -0.042612, -1.0).norm())
    cx = Vec(width * 0.5135 / height, 0.0, 0.0)    # int->float promotion (32.1)
    cy = cx.cross(cam.dir).norm().scale(0.5135)

    for y in Rows(wid, n_workers, height):     # for over own iterator (40.3)
        for col in range(width):
            acc = BLACK
            for sy in range(2):                # original's 2x2 subpixels
                for sx in range(2):
                    part = BLACK
                    for s in range(spp):
                        r1 = 2.0 * rnd()       # tent filter
                        dx = sqrt(r1) - 1.0 if r1 < 1.0 else 1.0 - sqrt(2.0 - r1)
                        r2 = 2.0 * rnd()
                        dy = sqrt(r2) - 1.0 if r2 < 1.0 else 1.0 - sqrt(2.0 - r2)
                        d = (cx.scale(((sx + 0.5 + dx) / 2.0 + col) / width - 0.5)
                               .add(cy.scale(((sy + 0.5 + dy) / 2.0 + y) / height - 0.5))
                               .add(cam.dir))
                        ray = Ray(cam.org.add(d.scale(140.0)), d.norm())
                        part = part.add(radiance(scene, in ray).scale(1.0 / spp))
                        rays += 1
                    acc = acc.add(part.clamped().scale(0.25))
            i = ((height - y - 1) * width + col) * 3
            px[i] = acc.x
            px[i + 1] = acc.y
            px[i + 2] = acc.z
        rows_done += 1                         # compound atomic: the var's lock (42.3)

    times[wid] = sys.time() - start            # shared dict / ETS (42.1)
    parent.send(Stat(wid, times[wid], rays))   # POD via memcpy (34.3, 36.1)


# ------------------------------------------------------------------ JSON scene

private def vec_from(o: any) -> Vec:
    trio = o as List<any>                      # unboxing is `as`, checked (55.2)
    return Vec(trio[0] as float, trio[1] as float, trio[2] as float)

private def sphere_from(o: any) -> Sphere:
    m = o as Dict<str, any>
    kind_s = m["kind"] as str
    if kind_s not in MATERIALS:                # set + not in (8.1)
        raise error(f"unknown material: {kind_s}")
    kind = DIFF if kind_s == "diff" else (SPEC if kind_s == "spec" else REFR)
    return Sphere(rad=m["rad"] as float, pos=vec_from(m["pos"]),
                  emit=vec_from(m["emit"]), color=vec_from(m["color"]), kind=kind)

def load_scene(path: str) -> List<Sphere>:
    """JSON -> scene. Exercises json.parse -> any and checked navigation (41.1)."""
    with open(path, "r") as f:                 # 48.1; failure raises category io
        raw = json.parse(f.read())
    return [sphere_from(o) for o in raw as List<any>]   # comprehension (8.1)


# ------------------------------------------------------------------ output

def save_ppm(path: str, px: View<f64>, width: int, height: int,
             tone: def(float) -> float):       # function as parameter (28.1)
    """PPM P3, with pluggable tone mapping."""
    with open(path, "w") as f:
        f.write(f"P3\n{width} {height}\n255\n")
        for i in range(0, width * height * 3, 3):
            r = int(255.0 * tone(px[i]) + 0.5)
            g = int(255.0 * tone(px[i + 1]) + 0.5)
            b = int(255.0 * tone(px[i + 2]) + 0.5)
            f.write(f"{r} {g} {b}\n")


# ================================================================== main
# Loose code = implicit main (6.2), which is async: top-level await (39.4).

t0 = sys.time()
defer:                                          # surface defer (43.4)
    print(f"total time: {sys.time() - t0:.1f}s")

samples = 16
width = 1024
height = 768
out_path = "image.ppm"
scene_path: str? = None
tone_name: str? = None
n_workers = int(sys.env.get("PSC_WORKERS") ?? "8")      # T? + ?? (43.2)

args = sys.argv[1:]                             # slice (17.3)
i = 0
while i < len(args):
    match args[i]:                              # string match (inherited from P)
        case "--dim":
            i += 1
            m = re.match("^([0-9]+)x([0-9]+)$", args[i])   # POSIX regex (41.2)
            if not m:                           # T? truthiness (40.1)
                raise error(f"bad --dim: {args[i]} (expected WxH)")
            parts = args[i].split("x")
            width = int(parts[0])               # int(str) CONVERTS (55.2)
            height = int(parts[-1])             # negative index (31.4)
        case "--out":
            i += 1
            out_path = args[i]
        case "--scene":
            i += 1
            scene_path = args[i]
        case "--tone":
            i += 1
            tone_name = args[i]
        case _:
            samples = int(args[i])
    i += 1

assert width > 0 and height > 0, "bad dimensions"        # assert (46.4)
assert samples >= 4, "at least 4 samples"
spp = samples // 4                              # // floor (39.1): 4 subpixels

# tone mapping: Dict<str, def> — callbacks by name, visible in the type (29.3)
gamma = 2.2
tonemaps: Dict<str, def> = {
    "gamma":    lambda v: clamp01(v) ** (1.0 / gamma),   # capture by value (19.2)
    "linear":   lambda v: clamp01(v),
    "reinhard": lambda v: clamp01(v / (1.0 + v)) ** (1.0 / gamma),
}
tone_name ??= "gamma"                           # ??= (43.2)
if tone_name not in tonemaps:
    raise error(f"unknown --tone: {tone_name}")
tone = tonemaps[tone_name] as def(float) -> float        # narrow def (29.4)

# scene: the built-in const, or the JSON one
scene = load_scene(scene_path) if scene_path else [s for s in SCENE]   # T[N] -> list

print(f"smallpt {width}x{height}, {samples} samples/pixel, {n_workers} workers")

with Buffer(width * height * 3 * 8) as fb:      # shared Buffer + with (19.4)
    ws = [spawn(render, (wid, n_workers, width, height, spp, scene, fb))
          for wid in range(n_workers)]          # spawn (35.1) in a comprehension

    ticker = interval(0.5)                      # 48.2
    while rows_done < height:
        await ticker.tick()                     # 51.1, inside the async main (39.4)
        alive = len([w for w in ws if status(w.id) == RUNNING])   # 37.3, 36.4
        pct = 100.0 * rows_done / height
        print(f"  {pct:>5.1f}%  ({rows_done}/{height} rows, {alive} workers alive)")

    stats = await gather([w.recv() for w in ws])         # gather (35.3)

    try:                                        # try/catch, one error type (5.1)
        save_ppm(out_path, fb.view_f64(), width, height, tone)
        print(f"wrote: {out_path}")
    catch e:
        if e.category == IO:                    # error metadata (15.2)
            print(f"could not write {out_path}: {e.msg}")
            sys.exit(1)
        raise e                                 # re-raise (54.3)

    # stats: leave any with `as` (55.2) + sorted with key=lambda (28.4)
    by_time = sorted([m as Stat for m in stats], key=lambda e: e.time)
    total_rays = 0
    for e in by_time:
        print(f"  worker {e.wid:>2}: {e.time:>7.2f}s  {e.rays:>12} rays")
        total_rays += e.rays
    slowest = by_time[-1]                       # negative index (31.4)
    print(f"total: {total_rays} rays; bottleneck was worker {slowest.wid}")
