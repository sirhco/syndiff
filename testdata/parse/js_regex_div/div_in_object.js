// ({} / 2) -- {} inside ( is an object literal, so / is division.
function f() {
  var x = ({} / 2);
  return x;
}
function sentinel() {}
