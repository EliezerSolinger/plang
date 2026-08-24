#!/usr/bin/env bash
# pstudio-build.sh — the BUILD ENGINE inside the editor (F6).
#
# F6 promises that the editor does not talk to a build process: it imports the
# engine (`packages/pforge`) and runs it on the same scheduler that handles the
# keyboard. That is a claim which, without this harness, could only be checked by
# looking at a window — and it is exactly the kind of thing that rots unseen.
#
# The descriptor belongs to the PROJECT and the editor does not know it (nor
# should it: it opens any tree). Who knows it is that tree's `pforge`, so the
# editor asks IT for the graph and runs it. The serialization is the price of the
# editor serving more than one project.
set -u
cd "$(dirname "$0")/.."

PSTUDIO=${PSTUDIO:-build/bin/pstudio}
ok=0; fail=0
check() { if [ "$2" = "$3" ]; then ok=$((ok+1)); else echo "  FAIL $1: expected '$2', got '$3'"; fail=$((fail+1)); fi; }

[ -x "$PSTUDIO" ] || { echo "   pstudio-build: no editor built — skipped"; exit 0; }

# 1. a small target: it builds, and says how many edges
got=$("$PSTUDIO" --build build/bin/verdict 2>&1 | head -1)
case $got in
    "build ok"*|"nothing to do") ok=$((ok+1)) ;;
    *) echo "  FAIL a simple target: got '$got'"; fail=$((fail+1)) ;;
esac

# 2. the graph came whole (the editor asks pforge for it and runs it with the engine)
n=$("$PSTUDIO" --build build/bin/verdict 2>&1 | grep -oE 'targets in the graph: [0-9]+' | grep -oE '[0-9]+')
if [ "${n:-0}" -gt 100 ]; then ok=$((ok+1)); else echo "  FAIL the graph should have hundreds of targets, got ${n:-0}"; fail=$((fail+1)); fi

# 3. a target that does not exist is a message, and the status says it failed
"$PSTUDIO" --build nosuchtarget >/dev/null 2>&1 && { echo "  FAIL a nonexistent target should fail"; fail=$((fail+1)); } || ok=$((ok+1))
msg=$("$PSTUDIO" --build nosuchtarget 2>&1 | head -1)
case $msg in
    *"unknown target"*) ok=$((ok+1)) ;;
    *) echo "  FAIL the message did not say the target is unknown: '$msg'"; fail=$((fail+1)) ;;
esac

# 5. the PLAY: it builds and LAUNCHES the program, and can then kill it. That is
#    the other half of F6, and the one that needed a new primitive (`os.spawn`).
got2=$("$PSTUDIO" --run build/bin/verdict 2>&1 | tail -1)
check "play launches the program" "launched True" "$got2"

# 6. THE MANIFEST (what was left of F6). The "panel" is not a form: it is the
#    palette doing the two things that are annoying to write by hand and easy to
#    write wrong — choosing a default target that EXISTS, and adding a
#    dependency, which you do not write but resolve. Editing the rest of
#    `pack.json` is opening `pack.json`, which is what a text editor does.
MT=$(mktemp -d)
cat > "$MT/pack.json" <<'EOF'
{
  "members": ["nothing"],
  "default": "build/bin/old",
  "deps": {}
}
EOF
got3=$("$PSTUDIO" --manifest "$MT" 2>&1)
case $got3 in
    *"in the manifest True"*) ok=$((ok+1)) ;;
    *) echo "  FAIL the default target was not written:"; echo "$got3" | head -4; fail=$((fail+1)) ;;
esac
case $got3 in
    *"only once 1 and it is the new one True"*) ok=$((ok+1)) ;;
    *) echo "  FAIL the existing key should be REPLACED, not repeated"; fail=$((fail+1)) ;;
esac
case $got3 in
    *"and it wrote nothing True"*) ok=$((ok+1)) ;;
    *) echo "  FAIL a dependency that does not resolve cannot enter the manifest"; fail=$((fail+1)) ;;
esac
# and the rest of the file stayed as it was — that is the promise that makes this
# usable on a file somebody commits
grep -q '"members": \["nothing"\]' "$MT/pack.json" && ok=$((ok+1)) || { echo "  FAIL the rest of pack.json did not survive"; cat "$MT/pack.json"; fail=$((fail+1)); }
rm -rf "$MT"

echo "   pstudio-build: $ok ok, $fail failed"
[ $fail = 0 ]
