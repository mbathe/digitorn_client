/// Digitorn Widgets v1 — binding engine.
///
/// Parses and evaluates `{{expression}}` bindings. Designed to be
/// safe, closed-form, and cheap enough to run on every rebuild.
///
/// Supported:
///   * Literals: `"s"`, `'s'`, int, float, true, false, null
///   * Path lookup: `a`, `a.b.c`, `a[0]`, `a.b[2].c`
///   * Binary ops: `==`, `!=`, `>`, `<`, `>=`, `<=`, `&&`, `||`,
///                 `+`, `-`, `*`, `/`, `%`
///   * Unary: `!`, `-`
///   * Ternary: `a ? b : c`
///   * `a is empty`, `a is not empty`, `a is null`, `a is not null`
///   * Filter pipeline: `x | f`, `x | f(arg1, arg2)`
///
/// Values look up in a [BindingScope] which exposes form/state/
/// data/ctx/session/app/item/row via a chained map. Missing paths
/// return `null` (never throw).
library;

import 'dart:convert';

/// The environment an expression evaluates against. A scope is a
/// stack of maps where lookups walk from innermost (current loop
/// iteration) outwards. Immutable — use [fork] to layer a scope.
class BindingScope {
  final List<Map<String, dynamic>> _layers;

  const BindingScope._(this._layers);

  factory BindingScope.empty() => const BindingScope._([]);

  factory BindingScope.root({
    Map<String, dynamic> form = const {},
    Map<String, dynamic> state = const {},
    Map<String, dynamic> data = const {},
    Map<String, dynamic> ctx = const {},
    Map<String, dynamic> session = const {},
    Map<String, dynamic> app = const {},
  }) {
    final now = DateTime.now();
    return BindingScope._([
      {
        'form': form,
        'state': state,
        'data': data,
        'ctx': ctx,
        'session': session,
        'app': app,
        'today': _ymd(now),
        'now': now.toIso8601String(),
      },
    ]);
  }

  /// Push a new map on top of the stack. Used for loop iteration
  /// scopes (`item`, `row`, `index`, …).
  BindingScope fork(Map<String, dynamic> layer) =>
      BindingScope._([..._layers, layer]);

  /// Resolve a top-level identifier. Walks inner layers first.
  dynamic resolveRoot(String ident) {
    for (var i = _layers.length - 1; i >= 0; i--) {
      final m = _layers[i];
      if (m.containsKey(ident)) return m[ident];
    }
    return null;
  }
}

/// Exception used by the evaluator to signal a parse-time problem.
/// Production builds catch this and return null — the widget
/// renders a "binding error" badge instead of crashing.
class BindingError implements Exception {
  final String message;
  final String expr;
  const BindingError(this.message, {this.expr = ''});
  @override
  String toString() => 'BindingError: $message (in "$expr")';
}

/// Main entry point. Takes a raw template string and returns:
///   * the same string if no `{{ }}` tokens are present
///   * a string with each `{{expr}}` replaced by its stringified
///     result
///   * when the entire input IS a single `{{expr}}`, returns the
///     raw value (dynamic) via [evalValue] — so callers that need
///     numbers/lists keep them typed.
String evalTemplate(String? raw, BindingScope scope) {
  if (raw == null || raw.isEmpty) return raw ?? '';
  if (!raw.contains('{{')) return raw;
  final sb = StringBuffer();
  var i = 0;
  while (i < raw.length) {
    final start = raw.indexOf('{{', i);
    if (start < 0) {
      sb.write(raw.substring(i));
      break;
    }
    sb.write(raw.substring(i, start));
    final end = raw.indexOf('}}', start + 2);
    if (end < 0) {
      sb.write(raw.substring(start));
      break;
    }
    final expr = raw.substring(start + 2, end).trim();
    final value = _safeEval(expr, scope);
    sb.write(_stringify(value));
    i = end + 2;
  }
  return sb.toString();
}

