# psys.ph — camada de sistema do pstudio (SÓ OS: arquivos, processos, tempo).
#
# O VFS é uma interface por function pointers: o editor nunca chama a libc de
# arquivos diretamente — chama o backend ativo. Hoje existe o backend `local`;
# um backend `ssh/sftp` futuro é só outra Vfs preenchida (transporte por
# subprocesso, ver DESIGN.md). API de ARQUIVO INTEIRO por decisão de design:
# um editor carrega e salva arquivos inteiros; write é atômico (temp+rename).
include <stddef.h>

struct PsStat:
    exists: bool
    is_dir: bool
    size: i64
    mtime: i64       # segundos unix (detecção de mudança externa)

struct PsDirEntry:
    name: *char      # malloc'd (liberar com ps_entries_free)
    is_dir: bool

# Backend do VFS. As assinaturas usam ponteiros crus (não byref) porque
# tipos de function pointer não carregam os modificadores out/ref/in —
# os WRAPPERS abaixo dão a interface confortável.
struct Vfs:
    ctx: *void
    read_all_fn: def(ctx: *void, path: const *char, out_len: *usize) -> *char
    write_all_fn: def(ctx: *void, path: const *char, data: const *char, len: usize) -> bool
    list_dir_fn: def(ctx: *void, path: const *char, out_n: *i32) -> *PsDirEntry
    stat_fn: def(ctx: *void, path: const *char, out_st: *PsStat) -> bool

# ---- wrappers (a API que o editor usa) ----
# lê o arquivo inteiro; None em erro. Buffer malloc'd, NUL-terminado
# (len NÃO conta o NUL) — livre para tratar como string ou bytes.
def vfs_read_all(in v: Vfs, path: const *char, out len: usize) -> *char

# grava o arquivo inteiro ATOMICAMENTE (temp no mesmo diretório + rename)
def vfs_write_all(in v: Vfs, path: const *char, data: const *char, len: usize) -> bool

# lista um diretório (entradas ordenadas: dirs primeiro, depois nome);
# None em erro; liberar com ps_entries_free
def vfs_list_dir(in v: Vfs, path: const *char, out n: i32) -> *PsDirEntry

def vfs_stat(in v: Vfs, path: const *char, out st: PsStat) -> bool

def ps_entries_free(entries: *PsDirEntry, n: i32)

# ---- backend local (libc) ----
def vfs_local() -> Vfs

# ---- processos ----
# roda um comando (sh -c), captura stdout+stderr juntos; retorna o exit code.
# output é malloc'd NUL-terminado (None se nem rodou).
def ps_run(cmd: const *char, out output: *char) -> i32

# ---- tempo ----
def ps_millis() -> i64          # relógio monotônico, milissegundos

# ---- paths ----
def ps_path_join(a: const *char, b: const *char) -> *char   # malloc'd
def ps_path_dirname(path: const *char) -> *char             # malloc'd
def ps_path_basename(path: const *char) -> const *char      # aponta para dentro
