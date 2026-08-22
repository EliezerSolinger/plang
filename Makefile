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
#   make pstudio    # build the editor (pstudio/ps/, pscript; needs libsdl2-dev)
#   make clean

CC     ?= cc
CFLAGS ?= -O2 -std=c11
# the pscript runtime speaks POSIX (socket, getaddrinfo, poll, pipe, pthread),
# and glibc hides those under a strict `-std=`
PSDEFS = -D_POSIX_C_SOURCE=200112L -D_DEFAULT_SOURCE

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
	@mkdir -p out/bin
	@ln -sf ../../plangc2 out/bin/pscript
	@echo "self-host OK: plangc2 rebuilt from Plang source (out/bin/pscript is the run-it alias)"

# O driver gráfico (pstudio/pgfx*.p, font_atlas.p): a única parte do editor que
# continua em P, porque é pixel e ponteiro do começo ao fim e a 45.5 não deixa
# isso atravessar. Ele é compilado junto com o editor, no alvo `pstudio`.
PSTUDIO_DRIVER = pstudio/font_atlas.p pstudio/pgfx_raster.p pstudio/pgfx.p \
                 pstudio/ps/shim.p pstudio/ps/hl.p
PSTUDIO_DEPS = selfhost/lexer.p selfhost/utf8.p selfhost/util.p

# PLANG STUDIO: a lógica inteira em pscript (pstudio/ps/*.psc), e em P só o
# driver — a mão que toca o SDL2 (`shim.p`) e a que chama o lexer do compilador
# para o realce (`hl.p`, bateria 113). Construído como qualquer programa em
# pscript: o runtime compilado ao lado.
#
# 116: o editor em P (core/pui/codeview/complete/app/main/psys, 6448 linhas) foi
# APOSENTADO depois da paridade medida método por método (115). `pstudio-ps`
# continua existindo como apelido de `pstudio`.
pstudio pstudio-ps: export PLANGC_CPP = $(CC) $(SDL2_CFLAGS) $(SDL2_NOSIMD)
pstudio pstudio-ps: plangc
	@pkg-config --exists sdl2 || { echo "pstudio: falta libsdl2-dev"; exit 1; }
	./plangc --out-dir out stl/*.ph selfhost/plang.ph selfhost/ast.ph selfhost/lexer.ph \
	         pstudio/*.ph pstudio/ps/shim.ph pstudio/ps/hl.ph \
	         $(PSTUDIO_DRIVER) $(PSTUDIO_DEPS) \
	         pscript/runtime/psrt.ph pscript/runtime/psrt_types.ph pscript/runtime/psrt_mem.ph pscript/runtime/psrt_val.ph pscript/runtime/psrt_rt.ph pscript/runtime/psrt_std.ph pscript/runtime/psrt_os.ph pscript/runtime/psrt_top.ph pscript/runtime/psrt_mem.p pscript/runtime/psrt_val.p pscript/runtime/psrt_rt.p pscript/runtime/psrt_std.p pscript/runtime/psrt_os.p pscript/runtime/psrt_top.p
	./plangc --out-dir out pstudio/ps/app.psc
	@mkdir -p out/bin
	$(CC) $(CFLAGS) -w $(PSDEFS) -o out/bin/pstudio-ps \
	      out/pstudio/ps/app.c out/pscript/runtime/psrt_mem.c out/pscript/runtime/psrt_val.c out/pscript/runtime/psrt_rt.c out/pscript/runtime/psrt_std.c out/pscript/runtime/psrt_os.c out/pscript/runtime/psrt_top.c \
	      out/pstudio/ps/shim.c out/pstudio/ps/hl.c out/selfhost/lexer.c out/selfhost/util.c out/selfhost/utf8.c \
	      out/pstudio/pgfx.c out/pstudio/pgfx_raster.c out/pstudio/font_atlas.c \
	      $(SDL2_NOSIMD) `pkg-config --cflags --libs sdl2` -lm -pthread
	@ln -sf pstudio-ps out/bin/pstudio
	@echo "pstudio pronto: ./out/bin/pstudio [pasta|arquivos]"

clean:
	rm -rf plangc plangc2 out tests/out stl/*.h .hello .hello.p .hello.c

.PHONY: check test test-qbe test-c89 verify verify-quick selfhost pstudio pstudio-ps clean
