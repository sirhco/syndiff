// const f = x => /re/ -- / after => is regex (expression position).
function f() {
  const g = x => /hello/;
  return g;
}
function sentinel() {}
