# dict.ph — Dict<K, V>: STL dictionary that unifies Map and StrMap.
#
# Same compact, insertion-ordered layout as Map (indices[] + dense
# hashes/keys/vals/dead), but the key handling DISPATCHES ON THE KEY TYPE at
# compile time (via `match type`, zero runtime cost):
#   - K = *char  -> hashed/compared BY CONTENT (FNV-1a + strcmp); the dict owns
#                   a private copy of each key (freed on remove/deinit).
#   - otherwise  -> BY BYTES (ints, enums, identity pointers; sizeof(K) bytes).
# So `Dict<*char, V>` behaves like the old StrMap and `Dict<int, V>` like Map,
# from a single generic type.
#
# Iteration (insertion order):
#   i: i32
#   for i in range(d.elen):
#       if not d.dead[i]:
#           ... d.keys[i] / d.vals[i] ...
import <stdlib.h>
import <string.h>
import "hash.ph"

struct Dict<K, V>:
    indices: *i32
    icap: i32      # capacity of indices[] (power of 2)
    hashes: *u64   # dense, in insertion order
    keys: *K
    vals: *V
    dead: *bool
    elen: i32      # free position in the dense arrays
    ecap: i32
    size: i32      # live entries
    tombs: i32     # tombstones in indices[]

    def init(self: *Dict<K, V>):
        memset(self, 0, sizeof(*self))

    # hash of a key — content for *char, raw bytes otherwise (compile-time dispatch)
    def key_hash(self: *Dict<K, V>, key: K) -> u64:
        match type(key):
            case *char:
                return hash_cstr(key)
            case _:
                return hash_bytes((*char)(&key), sizeof(K))

    # key equality — content for *char, raw bytes otherwise
    def key_eq(self: *Dict<K, V>, a: K, b: K) -> bool:
        match type(a):
            case *char:
                return strcmp(a, b) == 0
            case _:
                return memcmp(&a, &b, sizeof(K)) == 0

    # the dict's stored copy of a key — for *char, a private malloc'd copy
    def own_key(self: *Dict<K, V>, key: K) -> K:
        match type(key):
            case *char:
                n: usize = strlen(key) + 1
                kc: *char = malloc(n)
                memcpy(kc, key, n)
                return kc
            case _:
                return key

    # releases a stored key — frees the copy for *char, nothing otherwise
    def free_key(self: *Dict<K, V>, key: K):
        match type(key):
            case *char:
                free(key)
            case _:
                return

    def find_slot(self: *Dict<K, V>, key: K, h: u64, out_entry: *i32) -> i32:
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
            elif not self->dead[idx] and self->hashes[idx] == h and self->key_eq(self->keys[idx], key):
                *out_entry = idx
                return slot
            slot = (slot + 1) & mask

    def rehash(self: *Dict<K, V>, newcap: i32):
        w: i32 = 0
        r: i32
        for r in range(self->elen):
            if not self->dead[r]:
                if w != r:
                    self->hashes[w] = self->hashes[r]
                    self->keys[w] = self->keys[r]
                    self->vals[w] = self->vals[r]
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
            slot: i32 = i32(self->hashes[i] & u64(mask))
            while self->indices[slot] != -1:
                slot = (slot + 1) & mask
            self->indices[slot] = i

    def grow_entries(self: *Dict<K, V>):
        if self->elen < self->ecap:
            return
        nc: i32 = 8 if self->ecap == 0 else self->ecap * 2
        self->hashes = realloc(self->hashes, sizeof(u64) * usize(nc))
        self->keys = realloc(self->keys, sizeof(K) * usize(nc))
        self->vals = realloc(self->vals, sizeof(V) * usize(nc))
        self->dead = realloc(self->dead, sizeof(bool) * usize(nc))
        self->ecap = nc

    def put(self: *Dict<K, V>, key: K, value: V):
        if self->icap == 0 or (self->size + self->tombs + 1) * 3 >= self->icap * 2:
            self->rehash(8 if self->icap == 0 else self->icap * 2)
        h: u64 = self->key_hash(key)
        entry: i32 = -1
        slot: i32 = self->find_slot(key, h, &entry)
        if entry >= 0:
            self->vals[entry] = value
            return
        self->grow_entries()
        e: i32 = self->elen
        self->hashes[e] = h
        self->keys[e] = self->own_key(key)
        self->vals[e] = value
        self->dead[e] = False
        self->elen += 1
        if self->indices[slot] == -2:
            self->tombs -= 1
        self->indices[slot] = e
        self->size += 1

    def get(self: *Dict<K, V>, key: K, out: *V) -> bool:
        if self->size == 0:
            return False
        entry: i32 = -1
        self->find_slot(key, self->key_hash(key), &entry)
        if entry < 0:
            return False
        *out = self->vals[entry]
        return True

    def get_or(self: *Dict<K, V>, key: K, fallback: V) -> V:
        v: V = fallback
        self->get(key, &v)
        return v

    def has(self: *Dict<K, V>, key: K) -> bool:
        if self->size == 0:
            return False
        entry: i32 = -1
        self->find_slot(key, self->key_hash(key), &entry)
        return entry >= 0

    def remove(self: *Dict<K, V>, key: K) -> bool:
        if self->size == 0:
            return False
        entry: i32 = -1
        slot: i32 = self->find_slot(key, self->key_hash(key), &entry)
        if entry < 0:
            return False
        self->free_key(self->keys[entry])
        self->dead[entry] = True
        self->indices[slot] = -2
        self->size -= 1
        self->tombs += 1
        return True

    def clear(self: *Dict<K, V>):
        i: i32
        for i in range(self->elen):
            if not self->dead[i]:
                self->free_key(self->keys[i])
        i2: i32
        for i2 in range(self->icap):
            self->indices[i2] = -1
        self->elen = 0
        self->size = 0
        self->tombs = 0

    def deinit(self: *Dict<K, V>):
        i: i32
        for i in range(self->elen):
            if not self->dead[i]:
                self->free_key(self->keys[i])
        free(self->indices)
        free(self->hashes)
        free(self->keys)
        free(self->vals)
        free(self->dead)
        memset(self, 0, sizeof(*self))
