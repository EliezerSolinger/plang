# o mesmo programa, com o posixpath do CPython no lugar do nosso `path`
import posixpath as path

COMPS = ["", ".", "..", "a", "b"]
PRES = ["", "/", "//", "///"]
SUFS = ["", "/"]

ps = [""]
for pre in PRES:
    for i in range(len(COMPS)):
        for j in range(len(COMPS)):
            for k in range(len(COMPS)):
                mid = COMPS[i] + "/" + COMPS[j] + "/" + COMPS[k]
                for suf in SUFS:
                    ps.append(pre + mid + suf)

for p in ps:
    print("normpath [" + p + "] [" + path.normpath(p) + "]")
    print("dirname [" + p + "] [" + path.dirname(p) + "]")
    print("basename [" + p + "] [" + path.basename(p) + "]")

JS = ["", ".", "..", "a", "a/", "/a", "/", "//", "a//"]
for i in range(len(JS)):
    for j in range(len(JS)):
        print("join2 [" + JS[i] + "] [" + JS[j] + "] [" + path.join(JS[i], JS[j]) + "]")
        for k in range(len(JS)):
            print("join3 [" + JS[i] + "] [" + JS[j] + "] [" + JS[k] + "] [" + path.join(JS[i], JS[j], JS[k]) + "]")
