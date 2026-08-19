function build(n) {
  const parts = [];
  for (let i = 0; i < n; i++) parts.push("item-" + i);
  return parts.join(",").length;
}
console.log(build(200000));
