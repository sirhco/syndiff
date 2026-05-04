// if (x) /re/.test(y) -- / after ) of control stmt is regex, not division.
function f(x, y) {
  if (x) /re/.test(y);
}
function sentinel() {}
