# nominal (66.2) here too: having has_next/next is not implementing `Iterable`
struct Rows:
    at: int

    def has_next(self) -> bool:
        return self.at < 3

    def next(self) -> int:
        self.at += 1
        return self.at


for x in Rows(0):
    print(f"{x}")
