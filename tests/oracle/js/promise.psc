"""test262's promises about promises, asked of both runtimes.

test262's Promise directory does not port literally: it drives `Promise.resolve`,
thenables and the resolve-element functions, and we have none of those. What DOES
port is every property those tests exist to pin down — the order `all` answers
in, whether `allSettled` keeps the input's order, what `any` does with the
failures that came before the first success, whether awaiting a task that has
already finished still gives the others a turn. Those are promises OUR design
makes too (35.1, 78.4, 79.x), so they are asked here in both languages and the
answers diffed.

Where the two models genuinely differ this says so and prints the difference on
purpose. There is one: our `race` CANCELS the losers and JS's leaves them
running, so a race is compared on its winner and never on what became of the
loser. A silent skip is how a divergence becomes a feature nobody chose.
"""

log: List<str> = []


async def after(ms: int, name: str) -> str:
    await sleep(float(ms) / 1000.0)
    log.append(name)
    return name


async def boom(ms: int, name: str) -> str:
    await sleep(float(ms) / 1000.0)
    log.append("!" + name)
    raise error("boom " + name, VALUE)
    return name


async def main_task() -> int:
    # 1. `all` answers in the order the tasks were GIVEN. The three below finish
    #    backwards, which is the whole point of the test.
    vs = await gather([after(30, "slow"), after(20, "mid"), after(10, "fast")])
    print("all", vs[0], vs[1], vs[2])
    print("finished", log[0], log[1], log[2])

    # 2. One failure, and the await raises it. (Two failures at different times
    #    is NOT asked: JS rejects with the temporally first and that is a
    #    tie-break nobody here has decided.)
    try:
        bad = await gather([after(10, "ok1"), boom(20, "b")])
        print("all: no error?!", len(bad))
    catch e:
        print("all raised", e.message)

    # 3. `allSettled` waits for everyone and answers in the INPUT's order, with
    #    the failures in place instead of bringing the set down.
    ts = [boom(30, "x"), after(10, "y"), boom(20, "z")]
    errs = await gather_settled(ts)
    i = 0
    while i < len(errs):
        se = errs[i]
        if se != None:
            print("settled", i, "failed", se.message)
        else:
            print("settled", i, "gave", await ts[i])
        i += 1

    # 4. The first SUCCESS, with the failures before it ignored — `any`.
    which = [boom(10, "p"), after(20, "q"), boom(30, "r")]
    k = await first_ok(which)
    print("any", k, await which[k])

    # 5. A race is compared on its winner. In JS the loser keeps running; here
    #    it is cancelled. Same winner either way, and that is what is asked.
    print("race", await race([after(40, "tortoise"), after(5, "hare")]))

    # 6. Awaiting the same task twice gives the same answer once — a task
    #    settles once and stays settled.
    once = after(10, "once")
    a1 = await once
    a2 = await once
    print("settled once", a1, a2)

    # 7. An `async def` that raises does not raise where it is CALLED. It is
    #    started there (35.1) and the error arrives at the await.
    t = boom(10, "late")
    print("called, not raised yet")
    try:
        await t
        print("no error?!")
    catch e:
        print("raised at the await", e.message)
    return 0


rc = await main_task()
