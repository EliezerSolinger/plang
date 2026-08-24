"""The finalizers (136), and the gate that makes a leak a NUMBER.

A `bytes` owns a block the collector does not own — malloc'd, outside the heap,
so a window over it can be a window and not a copy. Something has to give that
block back, and 136.1 says which mechanism: **deterministic for what is SCARCE,
collection for what is MEMORY.** A `bytes` is memory and nothing else, so its
scarcity IS the pressure on the heap, and the collector runs exactly when there
is pressure. That is what lets it have no `close` at all — and what lets it be a
value that circulates, returned from a function and stored in a `Dict`, which is
the thing `with` cannot do because a value has no scope, only reachability.

What this file measures is the other half of 136.3: **the hooks that ran against
the hooks that were registered.** Without that number, "the cleanup is
guaranteed" is a claim nobody checks.
"""
import gc


def churn(n: int) -> int:
    """Make and drop `n` blocks of a kilobyte. Nothing keeps them, so every one
    of them is garbage by the time the next safe point comes round."""
    total = 0
    src: List<u8> = []
    for i in range(1024):
        src.append(u8(i % 251))
    for k in range(n):
        b = bytes(src)
        total += b[0] + b[1023]
    return total


def kept() -> List<bytes>:
    """... and these are NOT garbage: a value that circulates, held in a list.
    A finalizer has to leave them alone, which is the case a `with` could not
    have expressed at all."""
    out: List<bytes> = []
    for i in range(64):
        out.append(("held " + str(i)).encode())
    return out


def main():
    live = kept()

    before = gc.stats()
    n = churn(4000)
    print("churned", n > 0)

    # every dropped block is released by the collector, at the moment there is
    # pressure — so after the churn the number RUN has to have moved
    gc.collect()
    after = gc.stats()
    ran = after["finalizers_run"] - before["finalizers_run"]
    made = after["finalizers"] - before["finalizers"]
    print("registered more than 1000:", made > 1000)
    print("released almost all of them:", ran > made - 100, ran <= made)

    # ... and the 64 that are still reachable are still THERE, with their bytes
    print("kept:", len(live), str(live[0]), str(live[63]))

    # a slice registers NOTHING: it shares the owner's block, so the mechanism
    # costs one entry per block and not one per window
    src = b"abcdefghij"
    b0 = gc.stats()["finalizers"]
    v1 = src[0:5]
    v2 = src[5:10]
    v3 = v1[1:3]
    b1 = gc.stats()["finalizers"]
    print("a window costs no entry:", b1 == b0, str(v1), str(v2), str(v3))

    print("finalizers-ok")


main()
