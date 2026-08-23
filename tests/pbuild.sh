#!/usr/bin/env bash
# tests/pbuild.sh — o MOTOR do pbuild (F2B), mecanismo por mecanismo.
#
# O motor é escrito em pscript (pbuild/ps/lib_{graph,log,build}.psc) e o que
# este arreio faz é compilá-lo e rodar a suíte que vive ao lado dele — o mesmo
# arranjo do `pui_test.psc` do editor: o teste mora com o módulo.
#
# O que a suíte prende está dito lá dentro, caso a caso, mas a ideia é uma só:
# um build só tem um defeito que importa, que é NÃO refazer o que mudou. Todo
# caso aqui é uma forma de isso acontecer.
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-build/bin/plangc_s2}
OUT=tests/out/pbuild-bin
mkdir -p "$OUT"

if ! PLANGC="$PLANGC" bash tests/psbuild.sh pbuild/ps/engine_test.psc "$OUT/engine" 2>"$OUT/build.err"; then
    echo "  FAIL: o motor do pbuild não compila"
    head -5 "$OUT/build.err"
    exit 1
fi
rm -rf tests/out/pbuild
"$OUT/engine"
rc=$?
[ $rc = 0 ] || exit $rc

# ---- F3: o descritor deste repositório, a CLI, e a exportação ----
# Um ENSAIO (`-n`) percorre o grafo inteiro sem rodar nada: ele prova que o
# descritor monta, que o compilador responde às quatro perguntas, que o grafo
# passa na higiene (sem duplicata, sem ciclo, sem entrada órfã) e que a ordem
# fecha. Custa segundos e cobre a cadeia toda.
if ! PLANGC="$PLANGC" bash tests/psbuild.sh pbuild/ps/ppack.psc "$OUT/ppack" 2>"$OUT/ppack.err"; then
    echo "  FAIL: o ppack não compila"
    head -5 "$OUT/ppack.err"
    exit 1
fi
# quantas arestas o ensaio RODA depende do que já está no disco (é um build
# incremental como outro qualquer); o que se cobra aqui é que ele feche sem
# reclamar de nada — os erros de higiene saem no quinto evento, com "erro:" na
# frente, e qualquer um deles invalida o grafo inteiro
if ! "$OUT/ppack" build -n --query "$PLANGC" >"$OUT/ensaio.log" 2>&1; then
    echo "  FAIL: o ensaio do descritor não fecha"
    grep -v '^\[' "$OUT/ensaio.log" | head -5
    exit 1
fi
if grep -q '^erro:' "$OUT/ensaio.log"; then
    echo "  FAIL: o grafo do descritor não passa na higiene"
    grep '^erro:' "$OUT/ensaio.log" | head -5
    exit 1
fi
echo "   pbuild-descritor: o ensaio fecha e o grafo passa na higiene"

# a exportação para ninja, sobre o grafo DE VERDADE: o que se confere aqui é que
# ela sai, que sai igual duas vezes, e que todo `$` do texto está escapado — o
# aspeamento fino tem casos próprios na suíte do motor
"$OUT/ppack" ninja --query "$PLANGC" > "$OUT/build.ninja" 2>"$OUT/ninja.err" || {
    echo "  FAIL: ppack ninja"; head -3 "$OUT/ninja.err"; exit 1; }
"$OUT/ppack" ninja --query "$PLANGC" > "$OUT/build.ninja.2" 2>/dev/null
if ! cmp -s "$OUT/build.ninja" "$OUT/build.ninja.2"; then
    echo "  FAIL: ppack ninja não é determinista"; exit 1
fi
regras=$(grep -c '^rule ' "$OUT/build.ninja")
if [ "$regras" -lt 100 ]; then
    echo "  FAIL: o build.ninja saiu com $regras regras"; exit 1
fi
if grep '^  command = ' "$OUT/build.ninja" | grep -q '[^$]\$\([^$]\|$\)'; then
    echo "  FAIL: há um \$ solto num comando do build.ninja"; exit 1
fi
echo "   pbuild-ninja: $regras regras, determinista, sem \$ solto"

