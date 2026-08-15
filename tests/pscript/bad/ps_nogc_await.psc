# waiting inside `nogc:` would let another task allocate with the collector off
async def work() -> int:
    return 1

nogc:
    v = await work()
    print(v)
