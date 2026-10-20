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

  group('live-session regressions (v2.12.0 bug)', () {
    const prompt =
        '\x1b]0;user@srv: ~\x07\x1b[01;32muser@srv\x1b[00m:\x1b[01;34m~\x1b[00m\$ ';
    const realistic = [
      'ls -la\r\n',
      'total 12\r\n',
      'drwxr-xr-x 3 user user 4096 Oct 20 10:01 \x1b[01;34m.\x1b[0m\r\n',
      '-rw-r--r-- 1 user user  220 Oct 20 10:01 /home/user/.profile\r\n',
      prompt,
      'ping -c1 8.8.8.8\r\n\x1b[?2004l\r',
      '64 bytes from 8.8.8.8: icmp_seq=1 ttl=117 time=12.3 ms\r\n',
      '2026-10-20 10:00:01 ERROR db: connection refused, see https://status.example.com/x\r\n',
      'Oct 20 10:00:02 srv app[42]: WARN slow request from 192.168.1.10\r\n',
      prompt,
    ];

    int fgAt(Terminal t, String needle) {
      for (var y = 0; y < t.buffer.lines.length; y++) {
        final l = t.buffer.lines[y];
        final i = l.getText().indexOf(needle);
        if (i >= 0) return l.getForeground(i);
      }
      fail('"$needle" not in buffer');
    }

    void play(Terminal t, TerminalHighlighter h, {int times = 1}) {
      for (var n = 0; n < times; n++) {
        for (final chunk in realistic) {
          t.write(chunk);
          h.onOutput(kDefaultHighlightCategories);
        }
      }
    }

    test('colors realistic output, keeps ANSI prompt and ls colors', () {
      final t = Terminal(maxLines: 1000)..resize(100, 30);
      final h = TerminalHighlighter(t);
      t.write(prompt);
      play(t, h);
      expect(fgAt(t, 'ERROR'), CellColor.named | 9);
      expect(fgAt(t, 'WARN'), CellColor.named | 11);
      expect(fgAt(t, '192.168.1.10'), CellColor.named | 14);
      expect(fgAt(t, 'https://status'), CellColor.named | 12);
      expect(fgAt(t, '8.8.8.8:'), CellColor.named | 14);
      expect(fgAt(t, '/home/user/.profile'), CellColor.named | 13);
      // Prompt keeps its own green.
      expect(fgAt(t, 'user@srv'), isNot(CellColor.normal));
      expect(fgAt(t, 'user@srv') & CellColor.valueMask, 2);
    });

    test('keeps coloring after the scrollback is full', () {
      // Absolute cursor row stops moving at maxLines: the old window logic
      // then processed nothing at all.
      final t = Terminal(maxLines: 200)..resize(100, 30);
      final h = TerminalHighlighter(t);
      play(t, h, times: 40);
      t.write('\r\nFINAL ERROR here\r\n');
      h.onOutput(kDefaultHighlightCategories);
      final l = t.buffer.lines[t.buffer.absoluteCursorY - 1];
      expect(l.getText(), startsWith('FINAL ERROR'));
      expect(l.getForeground(6), CellColor.named | 9);
    });

    test('tmux (alt screen) is colored only when allowed', () {
      Terminal mk() => Terminal(maxLines: 1000)..resize(80, 24)
        ..write('\x1b[?1049h\x1b[H')
        ..write('ERROR one 10.0.0.1\r\n\x1b[32m[0] bash\x1b[0m\r\n');
      final t1 = mk();
      TerminalHighlighter(t1).onOutput(kDefaultHighlightCategories);
      expect(t1.buffer.lines[0].getForeground(0), CellColor.normal);
      final t2 = mk();
      (TerminalHighlighter(t2)..allowAltBuffer = true)
          .onOutput(kDefaultHighlightCategories);
      expect(t2.buffer.lines[0].getForeground(0), CellColor.named | 9);
    });
  });
}
