# Índice de decisões — pbuild, ppack, packages e a linguagem

Uma linha por decisão, tudo de 2026-08-21/22. O detalhe e o *porquê* estão nos
documentos apontados; isto é o mapa.

`D` = `pbuild/DESIGN.md` · `A` = `pbuild/ARQUITETURA.md` · `L` = `pbuild/LINKER.md`
· `P` = `ppack/DESIGN.md` · `K` = `packages/README.md`

**O plano de execução — fases, ordem, critérios de pronto — é `pbuild/PLAN.md`**,
que é o ponto de retomada (mesmo contrato do `pscript/PLAN.md`).

## As três peças e a regra de cada uma  ·  `A`

| | |
|---|---|
| `plangc` | **responde** — nunca decide o que recompilar, em que ordem, com quantos processos |
| `pbuild` | **decide** — é uma **biblioteca**, e ela **não imprime**: relata eventos |
| `ppack` | **resolve** — e é o comando de cima (`ppack build/run/test/...`) |
| `pstudio` | **orquestra por cima** — IDE; nada depende dele, e ele chama a biblioteca em processo |
| fases | resolver (a única com rede) → descrever → planejar → decidir → executar |

**O protocolo (6 respostas do compilador):** o que li · hash de cada interface ·
o que vou emitir · quem sou · API pública + doc · diagnósticos.

## pbuild  ·  `D`

| # | decisão |
|---|---|
| 1.1 | a camada de SO vive na stdlib do pscript (feito na bateria 111) |
| 1.2 | `os.run` é **task com `await`** sobre o laço de eventos |
| 1.3 | **aresta gorda autônoma** é a verdade; `--emit-ninja` exporta |
| 1.4 | sujeira = os **seis testes do ninja**, `restat`, hash de comando **+ env** |
| 1.6 | comando é **`argv`, sem shell** |
| 1.6b | `argv` livre em qualquer lugar, com **aprovação gravada no lock** |
| 1.6c | `stdout:` é campo da aresta (o executor já captura) |
| 1.6d | glob **só no descritor**, com `os.listdir` ordenado |
| 1.6e | `env`/`cwd` na aresta, e o `env` entra no hash |
| 1.7 | a **duração** entra no log e a fila ordena por ela (vale ~4 s em 5) |
| 1.8 | grafo em **memória** na mesma execução, JSON quando pedido |
| — | forma: **um binário, dois modos**; `plangc` fica fora e intocado |
| — | falha: **para na primeira**, `-k N` continua; `ppack test` roda com `-k` |
| — | teste: **suítes nomeadas**, sempre rodam (veredicto não cacheado), **pisos no descritor** |
| — | `verify-all` vira **alvo do descritor** (`ppack verify`) — critério de pronto da v1 |
| — | pasta `build/` com `pkg/ obj/ bin/ log/`; **nada global**, e configurável |
| — | paralelismo: **núcleos** (aqui satura em ~4: o caminho crítico é um arquivo) |
| — | `--explain` sim; linha de status que se atualiza, não |
| — | `ppack dev` reconstrói **e reinicia**; `build --repro` constrói duas vezes e compara |
| — | **cruzamento na v1**; o alvo entra na chave de sujeira |
| — | eventos: ciclo de vida da aresta e o total, nada mais |
| — | erros do pbuild/ppack no **estilo do compilador** (`arquivo:linha:col:`) |

## A linguagem (o que o build obrigou a mudar)  ·  `D`

| # | decisão |
|---|---|
| 1.5a | **`import` implica o módulo** (a regra do `.p` irmão) — mata as seis listas |
| 1.5b | **hash de interface**: recompila quando a *interface* muda, não o arquivo |
| 1.5c | módulo pscript vira **TU**; público = o que não é `private`; header expõe o **layout** |
| 1.5d | definir o que `import "x.ph"` significa **dentro de módulo importado** (o defeito medido) |
| — | `import <pkg/mod.ph>` procura no caminho de pacotes; `"..."` segue relativo |
| — | **`static` → `private`** nas duas linguagens (alias → seed → conversão → remover). **EM ANDAMENTO** |
| — | **docstring `"""..."""`** nas duas; em P é dropada do binário |
| — | **reflexão**: `PsDesc` ganha tabela de campos **públicos**; `repr` vira dado; `--json` de graça |
| — | `plangc` ganha **semver da linguagem** + hash dos bytes no `--version` |
| — | o **`run` sai do compilador** (passo tardio, depois de o `ppack run` existir) |

