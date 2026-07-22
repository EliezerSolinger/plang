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
#   make clean

CC     ?= cc
CFLAGS ?= -O2 -std=c11

SEED = $(wildcard bootstrap/selfhost/*.c)

plangc: $(SEED)
	$(CC) $(CFLAGS) -w -o $@ $(SEED)

# compile & run a hello-world through the built compiler (C backend)
check: plangc
	@printf 'import <stdio.h>\ndef main() -> int:\n    printf("hello from Plang\\n")\n    return 0\n' > .hello.p
	./plangc .hello.p -o .hello.c
	$(CC) $(CFLAGS) -o .hello .hello.c
	@./.hello
	@rm -f .hello .hello.p .hello.c

# test suites (tests/run.sh): P end-to-end cases, multi-module build, STL,
# and the c-testsuite ported to P. c-suite (C frontend scoreboard) is
# informational: run it explicitly with `bash tests/run.sh c-suite`.
test: plangc
	bash tests/run.sh cases modules stl p-suite

test-qbe: plangc
	BACKEND=qbe bash tests/run.sh cases modules stl p-suite

test-c89: plangc
	STD=c89 bash tests/run.sh cases modules stl p-suite

# rebuild the compiler from its own Plang source using the seed compiler,
# then build that — proves the release still self-hosts on this machine.
selfhost: plangc
	@mkdir -p out
	@for f in stl/*.ph; do ./plangc $$f -o stl/$$(basename $$f .ph).h; done
	@for f in selfhost/*.ph; do ./plangc $$f -o out/$$(basename $$f .ph).h; done
	@for f in selfhost/*.p;  do ./plangc $$f -o out/$$(basename $$f .p).c;  done
	$(CC) $(CFLAGS) -w -o plangc2 out/*.c
	@echo "self-host OK: plangc2 rebuilt from Plang source"

clean:
	rm -rf plangc plangc2 out tests/out stl/*.h .hello .hello.p .hello.c

.PHONY: check test test-qbe test-c89 selfhost clean
