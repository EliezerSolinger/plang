# queue.ph — Queue<T>: FIFO ring buffer (ported from the jaketa runtime).
#
#   head -> next to leave
#   size -> live elements
#   cap  -> buffer size
#
# Full when size == cap; resize doubles the capacity and LINEARIZES the
# buffer (copies from head to the end, then from the start to the tail).
#
#   q: Queue<int>
#   q.init()
#   q.push(1)
#   x: int = q.pop()    # assumes size > 0 (C semantics, no check)
#   q.deinit()
include <stdlib.h>
include <string.h>

struct Queue<T>:
    data: *T
    head: i32
    size: i32
    cap: i32

    def init(self: *Queue<T>):
        memset(self, 0, sizeof(*self))

    def grow(self: *Queue<T>):
        if self->size < self->cap:
            return
        nc: i32 = 8 if self->cap == 0 else self->cap * 2
        nd: *T = malloc(sizeof(T) * usize(nc))
        i: i32
        for i in range(self->size):
            nd[i] = self->data[(self->head + i) % self->cap]
        free(self->data)
        self->data = nd
        self->head = 0
        self->cap = nc

    def push(self: *Queue<T>, item: T):
        self->grow()
        self->data[(self->head + self->size) % self->cap] = item
        self->size += 1

    def pop(self: *Queue<T>) -> T:
        v: T = self->data[self->head]
        self->head = (self->head + 1) % self->cap
        self->size -= 1
        return v

    def peek(self: *Queue<T>) -> T:
        return self->data[self->head]

    def is_empty(self: *Queue<T>) -> bool:
        return self->size == 0

    def clear(self: *Queue<T>):
        self->head = 0
        self->size = 0

    def deinit(self: *Queue<T>):
        free(self->data)
        memset(self, 0, sizeof(*self))
