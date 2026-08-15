"""A template is an f-string that lives in a file (63.2/63.3).

Same holes, same `{{`/`}}` escapes, same mini-language of formats — and the
same moment: the file is spliced at COMPILE time and the holes resolve against
the scope of the line that asked for it. There is no template engine at run
time, and no second language to specify or debug.
"""

name = "Ana"
total = 12.5
count = 3
print(render("email.tpl"))
print("---")
name = "Bo"
total = 0.125
count = 1
print(render("email.tpl"))
