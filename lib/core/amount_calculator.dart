/// Decimal operands and rational intermediates avoid binary floating-point drift.
/// Results are rounded to the nearest minor unit, with half cents rounded up.
int calculateMinorUnits(String expression) {
  final source = expression
      .replaceAll('×', '*')
      .replaceAll('÷', '/')
      .replaceAll('−', '-')
      .replaceAll(RegExp(r'\s+'), '');
  if (source.isEmpty || source.length > 120) {
    throw const FormatException('Enter a valid expression');
  }
  final tokens = RegExp(r'\d+(?:\.\d+)?|[+*/-]')
      .allMatches(source)
      .map((m) => m[0]!)
      .toList();
  if (tokens.join() != source) {
    throw const FormatException('The expression contains invalid characters');
  }
  var at = 0;
  _Fraction number() {
    if (at >= tokens.length ||
        !RegExp(r'^\d{1,9}(?:\.\d{1,2})?$').hasMatch(tokens[at])) {
      throw const FormatException(
        'Each amount allows up to 9 digits and 2 decimal places',
      );
    }
    final parts = tokens[at++].split('.');
    final decimals = parts.length == 1 ? '' : parts[1];
    return _Fraction(
      BigInt.parse(parts[0] + decimals),
      BigInt.from(10).pow(decimals.length),
    );
  }

  _Fraction product() {
    var result = number();
    while (at < tokens.length && (tokens[at] == '*' || tokens[at] == '/')) {
      final op = tokens[at++];
      final next = number();
      result = op == '*' ? result.multiply(next) : result.divide(next);
    }
    return result;
  }

  var result = product();
  while (at < tokens.length) {
    final op = tokens[at++];
    if (op != '+' && op != '-') {
      throw const FormatException('The expression is incomplete');
    }
    final next = product();
    result = result.add(next, subtract: op == '-');
  }
  if (result.numerator <= BigInt.zero) {
    throw const FormatException('The result must be greater than zero');
  }
  final scaled = result.numerator * BigInt.from(100);
  final cents = scaled ~/ result.denominator;
  final rounded =
      cents +
      ((scaled % result.denominator) * BigInt.two >= result.denominator
          ? BigInt.one
          : BigInt.zero);
  if (rounded <= BigInt.zero || rounded > BigInt.from(99999999999)) {
    throw const FormatException(
      'The result is out of the allowed amount range',
    );
  }
  return rounded.toInt();
}

class _Fraction {
  final BigInt numerator, denominator;
  _Fraction(BigInt n, BigInt d)
    : numerator = n ~/ n.gcd(d),
      denominator = d ~/ n.gcd(d);
  _Fraction multiply(_Fraction other) =>
      _Fraction(numerator * other.numerator, denominator * other.denominator);
  _Fraction divide(_Fraction other) {
    if (other.numerator == BigInt.zero) {
      throw const FormatException('Cannot divide by zero');
    }
    return _Fraction(
      numerator * other.denominator,
      denominator * other.numerator,
    );
  }

  _Fraction add(_Fraction other, {bool subtract = false}) => _Fraction(
    numerator * other.denominator +
        (subtract ? -other.numerator : other.numerator) * denominator,
    denominator * other.denominator,
  );
}
