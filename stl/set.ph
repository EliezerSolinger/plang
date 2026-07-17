# set.ph — Set<T> and StrSet: STL sets (ported from the jaketa runtime).
#
# Same topology as the dict (sparse indices[] + dense entries), but the
# entry is just the key — NO cached hash: the hash is recomputed on each
# resize. Deliberate trade-off: maximum memory savings; resizes are
# rare (amortized O(1)), so the cost is irrelevant in practice.
#
# Set<T>:  keys compared BY BYTES (ints, enums, identity pointers).
# StrSet:  *char keys by CONTENT; the set keeps its own copies.
#          Non-generic: materialize with `implement StrSet` in a .p file.
#
# Iteration (insertion order):
#   i: i32
#   for i in range(s.elen):
#       if not s.dead[i]:
#           ... s.keys[i] ...
import <stdlib.h>
import <string.h>
import "hash.ph"

struct Set<T>:
    indices: *i32
    icap: i32      # capacity of indices[] (power of 2)
    keys: *T       # dense, in insertion order
    dead: *bool
    elen: i32
    ecap: i32
    size: i32
    tombs: i32

    def init(self: *Set<T>):
        memset(self, 0, sizeof(*self))

    def key_hash(self: *Set<T>, key: T) -> u64:
        return hash_bytes((*char)(&key), sizeof(T))

    def key_eq(self: *Set<T>, a: T, b: T) -> bool:
        return memcmp(&a, &b, sizeof(T)) == 0

    def find_slot(self: *Set<T>, key: T, h: u64, out_entry: *i32) -> i32:
        mask: i32 = self->icap - 1
        slot: i32 = i32(h & u64(mask))
        first_tomb: i32 = -1
        while True:
            idx: i32 = self->indices[slot]
            if idx == -1:
                *out_entry = -1
                return first_tomb if first_tomb != -1 else slot
            if idx == -2:
                if first_tomb == -1:
                    first_tomb = slot
            elif not self->dead[idx] and self->key_eq(self->keys[idx], key):
                *out_entry = idx
                return slot
            slot = (slot + 1) & mask

    # compacts the dense arrays and rebuilds indices[]; hash recomputed here
    def rehash(self: *Set<T>, newcap: i32):
        w: i32 = 0
        r: i32
        for r in range(self->elen):
            if not self->dead[r]:
                if w != r:
                    self->keys[w] = self->keys[r]
                self->dead[w] = False
                w += 1
        self->elen = w
        self->tombs = 0
        free(self->indices)
        self->indices = malloc(sizeof(i32) * usize(newcap))
        self->icap = newcap
        i: i32
        for i in range(newcap):
            self->indices[i] = -1
        mask: i32 = newcap - 1
        for i in range(self->elen):
            slot: i32 = i32(self->key_hash(self->keys[i]) & u64(mask))
            while self->indices[slot] != -1:
                slot = (slot + 1) & mask
            self->indices[slot] = i

    def grow_entries(self: *Set<T>):
        if self->elen < self->ecap:
            return
        nc: i32 = 8 if self->ecap == 0 else self->ecap * 2
        self->keys = realloc(self->keys, sizeof(T) * usize(nc))
        self->dead = realloc(self->dead, sizeof(bool) * usize(nc))
        self->ecap = nc

    # True if inserted; False if the key already existed
    def add(self: *Set<T>, key: T) -> bool:
        if self->icap == 0 or (self->size + self->tombs + 1) * 3 >= self->icap * 2:
            self->rehash(8 if self->icap == 0 else self->icap * 2)
        h: u64 = self->key_hash(key)
        entry: i32 = -1
        slot: i32 = self->find_slot(key, h, &entry)
        if entry >= 0:
            return False
        self->grow_entries()
        e: i32 = self->elen
        self->keys[e] = key
        self->dead[e] = False
        self->elen += 1
        if self->indices[slot] == -2:
            self->tombs -= 1
        self->indices[slot] = e
        self->size += 1
        return True

    def has(self: *Set<T>, key: T) -> bool:
        if self->size == 0:
            return False
        entry: i32 = -1
        self->find_slot(key, self->key_hash(key), &entry)
        return entry >= 0

    def remove(self: *Set<T>, key: T) -> bool:
        if self->size == 0:
            return False
        entry: i32 = -1
        slot: i32 = self->find_slot(key, self->key_hash(key), &entry)
        if entry < 0:
            return False
        self->dead[entry] = True
        self->indices[slot] = -2
        self->size -= 1
        self->tombs += 1
        return True

    def clear(self: *Set<T>):
        i: i32
        for i in range(self->icap):
            self->indices[i] = -1
        self->elen = 0
        self->size = 0
        self->tombs = 0

    def deinit(self: *Set<T>):
        free(self->indices)
        free(self->keys)
        free(self->dead)
        memset(self, 0, sizeof(*self))

