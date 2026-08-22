# Plang — o projeto constrói-se a si mesmo.
#
# O caminho normal é o `ppack`, o sistema de build deste repositório, escrito em
# pscript e construído por ele mesmo. Este arquivo é a CASCA: ele nasce o
# compilador a partir do C comitado, constrói o `ppack` com ele, e daí em diante
# quem manda é o grafo.
#
#   make            # tudo: a escada com ponto fixo, o editor e o ppack (~70 s)
#   make test       # a suíte, caso a caso, como grafo
#   make verify     # a verificação inteira (5m48 do zero, 8 s sem mudança)
#   make check      # compila e roda um hello-world
#   make doc X      # a documentação de um módulo ou pacote
#   make ninja      # o build.ninja do bootstrap
#   make clean
#
# Numa máquina que só tem um compilador de C, `make` basta: nada aqui depende de
# nada que não esteja no repositório.
#
# TUDO sai em `build/`:
#   build/bin        os binários (plangc_seed, plangc_s1, plangc_s2, ppack, ...)
#   build/s1,s2,s3   os três degraus da escada (o C que cada compilador gerou)
#   build/psc        o C dos programas em pscript
#   build/obj        os objetos
#   build/log        o log incremental (as duas datas, os dois hashes)
#   build/stamp      os carimbos (ponto fixo, sem-tag-libc)
#   build/t          as suítes
#   build/pkg        os pacotes baixados

CC     ?= cc
CFLAGS ?= -O2 -std=c11
J      ?= $(shell nproc 2>/dev/null || echo 4)

SEED   = build/bin/plangc_seed
PPACK  = build/bin/ppack
PLANGC = build/bin/plangc_s2

.DEFAULT_GOAL := build

# ---------------------------------------------------------------------------
# O NASCIMENTO: o C comitado, um `cc`, e mais nada.
$(SEED): $(wildcard bootstrap/selfhost/*.c)
	@mkdir -p build/bin
	$(CC) $(CFLAGS) -w -o $@ $(wildcard bootstrap/selfhost/*.c)

seed: $(SEED)

# O sistema de build, construído pelo compilador que acabou de nascer. É a
# única coisa que a casca ainda sabe fazer sozinha — daqui para a frente o grafo
# manda, e ele constrói inclusive uma cópia deste mesmo `ppack`.
$(PPACK): $(SEED) $(wildcard pbuild/ps/*.psc)
	@mkdir -p build/bin
	@PLANGC=$(SEED) bash tests/psbuild.sh pbuild/ps/ppack.psc $(PPACK)

ppack: $(PPACK)

# ---------------------------------------------------------------------------
# E daqui para baixo é tudo o mesmo comando com outro alvo.
#
# `--query` é o compilador que RESPONDE as perguntas do protocolo enquanto o
# grafo é montado (o que este arquivo lê? o que ele vai emitir?); quem RODA em
# cada degrau é o artefato daquele degrau.
build: $(PPACK)
	./$(PPACK) build -j $(J) --query $(SEED)

test: $(PPACK)
	./$(PPACK) test -j $(J) --query $(SEED)

verify: $(PPACK)
	./$(PPACK) verify -j $(J) --query $(SEED)

ninja: $(PPACK)
	./$(PPACK) ninja build.ninja --query $(SEED)

explain: $(PPACK)
	./$(PPACK) explain --query $(SEED)

# `make doc pui` / `make doc x.ph nome` — os argumentos passam adiante
doc: $(PPACK)
	./$(PPACK) doc $(filter-out $@,$(MAKECMDGOALS)) --query $(SEED)
%::
	@:

# compila e roda um hello-world com o compilador do ponto fixo
check: build
	@printf 'include <stdio.h>\ndef main() -> int:\n    printf("hello from Plang\\n")\n    return 0\n' > .hello.p
	./$(PLANGC) --pkg-path packages .hello.p -o .hello.c
	$(CC) $(CFLAGS) -o .hello .hello.c
	@./.hello
	@rm -f .hello .hello.p .hello.c

# o auto-hospedar É a escada: seed -> s1 -> s2 -> s3, com o ponto fixo conferido
# (s2 == s3 byte a byte). O alvo existe pelo nome que as pessoas conhecem.
selfhost: $(PPACK)
	./$(PPACK) build build/stamp/compilador -j $(J) --query $(SEED)

pstudio pstudio-ps: $(PPACK)
	@pkg-config --exists sdl2 || { echo "pstudio: falta libsdl2-dev"; exit 1; }
	./$(PPACK) build build/bin/pstudio -j $(J) --query $(SEED)
	@echo "pstudio pronto: ./build/bin/pstudio [pasta|arquivos]"

# ---------------------------------------------------------------------------
# As leituras do corpus que o grafo ainda não expressa por dentro (o back end
# alternativo e o C89 são a MESMA suíte com outra flag, e por enquanto quem as
# roda é o arreio).
test-qbe: build
	BACKEND=qbe bash tests/run.sh cases modules stl p-suite errors pscript

test-c89: build
	STD=c89 bash tests/run.sh cases modules stl p-suite errors pscript

clean:
	rm -rf build tests/out out plangc plangc2 .hello .hello.p .hello.c

.PHONY: seed ppack build test verify ninja explain doc check selfhost \
        pstudio pstudio-ps test-qbe test-c89 clean
