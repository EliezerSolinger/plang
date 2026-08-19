def build(n):
    parts = []
    for i in range(n):
        parts.append("item-" + str(i))
    return len(",".join(parts))
print(build(200000))
