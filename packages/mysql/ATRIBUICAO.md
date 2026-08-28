# Atribuição

Este pacote é um **porte** do [PyMySQL](https://github.com/PyMySQL/PyMySQL), e o
que se seguiu dele foi o desenho do protocolo: a ordem do aperto de mão, a forma
dos pacotes, os embaralhamentos de cada plugin de autenticação, a lista de
capacidades. Nenhuma linha de Python foi traduzida mecanicamente — o código aqui
é escrito em pscript a partir do protocolo do MySQL e do MariaDB —, mas a dívida
é real e o PyMySQL foi também o **oráculo** dos testes: os embaralhamentos são
conferidos byte a byte contra o dele.

O PyMySQL é distribuído sob a licença MIT, que exige que o aviso de copyright e
a permissão acompanhem qualquer trabalho derivado. Aqui está:

```
Copyright (c) 2010, 2013 PyMySQL contributors

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

O resto do repositório é MIT com copyright de Eliezer Solinger (ver `LICENSE` na
raiz), e as duas licenças são compatíveis — é a mesma.
