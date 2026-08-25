#!/usr/bin/env bash
# knobs.sh — os knobs de COMPILAÇÃO do runtime (`-D PSRT_*`) mudam o binário.
#
# Por que isto é um teste de shell: um `.expected` compara UM binário, e o que
# se quer provar aqui é que DOIS binários do mesmo programa diferem porque o
# `-D` entrou. É o mesmo programa, compilado duas vezes.
#
# O knob escolhido é o do `repr` porque o efeito dele é visível na saída sem
# medir nada: com a profundidade em 2, uma lista de cinco níveis imprime `[[...]]`.
# Os outros (bloco do heap, trace, poll, pool, json, regex) mudam dimensão de
# array e não a saída — para eles o teste é que o programa CONTINUA compilando e
# rodando com o valor de fora, que é o que este arquivo também mede.
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-build/bin/plangc_s2}
OUT=tests/out/knobs
rm -rf "$OUT"; mkdir -p "$OUT"
fail=0

cat > "$OUT/fundo.psc" <<'EOF'
xs = [[[[[1, 2]]]]]
print(xs)
EOF

build() {   # build <dir> <flags...>
    local d=$1; shift
    PLANGC="$PLANGC $*" PSBUILD_RT="$OUT/$d/rt" bash tests/psbuild.sh \
        "$OUT/fundo.psc" "$OUT/$d/bin" > "$OUT/$d.log" 2>&1
}

mkdir -p "$OUT/padrao" "$OUT/raso"
if ! build padrao; then
    echo "  FAIL knobs (build padrão) — veja $OUT/padrao.log"; exit 1
fi
if ! build raso -D PSRT_REPR_MAX=2; then
    echo "  FAIL knobs (build com -D) — veja $OUT/raso.log"; exit 1
fi

got_p=$("$OUT/padrao/bin")
got_r=$("$OUT/raso/bin")
[ "$got_p" = "[[[[[1, 2]]]]]" ] || { echo "  FAIL knobs: padrão deu '$got_p'"; fail=1; }
[ "$got_r" = "[[...]]" ]        || { echo "  FAIL knobs: -D PSRT_REPR_MAX=2 deu '$got_r'"; fail=1; }

# e os outros knobs: com um valor de fora, o runtime inteiro ainda compila e roda
mkdir -p "$OUT/todos"
if build todos -D PSRT_BLOCK_BYTES=262144 -D PSRT_GC_BYTES=1048576 \
        -D PSRT_GC_OBJECTS=50000 -D PSRT_TRACE_MAX=8 -D PSRT_POLL_MAX=16 \
        -D PSRT_POOL_MAX=4 -D PSRT_JSON_DEPTH=100 \
        -D PSRT_GRAVE_MAX=4; then
    got_t=$("$OUT/todos/bin")
    [ "$got_t" = "[[[[[1, 2]]]]]" ] || { echo "  FAIL knobs: com todos os -D deu '$got_t'"; fail=1; }
else
    echo "  FAIL knobs (build com todos os -D) — veja $OUT/todos.log"; fail=1
fi

[ $fail = 0 ] && echo "   knobs: 3 builds ok (padrão, -D do repr, todos os -D)"
exit $fail
