import 'dart:convert';

/// Extended server metrics: swap, inodes, network throughput, uptime, top
/// processes and listening ports. One exec round-trip; every probe degrades
/// to "not available" when its tool is missing instead of failing the batch.
class ExtendedMetrics {
  int cores = 1;
  double loadAvg1 = 0;
  double? swapPercent;
  String swapText = '—';
  double? inodePercent;
  String inodeText = '—';
  int? uptimeSeconds;
  int? rxBytes;
  int? txBytes;
  double? rxRate; // bytes/s, from the previous sample
  double? txRate;
  List<ProcessRow> processes = [];
  List<ListeningPort> ports = [];
  bool portsAvailable = true;

  /// load average normalised by cores, 0..1+ (1.0 = all cores busy).
  double get cpuPressure => cores > 0 ? loadAvg1 / cores : loadAvg1;
}

class ProcessRow {
  final String pid, user, cpu, mem, command;
  const ProcessRow(this.pid, this.user, this.cpu, this.mem, this.command);
}

class ListeningPort {
  final String proto, address, process;
  const ListeningPort(this.proto, this.address, this.process);
}

const String extendedMetricsCmd = r'''
echo "C|$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null)"
echo "L|$(cat /proc/loadavg 2>/dev/null)"
echo "W|$(free -m 2>/dev/null | grep -i '^swap:')"
echo "I|$(df -iP / 2>/dev/null | tail -n 1)"
echo "U|$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
echo "N|$(awk 'NR>2 && $1 !~ /^lo:/ {sub(":"," ",$0); split($0,a," "); rx+=a[2]; tx+=a[10]} END {print rx" "tx}' /proc/net/dev 2>/dev/null)"
ps -eo pid=,user=,pcpu=,pmem=,comm= --sort=-pcpu 2>/dev/null | head -n 8 | sed 's/^ */P|/'
if command -v ss >/dev/null 2>&1; then
  ss -H -tulnp 2>/dev/null | head -n 40 | awk '{print "S|"$1"|"$5"|"$7}'
elif command -v netstat >/dev/null 2>&1; then
  netstat -tulnp 2>/dev/null | awk 'NR>2 {print "S|"$1"|"$4"|"$NF}' | head -n 40
else
  echo "S|__notool__"
fi
''';

/// Parses [extendedMetricsCmd] output. [previous] + [elapsed] give the
/// network rate.
ExtendedMetrics parseExtendedMetrics(String out,
    {ExtendedMetrics? previous, Duration? elapsed}) {
  final m = ExtendedMetrics();
  for (final line in const LineSplitter().convert(out)) {
    final sep = line.indexOf('|');
    if (sep < 1) continue;
    final tag = line.substring(0, sep);
    final v = line.substring(sep + 1).trim();
    final f = v.split(RegExp(r'\s+'));
    switch (tag) {
      case 'C':
        m.cores = int.tryParse(v) ?? 1;
      case 'L':
        m.loadAvg1 = double.tryParse(f.first) ?? 0;
      case 'W':
        if (f.length >= 3) {
          final total = int.tryParse(f[1]) ?? 0;
          final used = int.tryParse(f[2]) ?? 0;
          if (total > 0) {
            m.swapPercent = used / total;
            m.swapText = '${used}M / ${total}M';
          } else {
            m.swapText = '0M';
            m.swapPercent = 0;
          }
        }
      case 'I':
        if (f.length >= 5) {
          final p = int.tryParse(f[4].replaceAll('%', ''));
          if (p != null) {
            m.inodePercent = p / 100;
            m.inodeText = '${f[2]} / ${f[1]}';
          }
        }
      case 'U':
        final s = double.tryParse(f.first);
        if (s != null) m.uptimeSeconds = s.floor();
      case 'N':
        if (f.length >= 2) {
          m.rxBytes = int.tryParse(f[0]);
          m.txBytes = int.tryParse(f[1]);
        }
      case 'P':
        if (f.length >= 5) {
          m.processes.add(
              ProcessRow(f[0], f[1], f[2], f[3], f.sublist(4).join(' ')));
        }
      case 'S':
        if (v == '__notool__') {
          m.portsAvailable = false;
          continue;
        }
        final p = v.split('|');
        if (p.length >= 2) {
          final proc = p.length > 2 ? _procName(p[2]) : '';
          m.ports.add(ListeningPort(p[0], p[1], proc));
        }
    }
  }
  if (previous != null &&
      elapsed != null &&
      elapsed.inMilliseconds > 0 &&
      previous.rxBytes != null &&
      m.rxBytes != null &&
      m.rxBytes! >= previous.rxBytes!) {
    final s = elapsed.inMilliseconds / 1000;
    m.rxRate = (m.rxBytes! - previous.rxBytes!) / s;
    m.txRate = ((m.txBytes ?? 0) - (previous.txBytes ?? 0)) / s;
  }
  return m;
}

