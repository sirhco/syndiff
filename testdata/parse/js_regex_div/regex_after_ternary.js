// x ? /re1/ : /re2/ -- both / after ? and : are regex.
function f(x) {
  var r = x ? /yes/g : /no/g;
  return r;
}
function sentinel() {}
