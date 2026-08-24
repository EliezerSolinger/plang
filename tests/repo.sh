#!/usr/bin/env bash
# repo.sh — the whole REPOSITORY, end to end, with no network.
#
# What is pinned down here is the complete round trip `pforge/REPOSITORIO.md`
# draws:
#
#     publish  ->  a `.tar` and an index entry, in a directory
#     update   ->  the index stored, and the repository accepted into the lock (TOFU)
#     search   ->  offline, by name, description and SYMBOL
#     add      ->  the hash checked, the lock written, the dependencies alongside
#     install  ->  the tree unpacked into build/pkg/<name>-<version>-<hash>/
#     compile  ->  a program that uses the installed package, and RUNS
#
# A repository is a FORMAT, not a service: here it is a directory and the
# transport is `file://`. When HTTP comes in, it comes in underneath `fetch` and
# none of this changes — that is the property this test fixes.
#
# And it also fixes the one that matters most: the hash is NEVER waived. The last
# case corrupts one byte of the tarball in the store and demands that `install`
# refuse.
set -u
cd "$(dirname "$0")/.."

PFORGE=${PFORGE:-build/bin/pforge}
PLANGC=${PLANGC:-build/bin/plangc_s2}
CC=${CC:-cc}
OUT=${OUT:-tests/out/repo}
PSDEFS="-D_POSIX_C_SOURCE=200112L -D_DEFAULT_SOURCE"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); printf '   FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$2', got '$3'"; fi; }

