# `packages/` — os pacotes deste repositório

**Os dois primeiros pacotes já moraram para cá** (2026-08-22): `stl` e `pui`.
Este arquivo registra a estrutura decidida (`pforge/PACOTES.md`), o preço medido de
cada migração, e o que a migração ensinou.

## Duas pastas com nomes parecidos e papéis opostos

| pasta | o que é | vai para o git? |
|---|---|---|
| **`packages/`** | os pacotes que **nós escrevemos** — fonte | **sim** |
| `build/pkg/` | os pacotes que o `pforge` **baixou e verificou** | não |

## A forma de um pacote

O manifesto é **`pack.json`** — dado, nunca programa (é o arquivo que o painel de
configuração da IDE edita). O grafo de imports É o grafo do pacote (1.5a), então o
manifesto não repete a lista de arquivos.

```
packages/<nome>/
    pack.json         # nome, versão, dependências, dependência de sistema, toolchain
    <raiz>.ph|.psc    # o módulo RAIZ, que é a interface do pacote
    ...               # os demais módulos, alcançados por import
```

| tipo | pode conter | runtime | regra verificável |
|---|---|---|---|
| **P** | `.p`, `.ph`, `.c` | nenhum | um `.psc` dentro é **erro**; só depende de pacotes P |
| **pscript** | `.psc`, `.p`, `.ph`, `.c` | os 6 módulos | pode depender de pacote P |

## Os dois primeiros (decidido 2026-08-22)

Você recortou a lista: **`stl` e a lib de UI são pacotes de verdade; `core`, `hl`,
`cv` e `complete` são intrínsecos ao pstudio** e ficam lá.

### `stl` — o pacote zero do lado P

Dez `.ph` **sem nenhum `.p`**: só interface, zero dependência, zero sistema. É o
caso mais simples que existe **e** o mais exigente ao mesmo tempo, porque todo
módulo do compilador o usa.

**O preço da migração, medido:** `stl/` é referenciado em **41 lugares** —
`Makefile`, `reseed.sh`, `tests/verify-all.sh`, `tests/run.sh`, corpora de teste, e
os `import "../stl/vec.ph"` dentro dos fontes do compilador. Como o import é
**relativo ao arquivo**, mover a pasta muda os fontes do `selfhost`, o que muda o C
gerado, o que **obriga a regerar o seed**.

> Conclusão de planejamento: **mover o `stl` e renomear `static`→`private` são as
> duas migrações que exigem ciclo de seed. Fazer as duas no MESMO ciclo.**

### `pui` — o primeiro pacote pscript, e o mais fácil que podia aparecer

**FEITO.** `packages/pui/` com `pui.psc` (a raiz), `pack.json` e `test/` — e os
cinco módulos do editor que o usam passaram a escrever `import <pui> as pui`. O
teste dele saiu de `tests/pstudio/` e foi para `packages/pui/test/`, que é o
ponto: **um pacote publicado carrega a prova de que funciona**, e quem o instala
pode rodá-la na própria máquina.

Quem roda os testes dos pacotes é o `pforge test`, e ele os acha por estarem onde
têm de estar — nenhum arreio os cita.

Medido: `lib_pui.psc` tem **1 145 linhas e ZERO `import`** — não depende de
pacote, de módulo ou do SDL (a métrica de fonte é parâmetro do toolkit, decisão
112). E **já tem teste**: `pui_test.psc` (125 linhas) contra
`tests/pstudio/ps_pui.expected` (17 linhas), que roda na suíte.

Ou seja, o primeiro pacote pscript do ecossistema nasce com dependência nenhuma e
com teste próprio — o melhor caso possível para provar o mecanismo antes de ele
ter de aguentar algo difícil.

*(Nota: com `core`/`hl`/`cv` ficando no pstudio, o caso pscript→P — o defeito que
eu medi na 1.5(d) — deixa de ser bloqueio dos dois primeiros pacotes. Ele continua
sendo bloqueio do **editor**, que é onde ele já dói hoje.)*

## O manifesto — IMPLEMENTADO como a proposta abaixo (2026-08-22)

