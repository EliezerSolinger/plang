# Runtimes de Linguagens Não-Sistemas — Análise Completa

> Critério de "runtime completo": quanto você consegue fazer **sem instalar nada de terceiros** — GC, concorrência, I/O, rede, crypto, observabilidade, ferramentas de build/teste.
>
> Excluindo linguagens de sistemas (C, C++, Rust, Zig).

**Ordem aproximada de completude:**
`.NET ≈ JVM > BEAM > Go > Node/Deno/Bun > Python > PHP ≈ Ruby ≈ Dart`

---

## Parte 1 — Os Runtimes em Detalhe

### 1. .NET / CLR (C#, F#, VB.NET)

Provavelmente o mais completo em "área de superfície".

- **Execução:** JIT em camadas (tiered), AOT nativo, ReadyToRun, single-file publish, trimming
- **Memória:** GC geracional com modos workstation/server, `Span<T>`/`Memory<T>` para zero-alloc
- **Concorrência:** `async`/`await` de primeira classe, ThreadPool, `Task`, `Channels`, `Parallel.For`
- **Biblioteca base (BCL):** HTTP client e servidor (Kestrel), JSON, XML, crypto, regex, LINQ, globalização com ICU, data/hora com fusos, `System.IO.Pipelines`, sockets
- **Metaprogramação:** reflection, `Reflection.Emit`, source generators em tempo de compilação
- **Diagnóstico:** EventPipe, `dotnet-trace`, `dotnet-counters`, `dotnet-dump`, contadores de GC
- **Ferramentas inclusas:** CLI `dotnet` (build, test, run, format, publish), MSBuild, NuGet

### 2. JVM (Java, Kotlin, Scala, Clojure)

Perde em amplitude de stdlib, ganha em maturidade de runtime e observabilidade.

- **Execução:** JIT C1/C2 com otimização guiada por perfil *em produção*, desotimização, OSR
- **Memória:** GCs plugáveis — G1 (padrão), ZGC e Shenandoah com pausas sub-milissegundo, Parallel, Serial
- **Concorrência:** threads virtuais (Loom, Java 21+), concorrência estruturada, `java.util.concurrent` completo, memory model bem especificado
- **Stdlib:** NIO, HTTP/2 client, JCE (crypto), JDBC, collections, streams, `java.time`
- **Observabilidade — o melhor da categoria:** JFR (Flight Recorder), JMX, `jcmd`, `jstack`, `jmap`, heap dumps, agentes de bytecode
- **Ferramentas inclusas:** `javac`, `jshell` (REPL), `jlink` (runtime enxuto customizado), `jpackage`, `jdeps`
- Carregamento dinâmico de classes e instrumentação em runtime — base de tudo que é APM

### 3. BEAM (Erlang, Elixir, Gleam)

Não é o mais completo em geral, mas é **imbatível** no que se propõe: sistemas distribuídos e tolerantes a falha.

- **Concorrência:** milhões de processos leves, scheduler preemptivo por *reduções* (nenhum processo trava o resto)
- **Memória:** heap isolado por processo → GC por processo, sem stop-the-world global
- **Tolerância a falha:** árvores de supervisão OTP, `GenServer`, restart automático, "let it crash"
- **Distribuição nativa:** clustering entre nós e chamadas remotas transparentes, sem biblioteca externa
- **Hot code swapping** em produção, sem derrubar o serviço
- **Persistência embutida:** ETS/DETS (in-memory) e Mnesia (banco distribuído)
- **Introspecção:** tracing nativo de qualquer processo em produção, Observer, `recon`
- **Ferramentas:** Mix/rebar3, ExUnit, doctests, formatter
- **Ponto fraco:** processamento numérico pesado

### 4. Go

Fronteira com "sistemas", mas o runtime é gordo.

- Goroutines com scheduler M:N, channels, `select`
- GC concorrente otimizado para latência baixa
- Stdlib excelente: `net/http` pronto pra produção, `crypto/tls`, `encoding/json`, `database/sql`, `context`, `html/template`
- **Toolchain completo embutido:** `go build/test/fmt/vet/mod`, pprof (CPU, heap, goroutines), race detector, execution tracer, benchmarks, cobertura
- Binário estático e cross-compile trivial

### 5. Node.js / Deno / Bun (JavaScript, TypeScript)

