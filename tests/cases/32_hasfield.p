# hasfield(x, "name") — comptime test for a struct member, folded to True/False
# so `if hasfield(...)` prunes and the DEAD branch is never type-checked. That
# last part is the whole point: the untaken branch may name a member that does
# not exist here at all, which is what makes it usable for libc shapes that
# differ per platform.
#
# The case that motivated it: `struct stat`'s modification time. glibc has
# `st_mtim` (POSIX.1-2008), macOS has `st_mtimespec` (__DARWIN_UNIX03), older
# systems have a plain `st_mtime` — and the one portable NAME, `st_mtime`, is a
# MACRO on both modern libcs, so it is gone by the time P sees the struct and
# cannot be spelled. The pscript runtime (psrt_os.p) selects with hasfield.
include <stdio.h>

struct Ts:
    tv_sec: i64
    tv_nsec: i64

struct Linuxish:
    st_mode: u32
    st_mtim: Ts

struct Macish:
    st_mode: u32
    st_mtimespec: Ts

struct Old:
    st_mode: u32
    st_mtime: i64

# the same three-way selection psrt_os.p makes, once per struct. Each call compiles
# only ONE of the three bodies; the other two name members the argument's type
# does not have, and are discarded before checking.
def secs_l(in s: Linuxish) -> i64:
    if hasfield(s, "st_mtim"):
        return s.st_mtim.tv_sec
    elif hasfield(s, "st_mtimespec"):
        return s.st_mtimespec.tv_sec
    else:
        return s.st_mtime

def secs_m(in s: Macish) -> i64:
    if hasfield(s, "st_mtim"):
        return s.st_mtim.tv_sec
    elif hasfield(s, "st_mtimespec"):
        return s.st_mtimespec.tv_sec
    else:
        return s.st_mtime

def secs_v(in s: Old) -> i64:
    if hasfield(s, "st_mtim"):
        return s.st_mtim.tv_sec
    elif hasfield(s, "st_mtimespec"):
        return s.st_mtimespec.tv_sec
    else:
        return s.st_mtime

# through a POINTER: hasfield(p, "x") asks about *p
def by_pointer(p: *Macish) -> i64:
    if hasfield(p, "st_mtimespec"):
        return p->st_mtimespec.tv_sec
    return -1

def main() -> i32:
    l: Linuxish = {0, {11, 0}}
    m: Macish = {0, {22, 0}}
    v: Old = {0, 33}
    printf("%lld %lld %lld %lld\n", secs_l(in l), secs_m(in m), secs_v(in v), by_pointer(&m))
    # usable as a plain comptime boolean too
    printf("%d %d\n", 1 if hasfield(l, "st_mtim") else 0, 1 if hasfield(l, "st_mtimespec") else 0)
    return 0
