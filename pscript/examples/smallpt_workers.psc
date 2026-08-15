"""smallpt rendered by WORKERS — the same path tracer, in parallel.

Each worker is an OS thread with a heap and a collector of its own (35.1/18.1).
It renders the rows `y = wid, wid + n, wid + 2n, …` and sends back what it
found. The scene is built INSIDE each worker: nothing collected crosses, because
what crosses between two heaps is BYTES (34.3) — here a `record` of three
numbers.

Deterministic all the same: each worker seeds its own RNG from its id, so the
numbers are the same however the threads interleave.

What the real `smallpt.psc` of battery 52 still waits for: the shared
framebuffer (52.3/19.4), so workers write pixels instead of summing them, and
the stdlib modules (`sys`, `json`, `re`).

Kevin Beason's smallpt (99 lines of C++, kevinbeason.com/smallpt), rewritten the
way pscript wants it written: `record` for the value types (52.1), methods with
`in self` so nothing is copied (57.1), an enum matched exhaustively (29.2), and
`include <math.h>` for the two functions that are genuinely libc's (45.5).

Deterministic: its own xorshift64* RNG (54.1's `%*` is where the wrap is meant),
so the same run gives the same image on any machine.
"""

include <math.h>


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


const EPS = 1e-4
const NC = 1.0
const NT = 1.5
const PI = 3.14159265358979323846


rng_state: u64 = 88172645463325252


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


def scene() -> list<Sphere>:
    """smallpt's Cornell box."""
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


def hit_sphere(in s: Sphere, in r: Ray) -> float:
    """Distance to the hit, or 0.0 if the ray misses. `in`: read by reference,
    with no 104-byte copy of the sphere (55.4/56)."""
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
    """Index of the nearest hit, or -1."""
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


def dist_to(spheres: list<Sphere>, in r: Ray, idx: int) -> float:
    return hit_sphere(in spheres[idx], in r)


def radiance(spheres: list<Sphere>, in r: Ray, depth: int) -> Vec:
    """Recursive Monte Carlo. It does NOT allocate: `Vec` is a value (52.1/56),
    so the whole hot loop runs on the stack and the collector never fires."""
    idx = nearest(spheres, in r)
    if idx < 0:
        return BLACK
    obj = spheres[idx]
    t = dist_to(spheres, in r, idx)
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


def clamp01(v: float) -> float:
    return 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)


def to_byte(v: float) -> int:
    return int(255.0 * (clamp01(v) ** (1.0 / 2.2)) + 0.5)


record Band:
    wid: int
    rows: int
    checksum: int


def render_band(wid: int, nworkers: int) -> Band:
    """One worker's share of the image: every nworkers-th row."""
    width = 32
    height = 24
    samples = 1
    seed(9781 + wid * 7919)
    spheres = scene()
    spheres = scene()
    cam = Ray(Vec(50.0, 52.0, 295.6), Vec(0.0, -0.042612, -1.0).norm())
    cx = Vec(float(width) * 0.5135 / float(height), 0.0, 0.0)
    cy = cx.cross(cam.dir).norm().scale(0.5135)
    total = 0
    rows = 0
    y = wid
    while y < height:
        x = 0
        while x < width:
            acc = BLACK
            sy = 0
            while sy < 2:
                sx = 0
                while sx < 2:
                    part = BLACK
                    s = 0
                    while s < samples:
                        r1 = 2.0 * rnd()
                        dx = sqrt(r1) - 1.0 if r1 < 1.0 else 1.0 - sqrt(2.0 - r1)
                        r2 = 2.0 * rnd()
                        dy = sqrt(r2) - 1.0 if r2 < 1.0 else 1.0 - sqrt(2.0 - r2)
                        d = cx.scale(((float(sx) + 0.5 + dx) / 2.0 + float(x)) / float(width) - 0.5)
                        d = d.add(cy.scale(((float(sy) + 0.5 + dy) / 2.0 + float(height - y - 1)) / float(height) - 0.5))
                        d = d.add(cam.dir)
                        ray = Ray(cam.org.add(d.scale(140.0)), d.norm())
                        part = part.add(radiance(spheres, in ray, 0).scale(1.0 / float(samples)))
                        s += 1
                    acc = acc.add(Vec(clamp01(part.x), clamp01(part.y), clamp01(part.z)).scale(0.25))
                    sx += 1
                sy += 1
            total += to_byte(acc.x) * (x % 7 + 1) + to_byte(acc.y) * (x % 5 + 1) + to_byte(acc.z) * (x % 3 + 1)
            x += 1
        rows += 1
        y += nworkers
    b = Band(wid, rows, total)
    parent.send(b)
    return b



NWORKERS = 4

ws: list<Worker<Band>> = []
w = 0
while w < NWORKERS:
    ws.append(spawn(render_band, (w, NWORKERS)))
    w += 1

rows = 0
sum = 0
k = 0
while k < len(ws):
    b = await ws[k].recv()
    rows += b.rows
    sum += b.checksum
    k += 1
print(f"workers {NWORKERS} rows {rows} checksum {sum}")
