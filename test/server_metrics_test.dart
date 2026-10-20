import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/services/secret_mask.dart';
import 'package:terminal_agent/services/server_metrics.dart';

const _sample = '''
C|4
L|2.00 1.50 1.00 2/300 1234
W|Swap:          2047         512        1535
I|/dev/sda1      6553600  655360  5898240   10% /
U|90061.42 123.0
N|1000 2000
P|  101 root      55.0  1.2 dockerd
P|  202 www-data   3.1  0.5 nginx
S|tcp|0.0.0.0:22|users:(("sshd",pid=1,fd=3))
S|tcp|[::]:443|users:(("nginx",pid=2,fd=6))
''';

void main() {
  group('extended metrics', () {
    test('parses every probe', () {
      final m = parseExtendedMetrics(_sample);
      expect(m.cores, 4);
      expect(m.cpuPressure, 0.5);
      expect(m.swapPercent, closeTo(512 / 2047, 1e-9));
      expect(m.inodePercent, 0.10);
      expect(m.uptimeSeconds, 90061);
      expect(formatUptime(m.uptimeSeconds), '1d 1h');
      expect(m.processes.first.command, 'dockerd');
      expect(m.processes.first.cpu, '55.0');
      expect(m.ports.map((p) => p.process), ['sshd', 'nginx']);
      expect(m.ports[1].address, '[::]:443');
    });

    test('network rate from two samples', () {
      final a = parseExtendedMetrics('N|1000 2000');
      final b = parseExtendedMetrics('N|3048 2000',
          previous: a, elapsed: const Duration(seconds: 2));
      expect(b.rxRate, 1024);
      expect(formatBytesRate(b.rxRate), '1.0 KB/s');
      expect(b.txRate, 0);
    });

    test('missing tools degrade instead of failing', () {
      final m = parseExtendedMetrics('S|__notool__\nW|');
      expect(m.portsAvailable, isFalse);
      expect(m.swapPercent, isNull);
    });
  });

  group('thresholds', () {
    test('alerts once per crossing, re-arms below the margin', () {
      final w = ThresholdWatcher();
      const t = Thresholds(enabled: true, ramPercent: 90);
      expect(w.evaluate(t, {MetricKind.ram: 0.95}).length, 1);
      expect(w.evaluate(t, {MetricKind.ram: 0.97}), isEmpty);
      expect(w.evaluate(t, {MetricKind.ram: 0.88}), isEmpty); // within margin
      expect(w.evaluate(t, {MetricKind.ram: 0.95}), isEmpty);
      expect(w.evaluate(t, {MetricKind.ram: 0.80}), isEmpty); // re-armed
      expect(w.evaluate(t, {MetricKind.ram: 0.91}).single.kind, MetricKind.ram);
    });

    test('disabled never alerts', () {
      expect(
          ThresholdWatcher()
              .evaluate(const Thresholds(), {MetricKind.cpu: 5.0}),
          isEmpty);
    });

    test('round-trips through JSON', () {
      const t = Thresholds(enabled: true, cpuPercent: 70, swapPercent: 60);
      final back = Thresholds.fromJson(t.toJson());
      expect(back.enabled, isTrue);
      expect(back.cpuPercent, 70);
      expect(back.swapPercent, 60);
    });
  });

  group('network checks', () {
    test('only plain hosts reach the shell', () {
      expect(isSafeHost('example.com'), isTrue);
      expect(isSafeHost('10.0.0.1'), isTrue);
      expect(isSafeHost('2001:db8::1'), isTrue);
      for (final bad in [
        'a.com;rm -rf /',
        r'$(id)',
        'a b',
        '`id`',
        "x'y",
        '-oProxyCommand=x',
        ''
      ]) {
        expect(isSafeHost(bad), isFalse, reason: bad);
        expect(() => buildNetCheckCmd(NetCheckKind.dns, bad),
            throwsArgumentError);
      }
      expect(() => buildNetCheckCmd(NetCheckKind.tcp, 'a.com', port: 0),
          throwsArgumentError);
    });

    test('commands check that their tool exists', () {
      expect(buildNetCheckCmd(NetCheckKind.tls, 'a.com', port: 443),
          allOf(contains('command -v openssl'), contains('-servername a.com')));
      expect(buildNetCheckCmd(NetCheckKind.tcp, 'a.com', port: 22),
          contains('command -v nc'));
    });

    test('parses results', () {
      expect(parseNetCheck(NetCheckKind.tcp, '__open__\n').ok, isTrue);
      expect(parseNetCheck(NetCheckKind.tcp, '__closed__').ok, isFalse);
      expect(parseNetCheck(NetCheckKind.dns, '__notool__').toolMissing, isTrue);
      expect(parseNetCheck(NetCheckKind.dns, '1.2.3.4\n').lines, ['1.2.3.4']);
      final tls = parseNetCheck(NetCheckKind.tls,
          'subject=CN = a.com\nissuer=CN = R3\nnotAfter=Jan  5 12:00:00 2027 GMT\n');
      expect(tls.ok, isTrue);
      expect(tls.certExpires, DateTime.utc(2027, 1, 5, 12));
      expect(tls.daysLeft(DateTime.utc(2026, 12, 6, 12)), 30);
    });
  });

  group('secret masking', () {
    test('masks env vars that look like secrets', () {
      expect(maskEnvEntry('POSTGRES_PASSWORD=hunter2'),
          'POSTGRES_PASSWORD=$kMask');
      expect(maskEnvEntry('GITHUB_TOKEN=ghp_x'), 'GITHUB_TOKEN=$kMask');
      expect(maskEnvEntry('AWS_SECRET_ACCESS_KEY=x'),
          'AWS_SECRET_ACCESS_KEY=$kMask');
      expect(maskEnvEntry('PATH=/usr/bin'), 'PATH=/usr/bin');
      expect(maskEnvEntry('EMPTY_PASSWORD='), 'EMPTY_PASSWORD=');
    });

    test('masks credentials inside URLs', () {
      expect(maskEnvEntry('DATABASE_URL=postgres://app:s3cr3t@db:5432/app'),
          'DATABASE_URL=postgres://app:$kMask@db:5432/app');
      expect(maskUrlCredentials('see https://example.com/x'),
          'see https://example.com/x');
    });
  });
}
