GREET: str = "hi"

def msg(name: str, greet: str = GREET, mark: str = "!") -> str:
    return greet + " " + name + mark

struct Counter:
    n: int
    def bump(self, by: int = 1, times: int = 1):
        self.n += by * times

def main():
    print(msg("ana"))
    print(msg("bo", "yo"))
    print(msg("cy", mark="?"))
    print(msg(name="di", greet="hey", mark="."))
    print(msg(greet="oi", name="ed"))
    c = Counter(0)
    c.bump()
    c.bump(by=5)
    c.bump(times=3, by=2)
    print(c.n)
    # a default is evaluated per call, and reads the module scope even when the
    # caller has a name of its own that looks the same
    GREET = "shadow"
    print(msg("fi"))
main()
