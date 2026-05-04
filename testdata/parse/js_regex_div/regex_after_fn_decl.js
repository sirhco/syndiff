// function f() {} /re/g -- after a function declaration at stmt level, / is regex.
function outer() {
  function inner() {}
  /re/g;
}
function sentinel() {}
