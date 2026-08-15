trait Counter:
    type Item
    def next(in self) -> Item


record Upto implements Counter:
    at: int

    type Item = str

    def next(in self) -> int:
        return self.at
