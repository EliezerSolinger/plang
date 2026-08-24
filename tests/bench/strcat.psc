"""Building text: allocation and the collector, which is what this measures."""

def build(n: int) -> int:
    parts: List<str> = []
    for i in range(n):
        parts.append("item-" + str(i))
    joined = ",".join(parts)
    return len(joined)


print(build(200000))
