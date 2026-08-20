// The JS side of tests/oracle/js/promise.psc — written to print the same lines
// for the same reasons, not translated afterwards.
const log = [];
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function after(ms, name) { await sleep(ms); log.push(name); return name; }
async function boom(ms, name) {
  await sleep(ms); log.push("!" + name); throw new Error("boom " + name);
}

const vs = await Promise.all([after(30, "slow"), after(20, "mid"), after(10, "fast")]);
console.log("all", vs[0], vs[1], vs[2]);
console.log("finished", log[0], log[1], log[2]);

try {
  const bad = await Promise.all([after(10, "ok1"), boom(20, "b")]);
  console.log("all: no error?!", bad.length);
} catch (e) {
  console.log("all raised", e.message);
}

const ts = [boom(30, "x"), after(10, "y"), boom(20, "z")];
const settled = await Promise.allSettled(ts);
for (let i = 0; i < settled.length; i++) {
  const s = settled[i];
  if (s.status === "rejected") console.log("settled", i, "failed", s.reason.message);
  else console.log("settled", i, "gave", s.value);
}

// `any` gives the VALUE; ours gives the INDEX of the winner, so each promise
// carries its index along and both print the index and the value at it.
const which = [boom(10, "p"), after(20, "q"), boom(30, "r")];
const [k, won] = await Promise.any(which.map((p, i) => p.then(v => [i, v])));
console.log("any", k, won);

// A race is compared on its winner: JS leaves the loser running, ours cancels
// it, and neither is asked about the loser here.
const runners = [after(40, "tortoise"), after(5, "hare")];
const winner = await Promise.race(runners.map((p, i) => p.then(() => i)));
console.log("race", winner);

const once = after(10, "once");
console.log("settled once", await once, await once);

const t = boom(10, "late");
console.log("called, not raised yet");
try { await t; console.log("no error?!"); }
catch (e) { console.log("raised at the await", e.message); }
