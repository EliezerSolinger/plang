# Gerenciadores de pacotes: erros históricos e o design ideal

## Por que gerenciador de pacotes importa para o sucesso de uma linguagem

Uma linguagem sem gerenciador de pacotes centralizado obriga cada dev a resolver dependências na mão (vendoring, git submodules, copiar arquivos manualmente). Isso tem custo alto o suficiente para afastar contribuintes ocasionais — que são justamente quem cria a maior parte dos pacotes de "nicho" que fazem um ecossistema parecer rico.

Exemplos:
- **C/C++**: sem gerenciador oficial por décadas (CMake+FetchContent, Conan, vcpkg surgiram tarde e nunca unificaram) → ecossistema fragmentado.
- **Rust**: cargo + crates.io desde muito cedo → hoje tem um dos ecossistemas mais ricos proporcionalmente à idade da linguagem.
- **Go**: demorou pra ter algo oficial (go modules só em 2018, antes GOPATH bagunçado) → adoção de bibliotecas sofreu nesse período.
- **npm/JS**: gerenciador chegou cedo e virou sinônimo da linguagem — caso extremo de sucesso via ecossistema, com efeitos colaterais ruins (dependency hell, pacotes triviais).

Fatores-chave de sucesso:
1. Zero-friction de descoberta e instalação (`cargo add foo`, `npm install foo`)
2. Resolução de dependências automática e determinística (lockfiles)
3. Um único ponto canônico de registry (evita fragmentação de descoberta)
4. Stdlib e pacotes "oficiais" dando o tom de qualidade do ecossistema
5. Facilidade de publicar um pacote

---

## O que deu errado, historicamente

### 1. Dependency hell (npm, pip clássico, Ruby gems pré-Bundler)
Sem lockfile determinístico, `npm install` em máquinas diferentes gerava árvores de dependência diferentes. A solução veio tarde (package-lock.json em 2017, quase 10 anos depois do npm existir).
**Lição:** lockfile determinístico desde o dia 1, não como patch depois.

### 2. Diamond dependency problem (Java/Maven clássico, C++)
Se A depende de C v1 e B depende de C v2, e você depende de A e B — quem ganha? Java resolvia com "o mais próximo na árvore" (nearest wins), arbitrário e gerador de bugs silenciosos. Rust resolve permitindo múltiplas versões coexistindo no grafo de compilação.

### 3. Instalação global vs local (Python é o caso clássico)
`pip install` sem venv quebrando o Python do sistema é um erro de design que o ecossistema levou 20+ anos para corrigir (pipx, PEP 668, depois uv). Pip nunca teve isolamento de projeto nativo — foi bolado depois, por fora (virtualenv, venv, poetry, pdm, uv).
**Lição:** isolamento por projeto tem que ser o padrão desde o início, nunca opcional.

### 4. Left-pad / pacotes triviais demais (npm)
Um pacote de 11 linhas (`left-pad`) foi removido do registry e quebrou metade da internet JS em 2016. Expôs dois problemas: (a) nenhuma verificação de que remover um pacote publicado quebra o mundo, e (b) cultura de granularidade excessiva incentivada por fricção zero de publicar.

### 5. Supply chain attacks (npm, PyPI, crates.io)
Pacotes maliciosos com nomes parecidos (typosquatting), ou pacotes legítimos comprometidos via conta de mantenedor sequestrada (caso `event-stream`, caso `xz-utils`). Nenhum gerenciador de pacotes grande resolveu isso de verdade ainda.

### 6. Falta de dependências opcionais/features bem modeladas
Historicamente ruim em C/C++; resolvido bem em Rust com feature flags do Cargo. Sem isso, ligar/desligar funcionalidades opcionais de uma lib força o usuário a puxar todas as dependências transitivas.

### 7. Build scripts arbitrários rodando código na instalação
npm postinstall, pip setup.py — vetor de ataque gigante: instalar um pacote pode rodar código arbitrário na máquina antes mesmo de usá-lo. Cargo reduziu isso (build.rs é mais controlado); npm e pip são bem mais abertos a isso.

---

## Quem acertou bem — o que copiar

- **Cargo (Rust)**: lockfile desde cedo, resolução semver estrita, workspaces nativos, registry único e canônico, publicação trivial, testes/docs no fluxo padrão, feature flags bem desenhadas.
- **Go modules** (depois de aprender com o GOPATH): versionamento via tags de git direto, sem exigir registry central — código-fonte é a fonte da verdade, com proxy central (`proxy.golang.org`) para cache/disponibilidade.
- **Deno**: importa direto de URL (sem registry central obrigatório), com lockfile de hash para integridade — modelo mais descentralizado, resolve o problema do "pacote sumiu" com cache imutável.

---

## Design do gerenciador de pacotes ideal