/// `users:(("nginx",pid=1,fd=6))` → `nginx`; netstat `123/nginx` → `nginx`.
String _procName(String raw) {
  final q = RegExp(r'"([^"]+)"').firstMatch(raw);
  if (q != null) return q[1]!;
  final slash = raw.indexOf('/');
  if (slash >= 0) return raw.substring(slash + 1);
  return raw == '-' ? '' : raw;
}

String formatBytesRate(double? bps) {
  if (bps == null) return '—';
  const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
  var v = bps;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}';
}

String formatUptime(int? seconds) {
  if (seconds == null) return '—';
  final d = seconds ~/ 86400;
  final h = (seconds % 86400) ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (d > 0) return '${d}d ${h}h';
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}

// ---------------------------------------------------------------------------
// Threshold alerts
// ---------------------------------------------------------------------------

enum MetricKind { cpu, ram, disk, swap, inode }

class Thresholds {
  final bool enabled;
  final int cpuPercent; // load per core
  final int ramPercent;
  final int diskPercent;
  final int swapPercent;
  const Thresholds({
    this.enabled = false,
    this.cpuPercent = 90,
    this.ramPercent = 90,
    this.diskPercent = 90,
    this.swapPercent = 80,
  });

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'cpu': cpuPercent,
        'ram': ramPercent,
        'disk': diskPercent,
        'swap': swapPercent,
      };
  factory Thresholds.fromJson(Map<String, dynamic> j) => Thresholds(
        enabled: j['enabled'] as bool? ?? false,
        cpuPercent: j['cpu'] as int? ?? 90,
        ramPercent: j['ram'] as int? ?? 90,
        diskPercent: j['disk'] as int? ?? 90,
        swapPercent: j['swap'] as int? ?? 80,
      );
  Thresholds copyWith(
          {bool? enabled, int? cpu, int? ram, int? disk, int? swap}) =>
      Thresholds(
        enabled: enabled ?? this.enabled,
        cpuPercent: cpu ?? cpuPercent,
        ramPercent: ram ?? ramPercent,
        diskPercent: disk ?? diskPercent,
        swapPercent: swap ?? swapPercent,
      );
}

class ThresholdBreach {
  final MetricKind kind;
  final double value; // 0..1+
  final int limit; // percent
  const ThresholdBreach(this.kind, this.value, this.limit);
}

/// Edge-triggered with hysteresis: a metric alerts once when it crosses its
/// limit and re-arms only after dropping [rearmMargin] points below it, so a
/// value hovering at the limit doesn't alert on every poll.
class ThresholdWatcher {
  ThresholdWatcher({this.rearmMargin = 5});
  final int rearmMargin;
  final Set<MetricKind> _tripped = {};

  List<ThresholdBreach> evaluate(Thresholds t, Map<MetricKind, double?> values) {
    if (!t.enabled) {
      _tripped.clear();
      return const [];
    }
    final out = <ThresholdBreach>[];
    int limitFor(MetricKind k) => switch (k) {
          MetricKind.cpu => t.cpuPercent,
          MetricKind.ram => t.ramPercent,
          MetricKind.disk => t.diskPercent,
          MetricKind.swap => t.swapPercent,
          MetricKind.inode => t.diskPercent,
        };
    values.forEach((k, v) {
      if (v == null) return;
      final pct = v * 100;
      final limit = limitFor(k);
      if (pct >= limit) {
        if (_tripped.add(k)) out.add(ThresholdBreach(k, v, limit));
      } else if (pct < limit - rearmMargin) {
        _tripped.remove(k);
      }
    });
    return out;
  }

