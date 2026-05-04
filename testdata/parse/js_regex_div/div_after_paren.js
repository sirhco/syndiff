// (a)/b/g -- the / after ) is division, not regex.
// If misclassified, /g would start a second regex and the trailing g would confuse the parser.
function f() {
  var a = 10;
  var r = (a)/b/g;
  return r;
}
function sentinel() {}
