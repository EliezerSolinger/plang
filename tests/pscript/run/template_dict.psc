"""A template whose values come in a dict, written at the call (75.2).

The one-argument form resolves each hole against whatever name happens to be
in scope on that line. This one says out loud what goes where — and because
the dict is a LITERAL, everything still happens at compile time: the key set
is checked against the holes in both directions, the format spec applies to
the type actually written, and the values may be of different types, which a
real `dict` could not hold.
"""

who = "Ana"
n = 3

print(render("email.tpl", {"name": who, "total": 12.5, "count": n}))
print("---")

# the same template, values computed at the call
print(render("email.tpl", {"name": "Bo" + "!", "total": 1.0 / 8.0, "count": n - 2}))
print("---")

# a key two holes ask for is spliced twice — the expression is cloned, so the
# second hole is not the same node checked over again
print(render("twice.tpl", {"w": "echo"}))
