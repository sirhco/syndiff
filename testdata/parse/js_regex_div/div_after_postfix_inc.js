// a++/2 -- postfix ++ makes a++ an operand, so / is division.
function f(a) {
  var r = a++/2;
  return r;
}
function sentinel() {}
