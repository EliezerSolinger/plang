// The JS side of tests/oracle/js/settle.psc.
const sleep = ms => new Promise(r => setTimeout(r, ms));
// the verdict in words, because `True` and `true` differ in the spelling of a
// boolean and not in who won the race
const yn = b => (b ? "yes" : "no");

async function after(ms, name) { await sleep(ms); return name; }
async function boom(ms, name) { await sleep(ms); throw new Error("boom " + name); }
async function early(name) { throw new Error("early " + name); }

const t = early("one");
console.log("called early, still here");
try { await t; console.log("no error?!"); }
catch (e) { console.log("early raised at the await", e.message); }

try {
  await Promise.all([Promise.all([after(10, "a"), boom(20, "b")]), Promise.all([after(10, "c")])]);
  console.log("nested: no error?!");
} catch (e) { console.log("nested raised", e.message); }

const same = after(10, "twice");
const two = await Promise.all([same, same]);
console.log("dup", two[0], two[1]);

try {
  const k = await Promise.any([boom(10, "p"), boom(20, "q")]);
  console.log("any: no error?!", k);
} catch (e) { console.log("any with nothing to pick: refused"); }

// `timeout(task, seconds)`: True when the work finished in time. JS spells the
// same race by hand, and leaves the loser running.
const timeout = (p, sec) => Promise.race([p.then(() => true), sleep(sec * 1000).then(() => false)]);
console.log("in time", yn(await timeout(after(5, "quick"), 0.05)));
console.log("too slow", yn(await timeout(after(50, "slow"), 0.005)));

const order = [];
const longOne = after(30, "long");
const shortOne = after(5, "short");
order.push(await shortOne);
order.push(await longOne);
console.log("by duration", order[0], order[1]);
