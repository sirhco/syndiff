// return /re/g; -- / after 'return' keyword is always regex.
function f() {
  return /hello world/g;
}
function sentinel() {}
