// [/regex/] -- / inside array literal initializer is a regex.
function f() {
  var arr = [/hello/, /world/g];
  return arr;
}
function sentinel() {}
