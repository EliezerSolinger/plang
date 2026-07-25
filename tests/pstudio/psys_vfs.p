include <stdio.h>
include <stdlib.h>
include <string.h>
import "../../pstudio/psys.ph"

def main() -> int:
    v: Vfs = vfs_local()
    # atomic write + read
    ok: bool = vfs_write_all(in v, "/tmp/pstudio_vfs_test.txt", "hello vfs\n", 10)
    printf("write=%d\n", ok)
    n: usize
    data: *char = vfs_read_all(in v, "/tmp/pstudio_vfs_test.txt", out n)
    printf("read=%zu [%s]", n, data)
    free(data)
    # stat
    st: PsStat
    vfs_stat(in v, "/tmp/pstudio_vfs_test.txt", out st)
    printf("stat: exists=%d dir=%d size=%lld\n", st.exists, st.is_dir, st.size)
    # list (just checks that listing the root works and does not crash)
    cnt: i32
    es: *PsDirEntry = vfs_list_dir(in v, "/", out cnt)
    printf("list_root=%d\n", 1 if cnt > 0 else 0)
    ps_entries_free(es, cnt)
    # paths
    j: *char = ps_path_join("/a/b", "c.p")
    d: *char = ps_path_dirname(j)
    printf("join=%s dir=%s base=%s\n", j, d, ps_path_basename(j))
    free(j)
    free(d)
    # the monotonic clock advances
    t0: i64 = ps_millis()
    printf("clock=%d\n", 1 if t0 >= 0 else 0)
    # processes
    outp: *char
    rc: i32 = ps_run("echo proc-ok", out outp)
    printf("run rc=%d out=%s", rc, outp)
    free(outp)
    remove("/tmp/pstudio_vfs_test.txt")
    return 0
