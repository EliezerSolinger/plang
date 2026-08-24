#!/usr/bin/env bash
# tests/pforge.sh — pforge's ENGINE (F2B), mechanism by mechanism.
#
# The engine is written in pscript (pforge/src/lib_{graph,log,build}.psc) and what
# this harness does is compile it and run the suite that lives next to it — the
# same arrangement as the editor's `pui_test.psc`: the test lives with the module.
#
# What the suite pins down is stated inside it, case by case, but the idea is a
# single one: a build has only one defect that matters, which is NOT redoing what
# changed. Every case here is a way for that to happen.
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-build/bin/plangc_s2}
OUT=tests/out/pforge-bin
mkdir -p "$OUT"

if ! PLANGC="$PLANGC" bash tests/psbuild.sh pforge/src/engine_test.psc "$OUT/engine" 2>"$OUT/build.err"; then
    echo "  FAIL: pforge's engine does not compile"
    head -5 "$OUT/build.err"
    exit 1
fi
rm -rf tests/out/pforge
"$OUT/engine"
rc=$?
[ $rc = 0 ] || exit $rc

# ---- F3: this repository's descriptor, the CLI, and the export ----
# A DRY RUN (`-n`) walks the whole graph without running anything: it proves that
# the descriptor assembles, that the compiler answers the four questions, that
# the graph passes hygiene (no duplicate, no cycle, no orphan input) and that the
# order closes. It costs seconds and covers the whole chain.
if ! PLANGC="$PLANGC" bash tests/psbuild.sh pforge/src/main.psc "$OUT/pforge" 2>"$OUT/pforge.err"; then
    echo "  FAIL: pforge does not compile"
    head -5 "$OUT/pforge.err"
    exit 1
fi
# how many edges the dry run RUNS depends on what is already on disk (it is an
# incremental build like any other); what is demanded here is that it closes
# without complaining about anything — the hygiene errors come out in the fifth
# event, with "error:" in front, and any one of them invalidates the whole graph
if ! "$OUT/pforge" build -n --query "$PLANGC" >"$OUT/dryrun.log" 2>&1; then
    echo "  FAIL: the descriptor's dry run does not close"
    grep -v '^\[' "$OUT/dryrun.log" | head -5
    exit 1
fi
if grep -q '^error:' "$OUT/dryrun.log"; then
    echo "  FAIL: the descriptor's graph does not pass hygiene"
    grep '^error:' "$OUT/dryrun.log" | head -5
    exit 1
fi
echo "   pforge-descriptor: the dry run closes and the graph passes hygiene"

# the export to ninja, over the REAL graph: what is checked here is that it comes
# out, that it comes out the same twice, and that every `$` in the text is
# escaped — the fine quoting has its own cases in the engine's suite
"$OUT/pforge" ninja --query "$PLANGC" > "$OUT/build.ninja" 2>"$OUT/ninja.err" || {
    echo "  FAIL: pforge ninja"; head -3 "$OUT/ninja.err"; exit 1; }
"$OUT/pforge" ninja --query "$PLANGC" > "$OUT/build.ninja.2" 2>/dev/null
if ! cmp -s "$OUT/build.ninja" "$OUT/build.ninja.2"; then
    echo "  FAIL: pforge ninja is not deterministic"; exit 1
fi
rules=$(grep -c '^rule ' "$OUT/build.ninja")
if [ "$rules" -lt 100 ]; then
    echo "  FAIL: the build.ninja came out with $rules rules"; exit 1
fi
if grep '^  command = ' "$OUT/build.ninja" | grep -q '[^$]\$\([^$]\|$\)'; then
    echo "  FAIL: there is a loose \$ in a build.ninja command"; exit 1
fi
echo "   pforge-ninja: $rules rules, deterministic, no loose \$"