# ---- `ppack doc`: a documentação do que já existe, sem gerar nada ----
# A fonte é a resposta 5 do compilador, que já traz interface e docstring. O que
# se confere aqui é a cadeia inteira: o compilador responde, o `lib_api` lê, e o
# `ppack` formata.
d=$("$OUT/ppack" doc tests/cases/docstring.p dobro --query "$PLANGC" 2>&1)
case $d in
    *"def dobro(i32) -> i32"*"O dobro de x."*) ;;
    *) echo "  FAIL: ppack doc não achou a docstring"; echo "$d" | head -3; exit 1 ;;
esac
d=$("$OUT/ppack" doc tests/cases/docstring.p --query "$PLANGC" 2>&1)
case $d in
    *"Um par de inteiros."*) ;;
    *) echo "  FAIL: ppack doc do módulo inteiro"; echo "$d" | head -3; exit 1 ;;
esac
if "$OUT/ppack" doc nao_existe_nenhum --query "$PLANGC" >/dev/null 2>&1; then
    echo "  FAIL: ppack doc devia recusar um alvo que não existe"; exit 1
fi
echo "   pbuild-doc: a documentação sai do --api, e o alvo inexistente é recusado"

# ---- `--json`: os MESMOS dados, para quem consome em vez de ler ----
# Um objeto por LINHA no fluxo de eventos (quem lê quer reagir enquanto o build
# corre), e um documento só nas consultas, que são resposta e não fluxo.
"$OUT/ppack" build -n --json --query "$PLANGC" > "$OUT/ev.jsonl" 2>&1 || true
python3 - "$OUT/ev.jsonl" <<'PY2' || { echo "  FAIL: o fluxo de eventos não é JSON por linha"; exit 1; }
import json, sys
tipos = set()
for ln in open(sys.argv[1]):
    ln = ln.strip()
    if not ln:
        continue
    tipos.add(json.loads(ln)["event"])
assert "plan" in tipos, tipos
assert "done" in tipos, tipos
PY2
"$OUT/ppack" doc --json tests/cases/docstring.p dobro --query "$PLANGC" > "$OUT/doc.json" 2>&1
python3 - "$OUT/doc.json" <<'PY2' || { echo "  FAIL: ppack doc --json"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
assert d["name"] == "dobro", d
assert "O dobro de x." in d["doc"], d
PY2
echo "   pbuild-json: o fluxo de eventos e a consulta saem em JSON"

# ---- `ppack tree` e `ppack why`: as consultas de PACOTE ----
# Rodam sobre o workspace DESTE repositório, que deixou de ser o caso simples de
# dois pacotes independentes: hoje são nove, e um deles (`ed25519`) puxa outro
# (`sha2`), que por sua vez puxa o `stl`. É por isso que o que se cobra aqui é a
# ANINHAMENTO e não uma ordem de linhas — um pacote que é dependência de outro
# aparece por baixo dele, e não como raiz. A ordem das raízes é a do manifesto,
# e prendê-la aqui faria acrescentar um pacote quebrar um teste que não é sobre
# isso.
t=$("$OUT/ppack" tree 2>&1)
case $t in
    *"pui 0.1.0"*) ;;
    *) echo "  FAIL: ppack tree"; echo "$t" | head -3; exit 1 ;;
esac
case $t in
    *"ed25519 0.1.0"*"sha2 0.1.0"*"stl 0.1.0"*) ;;
    *) echo "  FAIL: ppack tree não aninhou ed25519 -> sha2 -> stl"; echo "$t" | head -12; exit 1 ;;
esac
w=$("$OUT/ppack" why pui 2>&1)
case $w in
    *"pui 0.1.0"*"packages/pui"*) ;;
    *) echo "  FAIL: ppack why"; echo "$w" | head -3; exit 1 ;;
esac
if "$OUT/ppack" why naoexiste >/dev/null 2>&1; then
    echo "  FAIL: ppack why devia recusar um pacote que não existe"; exit 1
fi
"$OUT/ppack" tree --json > "$OUT/tree.json" 2>&1
python3 - "$OUT/tree.json" <<'PY2' || { echo "  FAIL: ppack tree --json"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
nomes = sorted(p["name"] for p in d["packages"])
# as RAÍZES do workspace: os membros que não são dependência de outro membro
assert "pui" in nomes and "pbuild" in nomes and "ed25519" in nomes, nomes
PY2
echo "   pbuild-pacotes: tree e why, no texto e em JSON"
