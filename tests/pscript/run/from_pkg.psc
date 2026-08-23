"""`from <pkg/mod.psc> import x` — the same import, written the other way.

It was missing, and it was an asymmetry with no reason: `import <pkg/mod.psc>`
already existed, and a package whose names can only be reached one way forces you
to qualify everything. The path's spelling is the same as the other `<>` forms;
what changes is what gets bound at the end.
"""

from <tar/tar.psc> import octal, bytes_of, safe_name
from <tar/tar.psc> import write as pack

print(octal(493, 8))
print(len(bytes_of("olá")))
print(safe_name("a/b.txt") == "")
print(safe_name("/etc/passwd") != "")
b = pack([])
print(len(b))
