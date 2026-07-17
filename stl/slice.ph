# slice.ph — Slice<T>: NON-OWNING view over contiguous memory.
#
# In jaketa the slice held the storage via refcount; in P (manual memory)
# it is just {data, len}: it does NOT own the memory and must NOT outlive
# the owner (a Vec that reallocs/deinits, a freed buffer, etc. invalidate
# the slice).
#
#   sl: Slice<int>
#   sl.init_from(v.data, v.len)
#   mid: Slice<int> = sl.sub(3, 4)    # no copy
#
# get/set/sub have no bounds-check (C semantics).

struct Slice<T>:
    data: *T
    len: i32

    def init_from(self: *Slice<T>, data: *T, len: i32):
        self->data = data
        self->len = len

    def get(self: *Slice<T>, i: i32) -> T:
        return self->data[i]

    def set(self: *Slice<T>, i: i32, item: T):
        self->data[i] = item

    def first(self: *Slice<T>) -> T:
        return self->data[0]

    def last(self: *Slice<T>) -> T:
        return self->data[self->len - 1]

    def is_empty(self: *Slice<T>) -> bool:
        return self->len == 0

    # sub-view [offset, offset+len) pointing into the same memory
    def sub(self: *Slice<T>, offset: i32, len: i32) -> Slice<T>:
        s: Slice<T>
        s.data = self->data + offset
        s.len = len
        return s
