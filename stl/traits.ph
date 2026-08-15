# traits.ph — the system traits, in the form P can have (67.1/67.4).
#
# A trait in P is STATIC only: a bound on a generic (`def sort<T: Comparable>`)
# that monomorphizes and disappears. There is no `dyn` here — that half lives in
# pscript, where a runtime already exists to carry a box. What P gets is the
# thing it was missing: a contract that is CHECKED, where today there is a
# `*void` and a convention.
#
# The two languages agree on `Comparable` and `Iterable` because they are pure
# method contracts and cost nothing on either side. `Printable` cannot be the
# same in both: in pscript it returns `str`, which is a collected object, so in
# P it WRITES INTO A BUFFER the caller owns (67.4) — same contract, expressed
# in a language that has no allocator behind it.
#
# The receiver is spelled `*TraitName` in the signature: it is a placeholder
# that the implementing type replaces, exactly as `Self` does in pscript.
import "str.ph"

# `cmp(a, b)` is negative, zero or positive, like C's convention — which is what
# every sort in the neighbourhood already speaks.
trait Comparable:
    def cmp(self: *Comparable, other: *Comparable) -> i32

# The protocol of 40.3: `has_next()` then `next()`, and NOT a `next()` that
# returns an option — with an option, iterating a sequence of options cannot
# tell the end from an element that is empty.
trait Iterable:
    def has_next(self: *Iterable) -> bool
    def next(self: *Iterable) -> i64

# 67.4: writing into a buffer, because P has no string to return that someone
# else has to free. `ref` and not `out`: the buffer is the CALLER's, already
# initialized, and what the method does is append to it — `out` in P means the
# callee assigns the whole thing, which is a different promise.
trait Printable:
    def to_str(self: *Printable, ref b: Str)
