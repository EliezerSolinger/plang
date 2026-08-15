record Rows implements Iterable:
    at: int

    type Item = int

    def has_next(in self) -> bool:
        return self.at < 3

    def next(in self) -> int:
        return self.at


for x in Rows(0):
    print(f"{x}")
