// The JS side of tests/oracle/js/turns.psc.
const log = [];
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function chain(name, n) {
  for (let i = 0; i < n; i++) { log.push(name + i); await sleep(0); }
  return n;
}
async function child(name) {
  log.push(name + "-started"); await sleep(0); log.push(name + "-finished"); return 0;
}
async function parent() {
  log.push("parent-before");
  const c = child("kid");        // calling an async function runs it to its first await
  log.push("parent-after");
  await c;
  log.push("parent-joined");
  return 0;
}
let mark = 0;
function show(label) {
  console.log(label, log.slice(mark).join(" ") + (log.length > mark ? " " : ""));
  mark = log.length;
}

await Promise.all([chain("a", 3), chain("b", 3), chain("c", 3)]);
show("fair");

await parent();
show("nested");

const inner1 = Promise.all([chain("x", 1), chain("y", 1)]);
const inner2 = Promise.all([chain("z", 1)]);
await Promise.all([inner1, inner2]);
show("nested gather");

const t = chain("done", 1);
await sleep(20);
log.push("awaiting-late");
await t;
log.push("awaited-late");
show("late");
