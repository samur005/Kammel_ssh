/// Safety helpers for the file editor: structured-file validation and a
/// compact line diff shown before saving.
library;

import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../l10n/l10n.dart';

enum StructuredKind { json, yaml }

StructuredKind? structuredKindFor(String path) {
  final p = path.toLowerCase();
  if (p.endsWith('.json')) return StructuredKind.json;
  if (p.endsWith('.yaml') || p.endsWith('.yml')) return StructuredKind.yaml;
  return null;
}

/// Null when [text] parses (or the type is not validated), otherwise a short
/// human-readable error with the line when known.
String? validateStructured(String path, String text) {
  final kind = structuredKindFor(path);
  if (kind == null || text.trim().isEmpty) return null;
  try {
    if (kind == StructuredKind.json) {
      jsonDecode(text);
    } else {
      loadYamlStream(text);
    }
    return null;
  } on YamlException catch (e) {
    final line = (e.span?.start.line ?? -1) + 1;
    return line > 0
        ? tr('YAML no válido (línea {0}): {1}', [line, e.message])
        : tr('YAML no válido: {0}', [e.message]);
  } on FormatException catch (e) {
    final off = e.offset;
    if (off != null && off >= 0 && off <= text.length) {
      final line = '\n'.allMatches(text.substring(0, off)).length + 1;
      return tr('JSON no válido (línea {0}): {1}', [line, e.message]);
    }
    return tr('JSON no válido: {0}', [e.message]);
  } catch (e) {
    return '$e';
  }
}

enum DiffOp { same, add, remove }

class DiffLine {
  final DiffOp op;
  final String text;
  const DiffLine(this.op, this.text);
  @override
  String toString() =>
      '${op == DiffOp.add ? '+' : op == DiffOp.remove ? '-' : ' '}$text';
}

/// Line diff of [before] → [after]. Common prefix/suffix are stripped first,
/// then an LCS runs on the middle; when the middle is too large for an LCS
/// table it degrades to "all removed, all added" (still correct, less tidy).
List<DiffLine> lineDiff(String before, String after, {int maxCells = 4000000}) {
  final a = before.split('\n');
  final b = after.split('\n');
  var pre = 0;
  while (pre < a.length && pre < b.length && a[pre] == b[pre]) {
    pre++;
  }
  var suf = 0;
  while (suf < a.length - pre &&
      suf < b.length - pre &&
      a[a.length - 1 - suf] == b[b.length - 1 - suf]) {
    suf++;
  }
  final am = a.sublist(pre, a.length - suf);
  final bm = b.sublist(pre, b.length - suf);
  final out = <DiffLine>[for (var i = 0; i < pre; i++) DiffLine(DiffOp.same, a[i])];
  if (am.length * bm.length > maxCells) {
    out.addAll(am.map((l) => DiffLine(DiffOp.remove, l)));
    out.addAll(bm.map((l) => DiffLine(DiffOp.add, l)));
  } else {
    final n = am.length, m = bm.length;
    final t = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        t[i][j] = am[i] == bm[j]
            ? t[i + 1][j + 1] + 1
            : (t[i + 1][j] >= t[i][j + 1] ? t[i + 1][j] : t[i][j + 1]);
      }
    }
    var i = 0, j = 0;
    while (i < n && j < m) {
      if (am[i] == bm[j]) {
        out.add(DiffLine(DiffOp.same, am[i]));
        i++;
        j++;
      } else if (t[i + 1][j] >= t[i][j + 1]) {
        out.add(DiffLine(DiffOp.remove, am[i++]));
      } else {
        out.add(DiffLine(DiffOp.add, bm[j++]));
      }
    }
    while (i < n) {
      out.add(DiffLine(DiffOp.remove, am[i++]));
    }
    while (j < m) {
      out.add(DiffLine(DiffOp.add, bm[j++]));
    }
  }
  for (var k = a.length - suf; k < a.length; k++) {
    out.add(DiffLine(DiffOp.same, a[k]));
  }
  return out;
}

/// Keeps only changed lines plus [context] lines around them; gaps become a
/// single `null` entry (rendered as "…").
List<DiffLine?> compactDiff(List<DiffLine> diff, {int context = 2}) {
  final keep = List<bool>.filled(diff.length, false);
  for (var i = 0; i < diff.length; i++) {
    if (diff[i].op != DiffOp.same) {
      for (var k = i - context; k <= i + context; k++) {
        if (k >= 0 && k < diff.length) keep[k] = true;
      }
    }
  }
  final out = <DiffLine?>[];
  var gap = false;
  for (var i = 0; i < diff.length; i++) {
    if (keep[i]) {
      out.add(diff[i]);
      gap = false;
    } else if (!gap) {
      out.add(null);
      gap = true;
    }
  }
  return out;
}
