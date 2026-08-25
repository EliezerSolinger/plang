# psrt_os.ph — a camada de SISTEMA: `os` e `path`.
#
# 111: nasceu do `psys.p` do pstudio (o editor já tinha tudo isto em P) porque
# a decisão 1.1 do pforge manda a camada de sistema para a lib/runtime do
# pscript: dois consumidores diferentes — um gráfico, um paralelo — provam que
# ela está no lugar certo.
#
# O que NÃO está aqui, e por quê:
#   * `chdir`/`umask` — o diretório de trabalho é do PROCESSO e um worker é uma
#     THREAD (18.1), então mudá-lo seria uma corrida entre workers. Um caminho
#     absoluto resolve o mesmo problema sem corrida.
#   * rodar um processo — é a pergunta 1.2 do pforge, e é SUA decisão (síncrono
#     como o `ps_run` do editor, ou uma task com `await`). Nada aqui a antecipa.
import "psrt_types.ph"

# ---------- `os`: o que MUDA o sistema de arquivos ----------
# Os nomes de um diretório, sem `.` nem `..`, ORDENADOS por bytes. O Python não
# ordena (a ordem dele é a do sistema de arquivos), e essa é a divergência
# deliberada: um build e um editor querem a mesma lista sempre, e quem quer a
# ordem do disco não tem como recuperar a determinística — o contrário é
# `sorted()`.
def ps_os_listdir(ctx: *PsCtx, path: *PsStr, file: const *char, line: i32) -> *PsList
# `os.mkdir` cria UM diretório e levanta se ele já existe; `os.makedirs` é o
# `mkdir -p`, e não levanta quando o destino já está lá (é o que um build quer
# de um diretório de saída, e o `exist_ok=True` do Python é o que todo mundo
# escreve).
def ps_os_mkdir(ctx: *PsCtx, path: *PsStr, parents: bool, file: const *char, line: i32)
def ps_os_remove(ctx: *PsCtx, path: *PsStr, file: const *char, line: i32)
def ps_os_rmdir(ctx: *PsCtx, path: *PsStr, file: const *char, line: i32)
def ps_os_rename(ctx: *PsCtx, src: *PsStr, dst: *PsStr, file: const *char, line: i32)
def ps_os_getcwd(ctx: *PsCtx, file: const *char, line: i32) -> *PsStr

# ---------- `path`: contas sobre o NOME, e três perguntas ao disco ----------
# `join`/`dirname`/`basename`/`normpath` são o `posixpath` do Python à letra —
# inclusive os casos que surpreendem (`dirname('a')` é `''`, não `'.'`;
# `join(a, '/b')` é `'/b'`) — porque é o oráculo `python3` que os confere.
def ps_os_join(ctx: *PsCtx, a: *PsStr, b: *PsStr) -> *PsStr
def ps_os_dirname(ctx: *PsCtx, p: *PsStr) -> *PsStr
def ps_os_basename(ctx: *PsCtx, p: *PsStr) -> *PsStr
def ps_os_normpath(ctx: *PsCtx, p: *PsStr) -> *PsStr
def ps_os_abspath(ctx: *PsCtx, p: *PsStr, file: const *char, line: i32) -> *PsStr
# as três do disco: existe, é diretório, é arquivo. Um caminho que não existe é
# `False` nas três — como no Python, e é o que faz `if not path.exists(p):` ler
# do jeito certo em vez de levantar.
def ps_os_exists(ctx: *PsCtx, p: *PsStr, kind: i32, file: const *char, line: i32) -> bool
# tamanho e mtime LEVANTAM quando o caminho não existe (o Python também): não há
# valor honesto para devolver, e um build que confunde "não existe" com "mtime 0"
# reconstrói o mundo ou nada.
def ps_os_getsize(ctx: *PsCtx, p: *PsStr, file: const *char, line: i32) -> i64
def ps_os_getmtime(ctx: *PsCtx, p: *PsStr, file: const *char, line: i32) -> i64

# 118: o mtime em NANOSSEGUNDOS (o `getmtime` acima continua em segundos, que é o
# que o Python devolve e o que o oráculo confere). Um build que compara mtime em
# segundos não distingue dois arquivos escritos no mesmo segundo — e é assim que
# um incremental esquece de refazer alguma coisa.
def ps_os_getmtime_ns(ctx: *PsCtx, p: *PsStr, file: const *char, line: i32) -> i64
# 118: quantos núcleos a máquina tem, para quem decide quantos processos manter
# em voo
def ps_os_nproc() -> i64

