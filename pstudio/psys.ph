# psys.ph — the pstudio system layer (OS ONLY: files, processes, time).
#
# The VFS is an interface of function pointers: the editor never calls libc's
# file functions directly — it calls the active backend. Today there is the
# `local` backend; a future `ssh/sftp` one is just another filled-in Vfs
# (transport over a subprocess, see DESIGN.md). WHOLE-FILE API by design: an
# editor loads and saves entire files; write is atomic (temp + rename).
include <stddef.h>

struct PsStat:
    exists: bool
    is_dir: bool
    size: i64
    mtime: i64       # unix seconds (detects external changes)

struct PsDirEntry:
    name: *char      # malloc'd (free with ps_entries_free)
    is_dir: bool

# A VFS backend. The signatures take raw pointers (not byref) because
# function-pointer types don't carry the out/ref/in modifiers — the WRAPPERS
# below provide the comfortable interface.
struct Vfs:
    ctx: *void
    read_all_fn: def(ctx: *void, path: const *char, out_len: *usize) -> *char
    write_all_fn: def(ctx: *void, path: const *char, data: const *char, len: usize) -> bool
    list_dir_fn: def(ctx: *void, path: const *char, out_n: *i32) -> *PsDirEntry
    stat_fn: def(ctx: *void, path: const *char, out_st: *PsStat) -> bool

# ---- wrappers (the API the editor uses) ----
# reads the whole file; None on error. malloc'd, NUL-terminated buffer
# (len does NOT count the NUL) — treat it as a string or as bytes.
def vfs_read_all(in v: Vfs, path: const *char, out len: usize) -> *char

# writes the whole file ATOMICALLY (temp in the same dir + rename)
def vfs_write_all(in v: Vfs, path: const *char, data: const *char, len: usize) -> bool

# lists a directory (sorted: dirs first, then by name); None on error;
# free with ps_entries_free
def vfs_list_dir(in v: Vfs, path: const *char, out n: i32) -> *PsDirEntry

def vfs_stat(in v: Vfs, path: const *char, out st: PsStat) -> bool

def ps_entries_free(entries: *PsDirEntry, n: i32)

# ---- local backend (libc) ----
def vfs_local() -> Vfs

# ---- processes ----
# runs a command (sh -c), capturing stdout+stderr together; returns the exit
# code. output is malloc'd and NUL-terminated (None if it never ran).
def ps_run(cmd: const *char, out output: *char) -> i32

# ---- time ----
def ps_millis() -> i64          # monotonic clock, milliseconds

# ---- paths ----
def ps_path_join(a: const *char, b: const *char) -> *char   # malloc'd
def ps_path_dirname(path: const *char) -> *char             # malloc'd
def ps_path_basename(path: const *char) -> const *char      # points inside `path`
