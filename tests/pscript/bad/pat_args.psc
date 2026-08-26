# o padrão é o objecto: passá-lo outra vez é escrevê-lo duas vezes
import re


p = re.compile("[0-9]+")
print(p.search("[0-9]+", "42"))
