// ++/a/ -- prefix ++ is not an operand; / following is regex.
// (This is a pathological but grammatically valid expression in non-strict mode.)
function f(a) {
  var r = ++/a/;
  return r;
}
function sentinel() {}