/// Evaluate a single expression (without surrounding braces) and
/// return its raw Dart value. If [raw] contains `{{…}}`, strips
/// them first. Null-safe, returns null on error.
dynamic evalValue(String? raw, BindingScope scope) {
  if (raw == null) return null;
  var e = raw.trim();
  if (e.isEmpty) return null;
  if (e.startsWith('{{') && e.endsWith('}}')) {
    e = e.substring(2, e.length - 2).trim();
  }
  return _safeEval(e, scope);
}

/// Truthy coercion à la JS — null / false / 0 / "" / empty list =
/// false, everything else = true. Used by `when:` and `disabled:`.
bool evalBool(String? raw, BindingScope scope, {bool fallback = false}) {
  if (raw == null) return fallback;
  final v = evalValue(raw, scope);
  return _truthy(v);
}

/// Resolve a value that may or may not be wrapped in `{{…}}`.
/// Accepts `num`, `bool`, `String`, `List`, `Map` as-is.
dynamic resolve(dynamic raw, BindingScope scope) {
  if (raw == null) return null;
  if (raw is String) {
    if (raw.contains('{{')) {
      // If it's a pure single binding, return the raw value.
      final t = raw.trim();
      if (t.startsWith('{{') && t.endsWith('}}') && t.indexOf('{{', 2) == -1) {
        return evalValue(t, scope);
      }
      return evalTemplate(raw, scope);
    }
    return raw;
  }
  return raw;
}

// ── Internals ──────────────────────────────────────────────────────

dynamic _safeEval(String expr, BindingScope scope) {
  try {
    final parser = _Parser(expr);
    final node = parser.parseExpression();
    parser.expectEnd();
    return _Eval.eval(node, scope);
  } catch (e) {
    // Keep silent in release — binding errors shouldn't crash UI.
    return null;
  }
}

String _stringify(dynamic v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  if (v is DateTime) return v.toIso8601String();
  if (v is List || v is Map) {
    try {
      return jsonEncode(v);
    } catch (_) {
      return v.toString();
    }
  }
  return v.toString();
}

