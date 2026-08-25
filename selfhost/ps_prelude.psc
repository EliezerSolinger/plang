"""pscript's prelude — the names every program has without importing anything.

It is SOURCE, parsed like any other module and prepended to the program (D3),
because a trait built by hand out of AST nodes would be a second way to say the
same thing, and the day the surface changed one of them would be forgotten.

A program's own names WIN over these, with a warning (68.3): shadowing a
default is legal, and worth saying out loud.
"""

enum Category:
    NONE
    INDEX
    KEY
    TYPE
    VALUE
    ZERO
    OVERFLOW
    IO

enum Status:
    RUNNING
    DONE
    ERROR
    GONE

enum Endian:
    LE
    BE

trait Comparable:
    def cmp(in self, other: Self) -> int

trait Iterable:
    type Item
    def has_next(self) -> bool
    def next(self) -> Item

trait Closeable:
    def close(self)

# 135.2/S5: the two ends of byte I/O, and the reason they are TRAITS is that
# there are three implementations of each and a program should be able to write
# one function that serves all three.
#
# `async`, and it is not a decoration: a file and a socket both PARK in the
# scheduler, and a `Reader` that could not say `async` would not cover a socket
# — which is half the reason to have one. The cost is that an implementation
# with nothing to wait for still says `async`; today there is no such
# implementation, so it costs nobody anything yet.
#
# The shape is the one 135.2 decided, and it is the same on both sides: a
# `Buffer` the caller already has, where in it to start, and how many bytes. A
# Buffer is malloc'd and never moves (52.3), so the syscall reads and writes it
# DIRECTLY — which is what turns a proxy's four copies into none.

trait Reader:
    async def read_into(self, b: Buffer, off: int, n: int) -> int

trait Writer:
    async def write_from(self, b: Buffer, off: int, n: int) -> int


# 140/F5: as espécies de mudança que um `Watcher` entrega.
#
# `RESCAN` é o transbordo (146.5): quando a fila do núcleo enche, o que se
# perdeu perdeu-se, e a única resposta honesta é "não sei o que mudou, relê
# tudo" — em vez de continuar a entregar eventos como se nada faltasse. O nome
# diz o que FAZER e não o que aconteceu ao núcleo, que é o que um nome de evento
# vale.
enum Change:
    CREATED
    MODIFIED
    DELETED
    MOVED_FROM
    MOVED_TO
    RESCAN
