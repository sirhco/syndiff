// Adversarial Dart fixture for Phase 8: ${...} interpolation recursion.

/// Returns a formatted string. Contains '${ {} }' which embeds an empty
/// map literal inside interpolation — previously confused brace depth.
String format(Object v) {
  final label = '${ {} }';
  final nested = '${"a${"b"}c"}';
  final raw = r'${ not interpolated }';
  final multi = '''
value: ${ {} }
nested: ${"x${v}z"}
''';
  return '$label $nested $raw $multi';
}

/// A second top-level function that must remain a separate AST node.
int compute(int a, int b) {
  return a + b;
}
