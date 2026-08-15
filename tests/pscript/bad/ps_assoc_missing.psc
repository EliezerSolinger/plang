trait Counter:
    type Item
    def next(in self) -> Item


record Upto implements Counter:
    at: int

    def next(in self) -> int:
        return self.at
