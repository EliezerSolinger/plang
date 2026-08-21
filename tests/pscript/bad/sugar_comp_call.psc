def make() -> list<int>:
    return [1, 2]

print([f"{i}{v}" for i, v in enumerate(make())])