# StrSet — string keys by content; the set owns copies of the keys
struct StrSet:
    indices: *i32
    icap: i32
    keys: **char
    dead: *bool
    elen: i32
    ecap: i32
    size: i32
    tombs: i32

    def init(self: *StrSet):
        memset(self, 0, sizeof(*self))

    def find_slot(self: *StrSet, key: const *char, h: u64, out_entry: *i32) -> i32:
        mask: i32 = self->icap - 1
        slot: i32 = i32(h & u64(mask))
        first_tomb: i32 = -1
        while True:
            idx: i32 = self->indices[slot]
            if idx == -1:
                *out_entry = -1
                return first_tomb if first_tomb != -1 else slot
            if idx == -2:
                if first_tomb == -1:
                    first_tomb = slot
            elif not self->dead[idx] and strcmp(self->keys[idx], key) == 0:
                *out_entry = idx
                return slot
            slot = (slot + 1) & mask

    def rehash(self: *StrSet, newcap: i32):
        w: i32 = 0
        r: i32
        for r in range(self->elen):
            if not self->dead[r]:
                if w != r:
                    self->keys[w] = self->keys[r]
                self->dead[w] = False
                w += 1
        self->elen = w
        self->tombs = 0
        free(self->indices)
        self->indices = malloc(sizeof(i32) * usize(newcap))
        self->icap = newcap
        i: i32
        for i in range(newcap):
            self->indices[i] = -1
        mask: i32 = newcap - 1
        for i in range(self->elen):
            slot: i32 = i32(hash_cstr(self->keys[i]) & u64(mask))
            while self->indices[slot] != -1:
                slot = (slot + 1) & mask
            self->indices[slot] = i

    def grow_entries(self: *StrSet):
        if self->elen < self->ecap:
            return
        nc: i32 = 8 if self->ecap == 0 else self->ecap * 2
        self->keys = realloc(self->keys, sizeof(self->keys[0]) * usize(nc))
        self->dead = realloc(self->dead, sizeof(bool) * usize(nc))
        self->ecap = nc

    def add(self: *StrSet, key: const *char) -> bool:
        if self->icap == 0 or (self->size + self->tombs + 1) * 3 >= self->icap * 2:
            self->rehash(8 if self->icap == 0 else self->icap * 2)
        h: u64 = hash_cstr(key)
        entry: i32 = -1
        slot: i32 = self->find_slot(key, h, &entry)
        if entry >= 0:
            return False
        self->grow_entries()
        n: usize = strlen(key) + 1
        kcopy: *char = malloc(n)
        memcpy(kcopy, key, n)
        e: i32 = self->elen
        self->keys[e] = kcopy
        self->dead[e] = False
        self->elen += 1
        if self->indices[slot] == -2:
            self->tombs -= 1
        self->indices[slot] = e
        self->size += 1
        return True

    def has(self: *StrSet, key: const *char) -> bool:
        if self->size == 0:
            return False
        entry: i32 = -1
        self->find_slot(key, hash_cstr(key), &entry)
        return entry >= 0

    def remove(self: *StrSet, key: const *char) -> bool:
        if self->size == 0:
            return False
        entry: i32 = -1
        slot: i32 = self->find_slot(key, hash_cstr(key), &entry)
        if entry < 0:
            return False
        free(self->keys[entry])
        self->keys[entry] = None
        self->dead[entry] = True
        self->indices[slot] = -2
        self->size -= 1
        self->tombs += 1
        return True

    def deinit(self: *StrSet):
        i: i32
        for i in range(self->elen):
            if not self->dead[i]:
                free(self->keys[i])
        free(self->indices)
        free(self->keys)
        free(self->dead)
        memset(self, 0, sizeof(*self))
