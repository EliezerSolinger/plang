# vec.ph — Vec<T>: STL generic dynamic array.
# Template: does not generate C. Use `declare Vec<T>` (definition) and
# `implement Vec<T>` (bodies, in a single .p file).
#
#   v: Vec<int>
#   v.init()
#   v.push(42)
#   x: int = v.get(0)
#   v.deinit()
#
# No bounds-check (C semantics); manual memory via init/deinit.
include <stdlib.h>
include <string.h>

struct Vec<T>:
    data: *T
    len: i32
    cap: i32

    def init(self: *Vec<T>):
        self->data = None
        self->len = 0
        self->cap = 0

    # ensures capacity for at least n elements
    def reserve(self: *Vec<T>, n: i32):
        if n <= self->cap:
            return
        nc: i32 = 8 if self->cap == 0 else self->cap
        while nc < n:
            nc *= 2
        self->data = realloc(self->data, sizeof(T) * usize(nc))
        self->cap = nc

    def push(self: *Vec<T>, item: T):
        self->reserve(self->len + 1)
        self->data[self->len] = item
        self->len += 1

    def pop(self: *Vec<T>) -> T:
        self->len -= 1
        return self->data[self->len]

    def get(self: *Vec<T>, i: i32) -> T:
        return self->data[i]

    def set(self: *Vec<T>, i: i32, item: T):
        self->data[i] = item

    def last(self: *Vec<T>) -> T:
        return self->data[self->len - 1]

    def is_empty(self: *Vec<T>) -> bool:
        return self->len == 0

    # removes while preserving order (O(n))
    def remove_at(self: *Vec<T>, i: i32):
        memmove(&self->data[i], &self->data[i + 1], sizeof(T) * usize(self->len - i - 1))
        self->len -= 1

    # removes by swapping with the last element (O(1), does not preserve order)
    def swap_remove(self: *Vec<T>, i: i32):
        self->len -= 1
        self->data[i] = self->data[self->len]

    def clear(self: *Vec<T>):
        self->len = 0

    def deinit(self: *Vec<T>):
        free(self->data)
        self->data = None
        self->len = 0
        self->cap = 0
