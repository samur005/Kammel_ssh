/// Optional, rule-based highlighting of terminal **output**.
///
/// Safety rules (spec §3.2):
/// * Never touches the alternate screen (vim, htop, less, tmux…).
/// * Never touches a line that already carries any ANSI foreground color, so
///   program colors (ls, git, prompts) are preserved exactly.
/// * Only recolors cells whose foreground is the terminal default.
/// * Only processes lines the cursor has left — the line being typed/edited
///   is never colored, so we don't guess where input ends.
/// * Bounded work per pass ([maxLinesPerPass]); passes run once per batched
///   write (≈ once per frame), and a processed line becomes colored so it is
///   skipped cheaply afterwards (the pass is idempotent).
library;

import 'package:xterm/xterm.dart';

enum HighlightCategory { status, logLevel, ip, url, path, number, date }

const Set<HighlightCategory> kDefaultHighlightCategories = {
  ...HighlightCategory.values,
};

/// Palette indexes (theme-aware: drawn with the active scheme's colors).
const int _brightRed = 9, _brightGreen = 10, _brightYellow = 11;
const int _brightBlue = 12, _brightMagenta = 13, _brightCyan = 14;
const int _cyan = 6, _brightBlack = 8;

class HighlightSpan {
  final int start, end; // UTF-16 offsets into the line text, end exclusive
  final int colorIndex;
  const HighlightSpan(this.start, this.end, this.colorIndex);
  @override
  String toString() => 'HighlightSpan($start,$end,$colorIndex)';
}

final _rules = <(HighlightCategory, RegExp, int Function(String))>[
  (
    HighlightCategory.url,
    RegExp(r'''\b(?:https?|ftp|ssh|wss?)://[^\s<>"'`]+[^\s<>"'`.,;:)\]]'''),
    (_) => _brightBlue,
  ),
  (
    HighlightCategory.date,
    RegExp(
        r'\b\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?\b|\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) +\d{1,2} \d{2}:\d{2}:\d{2}\b|\b\d{2}:\d{2}:\d{2}\b'),
    (_) => _brightBlack,
  ),
  (
    HighlightCategory.ip,
    RegExp(
        r'\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:/\d{1,2}|:\d{1,5})?\b|\b(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}\b'),
    (_) => _brightCyan,
  ),
  (
    HighlightCategory.logLevel,
    RegExp(
        r'\b(?:FATAL|CRIT(?:ICAL)?|ERROR|ERR|WARN(?:ING)?|INFO|DEBUG|TRACE|NOTICE)\b'),
    (m) => switch (m) {
          'FATAL' || 'CRIT' || 'CRITICAL' || 'ERROR' || 'ERR' => _brightRed,
          'WARN' || 'WARNING' => _brightYellow,
          'INFO' || 'NOTICE' => _brightGreen,
          _ => _brightBlack,
        },
  ),
  (
    HighlightCategory.status,
    RegExp(
        r'\b(?:[Ee]rror|[Ff]ailed|[Ff]ailure|[Ff]atal|[Dd]enied|[Rr]efused|[Pp]anic|[Ee]xception|[Tt]raceback|[Nn]ot found|[Tt]imed? ?out)\b|\b(?:[Ww]arning|[Dd]eprecated)\b|\b(?:[Ss]uccess(?:ful(?:ly)?)?|OK|[Dd]one|[Pp]assed|[Cc]ompleted|[Aa]ctive \(running\))\b'),
    (m) {
      final l = m.toLowerCase();
      if (l.startsWith('warn') || l.startsWith('deprec')) return _brightYellow;
      if (l.startsWith('succ') ||
          l == 'ok' ||
          l == 'done' ||
          l == 'passed' ||
          l == 'completed' ||
          l.startsWith('active')) {
        return _brightGreen;
      }
      return _brightRed;
    },
  ),
  (
    HighlightCategory.path,
    RegExp(r'(?<![\w.:/~-])(?:~|\.{1,2})?/(?:[\w.@+-]+/?)+'),
    (_) => _brightMagenta,
  ),
  (
    HighlightCategory.number,
    RegExp(r'(?<![\w.])\d+(?:\.\d+)?(?:[KMGTP]i?B?|%|ms|s)?(?![\w.])'),
    (_) => _cyan,
  ),
];

