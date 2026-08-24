#!/usr/bin/env bash
# theme.sh — nobody writes a colour outside the theme.
#
# The rule the theme was built on is only worth having if it is checked: "no
# layer uses a colour directly". A widget written next month with one hard-coded
# hex is a widget that will not follow a theme, and nothing else would notice —
# it would simply look wrong in the light theme and right in the dark one, which
# is the kind of bug nobody files.
#
# So it is a `grep`. It is the cheapest gate in the suite and it defends one of
# the two rules that were laid down as permanent.
set -u
cd "$(dirname "$0")/.."

ok=0; fail=0

# Where a colour may be written down. One file.
THEME=packages/pui/theme.psc

# Where it may not: the toolkit and both editors.
SEARCH="packages/pui/pui.psc pstudio/pui*.psc pstudio/*.psc"

for f in $SEARCH; do
    [ -f "$f" ] || continue
    [ "$f" = "$THEME" ] && continue
    case $f in *_test.psc) continue ;; esac      # a test may name a colour it checks
    hits=$(grep -nE '0x[0-9A-Fa-f]{8}' "$f" || true)
    if [ -z "$hits" ]; then
        ok=$((ok+1))
    else
        echo "  FAIL $f writes a colour instead of asking for a role:"
        echo "$hits" | sed 's/^/       /' | head -5
        fail=$((fail+1))
    fi
done

# and the theme itself has to HAVE the roots, or the rule is decoration
for r in surface on_surface primary danger warning ok string keyword; do
    grep -qE "^    $r: int" "$THEME" && ok=$((ok+1)) || {
        echo "  FAIL the root '$r' is gone from $THEME"; fail=$((fail+1)); }
done

echo "   theme: $ok ok, $fail failed  (no colour literal outside $THEME)"
[ $fail = 0 ]
