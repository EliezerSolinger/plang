# Os corpos dos métodos de `CStr` e `CBytes`, materializados AQUI.
#
# `implement X` emite os corpos que o `.ph` declarou, e emite-os com ligação
# externa — então DOIS módulos que implementem o mesmo tipo colidem no linker,
# com uma mensagem que fala de `CStr_at` e não do problema. Aconteceu no dia em
# que dois pacotes (`sha2` e `ed25519`) precisaram da fronteira do pscript ao
# mesmo tempo.
#
# A regra que isso ensina é simples e é esta: **quem DECLARA o tipo é quem o
# materializa**. O `cstr.ph` é do `stl`, então o `cstr.p` também é — e a 1.5(a)
# faz o resto sozinha: quem escreve `import <stl/cstr.ph>` puxa este arquivo
# junto, uma vez, sem ter de saber que ele existe.
import <stl/cstr.ph>
implement CStr
implement CBytes
