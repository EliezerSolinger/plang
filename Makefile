# Plang — build the compiler (plangc) from its committed C seed.
#
# The compiler is written in Plang itself; bootstrap/ holds the C that plangc
# generated from that source, so the whole thing builds with only a C compiler.
#
#   make            # build ./plangc
#   make check      # build, then compile & run a hello-world
#   make test       # full test suite, C backend (tests/run.sh)
#   make test-qbe   # same through the QBE backend (needs qbe/)
#   make test-c89   # same in strict-C89 mode
#   make selfhost   # rebuild plangc from the Plang source (self-host check)
#   make pstudio    # build the editor (pstudio/, needs libsdl2-dev)
#   make clean

CC     ?= cc
CFLAGS ?= -O2 -std=c11

SEED = $(wildcard bootstrap/selfhost/*.c)

plangc: $(SEED)
	$(CC) $(CFLAGS) -w -o $@ $(SEED)

# compile & run a hello-world through the built compiler (C backend)
check: plangc
	@printf 'include <stdio.h>\ndef main() -> int:\n    printf("hello from Plang\\n")\n    return 0\n' > .hello.p
	./plangc .hello.p -o .hello.c
	$(CC) $(CFLAGS) -o .hello .hello.c
	@./.hello
	@rm -f .hello .hello.p .hello.c

# test suites (tests/run.sh): P end-to-end cases, multi-module build, STL,
# and the c-testsuite ported to P. c-suite (C frontend scoreboard) is
# informational: run it explicitly with `bash tests/run.sh c-suite`.
test: plangc
	bash tests/run.sh cases modules stl p-suite errors pscript

test-qbe: plangc
	BACKEND=qbe bash tests/run.sh cases modules stl p-suite errors pscript

test-c89: plangc
	STD=c89 bash tests/run.sh cases modules stl p-suite errors pscript

# the FULL verification battery in one command: bootstrap ladder from the
# committed seed, C fixed point (stage2==stage3), gating suites on C/QBE/C89,
# QBE self-compilation fixed point, scoreboards with regression floors, and
# seed-drift check. Use `make verify-quick` to skip the scoreboards.
verify:
	bash tests/verify-all.sh

verify-quick:
	bash tests/verify-all.sh quick

# rebuild the compiler from its own Plang source using the seed compiler,
# then build that — proves the release still self-hosts on this machine.
# out/ espelha a raiz do projeto (imports relativos ao arquivo resolvem no
# espelho): out/selfhost/*.c+h e out/stl/*.h — os fontes nunca são tocados
selfhost: plangc
	./plangc --out-dir out stl/*.ph selfhost/*.ph selfhost/*.p
	$(CC) $(CFLAGS) -w -o plangc2 out/selfhost/*.c
	@echo "self-host OK: plangc2 rebuilt from Plang source"

# Plang Studio: o editor em P puro (pstudio/). Precisa de libsdl2-dev; o C sai
# em out/ (espelho da raiz: imports relativos resolvem lá) e o binário em
# out/bin/pstudio — a raiz já tem a PASTA pstudio/, daí o out/bin.
PSTUDIO_SRC = pstudio/font_atlas.p pstudio/psys.p pstudio/pgfx_raster.p \
              pstudio/pgfx.p pstudio/pui.p pstudio/core.p pstudio/complete.p \
              pstudio/codeview.p pstudio/app.p pstudio/main.p
PSTUDIO_DEPS = selfhost/lexer.p selfhost/utf8.p selfhost/util.p

# SDL2's headers are NOT on the default include path everywhere: Homebrew puts
# them under /opt/homebrew/include (Apple Silicon) or /usr/local/include (Intel),
# neither of which cc searches. plangc preprocesses `include <SDL2/SDL.h>` with
# its own cc, so it needs the same -I the final compile gets — otherwise the
# ingest fails with "failed to preprocess header 'SDL2/SDL.h'" on macOS while
# building fine on Linux, where /usr/include/SDL2 happens to be found anyway.
# Via PLANGC_CPP so that EVERY plangc invocation is covered, not just this one.
# It also passes -D_REENTRANT along, so the declarations plangc ingests are the
# same ones the C compiler will see.
#
# SDL_cpuinfo.h also pulls in the COMPILER-INTRINSICS headers — immintrin.h on
# x86, arm_neon.h on Apple Silicon — and SDL ships an opt-out for each, meant for
# consumers that do not use SIMD. pstudio is one: no vector type appears anywhere
# in SDL's own API, only in those headers. They are the densest, most
# compiler-specific C in the tree (arm_neon.h is generated, tens of thousands of
# lines of target attributes and builtin aliases) and ingesting it on arm64 macOS
# failed outright. Turning them off also cuts what plangc must parse from ~44k
# lines to under 5k, and the generated C is byte-identical either way.
SDL2_CFLAGS = $(shell pkg-config --cflags sdl2 2>/dev/null)
SDL2_NOSIMD = -DSDL_DISABLE_IMMINTRIN_H -DSDL_DISABLE_MMINTRIN_H \
              -DSDL_DISABLE_XMMINTRIN_H -DSDL_DISABLE_EMMINTRIN_H \
              -DSDL_DISABLE_PMMINTRIN_H -DSDL_DISABLE_ARM_NEON_H \
              -DSDL_DISABLE_MM3DNOW_H -DSDL_DISABLE_LSX_H -DSDL_DISABLE_LASX_H

pstudio: export PLANGC_CPP = $(CC) $(SDL2_CFLAGS) $(SDL2_NOSIMD)
pstudio: plangc
	@pkg-config --exists sdl2 || { echo "pstudio: falta libsdl2-dev"; exit 1; }
	./plangc --out-dir out stl/*.ph selfhost/plang.ph selfhost/ast.ph selfhost/lexer.ph \
	         pstudio/*.ph $(PSTUDIO_SRC) $(PSTUDIO_DEPS)
	@mkdir -p out/bin
	$(CC) $(CFLAGS) -w -D_DEFAULT_SOURCE -o out/bin/pstudio \
	      $(patsubst %.p,out/%.c,$(PSTUDIO_SRC)) $(patsubst %.p,out/%.c,$(PSTUDIO_DEPS)) \
	      $(SDL2_NOSIMD) `pkg-config --cflags --libs sdl2` -lm
	@echo "pstudio pronto: ./out/bin/pstudio [pasta|arquivos]"

# The pscript PORT of the editor (pstudio/ps/): the logic in pscript, the hand
# that touches SDL2 still in P. Built the way anyone would build a pscript
# program — the runtime compiled alongside — plus the shim it calls through.
pstudio-ps: export PLANGC_CPP = $(CC) $(SDL2_CFLAGS) $(SDL2_NOSIMD)
pstudio-ps: plangc
	@pkg-config --exists sdl2 || { echo "pstudio-ps: falta libsdl2-dev"; exit 1; }
	./plangc --out-dir out stl/*.ph selfhost/plang.ph pstudio/*.ph pstudio/ps/shim.ph \
	         pstudio/pgfx.p pstudio/pgfx_raster.p pstudio/font_atlas.p pstudio/psys.p \
	         pstudio/ps/shim.p pscript/runtime/psrt.ph pscript/runtime/psrt.p
	./plangc --cpp "$(CC) -Iout/pstudio/ps" --out-dir out pstudio/ps/app.psc
	@mkdir -p out/bin
	$(CC) $(CFLAGS) -w -D_DEFAULT_SOURCE -Iout/pstudio/ps -o out/bin/pstudio-ps \
	      out/pstudio/ps/app.c out/pscript/runtime/psrt.c out/pstudio/ps/shim.c \
	      out/pstudio/pgfx.c out/pstudio/pgfx_raster.c out/pstudio/font_atlas.c out/pstudio/psys.c \
	      $(SDL2_NOSIMD) `pkg-config --cflags --libs sdl2` -lm -pthread
	@echo "pstudio-ps pronto: ./out/bin/pstudio-ps [arquivo]"

clean:
	rm -rf plangc plangc2 out tests/out stl/*.h .hello .hello.p .hello.c

.PHONY: check test test-qbe test-c89 verify verify-quick selfhost pstudio pstudio-ps clean
