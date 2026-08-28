#!/bin/bash
# verify-all.sh — a bateria completa de verificação do plangc em UM comando.
#
#   bash tests/verify-all.sh          # bateria completa (~10 min)
#   bash tests/verify-all.sh quick    # pula os scoreboards (c-suite, wacct)
#
# Etapas (todas a partir dos FONTES atuais, nunca de binários velhos):
#   1. seed        bootstrap C -> plangc_seed
#   2. escada      seed compila selfhost -> s1; s1 -> s2; s2 -> out3
#   3. fixed point C      out2 == out3 (byte a byte) + nenhuma tag interna de
#                         libc no C gerado (portabilidade: glibc vs macOS)
#   4. suítes gating      cases/modules/stl/p-suite/errors em C, QBE e C89
#   5. fixed point QBE    ssa(s2) == ssa(compilador construído do próprio ssa)
#   6. scoreboards        c-suite e wacct-valid (informativos, com piso)
#   6b. conformidade      corpora de fora, oráculos e o coletor sob estresse
#   7. pstudio            o editor inteiro compila e linka (skip sem SDL2)
#   7. seed drift         bootstrap/ em dia com os fontes? (informativo)
#
# Sai com código != 0 em qualquer falha gating. Artefatos de falha ficam em
# .verify. Limpa artefatos STALE de execuções anteriores no início.
set -u
cd "$(dirname "$0")/.."
QUICK=${1:-}
V=.verify
CC=${CC:-cc}
CFLAGS="-O2 -std=c11 -w"
FAIL=0

# Os PISOS dos placares não moram mais aqui: moram no descritor, junto da suíte
# que os mede (`pforge/src/build_plang.psc`, a função `verificacao`), e quem os
# confere é uma aresta do grafo. Este arreio passou a LER o que o descritor diz,
# para que exista um lugar só onde o número se sobe.
piso_de() { grep -oE "\"$1\", \"[a-z-]+\", \"[^\"]+\", \"[0-9]+\"" pforge/src/build_plang.psc | grep -oE '[0-9]+"$' | tr -d '"'; }
CSUITE_FLOOR=$(piso_de c-suite); CSUITE_FLOOR=${CSUITE_FLOOR:-220}
WACCT_FLOOR=$(piso_de wacct);    WACCT_FLOOR=${WACCT_FLOOR:-741}

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
ok()   { printf '   \033[32mOK\033[0m %s\n' "${1:-}"; }
bad()  { printf '   \033[31mFAIL\033[0m %s\n' "${1:-}"; FAIL=1; }

rm -rf tests/out              # nunca deixar artefatos velhos enganarem o diagnóstico
mkdir -p $V/{out1,out2,out3,qb1,qb2} $V/packages/stl

