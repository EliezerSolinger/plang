# psys.p — the system layer implemented over libc (the `local` backend).
include <stdio.h>
include <stdlib.h>
include <string.h>
include <dirent.h>
include <sys/stat.h>
include <unistd.h>
include <time.h>
import "psys.ph"

# ---------- local backend ----------
static def ps_stat_path(path: const *char, out st: PsStat) -> bool

static def local_read_all(ctx: *void, path: const *char, out_len: *usize) -> *char:
    f: *FILE = fopen(path, "rb")
    if f == None:
        return None
    fseek(f, 0, SEEK_END)
    n: i64 = ftell(f)
    if n < 0:
        fclose(f)
        return None
    fseek(f, 0, SEEK_SET)
    buf: *char = malloc(usize(n) + 1)
    got: usize = fread(buf, 1, usize(n), f)
    fclose(f)
    buf[got] = '\0'
    out_len[0] = got
    return buf

static def local_write_all(ctx: *void, path: const *char, data: const *char, len: usize) -> bool:
    # atomic: write a temp in the SAME directory, then rename over the target
    tmp: *char = malloc(strlen(path) + 8)
    strcpy(tmp, path)
    strcat(tmp, ".pstmp")
    f: *FILE = fopen(tmp, "wb")
    if f == None:
        free(tmp)
        return False
    ok: bool = fwrite(data, 1, len, f) == len
    if fclose(f) != 0:
        ok = False
    if ok and rename(tmp, path) != 0:
        ok = False
    if not ok:
        remove(tmp)
    free(tmp)
    return ok

# sort order: directories first, then by name (plain case-sensitive)
static def entry_less(a: *PsDirEntry, b: *PsDirEntry) -> bool:
    if a->is_dir != b->is_dir:
        return a->is_dir
    return strcmp(a->name, b->name) < 0

static def local_list_dir(ctx: *void, path: const *char, out_n: *i32) -> *PsDirEntry:
    d: *DIR = opendir(path)
    if d == None:
        return None
    entries: *PsDirEntry = None
    n = 0; cap = 0
    while True:
        de: *dirent = readdir(d)
        if de == None:
            break
        nm: const *char = de->d_name
        if strcmp(nm, ".") == 0 or strcmp(nm, "..") == 0:
            continue
        full: *char = ps_path_join(path, nm)
        st: PsStat
        ok: bool = ps_stat_path(full, out st)
        free(full)
        if not ok:
            continue
        if n >= cap:
            cap = 16 if cap == 0 else cap * 2
            entries = realloc(entries, usize(cap) * sizeof(*entries))
        entries[n].name = malloc(strlen(nm) + 1)
        strcpy(entries[n].name, nm)
        entries[n].is_dir = st.is_dir
        n += 1
    closedir(d)
    # insertion sort (directory listings are small)
    for i in range(1, n):
        j: i32 = i
        while j > 0 and entry_less(&entries[j], &entries[j - 1]):
            t: PsDirEntry = entries[j]
            entries[j] = entries[j - 1]
            entries[j - 1] = t
            j -= 1
    out_n[0] = n
    return entries

static def ps_stat_path(path: const *char, out st: PsStat) -> bool:
    sb: stat
    st.exists = False
    st.is_dir = False
    st.size = 0
    st.mtime = 0
    if stat(path, &sb) != 0:
        return False
    st.exists = True
    # S_ISDIR is a macro (it vanishes on ingest): stable POSIX mask
    st.is_dir = (i32(sb.st_mode) & 0xF000) == 0x4000
    st.size = i64(sb.st_size)
    # `struct stat`'s modification time has no single spelling across libcs, and
    # the one portable NAME is a macro, so it is gone by the time P sees the
    # struct. `hasfield` picks at compile time and the dead branch is never
    # checked (so naming a field the platform lacks is fine):
    #   glibc  st_mtim      (struct timespec, POSIX.1-2008; needs -D_DEFAULT_SOURCE
    #                        under a strict -std=cNN, which the test suite passes)
    #   macOS  st_mtimespec (struct timespec, __DARWIN_UNIX03 — the default)
    #   older  st_mtime     (plain time_t member, no sub-second part)
    if hasfield(sb, "st_mtim"):
        st.mtime = i64(sb.st_mtim.tv_sec)
    elif hasfield(sb, "st_mtimespec"):
        st.mtime = i64(sb.st_mtimespec.tv_sec)
    else:
        st.mtime = i64(sb.st_mtime)
    return True

