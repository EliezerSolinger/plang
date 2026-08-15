enum Color:
    RED
    GREEN
    BLUE

record Pt:
    x: int
    y: int

record Line:
    a: Pt
    b: Pt
    tint: Color

struct Named:
    label: str
    at: Pt

struct Money:
    cents: int
    def to_str(self) -> str:
        return "$" + str(self.cents // 100)

def main():
    p = Pt(1, 2)
    print(p)
    print(Line(Pt(0, 0), Pt(3, 4), BLUE))
    print(GREEN)
    n = Named("origin", p)
    print(n)
    print(Money(250))
    print("value:", p, "and", RED)
    print(f"in a string: {p} / {BLUE} / {Money(99)}")
    print(str(p) == "Pt(x=1, y=2)")
main()