step "1/8 seed: bootstrap C -> plangc_seed"
if $CC $CFLAGS -o $V/plangc_seed bootstrap/selfhost/*.c 2>$V/seed.err; then ok; else bad "$(head -2 $V/seed.err)"; exit 1; fi

gen() { # gen <plangc> <outdir>  — gera stl headers + selfhost C
  # os .c gerados incluem "../packages/stl/x.h" relativo ao próprio diretório,
  # então os headers da stl vão para $V/packages/stl — o repo não é tocado
  local bin=$1 out=$2 f b
  for f in packages/stl/*.ph; do $bin --pkg-path packages "$f" -o $V/packages/stl/$(basename "${f%.ph}").h 2>/dev/null || return 1; done
  for f in selfhost/*.ph; do b=$(basename "${f%.ph}"); $bin --pkg-path packages "$f" -o $out/$b.h 2>$V/gen.err || { head -2 $V/gen.err; return 1; }; done
  for f in selfhost/*.p;  do b=$(basename "${f%.p}");  $bin --pkg-path packages "$f" -o $out/$b.c 2>$V/gen.err || { head -2 $V/gen.err; return 1; }; done
}

step "2/8 escada: seed -> s1 -> s2 -> out3"
if gen $V/plangc_seed $V/out1 && $CC $CFLAGS -o $V/plangc_s1 $V/out1/*.c 2>$V/s1.err; then ok "stage1"; else bad "stage1: $(head -2 $V/s1.err 2>/dev/null)"; exit 1; fi
if gen $V/plangc_s1 $V/out2 && $CC $CFLAGS -o $V/plangc_s2 $V/out2/*.c 2>$V/s2.err; then ok "stage2"; else bad "stage2: $(head -2 $V/s2.err 2>/dev/null)"; exit 1; fi
if gen $V/plangc_s2 $V/out3; then ok "stage3 (geração)"; else bad "stage3"; exit 1; fi

step "3/8 fixed point C: out2 == out3"
if diff -rq $V/out2 $V/out3 >/dev/null 2>&1; then ok; else bad "$(diff -rq $V/out2 $V/out3 | head -3)"; fi
# O C gerado não pode nomear TAG interna de uma libc: `FILE` é `struct _IO_FILE`
# na glibc e `struct __sFILE` no macOS, então imprimir a tag amarra a saída a uma
# libc — e onde o compilador também declara a função (popen/pclose) o header do
# sistema entra em conflito e a build quebra. Sema canonicaza no tag de propósito
# (é como os backends aprendem o layout); quem tem de imprimir o typedef é o
# backend C, via Module.tdrev_*. Este gate é o que impede a volta da regressão:
# em glibc a build passa dos dois jeitos, então o teste tem de ser sobre o TEXTO.
leak=$(grep -l '_IO_FILE\|__sFILE\|_G_config\|__gnuc_va_list' $V/out2/*.c $V/out2/*.h $V/packages/stl/*.h 2>/dev/null | head -3)
if [ -z "$leak" ]; then ok "sem tag interna de libc no C gerado"
else bad "tag interna de libc no C gerado: $leak"; fi

step "4/8 suítes gating (C, QBE, C89) com o stage2"
for mode in "C:" "QBE:BACKEND=qbe" "C89:STD=c89"; do
  name=${mode%%:*}; env=${mode#*:}
  if env PLANGC=$PWD/$V/plangc_s2 $env bash tests/run.sh cases modules stl p-suite errors pstudio roundtrip pscript >$V/suite_$name.log 2>&1; then
    ok "$name"
  else
    bad "$name (tests/out + $V/suite_$name.log)"
  fi
done

step "5/8 fixed point QBE"
# o `qbe/` é SUBMÓDULO, e um checkout sem `git submodule update --init` não o
# tem. Sem esta linha, a ausência dele saía como "o compilador QBE-built diverge
# do C-built" — uma frase alarmante sobre um problema que não existe, e que
# manda quem a lê procurar um defeito de back end durante uma tarde. É o mesmo
# tratamento que o SDL2 já tinha no passo 7: uma dependência que falta é uma
# máquina sem ela, e não uma regressão.
if [ ! -x ./qbe/qbe ] && ! (cd qbe && make -s >/dev/null 2>&1 && [ -x qbe ]); then
    printf '   \033[33mSKIP\033[0m sem `qbe/qbe` — `git submodule update --init` e refaça\n'
else
qfp=1
for f in selfhost/*.p; do b=$(basename "${f%.p}")
  $V/plangc_s2 --pkg-path packages --backend qbe "$f" -o $V/qb1/$b.ssa 2>/dev/null || qfp=0
  ./qbe/qbe $V/qb1/$b.ssa -o $V/qb1/$b.s 2>/dev/null || qfp=0
done
if [ $qfp = 1 ] && $CC $V/qb1/*.s -o $V/plangc_qbe 2>$V/qbe.err; then
  for f in selfhost/*.p; do b=$(basename "${f%.p}")
    $V/plangc_qbe --pkg-path packages --backend qbe "$f" -o $V/qb2/$b.ssa 2>/dev/null || qfp=0
    diff -q $V/qb1/$b.ssa $V/qb2/$b.ssa >/dev/null 2>&1 || { qfp=0; echo "   diverge: $b.ssa"; }
  done
else qfp=0; fi
[ $qfp = 1 ] && ok || bad "compilador QBE-built diverge do C-built"
fi

if [ "$QUICK" != "quick" ]; then
  step "6/8 scoreboards (pisos: c-suite>=$CSUITE_FLOOR, wacct>=$WACCT_FLOOR)"
  cs=$(PLANGC=$PWD/$V/plangc_s2 bash tests/run.sh c-suite 2>/dev/null | grep -oE 'score: [0-9]+' | grep -oE '[0-9]+')
  [ "${cs:-0}" -ge $CSUITE_FLOOR ] && ok "c-suite $cs/220" || bad "c-suite caiu: ${cs:-?}/220 (piso $CSUITE_FLOOR)"
  wa=$(PLANGC=$PWD/$V/plangc_s2 bash tests/run.sh wacct-valid 2>/dev/null | grep -oE 'wacct-valid: [0-9]+' | grep -oE '[0-9]+')
  [ "${wa:-0}" -ge $WACCT_FLOOR ] && ok "wacct-valid $wa ok" || bad "wacct-valid caiu: ${wa:-?} (piso $WACCT_FLOOR)"
  # paridade de diagnósticos com o clang da máquina (gating quando clang existe)
  if command -v clang >/dev/null 2>&1; then
    if PLANGC=$PWD/$V/plangc_s2 bash tests/clang-compare.sh >$V/clangcmp.log 2>&1; then
      ok "clang-compare $(grep -oE '[0-9]+ matches' $V/clangcmp.log | tail -1)"
    else
      bad "clang-compare divergiu (veja $V/clangcmp.log)"
    fi
  fi
else
  step "6/8 scoreboards — pulados (quick)"
fi

step "6b/8 conformidade, oráculos e o coletor sob estresse"
# Os três arreios que medem o pscript contra ALGO QUE NÃO SOMOS NÓS. Não são
# placar informativo: são portão, do mesmo jeito que o clang-compare é.
#
#   conformance  corpora que outros escreveram (JSONTestSuite, llhttp, WPT url).
#                O que sabidamente não fazemos vive em <corpus>.skips, com o
#                motivo, e um skip que volta a concordar é reportado como STALE.
#   oracle       os nossos programas rodam duas vezes, aqui e no intérprete de
#                referência (python3 para a linguagem, node para o runtime), e a
#                saída é diffada. Pula com aviso se o intérprete não existir.
#   gc-stress    coleta em TODO ponto seguro e envenena o que libera. É o único
#                arreio que acha a família inteira de "alguém segurou um ponteiro
#                através de um ponto seguro", que a suíte normal não vê porque
#                um programa pequeno nunca coleta.
if PLANGC=$PWD/$V/plangc_s2 bash tests/conformance/run.sh >$V/conf.log 2>&1; then
    ok "conformance $(grep -oE '[0-9]+/[0-9]+ agree' $V/conf.log | tr '\n' ' ')"
else
    bad "conformance divergiu (veja $V/conf.log)"
fi
if PLANGC=$PWD/$V/plangc_s2 bash tests/oracle/run.sh >$V/oracle.log 2>&1; then
    ok "oráculos $(grep -oE '[a-z]+: [0-9]+ agree' $V/oracle.log | tr '\n' ' ')"
else
    bad "um oráculo divergiu (veja $V/oracle.log)"
fi
# 137.2: truncar um ficheiro DEBAIXO de um mapa aberto. O que ele exige é que a
# mensagem diga o que aconteceu — a excepção continua por fazer, e a bateria 145
# diz porquê.
if PLANGC=$PWD/$V/plangc_s2 bash tests/mmap-truncate.sh >$V/mmaptrunc.log 2>&1; then
    ok "mmap-truncate $(grep -oE '[0-9]+ ok' $V/mmaptrunc.log | tail -1)"
else
    bad "mmap-truncate (veja $V/mmaptrunc.log)"
fi

# 142: um recém-chegado compila um `.p` com um `Vec` SEM configurar nada — o
# problema que a 142.0 mediu, e que era duas falésias antes do programa dele.
if PLANGC=$PWD/$V/plangc_s2 bash tests/builtin-stl.sh >$V/builtinstl.log 2>&1; then
    ok "$(sed 's/^   //' $V/builtinstl.log | tail -1)"
else
    bad "builtin-stl (veja $V/builtinstl.log)"
fi

# S7: o TLS, contra um servidor LOCAL com certificado auto-assinado — o que
# separa `starttls` de `starttls_insecure`. SALTA quando não há OpenSSL: a
# dependência é de sistema, e a ausência dela não é um defeito nosso.
if PLANGC=$PWD/$V/plangc_s2 bash tests/tls.sh >$V/tls.log 2>&1; then
    ok "$(sed 's/^   //' $V/tls.log | tail -1)"
else
    bad "tls (veja $V/tls.log)"
fi

if PLANGC=$PWD/$V/plangc_s2 bash tests/gc-stress.sh >$V/gcstress.log 2>&1; then
    ok "gc-stress $(grep -oE '[0-9]+ ok' $V/gcstress.log | tail -1)"
else
    bad "gc-stress achou algo (veja $V/gcstress.log)"
fi
#   run-pforge    `pforge run` e o cache atrás dele: a única coisa aqui que não é
#                uma compilação, então o que se mede são COMPORTAMENTOS — que a
#                segunda vez não chama o `cc`, que editar um módulo importado
#                invalida, que o status de saída é o do programa.
#   net-late     dado que chega DEPOIS que o leitor estacionou: dois PROCESSOS,
#                porque com cliente na mesma thread é impossível reproduzir — o
#                que ele faz acontece entre dois polls. Foi o que achou o laço
#                drenando o socket e comendo a mensagem.
if PLANGC=$PWD/$V/plangc_s2 bash tests/net-late.sh >$V/netlate.log 2>&1; then
    ok "net-late $(grep -oE '[0-9]+ ok' $V/netlate.log | tail -1)"
else
    bad "o dado que chega tarde se perdeu (veja $V/netlate.log)"
fi
#   print-atomic uma linha de `print` sai INTEIRA com oito workers imprimindo ao
#                mesmo tempo. Não cabe num `.expected` (a ordem é indeterminada),
#                e o que quebrava era a forma: `print` fazia duas chamadas de
#                stdio e stdout é o mesmo arquivo de todos os workers.
if PLANGC=$PWD/$V/plangc_s2 bash tests/print-atomic.sh >$V/printatomic.log 2>&1; then
    ok "print-atomic $(grep -oE '[0-9]+ linhas' $V/printatomic.log | tail -1)"
else
    bad "o print de workers concorrentes costurou linhas (veja $V/printatomic.log)"
fi
#   overflow-opt a aritmética checada continua a levantar COM otimização — o
#                corpus compila a -O0, e este defeito (o `*` que perdia a
#                checagem por UB) só existe a partir de -O1.
if PLANGC=$PWD/$V/plangc_s2 bash tests/overflow-opt.sh >$V/overflowopt.log 2>&1; then
    ok "overflow-opt $(grep -oE '[0-9]+ níveis' $V/overflowopt.log | tail -1)"
else
    bad "a aritmética checada mudou de resposta com otimização (veja $V/overflowopt.log)"
fi
#   nocheck      o bloco `nocheck:` dá a volta em release e levanta com -g — dois
#                modos de compilação do mesmo ficheiro, o que um `.expected` não vê.
if PLANGC=$PWD/$V/plangc_s2 bash tests/nocheck.sh >$V/nocheck.log 2>&1; then
    ok "nocheck $(grep -oE 'batem nos dois' $V/nocheck.log | tail -1 | sed 's/.*/ok/')"