static def local_stat(ctx: *void, path: const *char, out_st: *PsStat) -> bool:
    return ps_stat_path(path, out_st)

def vfs_local() -> Vfs:
    v: Vfs = {0}
    with v:
        .ctx = None
        .read_all_fn = local_read_all
        .write_all_fn = local_write_all
        .list_dir_fn = local_list_dir
        .stat_fn = local_stat
    return v

# ---------- wrappers ----------

def vfs_read_all(in v: Vfs, path: const *char, out len: usize) -> *char:
    len = 0
    return v.read_all_fn(v.ctx, path, &len)

def vfs_write_all(in v: Vfs, path: const *char, data: const *char, len: usize) -> bool:
    return v.write_all_fn(v.ctx, path, data, len)

def vfs_list_dir(in v: Vfs, path: const *char, out n: i32) -> *PsDirEntry:
    n = 0
    return v.list_dir_fn(v.ctx, path, &n)

def vfs_stat(in v: Vfs, path: const *char, out st: PsStat) -> bool:
    return v.stat_fn(v.ctx, path, &st)

def ps_entries_free(entries: *PsDirEntry, n: i32):
    for i in range(n):
        free(entries[i].name)
    free(entries)

# ---------- processes ----------

def ps_run(cmd: const *char, out output: *char) -> i32:
    output = None
    full: *char = malloc(strlen(cmd) + 8)
    strcpy(full, cmd)
    strcat(full, " 2>&1")
    f: *FILE = popen(full, "r")
    free(full)
    if f == None:
        return -1
    buf: *char = None
    n: usize = 0
    cap: usize = 0
    chunk: char[4096]
    while True:
        got: usize = fread(chunk, 1, sizeof(chunk), f)
        if got == 0:
            break
        if n + got + 1 > cap:
            cap = 8192 if cap == 0 else cap * 2
            while cap < n + got + 1:
                cap *= 2
            buf = realloc(buf, cap)
        memcpy(buf + n, chunk, got)
        n += got
    rc: i32 = pclose(f)
    if buf == None:
        buf = malloc(1)
    buf[n] = '\0'
    output = buf
    # WEXITSTATUS without the macro (POSIX layout: the high byte)
    if rc < 0:
        return -1
    return (rc >> 8) & 0xff

# ---------- time ----------

def ps_millis() -> i64:
    ts: timespec
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return i64(ts.tv_sec) * 1000 + i64(ts.tv_nsec) / 1000000

# ---------- paths ----------

def ps_path_join(a: const *char, b: const *char) -> *char:
    la: usize = strlen(a)
    r: *char = malloc(la + strlen(b) + 2)
    strcpy(r, a)
    if la > 0 and a[la - 1] != '/':
        strcat(r, "/")
    strcat(r, b)
    return r

def ps_path_dirname(path: const *char) -> *char:
    slash: const *char = strrchr(path, '/')
    if slash == None:
        r: *char = malloc(2)
        strcpy(r, ".")
        return r
    n: usize = usize(slash - path)
    if n == 0:
        n = 1   # "/x" -> "/"
    r2: *char = malloc(n + 1)
    memcpy(r2, path, n)
    r2[n] = '\0'
    return r2

def ps_path_basename(path: const *char) -> const *char:
    slash: const *char = strrchr(path, '/')
    return slash + 1 if slash != None else path