  void reset() => _tripped.clear();
}

// ---------------------------------------------------------------------------
// Network checks (run on the server over SSH)
// ---------------------------------------------------------------------------

enum NetCheckKind { dns, tcp, tls }

final RegExp _hostRe = RegExp(r'^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$');
final RegExp _ipv6Re = RegExp(r'^[0-9A-Fa-f:.]{2,45}$');

/// Only plain hostnames / IPs reach the shell: no quoting games.
bool isSafeHost(String host) =>
    host.isNotEmpty && (_hostRe.hasMatch(host) || (host.contains(':') && _ipv6Re.hasMatch(host)));

bool isValidPort(int? p) => p != null && p >= 1 && p <= 65535;

/// Builds the remote command. Throws [ArgumentError] for unsafe input.
String buildNetCheckCmd(NetCheckKind kind, String host, {int? port}) {
  if (!isSafeHost(host)) throw ArgumentError.value(host, 'host');
  if (kind != NetCheckKind.dns && !isValidPort(port)) {
    throw ArgumentError.value(port, 'port');
  }
  switch (kind) {
    case NetCheckKind.dns:
      return 'if command -v getent >/dev/null 2>&1; then getent ahosts $host | awk \'{print \$1}\' | sort -u; '
          'elif command -v dig >/dev/null 2>&1; then dig +short $host A $host AAAA; '
          'elif command -v nslookup >/dev/null 2>&1; then nslookup $host | awk \'/^Address/ && !/#/ {print \$2}\'; '
          'else echo __notool__; fi';
    case NetCheckKind.tcp:
      return 'if command -v nc >/dev/null 2>&1; then nc -z -w 5 $host $port >/dev/null 2>&1 && echo __open__ || echo __closed__; '
          'elif command -v bash >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then timeout 5 bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1 && echo __open__ || echo __closed__; '
          'else echo __notool__; fi';
    case NetCheckKind.tls:
      final sni = host.contains(':') ? '' : ' -servername $host';
      final target = host.contains(':') ? '[$host]:$port' : '$host:$port';
      return 'if command -v openssl >/dev/null 2>&1; then echo | timeout 10 openssl s_client -connect $target$sni 2>/dev/null '
          '| openssl x509 -noout -subject -issuer -enddate 2>/dev/null || echo __fail__; else echo __notool__; fi';
  }
}

class NetCheckResult {
  final bool ok;
  final bool toolMissing;
  final List<String> lines;
  final DateTime? certExpires;
  const NetCheckResult(
      {required this.ok,
      this.toolMissing = false,
      this.lines = const [],
      this.certExpires});

  int? daysLeft(DateTime now) => certExpires?.difference(now).inDays;
}

NetCheckResult parseNetCheck(NetCheckKind kind, String out) {
  final lines = const LineSplitter()
      .convert(out)
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.contains('__notool__')) {
    return const NetCheckResult(ok: false, toolMissing: true);
  }
  switch (kind) {
    case NetCheckKind.dns:
      return NetCheckResult(ok: lines.isNotEmpty, lines: lines);
    case NetCheckKind.tcp:
      return NetCheckResult(ok: lines.contains('__open__'));
    case NetCheckKind.tls:
      if (lines.isEmpty || lines.contains('__fail__')) {
        return const NetCheckResult(ok: false);
      }
      DateTime? expires;
      for (final l in lines) {
        if (l.startsWith('notAfter=')) expires = parseOpensslDate(l.substring(9));
      }
      return NetCheckResult(
          ok: expires != null, lines: lines, certExpires: expires);
  }
}

const _months = {
  'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
  'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
};

/// `Jan  5 12:00:00 2027 GMT` → UTC DateTime.
DateTime? parseOpensslDate(String s) {
  final m = RegExp(r'^(\w{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(\d{4})')
      .firstMatch(s.trim());
  if (m == null) return null;
  final mon = _months[m[1]];
  if (mon == null) return null;
  return DateTime.utc(int.parse(m[6]!), mon, int.parse(m[2]!),
      int.parse(m[3]!), int.parse(m[4]!), int.parse(m[5]!));
}