else
    bad "o bloco nocheck não se comportou nos dois modos (veja $V/nocheck.log)"
fi
#   httpd        o servidor HTTP/1.1 batido POR FORA, com o `curl` por oráculo:
#                quem conta se houve UMA conexão para três pedidos é ele.
if PLANGC=$PWD/$V/plangc_s2 bash tests/httpd.sh >$V/httpd.log 2>&1; then
    ok "httpd $(grep -oE '[0-9]+ ok' $V/httpd.log | tail -1)"
else
    bad "o servidor HTTP falhou no fio (veja $V/httpd.log)"
fi
#   knobs        os `-D PSRT_*` mudam o binário: o mesmo programa compilado duas
#                vezes tem de dar saídas diferentes (a profundidade do `repr` é a
#                que se vê sem medir), e com TODOS os knobs de fora ele ainda
#                compila e roda.
if PLANGC=$PWD/$V/plangc_s2 bash tests/knobs.sh >$V/knobs.log 2>&1; then
    ok "knobs $(grep -oE '[0-9]+ builds ok' $V/knobs.log | tail -1)"
else
    bad "um knob de compilação não pegou (veja $V/knobs.log)"
fi
# run pelo pforge: os mesmos comportamentos do `plangc run`, medidos do lado onde
# a decisão passou a viver (F7)
if PFORGE=$PWD/build/bin/pforge bash tests/run-cmd-pforge.sh >$V/runpforge.log 2>&1; then
    ok "run-pforge $(grep -oE '[0-9]+ ok' $V/runpforge.log | tail -1)"
