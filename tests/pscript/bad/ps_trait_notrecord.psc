trait Printable:
    def show(in self) -> str


implement Printable for int:
    def show(in self) -> str:
        return "1"
