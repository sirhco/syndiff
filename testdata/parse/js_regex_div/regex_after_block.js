// {} /re/g; at statement level -- the {} is a block, so / is regex.
function f() {
  {} /re/g;
}
function sentinel() {}