else
    bad "o run do pforge divergiu (veja $V/runpforge.log)"
fi

# A REGRA DO TEMA: nenhuma camada usa cor directa. É um `grep`, e é o portão
# mais barato da suíte — sem ele, um widget escrito no mês que vem com um hex
# dentro simplesmente fica errado no tema claro e certo no escuro, que é o tipo
# de defeito que ninguém reporta.
if bash tests/theme.sh >$V/theme.log 2>&1; then
    ok "theme $(grep -oE '[0-9]+ ok' $V/theme.log | tail -1) (nenhuma cor fora do theme.psc)"
else
    bad "alguém escreveu uma cor fora do tema (veja $V/theme.log)"
fi

# A PROVA DO CORTE: o `pcode` e o `pstudio` são dois programas, e a diferença é
# uma lista de arquivos que o compilador responde (`--deps`). Sem este portão, a
# separação vira uma afirmação num documento — e em três meses alguém acrescenta
# um `import` por uma boa razão e ninguém nota.
if PLANGC=$PWD/$V/plangc_s2 bash tests/decouple.sh >$V/decouple.log 2>&1; then
    ok "decouple $(grep -oE '[0-9]+ ok' $V/decouple.log | tail -1) $(grep -oE '\(pcode [0-9]+ files, pstudio [0-9]+\)' $V/decouple.log)"
