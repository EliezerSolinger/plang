# `xs[i] op= v` and `d[k] op= v`: the element is READ, the operator applied and
# the result written back — and the container and the index are each evaluated
# exactly ONCE, which is what makes a side effect in the index behave.

calls = 0

def idx() -> int:
    global calls
    calls += 1
    return 1

def main():
    xs = [10, 20, 30]
    xs[0] += 5
    xs[1] *= 3
    xs[2] //= 4
    print(xs[0], xs[1], xs[2])

    d: Dict<str, int> = {"a": 1, "b": 2}
    d["a"] += 41
    d["b"] **= 3
    print(d["a"], d["b"])

    # the index runs ONCE, like Python
    xs[idx()] += 1
    print("calls", calls, "value", xs[1])

    # floats and strings travel the same path
    fs = [1.5, 2.5]
    fs[0] /= 0.5
    print(fs[0])
    ss = ["a", "b"]
    ss[1] += "!"
    print(ss[1])

    # a nested container: the inner list is read once, not rebuilt
    grid: List<List<int>> = [[1, 2], [3, 4]]
    grid[1][0] -= 3
    print(grid[1][0])

    # the checks a plain read has are still there
    try:
        d["missing"] += 1
    catch e:
        print("missing key:", e.category == KEY)
    try:
        xs[9] += 1
    catch e:
        print("out of range:", e.category == INDEX)

main()