`pforge/src/lib_manifest.psc` lê e VALIDA as duas formas, e o erro sai como
`pack.json:4:12: error: ...` — clicável na IDE pelo mesmo caminho que um erro de
compilação, que é a razão de valer o trabalho. A posição é a da CHAVE, achada no
texto cru: o `json.parse` da linguagem devolve a estrutura e não as posições, e
escrever um segundo leitor de JSON só para as ter seria pagar caro por um número.

O que ele recusa hoje: nome fora de `[a-z][a-z0-9_-]*` (um nome de pacote vira
nome de diretório, pedaço de caminho de import e — mais tarde — pedaço de URL, e
esta é a interseção do que não dói em nenhum dos três); versão que não é
`x.y.z`; `lang` que não é `p` nem `pscript`; raiz que não existe; raiz `.psc` num
pacote `p`; dependência com nome inválido.

**Os campos continuam sendo os da proposta, e mudá-los é barato** — é um leitor
de cem linhas com portão próprio (`caso_manifesto` na suíte do motor).

### A forma (proposta implementada)

```json
{
  "name": "pui",
  "version": "0.1.0",
  "lang": "pscript",
  "root": "pui.psc",
  "deps":      { },
  "system":    { },
  "toolchain": ">= 0.1.0",
  "description": "toolkit de interface em pscript: layout, foco, desenho por retângulo"
}
```

## Como se importa de um pacote — DECIDIDO (2026-08-22)

**`import <stl/vec.ph>`** — o `<>` procura no caminho de pacotes que o `pforge`
montou; o `"..."` continua sendo relativo ao arquivo. É a distinção do C, que a
linguagem **já usa** para header de sistema, e agora o vocabulário fica com três
formas sem uma ambiguidade:

| forma | significa |
|---|---|
| `include <stdio.h>` | header de C do sistema (pré-processado pelo `cc`) |
| `import <stl/vec.ph>` | módulo de um **pacote** (procurado no caminho) |
| `import "vizinho.ph"` | módulo **relativo ao arquivo**, como hoje |

E o melhor: **o compilador continua sem saber o que é versão** — ele recebe um
caminho de busca e procura, exatamente como a fronteira decidida em
`pforge/ARQUITETURA.md` manda.

**FEITO em 2026-08-22.** `--pkg-path <dir>` (repetível) dá as raízes; a busca é
na ordem em que foram dadas, e a primeira que tiver o arquivo ganha. `<>` NÃO
recua para o caminho relativo — um `<>` não achado é erro, com a lista das
raízes na mensagem. Importar a interface de um pacote PUXA o `.p` dela: um
pacote é uma unidade, e quem o usa não tem de saber como ele é feito por dentro.
Vale nas duas linguagens. O portão é `tests/packages.sh`, e a raiz de exemplo
que ele usa (`tests/pkg/`) mostra a forma mínima de um pacote: uma pasta com um
nome, um `.ph` e um `.p`.

Um limite que vale saber antes de tropeçar nele: a raiz e os fontes têm de ser
nomeados do mesmo jeito — ambos relativos ao diretório de trabalho, ou ambos
absolutos. É o que faz o caminho relativo entre eles valer também dentro do
espelho do `--out-dir`; com um de cada lado, o compilador recusa e diz por quê.

Migração: os 41 `import "../stl/vec.ph"` viram `import <stl/vec.ph>` — no **mesmo
ciclo de seed** do `static`→`private`.

## O teste vive dentro do pacote — DECIDIDO

`packages/pui/test/` viaja com o pacote, e o `pforge test` roda os testes dos
pacotes do workspace também. Três consequências:

- **um pacote publicado carrega a prova de que funciona** — e quem instala pode
  rodá-la na própria máquina, que é algo que nenhum ecossistema grande oferece de
  verdade;
- some mais um pedaço das seis listas: hoje o `pui_test.psc` e o
  `tests/pstudio/ps_pui.expected` são citados à mão em `tests/run.sh`;
- e o `.expected` é dado do pacote, comparado pelo **nó de veredicto** — o mesmo
  mecanismo, sem nada novo.
