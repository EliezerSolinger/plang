// O servidor equivalente em Bun. `Bun.serve` usa UM processo por omissão
// (o `cluster` é opt-in), e é exactamente esse o ponto que a D12 defende — mas
// para a comparação ser justa medimos os dois de ambas as maneiras.
const porta = Number(process.argv[2] || 0);
const reuse = process.argv[3] === "reuse";
const srv = Bun.serve({
  port: porta,
  reusePort: reuse,
  fetch(req) {
    const u = new URL(req.url);
    if (u.pathname === "/") return new Response("ola do pscript");
    if (u.pathname === "/json") return Response.json({ quem: "pscript", quantos: 3 });
    return new Response("Not Found\n", { status: 404 });
  },
});
// `console.log` de um numero sai COLORIDO (o Bun mete codigos ANSI), e o
// arreio le isto com um `cat` — portanto escreve-se cru
process.stdout.write(String(srv.port) + "\n");
