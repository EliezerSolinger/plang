#!/usr/bin/env bash
# psbuild.sh — turn ONE .psc into a binary, the same way tests/run.sh does.
#
#   bash tests/psbuild.sh <src.psc> <out-binary> [extra cc flags...]
#
# It exists because three different harnesses now need exactly this and none of
# them should be re-deriving the recipe: the conformance corpora
# (tests/conformance), the differential oracles (tests/js-compare.sh,
# tests/py-compare.sh) and the side-by-side scoreboard (tests/bench.sh).
#
# The one thing worth knowing: the runtime (pscript/runtime/psrt.p) is P source
# compiled ALONGSIDE the program (16.4), not a library the compiler links. So a
# build is always two compilations, and the C it produces needs the POSIX
# defines — glibc hides socket/getaddrinfo under a strict `-std=`.
#
# CACHE: the runtime C is generated once per out-dir and reused, because
# regenerating it for each of 318 JSON files would dominate the wall clock.
#
# 108/111: o runtime são SEIS módulos em camadas (memória, valores, o que roda,
# a biblioteca, o sistema, o epílogo) mais o header de tipos. O programa gerado
# continua incluindo UM header — `psrt.ph` é o guarda-chuva.
set -eu
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-build/bin/plangc_s2}
CC=${CC:-cc}
CSTD=${CSTD:--std=c11}
CCOPT=${CCOPT:--O0}
PSDEFS="-D_POSIX_C_SOURCE=200112L -D_DEFAULT_SOURCE"
RT=${PSBUILD_RT:-tests/out/psbuild-rt}

src=$1; out=$2; shift 2

mkdir -p "$RT"
# 1.5(a): o guarda-chuva basta. `psrt.ph` importa os headers das seis camadas e
# cada um tem o `.p` irmão, então nomear UM arquivo traz o runtime inteiro — era
# a última cópia desta lista a viver num arreio.
RTSRC="pscript/runtime/psrt.ph"
RTC=""
for c in psrt_mem.c psrt_val.c psrt_rt.c psrt_std.c psrt_os.c psrt_top.c; do RTC="$RTC $RT/pscript/runtime/$c"; done
# O CACHE DO RUNTIME, e a armadilha que ele tinha: a condição era "o arquivo
# existe", então mexer no runtime e correr um arreio que reusa o mesmo `$RT`
# dava um link a falhar por um símbolo que o `.c` velho não tem. Custou uma
# investigação; a condição agora é a data.
regen=0
[ -f "$RT/pscript/runtime/psrt_mem.c" ] || regen=1
if [ $regen = 0 ]; then
    for f in pscript/runtime/*.p pscript/runtime/*.ph; do
        [ "$f" -nt "$RT/pscript/runtime/psrt_mem.c" ] && { regen=1; break; }
    done
fi
[ $regen = 1 ] && $PLANGC --pkg-path packages --out-dir "$RT" $RTSRC

$PLANGC --pkg-path packages --out-dir "$RT" "$src"

# `import "x.ph"` (75.3) e a 1.5(a) fazem o compilador emitir MÓDULOS EM P junto
# com o programa — o do lado (`pmod_x.p`) e o de um PACOTE (`packages/sha2/sha2.p`).
# Quais são não se adivinha por glob: pergunta-se (resposta 3), que é a mesma
# fonte que o `pbuild` usa. O glob que havia aqui só via `pmod_*.c` ao lado do
# fonte, e um programa que usasse um pacote em P não linkava.
extra=""
for pm in $($PLANGC --pkg-path packages --outputs --out-dir "$RT" "$src" | grep '\.c$'); do
    case " $RTC " in *" $pm "*) continue;; esac
    [ "$pm" = "$RT/${src%.psc}.c" ] && continue
    [ -f "$pm" ] && extra="$extra $pm"
done

$CC $CSTD $CCOPT $PSDEFS -w "$RT/${src%.psc}.c" $RTC \
    $extra -o "$out" "$@" -lm -pthread
