# os nomes são os do módulo `re`, e só esses
import re


p = re.compile("[0-9]+")
print(p.fullmatch("42"))
