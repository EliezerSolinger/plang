// E o `http` do Node, que é a linha de base que todo o mundo conhece.
const http = require("http");
const porta = Number(process.argv[2] || 0);
const srv = http.createServer((req, res) => {
  const p = req.url.split("?")[0];
  if (p === "/") { res.writeHead(200, {"content-type": "text/plain"}); res.end("ola do pscript"); return; }
  if (p === "/json") { res.writeHead(200, {"content-type": "application/json"}); res.end(JSON.stringify({quem:"pscript",quantos:3})); return; }
  res.writeHead(404, {"content-type": "text/plain"}); res.end("Not Found\n");
});
srv.listen(porta, "127.0.0.1", () => process.stdout.write(String(srv.address().port) + "\n"));