# ---- `pforge doc`: documentation of what already exists, generating nothing ----
# The source is the compiler's answer 5, which already carries interface and
# docstring. What is checked here is the whole chain: the compiler answers,
# `lib_api` reads, and `pforge` formats.
d=$("$OUT/pforge" doc tests/cases/docstring.p twice --query "$PLANGC" 2>&1)
case $d in
    *"def twice(i32) -> i32"*"Twice x."*) ;;
    *) echo "  FAIL: pforge doc did not find the docstring"; echo "$d" | head -3; exit 1 ;;
esac
d=$("$OUT/pforge" doc tests/cases/docstring.p --query "$PLANGC" 2>&1)
case $d in
    *"A pair of integers."*) ;;
    *) echo "  FAIL: pforge doc of the whole module"; echo "$d" | head -3; exit 1 ;;
esac
if "$OUT/pforge" doc no_such_target_at_all --query "$PLANGC" >/dev/null 2>&1; then
    echo "  FAIL: pforge doc should refuse a target that does not exist"; exit 1
fi
echo "   pforge-doc: the documentation comes out of --api, and a nonexistent target is refused"

# ---- `--json`: the SAME data, for whoever consumes instead of reading ----
# One object per LINE in the event stream (whoever reads it wants to react while
# the build runs), and a single document for the queries, which are an answer and
# not a stream.
"$OUT/pforge" build -n --json --query "$PLANGC" > "$OUT/ev.jsonl" 2>&1 || true
python3 - "$OUT/ev.jsonl" <<'PY2' || { echo "  FAIL: the event stream is not JSON per line"; exit 1; }
import json, sys
kinds = set()
for ln in open(sys.argv[1]):
    ln = ln.strip()
    if not ln:
        continue
    kinds.add(json.loads(ln)["event"])
assert "plan" in kinds, kinds
assert "done" in kinds, kinds
PY2
"$OUT/pforge" doc --json tests/cases/docstring.p twice --query "$PLANGC" > "$OUT/doc.json" 2>&1
python3 - "$OUT/doc.json" <<'PY2' || { echo "  FAIL: pforge doc --json"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
assert d["name"] == "twice", d
assert "Twice x." in d["doc"], d
PY2
echo "   pforge-json: the event stream and the query come out as JSON"

# ---- `pforge tree` and `pforge why`: the PACKAGE queries ----
# They run over THIS repository's workspace, which stopped being the simple case
# of two independent packages: today there are eight, and one of them (`ed25519`)
# pulls another (`sha2`), which in turn pulls `stl`. That is why what is demanded
# here is the NESTING and not an order of lines — a package that is another's
# dependency appears underneath it, and not as a root. The order of the roots is
# the manifest's, and pinning it here would make adding a package break a test
# that is not about that.
t=$("$OUT/pforge" tree 2>&1)
case $t in
    *"pui 0.1.0"*) ;;
    *) echo "  FAIL: pforge tree"; echo "$t" | head -3; exit 1 ;;
esac
case $t in
    *"ed25519 0.1.0"*"sha2 0.1.0"*"stl 0.1.0"*) ;;
    *) echo "  FAIL: pforge tree did not nest ed25519 -> sha2 -> stl"; echo "$t" | head -12; exit 1 ;;
esac
w=$("$OUT/pforge" why pui 2>&1)
case $w in
    *"pui 0.1.0"*"packages/pui"*) ;;
    *) echo "  FAIL: pforge why"; echo "$w" | head -3; exit 1 ;;
esac
if "$OUT/pforge" why doesnotexist >/dev/null 2>&1; then
    echo "  FAIL: pforge why should refuse a package that does not exist"; exit 1
fi
"$OUT/pforge" tree --json > "$OUT/tree.json" 2>&1
python3 - "$OUT/tree.json" <<'PY2' || { echo "  FAIL: pforge tree --json"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
names = sorted(p["name"] for p in d["packages"])
# the workspace's ROOTS: the members that are not another member's dependency
assert "pui" in names and "pforge" in names and "ed25519" in names, names
PY2
echo "   pforge-packages: tree and why, in text and in JSON"
