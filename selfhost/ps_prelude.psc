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