ROOT=$PWD
# the tools become ABSOLUTE once, here: this test changes directory several times
# on purpose (a project that has nothing but a manifest is the point), and a path
# relative to `$PWD` would stop being valid at the first `cd`. That is what
# happened when `verify-all` passed them already absolute and the script prefixed
# them again.
case $PFORGE in /*) ;; *) PFORGE=$ROOT/$PFORGE;; esac
case $PLANGC in /*) ;; *) PLANGC=$ROOT/$PLANGC;; esac
rm -rf "$OUT"; mkdir -p "$OUT/repo" "$OUT/proj"

# ---- 1. publish: two packages of this repository become tarballs ----
"$PFORGE" publish stl  --to "$OUT/repo" >"$OUT/pub1.log" 2>&1 || bad "publish stl"
"$PFORGE" publish sha2 --to "$OUT/repo" >"$OUT/pub2.log" 2>&1 || bad "publish sha2"
[ -f "$OUT/repo/index.json" ] && ok || bad "publish did not write the index"
[ -f "$OUT/repo/pkg/sha2/sha2-0.1.0.tar" ] && ok || bad "publish did not write the tarball"

# the system's `tar` opens ours — the reason for being a real tar
if command -v tar >/dev/null 2>&1; then
    n=$(tar tf "$OUT/repo/pkg/sha2/sha2-0.1.0.tar" | grep -c 'sha2-0.1.0/')
    [ "$n" -ge 4 ] && ok || bad "the system tar listed $n members"
fi

# a published version is IMMUTABLE
if "$PFORGE" publish sha2 --to "$OUT/repo" >"$OUT/pub3.log" 2>&1; then
    bad "republishing the same version should be refused"
else ok; fi

# ---- 2. a project that has nothing but a manifest ----
cd "$OUT/proj"
cat > pack.json <<EOF
{
  "members": ["nothing"],
  "repos": [{"url": "file://$ROOT/$OUT/repo/", "unsafe": true}]
}
EOF

"$PFORGE" update >update.log 2>&1 || bad "update"
grep -q "TOFU" update.log && ok || bad "the first update should say it accepted the repository"
[ -f pack.lock ] && ok || bad "update did not write the lock"

# ---- 3. search, offline and by symbol ----
"$PFORGE" search sha256_hex >search.log 2>&1
grep -q '\[symbol\]' search.log && ok || bad "search did not find by symbol"
"$PFORGE" search nosuchthing >search2.log 2>&1 && bad "a search for nothing should fail" || ok

# ---- 4. add: the hash checks out, and the dependency comes along ----
"$PFORGE" add sha2@0.1.0 >add.log 2>&1 || bad "add"
grep -q "^stl 0.1.0" add.log && ok || bad 'stl should come as a dependency of sha2'
grep -q '"unsafe": true' pack.lock && ok || bad "the lock should record unsafe mode"
grep -q '"sha2": "0.1.0"' pack.json && ok || bad "add should write the dependency into the manifest"

# with no exact version: a message, not a search
"$PFORGE" add sha2 >add2.log 2>&1 && bad "add with no version should be refused" || ok

# ---- 5. install: the tree unpacked ----
"$PFORGE" install >install.log 2>&1 || bad "install"
d=$(ls -d build/pkg/sha2-0.1.0-* 2>/dev/null | head -1)
[ -f "$d/sha2/sha2.ph" ] && ok || bad "install did not unpack the sha2 tree"
ls -d build/pkg/stl-0.1.0-* >/dev/null 2>&1 && ok || bad "install did not unpack stl"

# ---- 6. and a program that uses it COMPILES and RUNS ----
cat > use.psc <<'EOF'
import <sha2/sha2.ph>
b: List<u8> = []
for ch in "abc":
    b.append(u8(ord(ch)))
print(sha256_of(b))
EOF
ROOTS=""
for x in build/pkg/*/; do case "$x" in build/pkg/.*) ;; *) ROOTS="$ROOTS --pkg-path ${x%/}";; esac; done
mkdir -p rt
# From here on the command runs from plang's ROOT, and everything is named
# relative to it — the program, the package roots and `--ps-runtime`. It is not
# convenience: under `--out-dir` all these paths are mirrored, and the `#include`
# that comes out in the generated C is the relation BETWEEN them. Mixing absolute
# with relative has no relation at all inside the mirror, and the compiler says so
# instead of emitting an include that points outside (it is the same rule packages
# already had).
cd "$ROOT"
PROJ=$OUT/proj
ROOTS=""
for x in "$PROJ"/build/pkg/*/; do case "$(basename "$x")" in .*) ;; *) ROOTS="$ROOTS --pkg-path ${x%/}";; esac; done
mkdir -p "$PROJ/rt"
if "$PLANGC" $ROOTS --ps-runtime pscript/runtime --out-dir "$PROJ/rt" pscript/runtime/psrt.ph >"$PROJ/gen.log" 2>&1 \
   && "$PLANGC" $ROOTS --ps-runtime pscript/runtime --out-dir "$PROJ/rt" "$PROJ/use.psc" >>"$PROJ/gen.log" 2>&1; then ok; else bad "it did not compile against the installed package (see $PROJ/gen.log)"; fi
RT=$(find "$PROJ/rt" -name 'psrt_mem.c' | head -1); RTD=$(dirname "$RT")
if $CC -O1 -w $PSDEFS "$PROJ/rt/$PROJ/use.c" "$RTD"/psrt_*.c $(find "$PROJ/rt" -path '*sha2/sha2.c') -o "$PROJ/use" -lm -pthread >"$PROJ/cc.log" 2>&1; then ok; else bad "it did not link (see $PROJ/cc.log)"; fi
got=$("$PROJ/use" 2>&1)
check "the sha256 of abc, through the installed package" \
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$got"

# ---- 7. the hash is NEVER waived ----
cd "$ROOT/$OUT/proj"
rm -rf build/pkg/sha2-0.1.0-*
# the store names each tarball by its sha256, so the one to corrupt is named by
# the lock — picking the first of the directory would corrupt whichever package
# happened to sort first, and that one may not even be reinstalled
h=$(python3 -c "import json;d=json.load(open('pack.lock'));print([p for p in d['packages'] if p['name']=='sha2'][0]['sha256'])")
pak=build/pkg/.pak/$h
printf 'x' | dd of="$pak" bs=1 seek=600 count=1 conv=notrunc status=none
if "$PFORGE" install >install2.log 2>&1; then
    bad "install accepted a tampered tarball"
else
    grep -q "hash does NOT match" install2.log && ok || bad "the refusal did not say it was the hash"
fi

# ---- 8. SAFE MODE: the two signatures ----
#
# There are two, with different owners: the REPOSITORY signs the index (against
# an old list served as if it were today's) and the AUTHOR signs each version
# (against the repository itself serving a tarball the author did not make).
cd "$ROOT"
rm -rf "$OUT/safe" "$OUT/keys" "$OUT/projs"
mkdir -p "$OUT/keys"
"$PFORGE" keygen "$OUT/keys/k" >"$OUT/keygen.log" 2>&1 && ok || bad "keygen"
[ -f "$OUT/keys/k.pub" ] && ok || bad "keygen did not write the public key"
# a key that overwrites itself is a lost key
"$PFORGE" keygen "$OUT/keys/k" >/dev/null 2>&1 && bad "keygen should refuse to overwrite" || ok

"$PFORGE" publish stl  --to "$OUT/safe" --key "$OUT/keys/k" >"$OUT/ps1.log" 2>&1 || bad "signed publish (stl)"
"$PFORGE" publish sha2 --to "$OUT/safe" --key "$OUT/keys/k" >"$OUT/ps2.log" 2>&1 || bad "signed publish (sha2)"
[ -f "$OUT/safe/index.json.sig" ] && ok || bad "the index was not signed"
[ -f "$OUT/safe/pkg/sha2/sha2-0.1.0.tar.sig" ] && ok || bad "the tarball was not signed"

mkdir -p "$OUT/projs"
cd "$OUT/projs"
cat > pack.json <<EOF
{
  "members": ["nothing"],
  "repos": ["file://$ROOT/$OUT/safe/"]
}
EOF
"$PFORGE" update >update.log 2>&1 || bad "update in safe mode"
grep -q "TOFU" update.log && ok || bad "the first time should accept the key (TOFU)"
grep -q '"key": "[0-9a-f]\{64\}"' pack.lock && ok || bad "the key should be RECORDED in the lock"
"$PFORGE" add sha2@0.1.0 >add.log 2>&1 && ok || bad "add in safe mode"
grep -q '"unsafe": false' pack.lock && ok || bad "signed is not unsafe"

# the key is already known: the index does not change in silence
cp "$ROOT/$OUT/safe/index.json" "$ROOT/$OUT/safe/index.json.bak"
sed -i 's/"size": /"size": 1/' "$ROOT/$OUT/safe/index.json"
"$PFORGE" update >u2.log 2>&1 && bad "a swapped index should be refused" || ok
grep -q "key this project accepted" u2.log && ok || bad "the refusal did not mention the key (see $OUT/projs/u2.log)"
mv "$ROOT/$OUT/safe/index.json.bak" "$ROOT/$OUT/safe/index.json"

# a swapped tarball, with the old signature: the hash catches it first
cd "$ROOT"
cp "$OUT/safe/pkg/sha2/sha2-0.1.0.tar" "$OUT/safe/pkg/sha2/sha2-0.1.0.tar.bak"
printf 'x' | dd of="$OUT/safe/pkg/sha2/sha2-0.1.0.tar" bs=1 seek=700 count=1 conv=notrunc status=none
cd "$OUT/projs"
rm -f pack.lock; rm -rf build
cat > pack.json <<EOF
{
  "members": ["nothing"],
  "repos": ["file://$ROOT/$OUT/safe/"]
}
EOF
"$PFORGE" update >/dev/null 2>&1
"$PFORGE" add sha2@0.1.0 >add2.log 2>&1 && bad "a swapped tarball should be refused" || ok
grep -q "hash does NOT match" add2.log && ok || bad "the refusal did not mention the hash"
cd "$ROOT"
mv "$OUT/safe/pkg/sha2/sha2-0.1.0.tar.bak" "$OUT/safe/pkg/sha2/sha2-0.1.0.tar"

# a repository with NO signature and not declaring itself `unsafe`: refusal
mkdir -p "$OUT/projn"
cd "$OUT/projn"
cat > pack.json <<EOF
{
  "members": ["nothing"],
  "repos": ["file://$ROOT/$OUT/repo/"]
}
EOF
"$PFORGE" update >un.log 2>&1 && bad 'a repository with no signature and no unsafe should be refused' || ok
grep -q "unsafe" un.log && ok || bad "the refusal did not say how to declare unsafe"
cd "$ROOT"

# ---- 7b. `up`, the mismatched lock and the invariants ----
#
# Three things the build does not check because they are not its job.
cd "$ROOT"
"$PFORGE" check >check.log 2>&1 && ok || bad "pforge check should pass on this tree"
grep -q "no problems" check.log && ok || bad "check did not say everything was fine"
rm -f check.log

# a `lang: p` package depending on a `pscript` one has to be refused: it is the
# invariant that keeps P free of a runtime ACROSS packages
cp packages/sha2/pack.json "$OUT/sha2-pack.bak"
python3 - <<'PYX'
import json
p = "packages/sha2/pack.json"
d = json.load(open(p))
d["deps"]["pui"] = "0.1.0"
open(p, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PYX
"$PFORGE" check >check2.log 2>&1 && bad "a P package pulling in a pscript one should be refused" || ok
grep -q "drags the runtime along" check2.log && ok || bad "the refusal did not explain why"
cp "$OUT/sha2-pack.bak" packages/sha2/pack.json
rm -f check2.log

# `up` goes up to the highest the index has, and the manifest stays JSON
cd "$ROOT/$OUT"
rm -rf projup && mkdir projup && cd projup
cat > pack.json <<EOF
{
  "members": ["nothing"],
  "repos": [{"url": "file://$ROOT/$OUT/repo/", "unsafe": true}]
}
EOF
"$PFORGE" update >/dev/null 2>&1
"$PFORGE" add sha2@0.1.0 >/dev/null 2>&1 && ok || bad "add in the up project"
# TWO versions of the same package in the repository: that is what gives `up`
# something to choose from, and it is the only way to measure that it picks the
# highest
cd "$ROOT"
"$PFORGE" publish tar --to "$OUT/repo" >/dev/null 2>&1
python3 - <<'PYX'
import json
p = "packages/tar/pack.json"
d = json.load(open(p))
d["version"] = "0.2.0"
open(p, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PYX
"$PFORGE" publish tar --to "$OUT/repo" >/dev/null 2>&1
python3 - <<'PYX'
import json
p = "packages/tar/pack.json"
d = json.load(open(p))
d["version"] = "0.1.0"
open(p, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PYX
cd "$ROOT/$OUT/projup"
"$PFORGE" update >/dev/null 2>&1
"$PFORGE" add tar@0.1.0 >addtar.log 2>&1 && ok || bad "add tar@0.1.0 (see $OUT/projup/addtar.log)"
"$PFORGE" up >up.log 2>&1 && ok || bad "pforge up"
grep -q "0.1.0 -> 0.2.0" up.log && ok || bad "up did not raise the version"
python3 -c "import json,sys; d=json.load(open('pack.json')); sys.exit(0 if d['deps']['tar']=='0.2.0' else 1)" && ok || bad "the manifest did not end up with the new version (or stopped being JSON)"

# the TOOLCHAIN RANGE: checked before spending a second compiling
cd "$ROOT"
python3 - <<'PYX'
import json
p = "packages/tar/pack.json"
d = json.load(open(p))
d["toolchain"] = ">= 9.9.9"
d["version"] = "0.3.0"
open(p, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PYX
"$PFORGE" publish tar --to "$OUT/repo" >/dev/null 2>&1
python3 - <<'PYX'
import json
p = "packages/tar/pack.json"
d = json.load(open(p))
d["toolchain"] = ">= 0.1.0"
d["version"] = "0.1.0"
open(p, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PYX
cd "$ROOT/$OUT/projup"
"$PFORGE" update >/dev/null 2>&1
"$PFORGE" add tar@0.3.0 --query "$PLANGC" >tc.log 2>&1 && bad "a package requiring a compiler that does not exist should be refused" || ok
grep -q "requires plangc >= 9.9.9" tc.log && ok || bad "the refusal did not state the range and the version"

# the lock mismatched with the manifest: it warns, and with --frozen it refuses
python3 - <<'PYX'
import json
d = json.load(open("pack.json"))
d["deps"]["doesnotexist"] = "9.9.9"
open("pack.json", "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PYX
"$PFORGE" install >inst.log 2>&1
grep -q "does not match pack.json" inst.log && ok || bad "install should warn about the mismatched lock"
"$PFORGE" install --frozen >inst2.log 2>&1 && bad "--frozen should refuse" || ok
cd "$ROOT"

# ---- 8b. `--json`: the SAME data, for whoever is not a person ----
#
# The IDE and a script consume this; the escaper is the graph's, so that there is
# no second place to get it wrong. The test does not check the text — it checks
# that it is JSON, and who says so is `python3`.
cd "$ROOT/$OUT/projs"
if command -v python3 >/dev/null 2>&1; then
    "$PFORGE" search sha256 --json > s.json 2>/dev/null
    python3 -c "import json,sys; d=json.load(open('s.json')); sys.exit(0 if isinstance(d, list) and len(d) > 0 and 'name' in d[0] else 1)" && ok || bad "search --json is not a list of objects"
    "$PFORGE" install --json > i.json 2>/dev/null
    python3 -c "import json,sys; json.load(open('i.json'))" && ok || bad "install --json is not JSON"
fi
cd "$ROOT"

# ---- 9. THE SAME PATH, OVER HTTP ----
#
# Nothing above changes: the transport is an `if` inside `fetch`, and the rest of
# the manager does not know where the bytes came from. The server is python's
# `http.server`, which is precisely the point — a repository is a directory served
# by anything.
cd "$ROOT"
if command -v python3 >/dev/null 2>&1; then
    # the port is chosen by the system (bind on 0) and written to a file: a
    # fixed number here makes two test trees serve each other, and the mistake
    # only shows up as a 404 in the wrong place
    rm -f "$ROOT/$OUT/httpd.port"
    ( cd "$OUT/repo" && exec python3 -c '
import http.server, socketserver, sys
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
srv = socketserver.TCPServer(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
' "$ROOT/$OUT/httpd.port" >/dev/null 2>&1 ) &
    echo $! > "$ROOT/$OUT/httpd.pid"
    # wait for the server to answer, instead of sleeping a magic number
    i=0
    while [ $i -lt 100 ] && [ ! -s "$ROOT/$OUT/httpd.port" ]; do i=$((i+1)); sleep 0.1; done
    PORT=$(cat "$ROOT/$OUT/httpd.port" 2>/dev/null)
    if [ -z "$PORT" ]; then bad "the HTTP server did not come up"; PORT=0; fi
    i=0
    while [ $i -lt 50 ] && ! (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; do i=$((i+1)); sleep 0.1; done
    mkdir -p "$OUT/proj-http"
    cd "$OUT/proj-http"
    cat > pack.json <<EOF
{
  "members": ["nothing"],
  "repos": [{"url": "http://127.0.0.1:$PORT/", "unsafe": true}]
}
EOF
    "$PFORGE" update >update.log 2>&1 && ok || bad "update over HTTP"
    "$PFORGE" add sha2@0.1.0 >add.log 2>&1 && ok || bad "add over HTTP"
    "$PFORGE" install >install.log 2>&1 && ok || bad "install over HTTP"
    ls -d build/pkg/sha2-0.1.0-* >/dev/null 2>&1 && ok || bad "the tree did not come out of the tarball downloaded over HTTP"
    # and the hash is the SAME one that came over file:// — that is what makes
    # the transport not matter
    h1=$(grep -o '"sha256": "[0-9a-f]*"' pack.lock | head -1)
    h2=$(grep -o '"sha256": "[0-9a-f]*"' "$ROOT/$OUT/proj/pack.lock" | head -1)
    check "the same package, the same hash, another transport" "$h2" "$h1"
    # a path that does not exist: HTTP 404, and the message has to say so
    "$PFORGE" update >/dev/null 2>&1
    sed -i "s#127.0.0.1:$PORT/#127.0.0.1:$PORT/doesnotexist/#" pack.json
    "$PFORGE" update >u404.log 2>&1 && bad "an index that does not exist should fail" || ok
    grep -q "404" u404.log && ok || bad "the HTTP failure did not state the status (see $OUT/proj-http/u404.log)"
    cd "$ROOT"
    pkill -P "$(cat "$OUT/httpd.pid")" 2>/dev/null
    kill "$(cat "$OUT/httpd.pid")" 2>/dev/null
    rm -f "$OUT/httpd.pid" "$OUT/httpd.port"
fi

# ---- 10. PUBLISH'S REFUSALS ----
#
# Three cases where publishing would be publishing something that is no use, and
# none of them needs a new mechanism: the index already carries the dependencies,
# the manifest already says the language, and the API's canonical list is already
# computed to go into the index. Checking is comparing.
cd "$ROOT"
FAKE=$OUT/fake
rm -rf "$FAKE"; mkdir -p "$FAKE/empty"

# (a) a dependency the destination repository does not resolve. `sha2` depends on
# `stl`; in an empty repository it does not exist.
if "$PFORGE" publish sha2 --to "$FAKE/empty" >"$FAKE/dep.log" 2>&1; then
    bad "publishing with a dependency the destination does not have should be refused"
else ok; fi
grep -q "publish it first" "$FAKE/dep.log" && ok || bad "the dependency refusal did not say what to do"
[ -f "$FAKE/empty/index.json" ] && bad "the refusal wrote into the repository" || ok

# (b) a `.psc` inside a package declared `p` — and what is in `test/` does NOT
# count, which is how `sha2` proves the boundary crossing from pscript
mkdir -p "$FAKE/pkg/pmod"
cat > "$FAKE/pkg/pack.json" <<'EOF'
{ "name": "pmixed", "version": "0.1.0", "lang": "p", "root": "pmixed.ph" }
EOF
cat > "$FAKE/pkg/pmixed.ph" <<'EOF'
def pmixed_dois() -> i32
EOF
cat > "$FAKE/pkg/pmixed.p" <<'EOF'
import "pmixed.ph"
def pmixed_dois() -> i32:
    return 2
EOF
mkdir -p "$FAKE/repo2"
"$PFORGE" publish "$FAKE/pkg" --to "$FAKE/repo2" >"$FAKE/p1.log" 2>&1 && ok || bad "a simple P package should publish (see $FAKE/p1.log)"
mkdir -p "$FAKE/pkg/test"
echo 'print("hi")' > "$FAKE/pkg/test/t.psc"
rm -rf "$FAKE/repo3"; mkdir -p "$FAKE/repo3"
"$PFORGE" publish "$FAKE/pkg" --to "$FAKE/repo3" >"$FAKE/p2.log" 2>&1 && ok || bad "a .psc in test/ should NOT block it (see $FAKE/p2.log)"
echo 'x: int = 1' > "$FAKE/pkg/extra.psc"
rm -rf "$FAKE/repo4"; mkdir -p "$FAKE/repo4"
if "$PFORGE" publish "$FAKE/pkg" --to "$FAKE/repo4" >"$FAKE/p3.log" 2>&1; then
    bad "a .psc OUTSIDE test/ in a `lang: p` package should be refused"
else ok; fi
grep -q "extra.psc" "$FAKE/p3.log" && ok || bad "the refusal did not name the file"
rm -f "$FAKE/pkg/extra.psc"

# (c) the version goes up and the interface does not match what the bump
# promises. A `patch` says "nothing changed"; a `minor` says "I only added".
sed -i 's/"version": "0.1.0"/"version": "0.1.1"/' "$FAKE/pkg/pack.json"
cat > "$FAKE/pkg/pmixed.ph" <<'EOF'
def pmixed_dois() -> i32
def pmixed_tres() -> i32
EOF
cat > "$FAKE/pkg/pmixed.p" <<'EOF'
import "pmixed.ph"
def pmixed_dois() -> i32:
    return 2
def pmixed_tres() -> i32:
    return 3
EOF
if "$PFORGE" publish "$FAKE/pkg" --to "$FAKE/repo2" >"$FAKE/p4.log" 2>&1; then
    bad "a patch with a changed interface should be refused"
else ok; fi
grep -q "patch" "$FAKE/p4.log" && ok || bad "the patch refusal did not say why"
# the same change as a MINOR passes: adding is what a minor promises
sed -i 's/"version": "0.1.1"/"version": "0.2.0"/' "$FAKE/pkg/pack.json"
"$PFORGE" publish "$FAKE/pkg" --to "$FAKE/repo2" >"$FAKE/p5.log" 2>&1 && ok || bad "a minor that ADDS should publish (see $FAKE/p5.log)"
# Taking away in a minor: allowed WHILE THE MAJOR IS 0, and it says so.
#
# Semver clause 4 — "anything MAY change at any time" before 1.0 — and by
# convention the minor is the slot that carries the break. Cargo does the same.
# Refusing it would mean a library cannot correct its own interface before its
# first stable release, which is what the pre-1.0 period is FOR.
#
# The WARNING is the point of the case: an exception nobody sees is a rule
# nobody knows they are relying on.
sed -i 's/"version": "0.2.0"/"version": "0.3.0"/' "$FAKE/pkg/pack.json"
cat > "$FAKE/pkg/pmixed.ph" <<'EOF'
def pmixed_tres() -> i32
EOF
cat > "$FAKE/pkg/pmixed.p" <<'EOF'
import "pmixed.ph"
def pmixed_tres() -> i32:
    return 3
EOF
"$PFORGE" publish "$FAKE/pkg" --to "$FAKE/repo2" >"$FAKE/p6.log" 2>&1 && ok || bad "0.x: a minor that takes away should publish (see $FAKE/p6.log)"
grep -q "warning" "$FAKE/p6.log" && ok || bad "the 0.x exception has to WARN, not go quiet"
grep -q "the major is 0" "$FAKE/p6.log" && ok || bad "the warning should say why it was allowed"

# and past 1.0 the rule bites again: a major may change whatever it likes...
sed -i 's/"version": "0.3.0"/"version": "1.0.0"/' "$FAKE/pkg/pack.json"
"$PFORGE" publish "$FAKE/pkg" --to "$FAKE/repo2" >"$FAKE/p7.log" 2>&1 && ok || bad "a major should publish (see $FAKE/p7.log)"
# ... and then a minor may not take away
sed -i 's/"version": "1.0.0"/"version": "1.1.0"/' "$FAKE/pkg/pack.json"
cat > "$FAKE/pkg/pmixed.ph" <<'EOF'
def pmixed_quatro() -> i32
EOF
cat > "$FAKE/pkg/pmixed.p" <<'EOF'
import "pmixed.ph"
def pmixed_quatro() -> i32:
    return 4
EOF
if "$PFORGE" publish "$FAKE/pkg" --to "$FAKE/repo2" >"$FAKE/p8.log" 2>&1; then
    bad "after 1.0, a minor that TAKES AWAY should be refused"
else ok; fi
grep -q "a minor adds, it does not take away" "$FAKE/p8.log" && ok || bad "the minor refusal did not say why"

# ---- 11. `pforge lock`: the lock from the manifest, without building ----
cd "$ROOT/$OUT/proj"
cp pack.lock lock.before
# take a line out of the lock and ask for it to be redone: it comes back to what
# the manifest asks for
python3 - <<'PY2'
import json
d = json.load(open("pack.lock"))
d["packages"] = [p for p in d["packages"] if p["name"] != "stl"]
json.dump(d, open("pack.lock", "w"), indent=2)
PY2
"$PFORGE" lock >lock.log 2>&1 && ok || bad "pforge lock (see $OUT/proj/lock.log)"
grep -q '"name": "stl"' pack.lock && ok || bad "the redone lock did not bring stl back"
# and now it does match: `--frozen` accepts
"$PFORGE" lock --frozen >lock2.log 2>&1 && ok || bad "--frozen should accept an up-to-date lock"
# a manifest asking for a version the lock does not have: `--frozen` refuses
sed -i 's/"sha2": "0.1.0"/"sha2": "0.9.9"/' pack.json
"$PFORGE" lock --frozen >lock3.log 2>&1 && bad "--frozen should refuse a stale lock" || ok
grep -q "frozen" lock3.log && ok || bad "the --frozen refusal did not explain itself"
sed -i 's/"sha2": "0.9.9"/"sha2": "0.1.0"/' pack.json

# ---- 12. a BARE tarball: no repository, no index, no resolution ----
#
# *"porque não um tar sem um repo definido? mesmo que entre como usuário"*. The
# tarball IS the package: it carries its own `pack.json`, so there is nothing to
# resolve — what happens is that the bytes are hashed, kept under that hash, and
# written into the lock with where they came from.
#
# It is `unsafe` unless somebody names the AUTHOR, and that is the honest part: a
# `.sig` beside a file proves that whoever made the signature made the signature.
# A repository is what adds a NAME to check it against.
mkdir -p "$ROOT/$OUT/bare"
cd "$ROOT/$OUT/bare"
cat > pack.json <<EOF
{"members": ["nothing"]}
EOF
TARB="$ROOT/$OUT/repo/pkg/sha2/sha2-0.1.0.tar"

# without --unsafe and without --author it is REFUSED, and it says why
"$PFORGE" add "$TARB" >bare1.log 2>&1 && bad "a bare tarball with nobody to check it should be refused" || ok
grep -q "author" bare1.log && ok || bad "the refusal should name --author"

# with --unsafe it goes in, and the lock says so
"$PFORGE" add "$TARB" --unsafe >bare2.log 2>&1 || bad "add of a bare tarball (see $OUT/bare/bare2.log)"
grep -q '"name": "sha2"' pack.lock && ok || bad "the bare tarball did not reach the lock"
grep -q '"unsafe": true' pack.lock && ok || bad "a tarball nobody signed has to be recorded unsafe"
grep -q '"sha2": "0.1.0"' pack.json && ok || bad "add should write the dependency into the manifest"
# the version came from INSIDE the tarball: nobody typed it
grep -q '"version": "0.1.0"' pack.lock && ok || bad "the version should come from the tarball's own pack.json"
# and the hash is the same one the repository published
want=$(python3 -c "import json;d=json.load(open('$ROOT/$OUT/repo/index.json'));print(d['packages']['sha2']['0.1.0']['sha256'])" 2>/dev/null)
got=$(python3 -c "import json;d=json.load(open('pack.lock'));print([p for p in d['packages'] if p['name']=='sha2'][0]['sha256'])" 2>/dev/null)
check "the hash of a bare tarball" "$want" "$got"

# a file that is not a package is refused for the right reason
head -c 2048 /dev/urandom > notapackage.tar
"$PFORGE" add ./notapackage.tar --unsafe >bare3.log 2>&1 && bad "a tar with no pack.json should be refused" || ok
grep -q "not read this as a package" bare3.log && ok || bad "the refusal should name the file that was wrong"

# a URL takes the same path (`file://` is the transport that needs no network),
# and adding the same package twice REPLACES its line instead of doubling it
"$PFORGE" add "file://$TARB" --unsafe >bare4.log 2>&1 || bad "add by file:// URL (see $OUT/bare/bare4.log)"
n=$(python3 -c "import json;d=json.load(open('pack.lock'));print(len([p for p in d['packages'] if p['name']=='sha2']))" 2>/dev/null)
check "adding twice leaves one line" "1" "$n"

cd "$ROOT"
echo "   repo: $pass ok, $fail failed"
[ $fail = 0 ]
