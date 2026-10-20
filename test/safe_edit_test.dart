import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/services/safe_edit.dart';

void main() {
  test('json/yaml validation', () {
    expect(validateStructured('a.json', '{"a": 1}'), isNull);
    expect(validateStructured('a.json', '{"a": 1,\n}'), isNotNull);
    expect(validateStructured('a.yaml', 'a: 1\nb: [1, 2]\n'), isNull);
    expect(validateStructured('a.yml', 'a: [1, 2\n'), contains('YAML'));
    expect(validateStructured('a.txt', '{{{'), isNull);
    expect(validateStructured('a.json', '   '), isNull);
  });
  test('json error carries line', () {
    expect(validateStructured('x.json', '{\n"a": 1\n"b": 2}'), contains('3'));
  });
  test('line diff', () {
    final d = lineDiff('a\nb\nc\nd', 'a\nB\nc\nd\ne');
    expect(d.map((x) => x.toString()).toList(),
        [' a', '-b', '+B', ' c', ' d', '+e']);
    expect(lineDiff('x\ny', 'x\ny').every((l) => l.op == DiffOp.same), isTrue);
  });
  test('huge diff degrades without LCS table', () {
    final a = List.generate(3000, (i) => 'a$i').join('\n');
    final b = List.generate(3000, (i) => 'b$i').join('\n');
    final d = lineDiff(a, b, maxCells: 1000);
    expect(d.where((l) => l.op == DiffOp.remove).length, 3000);
    expect(d.where((l) => l.op == DiffOp.add).length, 3000);
  });
  test('compact diff keeps context and gaps', () {
    final before = List.generate(20, (i) => 'l$i').join('\n');
    final after = before.replaceFirst('l10', 'X');
    final c = compactDiff(lineDiff(before, after));
    expect(c.first, isNull);
    expect(c.whereType<DiffLine>().length, 6); // 2 ctx + -/+ + 2 ctx
  });
}
