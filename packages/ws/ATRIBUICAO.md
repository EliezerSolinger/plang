# Atribuição

O desenho *sans-io* deste pacote — a máquina de estados separada do I/O, bytes
para dentro e eventos para fora — segue o da biblioteca
[`websockets`](https://github.com/python-websockets/websockets) de Aymeric
Augustin e colaboradores. Ela foi também o **oráculo** do portão: os quadros que
ela serializa são lidos por nós, e os que nós serializamos são lidos por ela e
são byte a byte os mesmos que ela produziria.

Nenhuma linha de Python foi traduzida: o que está aqui é escrito a partir do RFC
6455, e a estrutura é diferente por uma razão que o próprio README explica — a
`websockets` tem a mesma lógica quatro vezes, uma por modelo de I/O, e aqui o
modelo de concorrência é um só. A dívida é de **desenho e de verificação**, e é
por isso que ela fica dita.

A `websockets` é distribuída sob a licença BSD de 3 cláusulas, que exige que o
aviso de copyright, a lista de condições e a isenção acompanhem qualquer
redistribuição — em código ou em forma binária. Aqui está:

```
Copyright (c) Aymeric Augustin and contributors

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software without
   specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

**A terceira cláusula é a que vale a pena ler:** o nome dos autores da
`websockets` não pode ser usado para endossar este pacote. Ela não o endossa — o
que ela é aqui é um oráculo, e o portão diz isso por escrito.

O resto do repositório é MIT com copyright de Eliezer Solinger (ver `LICENSE` na
raiz).
