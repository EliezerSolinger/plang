# pstudio em pscript — O editor

Este diretório **é** o Plang Studio. A lógica inteira é pscript; em P ficou o
driver — a mão que toca o SDL2 e a que chama o lexer do compilador. O editor em
P que existiu antes foi aposentado na bateria 116, depois de a paridade ter sido
medida método por método (115).

```sh
make pstudio               # -> out/bin/pstudio
./out/bin/pstudio .        # a árvore no diretório atual
./out/bin/pstudio a.p b.p  # arquivos em abas
```

## A divisão, e por que ela existe

A regra de fronteira do pscript (45.5) só deixa atravessar assinatura **sem
ponteiro**. O SDL2 é ponteiro do começo ao fim, então o driver não pode morar
no pscript — e não deve: é exatamente o tipo de código para o qual o P existe.

| arquivo | linguagem | o que é |
|---|---|---|
| `shim.ph` / `shim.p` | P | janela, eventos, pixels, área de transferência — a interface toda em ESCALARES (handles, códigos de tecla, cores, um codepoint por vez) |
| `hl.ph` / `hl.p` | P | o lexer DO COMPILADOR: o texto entra como `CStr` (ponteiro + comprimento, sem cópia) e os tokens voltam como números (113) |
| `lib_core.psc` | pscript | o buffer: linhas, cursores, seleção, desfazer, busca, dobras, marcas |
| `lib_pui.psc` | pscript | o toolkit: árvore de widgets, layout em duas fases, desenho retido, entrada |
| `lib_hl.psc` | pscript | o realce: spans por linha, e o comentário |
| `lib_complete.psc` | pscript | o índice de completamento |
| `lib_cv.psc` | pscript | o widget de edição: sarjetas, barras, minimapa, popup |
| `lib_app.psc` | pscript | abas, árvore, paleta, busca, atalhos |
| `app.psc` | pscript | o driver: janela, eventos, quadro, linha de comando |
| `core_test.psc`, `pui_test.psc`, `cv_test.psc`, `app_test.psc` | pscript | os quatro testes headless (rodam na suíte) |

O `app.psc` chama o P por `include "shim.h"` — o header que o próprio `plangc`
emite ao compilar `shim.p`. Não há FFI, não há binding: é a mesma fronteira de
C que a 45.5 já definia, e o compilador confere que nada além de escalar passa.

## O que o porte custou em linhas

O `core.p` do editor em P tem 1505 linhas; o `lib_core.psc` faz o mesmo
trabalho em 933. A diferença não é estilo — é que o pscript não precisa dizer
o que a linguagem já sabe:

- uma linha é um `str` e `len(s)` **são codepoints** (3.4), então some o cache
  `ncp` e somem `cp_count`, `col_to_byte`, `byte_to_col`;
- fatiar copia, então some `range_text` com `malloc`/`memcpy`/`free`;
- o coletor é dono do grafo, então somem `own`, `own_n`, `group_drop` e os
  `deinit` que percorrem tudo para liberar;
- índice fora de faixa LANÇA, então o teste que existia por disciplina agora é
  da linguagem.

## O que o porte encontrou

Um programa real acha o que uma suíte não acha. Estes vieram daqui, e cada um
virou conserto com teste (ver a bateria 71 em `pscript/PLAN.md`):

- um **método não enxergava variável de módulo** (uma função livre ao lado
  enxergava): as passagens estavam fora de ordem;
- assinaturas eram resolvidas tarde demais, então uma chamada podia comparar
  `Vec2` com `lib_geom.Vec2` e recusar o valor do tipo que ela mesma pediu;
- o tipo do **campo** não servia de contexto (`self.lines = []` não compilava);
- `<`, `>`, `<=`, `>=` entre strings comparavam **ponteiros** — resultado
  silenciosamente errado, e o motivo de `is_word_ch` devolver bobagem;
- um **local** de um módulo importado não podia ter o nome de uma variável do
  programa que importa;
- `ord`/`chr` não existiam, e sem eles nenhum texto chega a uma interface que
  fala número.

E estas ficaram registradas como lacunas, sem inventar decisão de design:
`"x" in s` (substring), `for ch in s` (iterar caracteres) e constantes de
header C invisíveis na fronteira (só funções atravessam).