bool _truthy(dynamic v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.isNotEmpty;
  if (v is List) return v.isNotEmpty;
  if (v is Map) return v.isNotEmpty;
  return true;
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// ── Lexer ──────────────────────────────────────────────────────────

enum _Tok {
  number,
  string,
  ident,
  lparen,
  rparen,
  lbrack,
  rbrack,
  comma,
  dot,
  pipe,
  question,
  colon,
  bang,
  eq,
  neq,
  lt,
  gt,
  lte,
  gte,
  and,
  or,
  plus,
  minus,
  star,
  slash,
  percent,
  kwTrue,
  kwFalse,
  kwNull,
  kwIs,
  kwNot,
  kwEmpty,
  eof,
}

class _Lexer {
  final String src;
  int pos = 0;
  _Tok tok = _Tok.eof;
  String value = '';
  num numValue = 0;

  _Lexer(this.src) {
    next();
  }

  void next() {
    // Skip whitespace
    while (pos < src.length && _isWs(src.codeUnitAt(pos))) {
      pos++;
    }
    if (pos >= src.length) {
      tok = _Tok.eof;
      return;
    }
    final ch = src.codeUnitAt(pos);
    // Numbers
    if (_isDigit(ch)) {
      final start = pos;
      while (pos < src.length && _isDigit(src.codeUnitAt(pos))) {
        pos++;
      }
      if (pos < src.length && src.codeUnitAt(pos) == 46) {
        pos++;
        while (pos < src.length && _isDigit(src.codeUnitAt(pos))) {
          pos++;
        }
      }
      value = src.substring(start, pos);
      numValue = num.parse(value);
      tok = _Tok.number;
      return;
    }
    // Strings
    if (ch == 34 || ch == 39) {
      final quote = ch;
      pos++;
      final sb = StringBuffer();
      while (pos < src.length && src.codeUnitAt(pos) != quote) {
        final c = src.codeUnitAt(pos);
        if (c == 92 && pos + 1 < src.length) {
          pos++;
          final n = src.codeUnitAt(pos);
          if (n == 110) {
            sb.writeCharCode(10);
          } else if (n == 116) {
            sb.writeCharCode(9);
          } else {
            sb.writeCharCode(n);
          }
          pos++;
        } else {
          sb.writeCharCode(c);
          pos++;
        }
      }
      if (pos < src.length) pos++; // closing quote
      value = sb.toString();
      tok = _Tok.string;
      return;
    }
    // Identifiers / keywords
    if (_isIdentStart(ch)) {
      final start = pos;
      while (pos < src.length && _isIdentCont(src.codeUnitAt(pos))) {
        pos++;
      }
      value = src.substring(start, pos);
      switch (value) {
        case 'true':
          tok = _Tok.kwTrue;
          break;
        case 'false':
          tok = _Tok.kwFalse;
          break;
        case 'null':
          tok = _Tok.kwNull;
          break;
        case 'is':
          tok = _Tok.kwIs;
          break;
        case 'not':
          tok = _Tok.kwNot;
          break;
        case 'empty':
          tok = _Tok.kwEmpty;
          break;
        case 'and':
          tok = _Tok.and;
          break;
        case 'or':
          tok = _Tok.or;
          break;
        default:
          tok = _Tok.ident;
      }
      return;
    }
    // Operators and punctuation
    pos++;
    switch (ch) {
      case 40:
        tok = _Tok.lparen;
        return;
      case 41:
        tok = _Tok.rparen;
        return;
      case 91:
        tok = _Tok.lbrack;
        return;
      case 93:
        tok = _Tok.rbrack;
        return;
      case 44:
        tok = _Tok.comma;
        return;
      case 46:
        tok = _Tok.dot;
        return;
      case 124:
        if (pos < src.length && src.codeUnitAt(pos) == 124) {
          pos++;
          tok = _Tok.or;
        } else {
          tok = _Tok.pipe;
        }
        return;
      case 63:
        tok = _Tok.question;
        return;
      case 58:
        tok = _Tok.colon;
        return;
      case 33:
        if (pos < src.length && src.codeUnitAt(pos) == 61) {
          pos++;
          tok = _Tok.neq;
        } else {
          tok = _Tok.bang;
        }
        return;
      case 61:
        if (pos < src.length && src.codeUnitAt(pos) == 61) {
          pos++;
          tok = _Tok.eq;
        } else {
          throw BindingError('Stray "="');
        }
        return;
      case 60:
        if (pos < src.length && src.codeUnitAt(pos) == 61) {
          pos++;
          tok = _Tok.lte;
        } else {
          tok = _Tok.lt;
        }
        return;
      case 62:
        if (pos < src.length && src.codeUnitAt(pos) == 61) {
          pos++;
          tok = _Tok.gte;
        } else {
          tok = _Tok.gt;
        }
        return;
      case 38:
        if (pos < src.length && src.codeUnitAt(pos) == 38) {
          pos++;
          tok = _Tok.and;
        } else {
          throw BindingError('Stray "&"');
        }
        return;
      case 43:
        tok = _Tok.plus;
        return;
      case 45:
        tok = _Tok.minus;
        return;
      case 42:
        tok = _Tok.star;
        return;
      case 47:
        tok = _Tok.slash;
        return;
      case 37:
        tok = _Tok.percent;
        return;
    }
    throw BindingError('Unexpected character "${String.fromCharCode(ch)}"');
  }

  bool _isDigit(int c) => c >= 48 && c <= 57;
  bool _isWs(int c) => c == 32 || c == 9 || c == 10 || c == 13;
  bool _isIdentStart(int c) =>
      (c >= 65 && c <= 90) ||
      (c >= 97 && c <= 122) ||
      c == 95 ||
      c == 36;
  bool _isIdentCont(int c) => _isIdentStart(c) || _isDigit(c);
}

// ── AST ────────────────────────────────────────────────────────────

abstract class _Node {}

class _LitN extends _Node {
  final dynamic value;
  _LitN(this.value);
}

class _IdentN extends _Node {
  final String name;
  _IdentN(this.name);
}

class _IndexN extends _Node {
  final _Node target;
  final _Node index;
  _IndexN(this.target, this.index);
}

class _DotN extends _Node {
  final _Node target;
  final String name;
  _DotN(this.target, this.name);
}

class _UnaryN extends _Node {
  final String op;
  final _Node arg;
  _UnaryN(this.op, this.arg);
}

class _BinaryN extends _Node {
  final String op;
  final _Node left;
  final _Node right;
  _BinaryN(this.op, this.left, this.right);
}

class _TernaryN extends _Node {
  final _Node cond;
  final _Node then;
  final _Node otherwise;
  _TernaryN(this.cond, this.then, this.otherwise);
}

class _FilterN extends _Node {
  final _Node arg;
  final String filter;
  final List<_Node> args;
  _FilterN(this.arg, this.filter, this.args);
}

class _IsN extends _Node {
  final _Node target;
  final bool negated;
  final String check; // "empty" | "null"
  _IsN(this.target, this.negated, this.check);
}

// ── Parser ─────────────────────────────────────────────────────────

class _Parser {
  final _Lexer lx;
  final String src;
  _Parser(this.src) : lx = _Lexer(src);

  _Node parseExpression() => _parseTernary();

  _Node _parseTernary() {
    final cond = _parsePipe();
    if (lx.tok == _Tok.question) {
      lx.next();
      final then = _parseTernary();
      if (lx.tok != _Tok.colon) {
        throw BindingError('Expected ":" in ternary', expr: src);
      }
      lx.next();
      final otherwise = _parseTernary();
      return _TernaryN(cond, then, otherwise);
    }
    return cond;
  }

  _Node _parsePipe() {
    var left = _parseOr();
    while (lx.tok == _Tok.pipe) {
      lx.next();
      if (lx.tok != _Tok.ident) {
        throw BindingError('Filter name expected', expr: src);
      }
      final fname = lx.value;
      lx.next();
      final args = <_Node>[];
      if (lx.tok == _Tok.lparen) {
        lx.next();
        while (lx.tok != _Tok.rparen && lx.tok != _Tok.eof) {
          args.add(_parseTernary());
          if (lx.tok == _Tok.comma) {
            lx.next();
          } else {
            break;
          }
        }
        if (lx.tok != _Tok.rparen) {
          throw BindingError('Missing ")" in filter args', expr: src);
        }
        lx.next();
      }
      left = _FilterN(left, fname, args);
    }
    return left;
  }

  _Node _parseOr() {
    var left = _parseAnd();
    while (lx.tok == _Tok.or) {
      lx.next();
      left = _BinaryN('||', left, _parseAnd());
    }
    return left;
  }

  _Node _parseAnd() {
    var left = _parseEquality();
    while (lx.tok == _Tok.and) {
      lx.next();
      left = _BinaryN('&&', left, _parseEquality());
    }
    return left;
  }

  _Node _parseEquality() {
    var left = _parseComparison();
    while (lx.tok == _Tok.eq || lx.tok == _Tok.neq) {
      final op = lx.tok == _Tok.eq ? '==' : '!=';
      lx.next();
      left = _BinaryN(op, left, _parseComparison());
    }
    return left;
  }

  _Node _parseComparison() {
    var left = _parseAdditive();
    while (lx.tok == _Tok.lt ||
        lx.tok == _Tok.gt ||
        lx.tok == _Tok.lte ||
        lx.tok == _Tok.gte ||
        lx.tok == _Tok.kwIs) {
      if (lx.tok == _Tok.kwIs) {
        lx.next();
        var negated = false;
        if (lx.tok == _Tok.kwNot) {
          negated = true;
          lx.next();
        }
        if (lx.tok == _Tok.kwEmpty) {
          lx.next();
          left = _IsN(left, negated, 'empty');
        } else if (lx.tok == _Tok.kwNull) {
          lx.next();
          left = _IsN(left, negated, 'null');
        } else {
          throw BindingError('Expected "empty" or "null" after is',
              expr: src);
        }
        continue;
      }
      final op = lx.tok == _Tok.lt
          ? '<'
          : lx.tok == _Tok.gt
              ? '>'
              : lx.tok == _Tok.lte
                  ? '<='
                  : '>=';
      lx.next();
      left = _BinaryN(op, left, _parseAdditive());
    }
    return left;
  }

  _Node _parseAdditive() {
    var left = _parseMultiplicative();
    while (lx.tok == _Tok.plus || lx.tok == _Tok.minus) {
      final op = lx.tok == _Tok.plus ? '+' : '-';
      lx.next();
      left = _BinaryN(op, left, _parseMultiplicative());
    }
    return left;
  }

  _Node _parseMultiplicative() {
    var left = _parseUnary();
    while (lx.tok == _Tok.star ||
        lx.tok == _Tok.slash ||
        lx.tok == _Tok.percent) {
      final op = lx.tok == _Tok.star
          ? '*'
          : lx.tok == _Tok.slash
              ? '/'
              : '%';
      lx.next();
      left = _BinaryN(op, left, _parseUnary());
    }
    return left;
  }

  _Node _parseUnary() {
    if (lx.tok == _Tok.bang) {
      lx.next();
      return _UnaryN('!', _parseUnary());
    }
    if (lx.tok == _Tok.minus) {
      lx.next();
      return _UnaryN('-', _parseUnary());
    }
    return _parsePostfix();
  }

  _Node _parsePostfix() {
    var left = _parsePrimary();
    while (lx.tok == _Tok.dot || lx.tok == _Tok.lbrack) {
      if (lx.tok == _Tok.dot) {
        lx.next();
        if (lx.tok != _Tok.ident) {
          throw BindingError('Expected identifier after "."', expr: src);
        }
        final name = lx.value;
        lx.next();
        left = _DotN(left, name);
      } else {
        lx.next();
        final idx = _parseTernary();
        if (lx.tok != _Tok.rbrack) {
          throw BindingError('Expected "]"', expr: src);
        }
        lx.next();
        left = _IndexN(left, idx);
      }
    }
    return left;
  }

  _Node _parsePrimary() {
    switch (lx.tok) {
      case _Tok.number:
        final v = lx.numValue;
        lx.next();
        return _LitN(v);
      case _Tok.string:
        final v = lx.value;
        lx.next();
        return _LitN(v);
      case _Tok.kwTrue:
        lx.next();
        return _LitN(true);
      case _Tok.kwFalse:
        lx.next();
        return _LitN(false);
      case _Tok.kwNull:
        lx.next();
        return _LitN(null);
      case _Tok.lparen:
        lx.next();
        final e = _parseTernary();
        if (lx.tok != _Tok.rparen) {
          throw BindingError('Expected ")"', expr: src);
        }
        lx.next();
        return e;
      case _Tok.ident:
        final name = lx.value;
        lx.next();
        return _IdentN(name);
      default:
        throw BindingError('Unexpected token', expr: src);
    }
  }

  void expectEnd() {
    if (lx.tok != _Tok.eof) {
      throw BindingError('Trailing characters', expr: src);
    }
  }
}

// ── Evaluator ──────────────────────────────────────────────────────

class _Eval {
  static dynamic eval(_Node node, BindingScope scope) {
    if (node is _LitN) return node.value;
    if (node is _IdentN) return scope.resolveRoot(node.name);
    if (node is _DotN) {
      final t = eval(node.target, scope);
      return _lookup(t, node.name);
    }
    if (node is _IndexN) {
      final t = eval(node.target, scope);
      final i = eval(node.index, scope);
      if (t is List) {
        final idx = (i is num) ? i.toInt() : int.tryParse(i?.toString() ?? '');
        if (idx == null || idx < 0 || idx >= t.length) return null;
        return t[idx];
      }
      if (t is Map) return t[i];
      return null;
    }
    if (node is _UnaryN) {
      final v = eval(node.arg, scope);
      if (node.op == '!') return !_truthy(v);
      if (node.op == '-') {
        if (v is num) return -v;
        return null;
      }
    }
    if (node is _BinaryN) {
      // Short-circuit logic first.
      if (node.op == '&&') {
        final l = eval(node.left, scope);
        if (!_truthy(l)) return false;
        return _truthy(eval(node.right, scope));
      }
      if (node.op == '||') {
        final l = eval(node.left, scope);
        if (_truthy(l)) return true;
        return _truthy(eval(node.right, scope));
      }
      final l = eval(node.left, scope);
      final r = eval(node.right, scope);
      switch (node.op) {
        case '==':
          return _equals(l, r);
        case '!=':
          return !_equals(l, r);
        case '>':
          return _cmp(l, r) > 0;
        case '<':
          return _cmp(l, r) < 0;
        case '>=':
          return _cmp(l, r) >= 0;
        case '<=':
          return _cmp(l, r) <= 0;
        case '+':
          if (l is num && r is num) return l + r;
          return '${_stringify(l)}${_stringify(r)}';
        case '-':
          if (l is num && r is num) return l - r;
          return null;
        case '*':
          if (l is num && r is num) return l * r;
          return null;
        case '/':
          if (l is num && r is num && r != 0) return l / r;
          return null;
        case '%':
          if (l is num && r is num && r != 0) return l % r;
          return null;
      }
    }
    if (node is _TernaryN) {
      return _truthy(eval(node.cond, scope))
          ? eval(node.then, scope)
          : eval(node.otherwise, scope);
    }
    if (node is _FilterN) {
      final v = eval(node.arg, scope);
      final args = node.args.map((a) => eval(a, scope)).toList();
      return Filters.apply(node.filter, v, args);
    }
    if (node is _IsN) {
      final v = eval(node.target, scope);
      bool result;
      if (node.check == 'empty') {
        result = v == null ||
            (v is String && v.isEmpty) ||
            (v is List && v.isEmpty) ||
            (v is Map && v.isEmpty);
      } else {
        result = v == null;
      }
      return node.negated ? !result : result;
    }
    return null;
  }

  static bool _truthy(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v.isNotEmpty;
    if (v is List) return v.isNotEmpty;
    if (v is Map) return v.isNotEmpty;
    return true;
  }

  static dynamic _lookup(dynamic target, String key) {
    if (target is Map) return target[key];
    if (target is List) {
      // Allow `.length` / `.first` / `.last` on lists.
      if (key == 'length') return target.length;
      if (key == 'first') return target.isEmpty ? null : target.first;
      if (key == 'last') return target.isEmpty ? null : target.last;
      if (key == 'isEmpty') return target.isEmpty;
      if (key == 'isNotEmpty') return target.isNotEmpty;
    }
    if (target is String) {
      if (key == 'length') return target.length;
      if (key == 'isEmpty') return target.isEmpty;
    }
    return null;
  }

  static bool _equals(dynamic a, dynamic b) {
    if (a == null || b == null) return a == b;
    if (a is num && b is num) return a == b;
    return a.toString() == b.toString();
  }

  static int _cmp(dynamic a, dynamic b) {
    if (a is num && b is num) {
      final d = a - b;
      return d == 0 ? 0 : (d > 0 ? 1 : -1);
    }
    return (a?.toString() ?? '').compareTo(b?.toString() ?? '');
  }

  static String _stringify(dynamic v) {
    if (v == null) return '';
    if (v is String) return v;
    return v.toString();
  }
}

// ── Filters ────────────────────────────────────────────────────────

/// Closed-set filter catalogue. Adding one → add a case here.
class Filters {
  static dynamic apply(String name, dynamic value, List<dynamic> args) {
    switch (name) {
      case 'upper':
        return value?.toString().toUpperCase();
      case 'lower':
        return value?.toString().toLowerCase();
      case 'title':
        return _titleCase(value?.toString() ?? '');
      case 'truncate':
        {
          final n = _num(args, 0, 80).toInt();
          final s = value?.toString() ?? '';
          if (s.length <= n) return s;
          return '${s.substring(0, n)}…';
        }
      case 'default':
        {
          final def = args.isNotEmpty ? args[0] : '';
          if (value == null) return def;
          if (value is String && value.isEmpty) return def;
          if (value is List && value.isEmpty) return def;
          return value;
        }
      case 'length':
        if (value is List) return value.length;
        if (value is Map) return value.length;
        if (value is String) return value.length;
        return 0;
      case 'date':
        return _formatDate(value, args.isNotEmpty ? args[0]?.toString() : null);
      case 'relative_time':
        return _relativeTime(value);
      case 'money':
        return _money(value, args.isNotEmpty ? args[0]?.toString() : 'USD');
      case 'number':
        {
          final p = _num(args, 0, 2).toInt();
          if (value is num) return value.toStringAsFixed(p);
          final n = num.tryParse(value?.toString() ?? '');
          return n?.toStringAsFixed(p) ?? value?.toString();
        }
      case 'percent':
        {
          if (value is num) return '${(value * 100).toStringAsFixed(0)}%';
          final n = num.tryParse(value?.toString() ?? '');
          if (n != null) return '${(n * 100).toStringAsFixed(0)}%';
          return value?.toString();
        }
      case 'json':
        try {
          return jsonEncode(value);
        } catch (_) {
          return value?.toString();
        }
      case 'filter':
        if (value is! List || args.length < 2) return value;
        final key = args[0]?.toString();
        final v = args[1];
        if (key == null) return value;
        return value.where((e) {
          if (e is Map) return e[key] == v;
          return false;
        }).toList();
      case 'map':
      case 'pluck':
        if (value is! List || args.isEmpty) return value;
        final key = args[0]?.toString();
        return value.map((e) {
          if (e is Map) return e[key];
          return null;
        }).toList();
      case 'join':
        if (value is! List) return value?.toString() ?? '';
        final sep = args.isNotEmpty ? args[0]?.toString() ?? '' : '';
        return value.map((e) => e?.toString() ?? '').join(sep);
      case 'first':
        if (value is List && value.isNotEmpty) return value.first;
        return null;
      case 'last':
        if (value is List && value.isNotEmpty) return value.last;
        return null;
      case 'sort':
        if (value is! List) return value;
        final key = args.isNotEmpty ? args[0]?.toString() : null;
        final copy = [...value];
        copy.sort((a, b) {
          final av = key != null && a is Map ? a[key] : a;
          final bv = key != null && b is Map ? b[key] : b;
          if (av is num && bv is num) return av.compareTo(bv);
          return (av?.toString() ?? '').compareTo(bv?.toString() ?? '');
        });
        return copy;
      case 'reverse':
        if (value is List) return value.reversed.toList();
        if (value is String) return value.split('').reversed.join();
        return value;
      case 'slice':
        if (value is! List) return value;
        final a = _num(args, 0, 0).toInt();
        final b = _num(args, 1, value.length).toInt();
        final lo = a.clamp(0, value.length);
        final hi = b.clamp(0, value.length);
        return value.sublist(lo, hi);
      case 'replace':
        if (value == null || args.length < 2) return value;
        return value.toString().replaceAll(
              args[0]?.toString() ?? '',
              args[1]?.toString() ?? '',
            );
      case 'markdown':
        return value?.toString() ?? '';
      case 'plus_days':
        return _shiftDays(value, _num(args, 0, 0).toInt());
      case 'minus_days':
        return _shiftDays(value, -_num(args, 0, 0).toInt());
      case 'status_color':
        return _statusColor(value?.toString() ?? '');
      case 'sev_color':
        return _sevColor(value?.toString() ?? '');
      default:
        return value;
    }
  }

  static num _num(List args, int i, num fallback) {
    if (i >= args.length) return fallback;
    final v = args[i];
    if (v is num) return v;
    return num.tryParse(v?.toString() ?? '') ?? fallback;
  }

  static String _titleCase(String s) {
    if (s.isEmpty) return s;
    return s
        .split(RegExp(r'\s+'))
        .map((w) => w.isEmpty
            ? w
            : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
        .join(' ');
  }

  static String _formatDate(dynamic v, String? fmt) {
    DateTime? d;
    if (v is DateTime) {
      d = v;
    } else if (v is num) {
      d = DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000);
    } else if (v is String) {
      d = DateTime.tryParse(v);
    }
    if (d == null) return v?.toString() ?? '';
    fmt ??= 'YYYY-MM-DD';
    String two(int n) => n.toString().padLeft(2, '0');
    return fmt
        .replaceAll('YYYY', d.year.toString().padLeft(4, '0'))
        .replaceAll('MM', two(d.month))
        .replaceAll('DD', two(d.day))
        .replaceAll('HH', two(d.hour))
        .replaceAll('mm', two(d.minute))
        .replaceAll('ss', two(d.second));
  }

  static String _relativeTime(dynamic v) {
    DateTime? d;
    if (v is DateTime) {
      d = v;
    } else if (v is String) {
      d = DateTime.tryParse(v);
    } else if (v is num) {
      d = DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000);
    }
    if (d == null) return '';
    final diff = DateTime.now().difference(d);
    final past = diff.isNegative ? false : true;
    final abs = diff.abs();
    String out;
    if (abs.inSeconds < 45) {
      out = 'a few seconds';
    } else if (abs.inMinutes < 2) {
      out = 'a minute';
    } else if (abs.inMinutes < 60) {
      out = '${abs.inMinutes} minutes';
    } else if (abs.inHours < 2) {
      out = 'an hour';
    } else if (abs.inHours < 24) {
      out = '${abs.inHours} hours';
    } else if (abs.inDays < 2) {
      out = 'a day';
    } else if (abs.inDays < 30) {
      out = '${abs.inDays} days';
    } else if (abs.inDays < 365) {
      out = '${(abs.inDays / 30).floor()} months';
    } else {
      out = '${(abs.inDays / 365).floor()} years';
    }
    return past ? '$out ago' : 'in $out';
  }

  static String _money(dynamic v, String? currency) {
    final n = v is num ? v : num.tryParse(v?.toString() ?? '');
    if (n == null) return v?.toString() ?? '';
    final symbol = switch (currency?.toUpperCase()) {
      'USD' => '\$',
      'EUR' => '€',
      'GBP' => '£',
      'JPY' => '¥',
      _ => '${currency ?? ''} ',
    };
    return '$symbol${n.toStringAsFixed(2)}';
  }

  static String _shiftDays(dynamic v, int days) {
    DateTime? d;
    if (v is DateTime) {
      d = v;
    } else if (v is String) {
      d = DateTime.tryParse(v);
    }
    d ??= DateTime.now();
    final shifted = d.add(Duration(days: days));
    return '${shifted.year.toString().padLeft(4, '0')}-${shifted.month.toString().padLeft(2, '0')}-${shifted.day.toString().padLeft(2, '0')}';
  }

  static String _statusColor(String s) {
    switch (s.toLowerCase()) {
      case 'ok':
      case 'active':
      case 'done':
      case 'success':
        return 'success';
      case 'warning':
      case 'pending':
      case 'doing':
        return 'warning';
      case 'error':
      case 'failed':
      case 'blocked':
        return 'error';
      default:
        return 'muted';
    }
  }

  static String _sevColor(String s) {
    switch (s.toLowerCase()) {
      case 'p0':
      case 'critical':
      case 'sev0':
      case 'sev1':
        return 'error';
      case 'p1':
      case 'high':
      case 'sev2':
        return 'warning';
      case 'p2':
      case 'medium':
        return 'info';
      default:
        return 'muted';
    }
  }
}
