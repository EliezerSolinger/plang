const log = [];
const sleep0 = () => new Promise(r => setTimeout(r, 0));

async function step(name, n) {
  for (let i = 0; i < n; i++) { log.push(name + i); await sleep0(); }
  return name;
}
async function quick(v) { return v * 2; }

log.push("before");
const a = step("a", 3);
const b = step("b", 3);
log.push("after");

const names = await Promise.all([a, b]);
console.log("gathered", names[0], names[1]);

const t = quick(21);
log.push("made");
const v = await t;
log.push("awaited");
console.log("value " + v);

console.log("log", log.join(" ") + " ");