/// Pure matcher: non-overlapping spans, earlier rules win.
List<HighlightSpan> findHighlights(
    String text, Set<HighlightCategory> enabled) {
  if (text.trim().isEmpty || enabled.isEmpty) return const [];
  final taken = List<bool>.filled(text.length, false);
  final out = <HighlightSpan>[];
  for (final (cat, re, color) in _rules) {
    if (!enabled.contains(cat)) continue;
    for (final m in re.allMatches(text)) {
      if (m.end <= m.start) continue;
      var free = true;
      for (var i = m.start; i < m.end; i++) {
        if (taken[i]) {
          free = false;
          break;
        }
      }
      if (!free) continue;
      for (var i = m.start; i < m.end; i++) {
        taken[i] = true;
      }
      out.add(HighlightSpan(m.start, m.end, color(m[0]!)));
    }
  }
  out.sort((a, b) => a.start - b.start);
  return out;
}

/// Per-terminal driver. Call [onOutput] after each (batched) write.
class TerminalHighlighter {
  TerminalHighlighter(this.terminal);

  final Terminal terminal;
  static const int maxLinesPerPass = 200;
  static const int maxLineWidth = 1000;

  int _lastCursorAbs = -1;

  /// When true the alternate screen is processed too. Used for tmux sessions,
  /// whose panes are plain shell output drawn on the alt screen.
  bool allowAltBuffer = false;

  /// Applies highlighting to completed lines written since the last pass.
  ///
  /// Always rescans the visible viewport above the cursor in addition to the
  /// lines the cursor moved past: the absolute cursor row stops growing once
  /// the scrollback is full (and shifts on resize/reflow), so a pure
  /// "since last cursor row" window silently stopped coloring anything in
  /// long sessions. Rescanning is idempotent and cheap: already-colored lines
  /// are rejected on their first non-default cell.
  void onOutput(Set<HighlightCategory> enabled) {
    if (enabled.isEmpty || (terminal.isUsingAltBuffer && !allowAltBuffer)) {
      _lastCursorAbs = -1;
      return;
    }
    final buffer = terminal.buffer;
    final lines = buffer.lines;
    final cur = buffer.absoluteCursorY;
    var from = cur - terminal.viewHeight;
    if (_lastCursorAbs >= 0 && _lastCursorAbs < from) from = _lastCursorAbs;
    if (cur - from > maxLinesPerPass) from = cur - maxLinesPerPass;
    if (from < 0) from = 0;
    for (var y = from; y < cur && y < lines.length; y++) {
      highlightLine(lines[y], enabled);
    }
    _lastCursorAbs = cur;
  }

  /// Highlights one buffer line in place. Exposed for tests.
  static void highlightLine(BufferLine line, Set<HighlightCategory> enabled) {
    final n = line.length < maxLineWidth ? line.length : maxLineWidth;
    // Skip lines that already have program colors (or were done before).
    final sb = StringBuffer();
    final cellOf = <int>[]; // UTF-16 unit → cell index
    var any = false;
    for (var x = 0; x < n; x++) {
      if (line.getForeground(x) != CellColor.normal) return;
      final cp = line.getCodePoint(x);
      if (cp == 0) {
        if (line.getWidth(x) == 0 && x > 0 && line.getWidth(x - 1) == 2) {
          continue; // second half of a wide glyph
        }
        sb.write(' ');
        cellOf.add(x);
        continue;
      }
      any = true;
      final s = String.fromCharCode(cp);
      sb.write(s);
      for (var k = 0; k < s.length; k++) {
        cellOf.add(x);
      }
    }
    if (!any) return;
    final spans = findHighlights(sb.toString(), enabled);
    for (final sp in spans) {
      final color = CellColor.named | sp.colorIndex;
      final a = cellOf[sp.start];
      final b = cellOf[sp.end - 1];
      for (var x = a; x <= b; x++) {
        line.setForeground(x, color);
        if (x + 1 < n && line.getWidth(x) == 2) line.setForeground(x + 1, color);
      }
    }
  }
}

/// Category set ↔ prefs.
List<String> encodeHighlightCategories(Set<HighlightCategory> s) =>
    [for (final c in s) c.name];
Set<HighlightCategory> decodeHighlightCategories(List<String>? names) {
  if (names == null) return {...kDefaultHighlightCategories};
  return {
    for (final c in HighlightCategory.values)
      if (names.contains(c.name)) c
  };
}