else
    bad "o corte entre pcode e pstudio deixou de valer (veja $V/decouple.log)"
fi

# o MOTOR do pforge, mecanismo por mecanismo (F2B), mais as consultas da CLI
# sobre o grafo deste repositório. Ele estava escrito e não estava ligado a
# portão nenhum — 89 conferências que ninguém corria, e uma delas já tinha
# apodrecido em silêncio (esperava dois pacotes no workspace, que hoje tem nove).
# Um teste que não corre não é um teste: é documentação que envelhece.
if PLANGC=$PWD/$V/plangc_s2 bash tests/pforge.sh >$V/pforge.log 2>&1; then
    ok "pforge $(grep -oE '[0-9]+ ok' $V/pforge.log | tail -1)"
else
    bad "o motor do pforge divergiu (veja $V/pforge.log)"
fi

# packages: `import <pkg/mod.ph>` — o pacote como CAMINHO DE BUSCA, nas duas
# linguagens, com as respostas do protocolo a enxergá-lo e o erro a dizer onde
# se procurou
if PLANGC=$PWD/$V/plangc_s2 bash tests/packages.sh >$V/packages.log 2>&1; then
    ok "packages $(grep -oE '[0-9]+ ok' $V/packages.log | tail -1)"
else
    bad "import <pkg> divergiu (veja $V/packages.log)"
fi

# repo: publish -> update -> search -> add -> install -> compilar contra o que
# foi instalado, tudo sobre `file://`. Um repositório é um FORMATO: aqui ele é
# um diretório, e quando o HTTP entrar nada disto muda.
if PFORGE=$PWD/build/bin/pforge PLANGC=$PWD/$V/plangc_s2 bash tests/repo.sh >$V/repo.log 2>&1; then
    ok "repo $(grep -oE '[0-9]+ ok' $V/repo.log | tail -1)"
else
    bad "o repositório divergiu (veja $V/repo.log)"
fi