# ---------- 118 / pforge 1.2: rodar um processo ----------
# `await os.run(argv, env=, cwd=, stdout=, console=)` -> um processo terminado,
# com o status e tudo que ele imprimiu. Sem shell: o comando é um VETOR, e o
# `execvp` o recebe como está. Ver o comentário em psrt_os.p para o porquê de
# cada decisão; o `waitpid` mora numa thread do pool.
#
# `console=True` é a ausência de captura: o filho herda ESTE terminal, e o que
# volta é só o status. É o `pool = console` do ninja visto de baixo, e quem
# garante que só uma aresta dessas corre de cada vez é o executor.
def ps_os_run(ctx: *PsCtx, argv: *PsList, env: *PsDict, cwd: *PsStr, outfile: *PsStr, console: bool, file: const *char, line: i32) -> *PsTask
def ps_os_exec(ctx: *PsCtx, argv: *PsList, file: const *char, line: i32)
def ps_os_spawn(ctx: *PsCtx, argv: *PsList, file: const *char, line: i32) -> i64
def ps_os_kill(ctx: *PsCtx, pid: i64)
def ps_os_alive(ctx: *PsCtx, pid: i64) -> bool
# F8: a child on a pseudo-terminal. What comes back is the same `Conn` a socket
# is, so `read`, `write` and `close` are the ones that already exist.
def ps_os_spawn_pty(ctx: *PsCtx, argv: *PsList, cols: i64, rows: i64, file: const *char, line: i32) -> *PsConn
def ps_os_pty_resize(ctx: *PsCtx, c: *PsConn, cols: i64, rows: i64)
def ps_os_pty_pid(ctx: *PsCtx, c: *PsConn) -> i64

# ---------- 137: o mapa de disco ----------
# `os.mmap(p)` — o ficheiro em memória, sem o ler. Um tipo PRÓPRIO porque DÁ
# coisas que não cabem num valor (`advise`, `sync`, `lock`), e porque FECHA:
# um mapa é espaço de endereçamento, um inode e um descritor, e essas coisas
# esgotam-se muito antes do monte (136.1).
def ps_map_open(ctx: *PsCtx, p: *PsStr, mode: *PsStr, off: i64, n: i64, has_region: bool, file: const *char, line: i32) -> *PsMapping
def ps_map_len(m: *PsMapping) -> i64
# fatia-se em `bytes` SEM copiar: o bloco é do núcleo e não se move (137.1)
def ps_map_slice(ctx: *PsCtx, m: *PsMapping, a: i64, b: i64, st: i64, has_a: bool, has_b: bool, file: const *char, line: i32) -> *PsBytes
def ps_map_advise(ctx: *PsCtx, m: *PsMapping, how: i64, file: const *char, line: i32)
def ps_map_sync(ctx: *PsCtx, m: *PsMapping, file: const *char, line: i32)
def ps_map_lock(ctx: *PsCtx, m: *PsMapping, file: const *char, line: i32)
def ps_map_close(ctx: *PsCtx, m: *PsMapping)

# ---------- 140/F4 ----------
# tudo o que o disco sabe do nome, de UMA vez (um Dict, como o `gc.stats`)
def ps_os_stat(ctx: *PsCtx, path: *PsStr, file: const *char, line: i32) -> *PsDict
# percorrer um directório SEM construir a lista inteira primeiro. `next` dá None
# no fim, e é o fim do laço.
def ps_dir_open(ctx: *PsCtx, path: *PsStr, file: const *char, line: i32) -> *PsDirIter
def ps_dir_next(ctx: *PsCtx, it: *PsDirIter) -> *PsStr
# ler e escrever POR POSIÇÃO: sem cursor, portanto seguro a partir de workers
def ps_os_pread(ctx: *PsCtx, f: *PsFile, b: *PsBuffer, off: i64, n: i64, file: const *char, line: i32) -> i64
def ps_os_pwrite(ctx: *PsCtx, f: *PsFile, b: *PsBuffer, off: i64, n: i64, file: const *char, line: i32) -> i64
# 135.10: o tamanho de um ficheiro já aberto, perguntado ao DESCRITOR
def ps_file_size(ctx: *PsCtx, f: *PsFile, file: const *char, line: i32) -> i64
