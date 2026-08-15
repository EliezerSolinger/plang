"""`with` over your own type (68.4): the trait `Closeable`, from the prelude.

`with` takes anything that DECLARES Closeable — nominal, like every use of a
trait (66.2) — and calls `close()` on every way out of the block, the error
path included, because the release lowers to P's `defer`. A file and a buffer
are simply the two implementations the runtime ships.
"""


struct Session:
    id: int
    open_count: int


implement Closeable for Session:
    def close(self):
        self.open_count -= 1
        print("closed", self.id)


log: list<str> = []

s = Session(7, 1)
with s as sess:
    print("inside", sess.id, sess.open_count)
print("after", s.open_count)

# the error path closes too
t = Session(9, 1)
try:
    with t as sess2:
        boom = 1 // 0
        print("unreachable")
catch e:
    print("caught:", e.message)
print("still closed:", t.open_count)
