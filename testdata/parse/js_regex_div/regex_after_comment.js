// Comments are transparent: goal state after the comment is the same as before.
function f() {
  return /* inline comment */ /re/g;
}
function sentinel() {}
