#!/usr/bin/env bash
# decouple.sh — the proof that `pcode` and `pstudio` are two programs.
#
# The editor was split so that the layers below the IDE could be shown to be
# separable, and a claim like that rots the moment nobody measures it. In three
# months somebody adds one `import` for one good reason, `pcode` links the build
# engine, and the only thing that changes is a number nobody looks at.
#
# So it is measured, and by the compiler rather than by reading: `plangc --deps`
# answers what a compilation READ, transitively, which is exactly the question.
#
# The list is a WHITELIST and not a blacklist. A blacklist names what may not
# come in, and a module invented next month with another name walks past it; a
# whitelist names what may, and anything else fails until somebody decides it
# belongs. It will be annoying one day, and that day is the point.
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-build/bin/plangc_s2}
ok=0; fail=0

# What `pcode` is allowed to read. Twenty-six files: the editor's own six
# modules, the two P adapters (SDL and the compiler's lexer), the graphics
# driver, the font atlas, the toolkit, two `stl` headers, and the four the
# compiler's lexer needs.
ALLOWED="
pstudio/pcode.psc
pstudio/driver.psc
pstudio/shell.psc
pstudio/codeview.psc
pstudio/core.psc
pstudio/highlight.psc
pstudio/complete.psc
pstudio/shim.p
pstudio/shim.ph
pstudio/hl.p
pstudio/hl.ph
pstudio/pgfx.p
pstudio/pgfx.ph
pstudio/pgfx_raster.p
pstudio/pgfx_raster.ph
pstudio/font_atlas.p
pstudio/font_atlas.ph
pstudio/font_atlas.bin
packages/pui/pui.psc
packages/stl/cstr.p
packages/stl/cstr.ph
packages/stl/vec.ph
selfhost/lexer.p
selfhost/lexer.ph
selfhost/plang.ph
selfhost/ast.ph
"

deps() { $PLANGC --pkg-path packages --deps "$1" 2>/dev/null | sort; }

pcode=$(deps pstudio/pcode.psc)
studio=$(deps pstudio/pstudio.psc)

if [ -z "$pcode" ]; then
    echo "  FAIL could not ask the compiler what pcode reads"
    echo "   decouple: 0 ok, 1 failed"
    exit 1
fi

# 1. nothing outside the list
for f in $pcode; do
    case " $(echo $ALLOWED) " in
        *" $f "*) ok=$((ok+1)) ;;
        *) echo "  FAIL pcode reads '$f', which is not on the list."
           echo "       Either the import does not belong in the editor, or the list in"
           echo "       tests/decouple.sh has to say why it does."
           fail=$((fail+1)) ;;
    esac
done

# 2. and nothing on the list that stopped being read — a list that outlives what
#    it describes stops being a measurement and becomes decoration
for f in $ALLOWED; do
    echo "$pcode" | grep -qx "$f" || { echo "  FAIL '$f' is on the list and is no longer read: remove it"; fail=$((fail+1)); }
done

# 3. the IDE and the engine are on the OTHER side. Without this the gate would
#    pass on the day somebody deleted the IDE.
for f in pstudio/ide.psc packages/pforge/build.psc packages/pforge/graph.psc packages/pforge/manifest.psc; do
    if echo "$studio" | grep -qx "$f"; then ok=$((ok+1))
    else echo "  FAIL pstudio does not read '$f' — is there still an IDE?"; fail=$((fail+1)); fi
    if echo "$pcode" | grep -qx "$f"; then echo "  FAIL pcode reads '$f'"; fail=$((fail+1)); else ok=$((ok+1)); fi
done

# 4. and the relation, which holds on its own and needs no list: everything
#    pcode reads, pstudio reads too — except the entry point, which is the one
#    file the two do not share, and is the whole reason there are two of them
for f in $pcode; do
    [ "$f" = "pstudio/pcode.psc" ] && continue
    echo "$studio" | grep -qx "$f" || { echo "  FAIL pcode reads '$f' and pstudio does not"; fail=$((fail+1)); }
done
np=$(echo "$pcode" | wc -l); ns=$(echo "$studio" | wc -l)
if [ "$ns" -gt "$np" ]; then ok=$((ok+1))
else echo "  FAIL pstudio reads $ns files and pcode $np: they are the same program"; fail=$((fail+1)); fi

echo "   decouple: $ok ok, $fail failed  (pcode $np files, pstudio $ns)"
[ $fail = 0 ]