1. **Isolamento por projeto por padrão, sempre** — nunca instalar global implicitamente. Instalação global é comando explícito e diferente, nunca comportamento default.

2. **Lockfile determinístico e obrigatório** — hash de conteúdo (não só versão semver) de cada pacote resolvido, comitado no repositório. Build reproduzível bit-a-bit em qualquer máquina.

3. **Resolução de dependências: permitir múltiplas versões no grafo** — como o Cargo faz, evita o diamond dependency problem. Só força versão única quando o tipo realmente vaza pela interface pública.

4. **Registry central + espelhamento descentralizado** — um registry canônico (evita fragmentação de descoberta) mas com content-addressing (hash) permitindo mirror/cache infinito sem quebrar confiança. Resolve o problema do left-pad sem forçar centralização total tipo Deno.

5. **Sem execução de código arbitrário na instalação, por padrão** — build scripts existem mas são sandboxed (sem rede, sem filesystem fora do próprio pacote) a menos que o usuário aprove permissões extras explicitamente — modelo capability-based tipo o runtime do Deno, aplicado à instalação.

6. **Assinatura criptográfica de publicação + 2FA obrigatório para mantenedores** — cada versão publicada assinada pela chave do autor. Mudança de "owner" de pacote de alto uso exige verificação adicional.

7. **Feature flags / dependências opcionais nativas** — modelagem tipo Cargo: pacote base leve, funcionalidades extras via flags, sem forçar quem só quer o core a puxar tudo.

8. **Hierarquia de workspace nativa (monorepo-first)** — múltiplos pacotes no mesmo repositório compartilhando lockfile/dependências, resolvendo "pacote local A depende do pacote local B" sem precisar publicar no registry para testar. Cargo e pnpm workspaces acertam nisso; pip é péssimo (editable installs ainda são gambiarra).

9. **SemVer real e verificado automaticamente** — o gerenciador roda diff de API pública entre versões antes de aceitar publicação com tag "minor"; se quebrou API pública, força bump major ou rejeita o publish. Ninguém faz isso de forma rigorosa hoje — seria um avanço genuíno.

10. **Depreciação e sunset explícitos, não silenciosos** — quando um pacote é abandonado ou tem vulnerabilidade, o gerenciador avisa no install/build, com metadata estruturada nativa (tipo `cargo audit`, mas embutido, não ferramenta separada).

---

## Documentação embutida (o ponto que quase todo gerenciador ignora)

### O que existe hoje (e por que é insuficiente)

- **Java/Javadoc**: o JAR pode empacotar um `-javadoc.jar` separado, gerado a partir de comentários `/** */`. Mas é **opt-in e desacoplado** — o mantenedor precisa lembrar de gerar e publicar esse artefato à parte do jar de código. Muita lib popular no Maven Central não tem javadoc jar publicado.
- **Rust/docs.rs**: o melhor caso hoje. A cada publicação no crates.io, o **docs.rs builda automaticamente** a doc a partir dos doc-comments (`///`) e hospeda em `docs.rs/nome-do-crate`. Não é opcional, não depende do mantenedor lembrar de nada — é parte do pipeline de publicação.
- **Python**: nada embutido. `pip install` não traz documentação — depende de docstrings via `help()` em runtime, ou de Sphinx/ReadTheDocs configurado por fora, sem ligação automática com o PyPI.
- **npm**: zero. README.md é a "documentação"; sem geração estruturada nativa (TypeDoc/JSDoc são ferramentas externas, opcionais).
- **Go**: meio-termo interessante — `go doc` lê comentários direto do código-fonte baixado (funciona offline, sem HTML pré-gerado), e `pkg.go.dev` gera doc automaticamente do próprio repositório público, sem publicação manual à parte.

### O problema de fundo

Documentação hoje é tratada como um **artefato separado e opcional** do artefato de código, quando deveria ser **parte inseparável da unidade de publicação**. Isso causa docs desatualizadas (processos de geração/publicação dessincronizados), fricção pro mantenedor (mais um passo manual = mais chance de pular), e fragmentação de onde buscar (README vs wiki vs site externo vs javadoc jar).

Importante: isso não é sobre **forçar** o dev a escrever documentação — isso é impossível de garantir tecnicamente (sempre vai ter `/// TODO`). É sobre garantir que, **se** o dev decidir documentar, o esforço de manter isso publicado e sincronizado caia a quase zero. Tornar o caminho fácil o caminho padrão, não obrigar ninguém a escrever nada.

### Como resolver isso no design ideal

1. **Doc-comments como parte obrigatória do parser/compilador da linguagem** — sintaxe canônica reconhecida pelo compilador (não convenção livre de comentário), com suporte a exemplos de código testáveis.

