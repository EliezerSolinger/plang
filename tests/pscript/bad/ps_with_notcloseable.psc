# `with` takes a Closeable implementer (68.4) — nominal, so a close() that was
# never declared does not count
struct Session:
    id: int

    def close(self):
        self.id = 0


s = Session(1)
with s as x:
    print(x.id)