step "7/8 pstudio (o editor: pscript por cima, driver em P por baixo)"
# 116: o editor em P foi aposentado (a paridade foi medida método por método na
# 115). O que este passo mede agora é o programa GRÁFICO inteiro: o driver em P
# (SDL2 + o lexer do compilador para o realce), o runtime do pscript e as 4200
# linhas de pscript do editor, compilados e LINKADOS juntos — e depois o
# auto-teste dele, que abre um arquivo, digita, desfaz, usa a paleta e desenha.
# SDL2 é dependência com skip gracioso — sem libsdl2-dev só avisa.
if pkg-config --exists sdl2 >/dev/null 2>&1; then
  # o cc que o plangc usa para pré-processar `include <SDL2/SDL.h>` precisa dos
  # mesmos -I da compilação final: fora do Linux os headers do SDL2 não estão
  # num caminho de busca padrão (Homebrew). E SDL_cpuinfo.h arrasta os headers de
  # intrínsecos SIMD do compilador (arm_neon.h no Apple Silicon), que ninguém aqui
  # usa. Ver PLANGC_CPP / SDL2_NOSIMD no Makefile.
  # continuações com '\': PLANGC_CPP vai para um shell, e um newline LITERAL aqui
  # encerraria o comando no meio (o cc recebia metade dos -D como um comando novo)
  nosimd="-DSDL_DISABLE_IMMINTRIN_H -DSDL_DISABLE_MMINTRIN_H -DSDL_DISABLE_XMMINTRIN_H \
-DSDL_DISABLE_EMMINTRIN_H -DSDL_DISABLE_PMMINTRIN_H -DSDL_DISABLE_ARM_NEON_H \
-DSDL_DISABLE_MM3DNOW_H -DSDL_DISABLE_LSX_H -DSDL_DISABLE_LASX_H"
  export PLANGC_CPP="$CC $(pkg-config --cflags sdl2) $nosimd"
  # 1.5(a): o guarda-chuva basta — ele importa os headers das seis camadas e
  # cada um tem o `.p` irmão
  RT_ARGS="pscript/runtime/psrt.ph"
  if $V/plangc_s2 --pkg-path packages --out-dir $V/pst selfhost/plang.ph selfhost/ast.ph \
       selfhost/lexer.ph selfhost/cfront.ph selfhost/vecs.ph pstudio/*.ph pstudio/shim.ph pstudio/hl.ph \
       pstudio/pgfx.p pstudio/pgfx_raster.p pstudio/font_atlas.p pstudio/icons.p \
       pstudio/shim.p pstudio/hl.p selfhost/lexer.p selfhost/utf8.p selfhost/util.p \
       selfhost/cfront.p selfhost/vecs.p \
       $RT_ARGS >$V/pstudio.log 2>&1 &&
     true; then
    # OS DOIS: o `pcode` (o editor) e o `pstudio` (o editor mais a IDE), das
    # mesmas camadas. Construir ambos aqui é metade da prova do corte; a outra
    # metade é o portao `decouple`, que pergunta ao compilador o que cada um lê.
    printf 'line one\nline two\nline three\n' > $V/pst/sample.txt
    for b in pcode pstudio; do
      exp=tests/pstudio/ps_selftest.expected
      [ "$b" = pcode ] && exp=tests/pstudio/pcode_selftest.expected
      if $V/plangc_s2 --pkg-path packages --out-dir $V/pst pstudio/$b.psc >>$V/pstudio.log 2>&1 &&
         $CC -w -D_POSIX_C_SOURCE=200112L -D_DEFAULT_SOURCE -D_DARWIN_C_SOURCE -o $V/bin_$b \
           $V/pst/pstudio/$b.c $V/pst/pscript/runtime/psrt_*.c \
           $V/pst/pstudio/shim.c $V/pst/pstudio/hl.c \
           $V/pst/pstudio/pgfx.c $V/pst/pstudio/pgfx_raster.c $V/pst/pstudio/font_atlas.c $V/pst/pstudio/icons.c \
           $V/pst/selfhost/lexer.c $V/pst/selfhost/utf8.c $V/pst/selfhost/util.c \
           $V/pst/selfhost/cfront.c $V/pst/selfhost/vecs.c \
           $nosimd $(pkg-config --cflags --libs sdl2) -lm -pthread >>$V/pstudio.log 2>&1 &&
         ( cd $V/pst && SDL_VIDEODRIVER=dummy timeout 30 ../bin_$b --selftest sample.txt >saida.$b 2>&1 ) &&
         diff -q $V/pst/saida.$b "$exp" >/dev/null 2>&1; then
        ok "$b compila, linka e passa o auto-teste"
      else
        bad "o auto-teste do $b falhou (veja $V/pstudio.log e $V/pst/saida.$b)"
      fi
    done
  else
    bad "pstudio nao compilou (veja $V/pstudio.log)"
  fi
else
  ok "skipped: no SDL2"
fi

step "8/8 seed drift (informativo)"
drift=0
for f in $V/out2/*.c $V/out2/*.h; do
  b=$(basename "$f")
  cmp -s "$f" "bootstrap/selfhost/$b" || { drift=1; break; }
done
for f in $V/packages/stl/*.h; do
  b=$(basename "$f")
  cmp -s "$f" "bootstrap/packages/stl/$b" || { drift=1; break; }
done
if [ $drift = 0 ]; then ok "bootstrap/ em dia com os fontes"
else printf '   \033[33mDRIFT\033[0m bootstrap/ difere dos fontes — regenere com: cp %s/out2/* bootstrap/selfhost/\n' "$V"; fi

echo
if [ $FAIL = 0 ]; then
  printf '\033[1;32m✔ VERIFY-ALL PASSED\033[0m\n'
  rm -rf $V tests/out 2>/dev/null
else
  printf '\033[1;31m✘ VERIFY-ALL FAILED — artefatos em %s\033[0m\n' "$V"
fi
exit $FAIL