2. **Geração de docs embutida no comando `publish`, não em ferramenta separada** — igual docs.rs: o próprio gerenciador de pacotes gera e hospeda a doc automaticamente ao publicar. Não existe "esquecer de gerar javadoc".

3. **Empacotador lê a documentação e gera artefatos estruturados em pelo menos dois formatos**:
   - **JSON** (ou outro formato estruturado tipo MessagePack) como formato canônico/intermediário — permite que qualquer ferramenta (IDE, LSP, site de docs, gerador de HTML customizado) consuma a doc programaticamente sem precisar reparsear código-fonte. É a "fonte da verdade" da doc extraída.
   - **HTML gerado a partir do JSON**, como opção explícita de build, para visualização offline navegável (tipo `pkgmanager doc build --html`) — sem depender de internet ou de um site externo tipo docs.rs pra consultar.

4. **Exemplos de código na doc são testados no CI de publicação** — tipo os doctests do Rust (`cargo test` roda os exemplos dentro dos doc-comments como testes reais). Resolve o clássico exemplo de doc que não compila mais há 3 versões.

5. **Documentação offline por padrão, sem depender de internet** — o gerenciador baixa o JSON de doc junto com o código-fonte/binário na hora do install, permitindo `pkgmanager doc nome-do-pacote` funcionar sem rede, tipo `go doc` faz.

6. **Versionamento de doc atrelado à versão do pacote, automaticamente** — cada versão publicada tem seu JSON/HTML de doc arquivado e acessível, evitando o problema de "a doc online mostra a versão mais nova mas eu uso uma mais antiga".

7. **Assinatura de tipos/API extraída automaticamente e comparada entre versões** — conecta com a verificação de semver: se o JSON gerado mostra que uma função pública sumiu ou mudou assinatura, isso vira sinal automático pro semver checker.

8. **Índice de busca full-text unificado no registry** — busca não só por nome de pacote, mas por símbolo/função dentro da doc de todos os pacotes publicados (docs.rs tem algo parecido, mas fraco comparado ao que dava pra fazer com o JSON estruturado como base).

9. **Site oficial de documentação online, automático, tipo docs.rs** — todo pacote publicado ganha uma página pública (`docs.pkgmanager.dev/nome-do-pacote`) renderizada a partir do mesmo JSON gerado no publish, sem o mantenedor precisar hospedar nada por conta própria. Isso resolve o problema de descoberta (alguém pesquisa a lib no Google antes mesmo de instalar) e serve como visualização "de referência" — o HTML offline (ponto 3) é o mesmo conteúdo, só que local. Precisa suportar:
   - **URL estável por versão** (`docs.pkgmanager.dev/nome/1.2.0/...`) e uma versão "latest" que redireciona — assim links em fóruns/Stack Overflow não quebram quando o pacote atualiza.
   - **Deep-linking direto pra função/tipo/símbolo específico**, não só pra página inicial do pacote.
   - **Renderização incremental/cacheada** — o build da doc de um pacote não pode travar o registry inteiro se um pacote específico tiver doc gigante ou build quebrado (isolamento de falha, assíncrono em relação à publicação do próprio pacote).
   - **Fallback gracioso quando o build de doc falha** — o pacote continua instalável mesmo se a geração de HTML falhar (o JSON cru pelo menos fica disponível), evitando o problema do docs.rs onde às vezes a doc simplesmente não builda e fica sem nada publicado.

---

## Versionamento e reprodutibilidade (o "outro inferno")

Problema real e comum: `pip install -r requirements.txt` (ou equivalente) não reconstrói o mesmo ambiente em outra máquina, mesmo travando versões.

### Por que isso acontece (caso Python)

1. **`requirements.txt` tradicional não trava versões transitivas** — só lista o que foi pedido direto (`requests==2.31.0`), não as dependências das dependências. Rodar em outra máquina/data pode resolver transitivas diferentes se algo foi publicado entre as duas instalações.
2. **Sem hash de conteúdo por padrão** — mesmo com `pip freeze` (que trava tudo, inclusive transitivas), a trava é por **número de versão**, não por hash do conteúdo. Se um mantenedor republicar a mesma versão com conteúdo diferente, a versão travada aponta pra coisa diferente.
3. **Dependência de wheels binários específicos de plataforma** — um `.whl` com extensão C compilada é específico de SO+arquitetura+versão do Python. Sem wheel pré-compilada pra combinação exata, o pip compila do source na hora — entrando toolchain de C, versão de gcc, headers de sistema, um universo fora do controle do gerenciador.
4. **Sem isolamento real da versão do interpretador nem de libs de sistema** — o venv isola pacotes, não a versão do Python nem libs como libc/OpenSSL que algumas wheels linkam dinamicamente.
5. **Fragmentação de ferramentas** (`pip-tools`, `poetry`, `pdm`) tentando resolver isso por fora, cada uma com formato de lockfile diferente, nenhuma virando padrão universal.

