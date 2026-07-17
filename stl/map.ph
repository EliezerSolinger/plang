# map.ph — Map<K, V> and StrMap<V>: STL dictionaries.
#
# Compact dict, Python 3.7+ style (ported from the jaketa runtime):
#   indices[]: sparse array of i32 (-1 = empty, -2 = tombstone, >=0 = entry)
#   dense entries in parallel arrays (hashes/keys/vals/dead), in
#   insertion order — iteration preserves order for free.
#   Linear probing; resize when load > 2/3; tombstones reused.
#
# Map<K, V>:  keys compared BY BYTES (ints, enums, identity pointers;
#             do not use structs with padding or *char by content).
# StrMap<V>:  *char keys by CONTENT (FNV-1a + strcmp); the map makes its own
#             copy of the keys and frees them on remove/deinit.
#
# Iteration (insertion order):
#   i: i32
#   for i in range(m.elen):
#       if not m.dead[i]:
#           ... m.keys[i] / m.vals[i] ...
import <stdlib.h>
import <string.h>
import "hash.ph"

struct Map<K, V>:
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

    def init(self: *Map<K, V>):
        memset(self, 0, sizeof(*self))

    def key_hash(self: *Map<K, V>, key: K) -> u64:
        return hash_bytes((*char)(&key), sizeof(K))

    def key_eq(self: *Map<K, V>, a: K, b: K) -> bool:
        return memcmp(&a, &b, sizeof(K)) == 0

    # finds the slot in indices[] for the key; *out_entry >= 0 if it exists.
    # for insertion, prefers the first tombstone seen during the probe.
    def find_slot(self: *Map<K, V>, key: K, h: u64, out_entry: *i32) -> i32:
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

    # compacts the dense arrays (discards dead entries) and rebuilds indices[]
    def rehash(self: *Map<K, V>, newcap: i32):
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

    def grow_entries(self: *Map<K, V>):
        if self->elen < self->ecap:
            return
        nc: i32 = 8 if self->ecap == 0 else self->ecap * 2
        self->hashes = realloc(self->hashes, sizeof(u64) * usize(nc))
        self->keys = realloc(self->keys, sizeof(K) * usize(nc))
        self->vals = realloc(self->vals, sizeof(V) * usize(nc))
        self->dead = realloc(self->dead, sizeof(bool) * usize(nc))
        self->ecap = nc

    def put(self: *Map<K, V>, key: K, value: V):
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
        self->keys[e] = key
        self->vals[e] = value
        self->dead[e] = False
        self->elen += 1
        if self->indices[slot] == -2:
            self->tombs -= 1
        self->indices[slot] = e
        self->size += 1

    def get(self: *Map<K, V>, key: K, out: *V) -> bool:
        if self->size == 0:
            return False
        h: u64 = self->key_hash(key)
        entry: i32 = -1
        self->find_slot(key, h, &entry)
        if entry < 0:
            return False
        *out = self->vals[entry]
        return True

    def get_or(self: *Map<K, V>, key: K, fallback: V) -> V:
        v: V = fallback
        self->get(key, &v)
        return v

    def has(self: *Map<K, V>, key: K) -> bool:
        entry: i32 = -1
        if self->size == 0:
            return False
        self->find_slot(key, self->key_hash(key), &entry)
        return entry >= 0

    def remove(self: *Map<K, V>, key: K) -> bool:
        if self->size == 0:
            return False
        h: u64 = self->key_hash(key)
        entry: i32 = -1
        slot: i32 = self->find_slot(key, h, &entry)
        if entry < 0:
            return False
        self->dead[entry] = True
        self->indices[slot] = -2
        self->size -= 1
        self->tombs += 1
        return True

    def clear(self: *Map<K, V>):
        i: i32
        for i in range(self->icap):
            self->indices[i] = -1
        self->elen = 0
        self->size = 0
        self->tombs = 0

    def deinit(self: *Map<K, V>):
        free(self->indices)
        free(self->hashes)
        free(self->keys)
        free(self->vals)
        free(self->dead)
        memset(self, 0, sizeof(*self))

# StrMap<V> — string keys by content; the map owns copies of the keys
struct StrMap<V>:
    indices: *i32
    icap: i32
    hashes: *u64
    keys: **char
    vals: *V
    dead: *bool
    elen: i32
    ecap: i32
    size: i32
    tombs: i32

    def init(self: *StrMap<V>):
        memset(self, 0, sizeof(*self))

    def find_slot(self: *StrMap<V>, key: const *char, h: u64, out_entry: *i32) -> i32:
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
            elif not self->dead[idx] and self->hashes[idx] == h and strcmp(self->keys[idx], key) == 0:
                *out_entry = idx
                return slot
            slot = (slot + 1) & mask

    def rehash(self: *StrMap<V>, newcap: i32):
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

    def grow_entries(self: *StrMap<V>):
        if self->elen < self->ecap:
            return
        nc: i32 = 8 if self->ecap == 0 else self->ecap * 2
        self->hashes = realloc(self->hashes, sizeof(u64) * usize(nc))
        self->keys = realloc(self->keys, sizeof(self->keys[0]) * usize(nc))
        self->vals = realloc(self->vals, sizeof(V) * usize(nc))
        self->dead = realloc(self->dead, sizeof(bool) * usize(nc))
        self->ecap = nc

    def put(self: *StrMap<V>, key: const *char, value: V):
        if self->icap == 0 or (self->size + self->tombs + 1) * 3 >= self->icap * 2:
            self->rehash(8 if self->icap == 0 else self->icap * 2)
        h: u64 = hash_cstr(key)
        entry: i32 = -1
        slot: i32 = self->find_slot(key, h, &entry)
        if entry >= 0:
            self->vals[entry] = value
            return
        self->grow_entries()
        n: usize = strlen(key) + 1
        kcopy: *char = malloc(n)
        memcpy(kcopy, key, n)
        e: i32 = self->elen
        self->hashes[e] = h
        self->keys[e] = kcopy
        self->vals[e] = value
        self->dead[e] = False
        self->elen += 1
        if self->indices[slot] == -2:
            self->tombs -= 1
        self->indices[slot] = e
        self->size += 1

    def get(self: *StrMap<V>, key: const *char, out: *V) -> bool:
        if self->size == 0:
            return False
        entry: i32 = -1
        self->find_slot(key, hash_cstr(key), &entry)
        if entry < 0:
            return False
        *out = self->vals[entry]
        return True

    def get_or(self: *StrMap<V>, key: const *char, fallback: V) -> V:
        v: V = fallback
        self->get(key, &v)
        return v

    def has(self: *StrMap<V>, key: const *char) -> bool:
        entry: i32 = -1
        if self->size == 0:
            return False
        self->find_slot(key, hash_cstr(key), &entry)
        return entry >= 0

    def remove(self: *StrMap<V>, key: const *char) -> bool:
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

    def deinit(self: *StrMap<V>):
        i: i32
        for i in range(self->elen):
            if not self->dead[i]:
                free(self->keys[i])
        free(self->indices)
        free(self->hashes)
        free(self->keys)
        free(self->vals)
        free(self->dead)
        memset(self, 0, sizeof(*self))
