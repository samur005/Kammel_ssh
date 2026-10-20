import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/services/terminal_highlighter.dart';
import 'package:xterm/xterm.dart';

String colored(String text, List<HighlightSpan> s) =>
    s.map((x) => text.substring(x.start, x.end)).join('|');

void main() {
  const all = kDefaultHighlightCategories;
  test('matches categories without overlap', () {
    const t = '2026-10-20 12:00:01 ERROR connect to 10.0.0.5:22 failed, see https://x.io/a/b and /var/log/syslog (3 retries)';
    final s = findHighlights(t, all);
    expect(colored(t, s),
        '2026-10-20 12:00:01|ERROR|10.0.0.5:22|failed|https://x.io/a/b|/var/log/syslog|3');
    // URL wins over path inside it.
    expect(s.where((x) => t.substring(x.start, x.end) == '/a/b'), isEmpty);
  });
  test('respects disabled categories', () {
    final s = findHighlights('ok 42 /etc', {HighlightCategory.number});
    expect(s.length, 1);
    expect(findHighlights('anything', {}), isEmpty);
  });
  test('status colors', () {
    final s = findHighlights('Warning: x; Success; Permission denied', all);
    expect(s.map((x) => x.colorIndex).toList(), [11, 10, 9]);
  });

  Terminal term() => Terminal(maxLines: 1000)..resize(80, 24);

  test('colors completed default-color lines only', () {
    final t = term();
    t.write('plain ERROR at 192.168.1.1\r\n');
    t.write('\x1b[32mgreen ERROR 1.2.3.4\x1b[0m\r\n');
    t.write('typing ERROR');
    final h = TerminalHighlighter(t)..onOutput(all);
    // Re-run with cursor beyond first lines.
    h.onOutput(all);
    final l0 = t.buffer.lines[0];
    expect(l0.getForeground(6), CellColor.named | 9); // "ERROR"
    expect(l0.getForeground(0), CellColor.normal); // "plain" untouched
    // ANSI-colored line is left exactly as the program drew it.
    final l1 = t.buffer.lines[1];
    expect(l1.getForeground(6), l1.getForeground(0));
    // Current (cursor) line is never touched.
    expect(t.buffer.lines[2].getForeground(7), CellColor.normal);
  });

  test('skips alt buffer', () {
    final t = term();
    t.write('\x1b[?1049hERROR in vim\r\nmore\r\n');
    TerminalHighlighter(t).onOutput(all);
    expect(t.buffer.lines[0].getForeground(0), CellColor.normal);
  });

  test('large output stays bounded and fast', () {
    final t = Terminal(maxLines: 10000)..resize(120, 40);
    final h = TerminalHighlighter(t);
    final sw = Stopwatch()..start();
    for (var i = 0; i < 5000; i++) {
      t.write('2026-10-20 INFO request $i from 10.1.2.${i % 255} /api/v1/x took ${i % 900}ms\r\n');
      if (i % 50 == 0) h.onOutput(all);
    }
    h.onOutput(all);
    sw.stop();
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });

  test('category prefs round trip', () {
    final s = {HighlightCategory.ip, HighlightCategory.url};
    expect(decodeHighlightCategories(encodeHighlightCategories(s)), s);
    expect(decodeHighlightCategories(null), kDefaultHighlightCategories);
  });
}
