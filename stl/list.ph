# list.ph — List<T>: STL dynamic array with a Python-flavored API.
#
# Like Vec<T> (contiguous, grows geometrically), plus Python list ergonomics:
# append/pop/insert/remove/index/contains/count/extend, and negative indices in
# get/set/pop. Value comparison (contains/index/remove/count) DISPATCHES ON T at
# compile time via `match type`: *char is compared BY CONTENT (strcmp), anything
# else BY BYTES — so List<*char> "just works" like Python. The list does NOT own
# the elements. `defer l.deinit()`.
import <stdlib.h>
import <string.h>

struct List<T>:
    data: *T
    len: i32
    cap: i32

    def init(self: *List<T>):
        self->data = None
        self->len = 0
        self->cap = 0

    def reserve(self: *List<T>, n: i32):
        if n <= self->cap:
            return
        nc: i32 = 8 if self->cap == 0 else self->cap * 2
        while nc < n:
            nc *= 2
        self->data = realloc(self->data, sizeof(T) * usize(nc))
        self->cap = nc

    # resolves a possibly-negative index (Python style): -1 = last
    def fix_index(self: *List<T>, i: i32) -> i32:
        return i + self->len if i < 0 else i

    def append(self: *List<T>, item: T):
        self->reserve(self->len + 1)
        self->data[self->len] = item
        self->len += 1

    def pop(self: *List<T>) -> T:
        self->len -= 1
        return self->data[self->len]

    def get(self: *List<T>, i: i32) -> T:
        return self->data[self->fix_index(i)]

    def set(self: *List<T>, i: i32, item: T):
        self->data[self->fix_index(i)] = item

    def insert(self: *List<T>, at: i32, item: T):
        p: i32 = self->fix_index(at)
        self->reserve(self->len + 1)
        j: i32
        for j in range(self->len, p, -1):
            self->data[j] = self->data[j - 1]
        self->data[p] = item
        self->len += 1

    def remove_at(self: *List<T>, at: i32):
        p: i32 = self->fix_index(at)
        j: i32
        for j in range(p, self->len - 1):
            self->data[j] = self->data[j + 1]
        self->len -= 1

    # element equality — content for *char, raw bytes otherwise (compile-time)
    def eq(self: *List<T>, a: T, b: T) -> bool:
        match type(a):
            case *char:
                return strcmp(a, b) == 0
            case _:
                return memcmp(&a, &b, sizeof(T)) == 0

    def index(self: *List<T>, item: T) -> i32:
        i: i32
        for i in range(self->len):
            if self->eq(self->data[i], item):
                return i
        return -1

    def contains(self: *List<T>, item: T) -> bool:
        return self->index(item) >= 0

    def count(self: *List<T>, item: T) -> i32:
        c: i32 = 0
        i: i32
        for i in range(self->len):
            if self->eq(self->data[i], item):
                c += 1
        return c

    # removes the first element equal to `item`; True if one was removed
    def remove(self: *List<T>, item: T) -> bool:
        idx: i32 = self->index(item)
        if idx < 0:
            return False
        self->remove_at(idx)
        return True

    def extend(self: *List<T>, other: *List<T>):
        i: i32
        for i in range(other->len):
            self->append(other->data[i])

    def clear(self: *List<T>):
        self->len = 0

    def deinit(self: *List<T>):
        free(self->data)
        self->data = None
        self->len = 0
        self->cap = 0
