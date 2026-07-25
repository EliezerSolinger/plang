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
	bash tests/run.sh cases modules stl p-suite errors

test-qbe: plangc
	BACKEND=qbe bash tests/run.sh cases modules stl p-suite errors

test-c89: plangc
	STD=c89 bash tests/run.sh cases modules stl p-suite errors

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
              pstudio/pgfx.p pstudio/pui.p pstudio/core.p pstudio/codeview.p \
              pstudio/app.p pstudio/main.p
PSTUDIO_DEPS = selfhost/lexer.p selfhost/utf8.p selfhost/util.p

pstudio: plangc
	@pkg-config --exists sdl2 || { echo "pstudio: falta libsdl2-dev"; exit 1; }
	./plangc --out-dir out stl/*.ph selfhost/plang.ph selfhost/ast.ph selfhost/lexer.ph \
	         pstudio/*.ph $(PSTUDIO_SRC) $(PSTUDIO_DEPS)
	@mkdir -p out/bin
	$(CC) $(CFLAGS) -w -D_DEFAULT_SOURCE -o out/bin/pstudio \
	      $(patsubst %.p,out/%.c,$(PSTUDIO_SRC)) $(patsubst %.p,out/%.c,$(PSTUDIO_DEPS)) \
	      `pkg-config --cflags --libs sdl2` -lm
	@echo "pstudio pronto: ./out/bin/pstudio [pasta|arquivos]"

clean:
	rm -rf plangc plangc2 out tests/out stl/*.h .hello .hello.p .hello.c

.PHONY: check test test-qbe test-c89 verify verify-quick selfhost pstudio clean