### O que outros ecossistemas fazem melhor

- **Cargo.lock (Rust)**: trava por versão **+ hash de conteúdo** de cada crate. Conteúdo mudou sem mudar versão → build falha explicitamente.
- **Nix/NixOS**: leva ao extremo — cada dependência (inclusive compilador, libc) referenciada por hash derivado de todas as entradas do build. Reprodutibilidade bit-a-bit real, mas com curva de aprendizado alta e pouca adoção fora de nicho.
- **Deno**: lockfile de hash desde o início, sem alternativa "sem lock".
- **Go modules**: `go.sum` trava hash de cada módulo; build falha se o conteúdo baixado não bater com o hash.

### Design ideal — dois cenários, consequências diferentes

A resposta certa depende de o gerenciador **distribuir binários pré-compilados** ou ser **source-only** (tudo buildado localmente a partir do código-fonte). As consequências e o design mudam bastante entre os dois:

#### Cenário A — Distribuindo binários pré-compilados

- **Complexidade adicional:** o registry precisa gerar e hospedar uma **matriz de binários por plataforma** (SO × arquitetura × versão de runtime), tipicamente via CI de publicação automatizado (modelo `cibuildwheel`/`manylinux`).
- **Vantagem:** instalação rápida pro usuário final, sem precisar de toolchain de build na máquina de quem só consome o pacote.
- **Risco novo:** hash do binário publicado precisa ser verificado no install (supply chain: binário pode divergir do source que supostamente o gerou). Exige build reprodutível no CI de publicação pra que qualquer um possa auditar "esse binário realmente veio desse source?".
- **Fallback necessário:** quando não existe binário pré-compilado pra uma combinação de plataforma específica, o gerenciador cai pra compilar do source local — reintroduzindo os mesmos problemas do cenário B, então esse fallback deveria ser exceção rara, não caminho comum.
- **Vendorizar/linkar estaticamente dependências de sistema** (evitar depender de libc/OpenSSL do host) reduz a superfície de "funciona numa distro, não funciona em outra".

#### Cenário B — Source-only (tudo buildado localmente, sem binário distribuído)

- **Simplicidade maior no registry** — não existe matriz de plataforma pra gerenciar, só o hash do tarball/código-fonte.
- **Ponto crítico desloca pra toolchain, não pro pacote** — se o compilador/interpretador da própria linguagem divergir de versão entre máquinas, o mesmo source pode compilar diferente ou nem compilar. É essencial travar a **versão do toolchain no lockfile** (não só das dependências), similar ao `rust-toolchain.toml` do Rust.
- **Build determinístico do compilador em si vira requisito** — remover fontes de non-determinismo do processo de compilação (timestamps embutidos, ordem de iteração não determinística, paths absolutos vazando pro artefato). Responsabilidade do compilador da linguagem, mas o gerenciador pode expor verificação (`build --verify-reproducible`, compara hash do output entre builds).
- **Risco elevado de build scripts arbitrários** — cada `install` de fato compila código de terceiros na máquina do usuário, não baixa algo pré-verificado. Sandboxing de build script (sem rede, sem filesystem fora do pacote) é ainda mais crítico aqui do que no cenário A.
- **Mais fácil de implementar num primeiro gerenciador** — é essencialmente o que o Cargo já faz (Rust também não distribui binário pré-compilado pro registry) e resolve reprodutibilidade bem via `Cargo.lock` (hash + versão) combinado com `rust-toolchain.toml` (versão do compilador travada).

### Pontos comuns aos dois cenários

1. **Lockfile obrigatório, sempre gerado** — não existe "instalar sem lockfile"; o primeiro install já cria o lock, installs seguintes resolvem a partir dele.
2. **Trava por hash de conteúdo, não só número de versão** — republish do mesmo número de versão com conteúdo diferente causa falha explícita no install, nunca aceitação silenciosa.
3. **Versão do compilador/interpretador como parte do lockfile** — trava a toolchain junto com as dependências, não só o ambiente do sistema operacional.
4. **Diagnóstico claro de divergência de lock** — comando tipo `pkgmanager diff-lock` que mostra exatamente qual pacote/versão resolveu diferente entre dois lockfiles e por quê (registry desatualizado, faixa de versão ambígua, hash não bate) — em vez do usuário investigar manualmente.

---

## Conclusão prática

O ponto de partida mais são hoje seria basicamente **"Cargo, mas com sandboxing de build script e verificação de API pública automática"** — porque o Cargo já resolveu boa parte dos erros históricos, e os problemas restantes (supply chain, build scripts arbitrários, semver não verificado) são os que ninguém resolveu bem ainda, logo é onde há espaço real para inovar em vez de apenas copiar.
