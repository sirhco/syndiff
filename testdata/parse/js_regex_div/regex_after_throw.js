// throw /re/; -- unusual but legal; / after 'throw' is regex.
function f() {
  throw /unexpected/;
}
function sentinel() {}