- **Execução:** V8 com JIT em múltiplas camadas (Ignition → Sparkplug → Maglev → TurboFan); Bun usa JavaScriptCore
- **I/O:** libuv — event loop + thread pool para I/O assíncrono
- **Node:** `fs`, `http/http2`, `net`, `crypto` (OpenSSL), `zlib`, streams, `worker_threads`, `cluster`, `child_process`, TLS, DNS, Buffer
- **Node moderno:** test runner nativo, watch mode, leitura de `.env`, remoção de tipos TypeScript sem transpilador, npm incluso, Chrome DevTools inspector
- **Deno:** TypeScript nativo, sandbox de permissões granular, formatter/linter/test/bench/`compile` embutidos, KV store
- **Bun:** package manager + bundler + test runner + cliente SQLite, tudo no mesmo binário

### 6. Python (CPython)

Runtime modesto, **stdlib gigantesca** — é o oposto do Go.

- `pathlib`, `socket`, `json`, `csv`, `sqlite3`, `ssl`, `hashlib`, `argparse`, `logging`, `dataclasses`, `typing`, `asyncio`, `threading`, `multiprocessing`, `concurrent.futures`, `subprocess`, `email`, `ast`, `dis`, `pickle`
- Ferramentas: `unittest`, `venv`, `pip`, `pdb` (debugger), `cProfile`
- GC por contagem de referências + coletor de ciclos
- **Ponto fraco:** sem JIT no interpretador padrão (há um JIT experimental recente), GIL — embora builds *free-threaded* sem GIL já existam —, e empacotamento historicamente bagunçado

### 7. PHP, Ruby, Dart

- **PHP:** OPcache + JIT desde a 8.0, stdlib enorme (porém inconsistente na nomenclatura), PDO, curl, intl, modelo *shared-nothing* por request, FPM, Composer
- **Ruby:** YJIT, Fibers e Ractors, `irb`, RubyGems/Bundler, GC geracional — runtime enxuto, força está nas gems
- **Dart:** JIT em dev com **hot reload** + AOT em produção, isolates (sem memória compartilhada), compila para nativo/JS/Wasm, analyzer + formatter + test inclusos

### Comparativo rápido

| | JIT | GC | Concorrência | Observabilidade | Toolchain incluso |
|---|---|---|---|---|---|
| .NET | Tiered + AOT | Muito bom | async/await, ThreadPool | Muito boa | Completo |
| JVM | O melhor | O melhor | Threads virtuais | Excepcional | Completo |
| BEAM | Sim (BeamAsm) | Por processo | Processos + OTP | Excepcional (live) | Bom |
| Go | Não (AOT) | Latência baixa | Goroutines | Muito boa (pprof) | Completo |
| Node | Sim (V8) | Bom | Event loop + workers | Boa (DevTools) | Bom |
| Python | Experimental | Refcount | GIL/asyncio | Média | Bom |

**Regra prática:**

- Runtime mais completo em capacidade bruta → **.NET ou JVM**
- Ficar de pé apesar de falhas → **BEAM**
- Menor atrito operacional → **Go**
- Maior quantidade de coisa pronta na stdlib → **Python**

---

## Parte 2 — Interseção: o que TODOS os 9 têm de fábrica

Cruzamento entre **.NET, JVM, BEAM, Go, Node.js, Python, PHP, Ruby e Dart**.
Lista única, sem repetição, apenas itens presentes nos 9.

> "De fábrica" inclui a stdlib oficial e o toolchain oficial. Onde a implementação varia muito, está anotado.

### Núcleo do runtime

1. **Gerenciamento automático de memória** — nenhum exige `free()` manual (estratégias diferem: tracing, refcount, por processo)
2. **Portabilidade** — Linux, macOS e Windows a partir do mesmo código-fonte
3. **Tratamento estruturado de erros** — try/catch em 8 deles; Go usa `panic`/`recover` + `defer`, que cumpre o mesmo papel
4. **Stack traces** com arquivo, linha e cadeia de chamadas
5. **FFI / interop com código nativo** — P/Invoke, JNI/FFM, NIFs, cgo, N-API, ctypes, FFI, Fiddle, `dart:ffi`
6. **Sistema de módulos/namespaces** com resolução de dependências
7. **Tipagem em runtime** — todo valor carrega seu tipo, verificável em execução
8. **Flags de configuração do runtime** via variáveis de ambiente e/ou linha de comando

### Concorrência e processos