## ppack  ·  `P`

| # | decisão |
|---|---|
| 2.1 | pacote = **diretório de módulos com módulo raiz de interface** |
| 2.2 | **versão única** no grafo, nas duas linguagens (o P não decora nomes) |
| 2.3 | publica **só fonte** |
| 2.4 | **dois arquivos, um armazém**: lock humano e comitado, log local e descartável |
| 2.5 | modelo **apt**: repositório é **formato, não serviço**; vários; um padrão; disco/http/ftp; pesquisável |
| 2.6 | API pública + doc em JSON, junto do hash de interface |
| 2.7 | dependência de sistema é **declaração**, com `pkg-config` como um resolvedor |
| 2.8 | nome **global** no repo padrão, **qualificado** nos outros |
| 2.9 | **SHA-256 + índice assinado** (repo) **+ assinatura do autor** |
| 2.11 | **pacote não tem build próprio** — o vetor do `postinstall` não existe no vocabulário |
| 2.12 | dois modos de confiança; o **unsafe** dispensa assinatura, **nunca o hash**, e fica no lock |
| 2.13 | o **C de um pacote é compilado pelo `plangc`** |
| — | versão **exata** na v1 (sem faixas, sem resolvedor); MVS depois, aditivo |
| — | `index.json` = metadado + hash + **lista canónica da API** (busca por símbolo) |
| — | `ppack run`: constrói e **o programa é o processo** |
| — | alvos com **nome nosso**: `linux-amd64`, `linux-amd64-musl`, `macos-arm64` |
| — | manifesto **`pack.json`**, declarativo; descritor `build.psc`, programa |
| — | workspace: **pacote local por caminho**; publicar com dep por caminho é recusado |
| — | vassoura apaga saídas, **mantém** os pacotes |
| — | comandos: núcleo + **inspeção** (`why tree graph explain`) |
| — | `add` mexe em manifesto e lock e **não constrói** |
| — | doc no terminal e `--html` para uma pasta |
| — | higiene: 3 erros (saída não produzida, ciclo, entrada inexistente) + avisos de suspeita |
| — | o **próprio plang** vira workspace com `pack.json` na raiz |

## packages/  ·  `K`

`packages/` é o que **nós escrevemos**; `build/pkg/` é o que o ppack **baixou**.
Primeiros dois: **`stl`** (pacote zero do lado P: 10 headers, nenhum `.p`) e
**`pui`** (1 145 linhas, **zero import**, e já tem teste). `core`/`hl`/`cv`/
`complete` são intrínsecos ao pstudio e ficam lá. Teste vive **dentro** do pacote.

## linker/assembler  ·  `L`

Nada se escreve agora. `minias` e `ucpp` ficam de fora (o `as` custa 0,356 s; e o
`cc -E` da máquina é a verdade sobre os headers dela). macOS/arm64 fica no `cc`
por tempo indeterminado. A **musl** fica registrada como a libc que faz a trilha
livre servir pscript, e espera. Quando a vez chegar, **assembler e linker são
escritos em P**, com `minias`/`neatld` como referência, e com oráculo: `as` byte a
byte, `ld` mais "o binário roda".

## As medições que sustentam tudo isto

| | |
|---|---|
| 97 % do build é `cc` | 0,47 s de geração contra 18,0 s de `cc` |
| o caminho crítico é **um arquivo** | 5,0 s em paralelo contra 4,96 s do `ps_lower.c` |
| **QBE serial ganha do C paralelo** | 4,50 s contra 5,0 s (e 18,5 s serial) |
| `run` frio × quente | 3,32 s × 0,006 s |
| um `exec` a mais | 1,4 ms |
| ler grafo de 6 000 arestas | ~40 ms (medido: 2 000 em 13 ms) |
| motor do samurai | 1 546 linhas (de 4 306; a linguagem do ninja são 921) |
| `neatld` / `minias` / `neatlibc` / musl | 860 / 5 462 / 4 441 / 89 723 linhas |
| repertório do QBE (amd64) | 86 mnemônicos; 10 são 95 % das instâncias |
| símbolos externos | 50 (compilador) · 90 (programa pscript) · **zero de libgcc** |
| seed | 50 773 linhas de C |
| a migração `static`→`private` | 1 965 ocorrências (+20 em testes) |
| mover o `stl` | 41 referências, e **obriga a regerar o seed** |
| descritores de tipo hoje | 38 no editor portado, ~470 linhas de 24 601 (1,9 %) |