9. **Alguma forma de execução concorrente** — threads, goroutines, processos BEAM, isolates, fibers ou event loop
10. **I/O não-bloqueante / assíncrono**
11. **Timers e agendamento** (`setTimeout`, `Timer`, `time.After`, `sleep`, `Process.send_after`)
12. **Criação e controle de subprocessos** com captura de stdin/stdout/stderr e exit code

### Dados e tipos primitivos

13. **Strings Unicode** com codificação/decodificação UTF-8
14. **Expressões regulares** (quase todos sobre PCRE ou dialeto próximo)
15. **Coleções básicas** — sequência ordenada, mapa chave-valor e conjunto
16. **Inteiros de precisão arbitrária** (BigInteger, BigInt, bignum nativo)
17. **Ponto flutuante IEEE 754** com dupla precisão
18. **Data e hora** com aritmética temporal e parsing/formatação
19. **Geração de números aleatórios**, incluindo fonte criptograficamente segura
20. **Codificação Base64 e hexadecimal**
21. **Serialização binária** de estruturas em memória (formatos próprios de cada um)

### Compressão

22. **zlib / gzip / deflate** — compressão e descompressão em stream e em buffer

### Criptografia

23. **Funções de hash** — SHA-2 e MD5 no mínimo
24. **HMAC** para autenticação de mensagens
25. **TLS/SSL** como cliente **e** como servidor, com validação de certificado

### Rede

26. **Sockets TCP** (cliente e servidor)
27. **Sockets UDP**
28. **Resolução DNS**
29. **Cliente HTTP** — desde `HttpClient` até `:httpc`
30. **Servidor HTTP** — nem todos com qualidade de produção, mas todos têm algo embutido
31. **Parsing e construção de URL/URI** com escape de componentes

### Sistema de arquivos e SO

32. **I/O de arquivos** — leitura, escrita, append, posicionamento
33. **Manipulação de caminhos** independente de plataforma
34. **Operações de diretório** — criar, listar, remover, percorrer recursivamente
35. **Metadados de arquivo** — tamanho, timestamps, permissões
36. **Arquivos e diretórios temporários**
37. **Variáveis de ambiente** — leitura e escrita
38. **Acesso aos argumentos de linha de comando** (o *parsing* estruturado não é universal)
39. **Código de saída do processo** e encerramento controlado

### Streams

40. **Abstração de stream** de leitura e escrita, componível, sobre arquivo, rede e memória

### Observabilidade

41. **Logging estruturado** com níveis de severidade
42. **Debugger oficial** com breakpoints, step e inspeção de variáveis
43. **Profiler** de CPU e de memória
44. **Métricas do runtime** expostas programaticamente (uso de heap, unidades de concorrência ativas)

### Ferramental

45. **Gerenciador de pacotes oficial** com resolução de versões, lockfile e repositório central público
46. **Framework de testes** oficial ou canônico, com runner e asserções
47. **Geração de documentação** a partir de comentários no código
48. **Ecossistema de build reprodutível** — comando único que baixa dependências e produz o artefato executável

---

## Parte 3 — O que parece universal e NÃO é

Essa parte costuma ser mais útil que a interseção.

| Funcionalidade | Quem NÃO tem de fábrica |
|---|---|
| **JSON** | JVM (ausência mais surpreendente da lista inteira) |
| **XML** | Node, Dart |
| **CSV** | Só Go, Python, PHP e Ruby têm |
| **Criptografia simétrica (AES)** | Dart (`dart:io` só cobre TLS) |
| **REPL** | Go, Dart |
| **Formatador oficial** | Java, C#, Python, Ruby, JS |
| **Parsing de argumentos CLI** | .NET, Java, Dart |
| **Fuso horário histórico completo** | Erlang/Elixir (precisam de `tzdata` externo) |
| **Bytecode intermediário** | Go (compila direto para código de máquina) |
| **Mutex/lock** | BEAM (por design — coordenação é por mensagens) |
| **SQLite embutido** | Só Python (e Bun, no lado JS) |

### Conclusão

O denominador comum entre todos é basicamente:

> *"um Unix decente + TCP + TLS + hash + gzip + gerenciador de pacotes"*

Tudo acima disso — JSON, HTTP de produção, criptografia rica, formatação, banco embutido — é onde os runtimes de fato se diferenciam, e é exatamente onde você vai sentir a diferença no dia a dia.
