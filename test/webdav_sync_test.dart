import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:terminal_agent/services/webdav_sync.dart';

/// In-memory WebDAV server honouring If-Match / If-None-Match.
class _FakeDav {
  final files = <String, String>{};
  final tags = <String, int>{};
  int _n = 0;
  final requests = <http.Request>[];

  late final client = MockClient((req) async {
    requests.add(req);
    final name = Uri.decodeComponent(req.url.pathSegments.last);
    final tag = tags[name] == null ? null : '"${tags[name]}"';
    switch (req.method) {
      case 'HEAD':
      case 'GET':
        if (!files.containsKey(name)) return http.Response('', 404);
        return http.Response(req.method == 'GET' ? files[name]! : '', 200,
            headers: {'etag': tag!});
      case 'PUT':
        final im = req.headers['If-Match'];
        if (im != null && im != tag) return http.Response('', 412);
        if (req.headers['If-None-Match'] == '*' && tag != null) {
          return http.Response('', 412);
        }
        files[name] = req.body;
        tags[name] = ++_n;
        return http.Response('', 201, headers: {'etag': '"$_n"'});
    }
    return http.Response('', 405);
  });
}

// Encryption is covered by backup_crypto_test; identity keeps these fast.
Future<Map<String, dynamic>> _enc(String s, String _) async =>
    {'clear': s};
Future<String> _dec(Map<String, dynamic> c, String _) async =>
    c['clear'] as String;

Map<String, dynamic> _env(String v) => {
      'kammel_backup': 1,
      'createdAt': DateTime.now().toIso8601String(),
      'prefs': {
        'settings_x': {'type': 'string', 'value': v}
      },
    };

class _Device {
  _Device(this.dav, this.value);
  final _FakeDav dav;
  String value;
  SyncState state = const SyncState();
  SyncConflictChoice? choice;
  int conflicts = 0;

  WebDavSyncEngine engine() => WebDavSyncEngine(
        dav: WebDavClient(
            folder: Uri.parse('https://dav.example/kammel'),
            username: 'u',
            password: 'p',
            client: dav.client),
        syncPassword: 'pw',
        buildLocal: () async => _env(value),
        applyRemote: (e) async =>
            value = (e['prefs'] as Map)['settings_x']['value'] as String,
        resolveConflict: () async {
          conflicts++;
          return choice;
        },
        loadState: () async => state,
        saveState: (s) async => state = s,
        encrypt: _enc,
        decrypt: _dec,
      );
}

void main() {
  test('first device uploads, second device downloads', () async {
    final dav = _FakeDav();
    final a = _Device(dav, 'A');
    expect(await a.engine().sync(), SyncOutcome.uploaded);
    final b = _Device(dav, 'A');
    // Same content on both sides: nothing to decide.
    expect(await b.engine().sync(), SyncOutcome.upToDate);

    a.value = 'A2';
    expect(await a.engine().sync(), SyncOutcome.uploaded);
    expect(await b.engine().sync(), SyncOutcome.downloaded);
    expect(b.value, 'A2');
    expect(await b.engine().sync(), SyncOutcome.upToDate);
  });

  test('only the encrypted container reaches the server, with Basic auth',
      () async {
    final dav = _FakeDav();
    await _Device(dav, 'secret-value').engine().sync();
    final put = dav.requests.firstWhere((r) => r.method == 'PUT');
    expect(put.headers['Authorization'],
        'Basic ${base64.encode(utf8.encode('u:p'))}');
    expect(put.headers['If-None-Match'], '*');
    expect(put.url.toString(),
        'https://dav.example/kammel/kammel-sync.enc.json');
  });

  group('both sides changed', () {
    Future<(_Device, _Device, _FakeDav)> diverge() async {
      final dav = _FakeDav();
      final a = _Device(dav, 'base');
      final b = _Device(dav, 'base');
      await a.engine().sync();
      await b.engine().sync();
      a.value = 'from A';
      await a.engine().sync();
      b.value = 'from B';
      return (a, b, dav);
    }

    test('never overwrites silently: cancel leaves everything as is',
        () async {
      final (_, b, dav) = await diverge();
      b.choice = null;
      expect(await b.engine().sync(), SyncOutcome.cancelled);
      expect(b.conflicts, 1);
      expect(b.value, 'from B');
      expect(dav.files['kammel-sync.enc.json'], contains('from A'));
    });

    test('keep local uploads this device', () async {
      final (a, b, dav) = await diverge();
      b.choice = SyncConflictChoice.keepLocal;
      expect(await b.engine().sync(), SyncOutcome.keptLocal);
      expect(dav.files['kammel-sync.enc.json'], contains('from B'));
      expect(await a.engine().sync(), SyncOutcome.downloaded);
      expect(a.value, 'from B');
    });

    test('keep cloud applies the remote copy', () async {
      final (_, b, _) = await diverge();
      b.choice = SyncConflictChoice.keepCloud;
      expect(await b.engine().sync(), SyncOutcome.keptCloud);
      expect(b.value, 'from A');
      expect(await b.engine().sync(), SyncOutcome.upToDate);
    });

    test('keep both stores this device as a conflict copy', () async {
      final (_, b, dav) = await diverge();
      b.choice = SyncConflictChoice.keepBoth;
      expect(await b.engine().sync(), SyncOutcome.keptBoth);
      expect(b.value, 'from A');
      final copy = dav.files.keys
          .firstWhere((k) => k.startsWith('kammel-sync-conflict-'));
      expect(dav.files[copy], contains('from B'));
    });
  });

  test('an auth failure surfaces as WebDavError', () async {
    final engine = WebDavSyncEngine(
      dav: WebDavClient(
          folder: Uri.parse('https://dav.example/'),
          username: 'u',
          password: 'bad',
          client: MockClient((_) async => http.Response('', 401))),
      syncPassword: 'pw',
      buildLocal: () async => _env('x'),
      applyRemote: (_) async {},
      resolveConflict: () async => null,
      loadState: () async => const SyncState(),
      saveState: (_) async {},
      encrypt: _enc,
      decrypt: _dec,
    );
    expect(engine.sync(),
        throwsA(isA<WebDavError>().having((e) => e.isAuth, 'isAuth', true)));
  });

  test('plain http is refused except on the local network', () {
    expect(WebDavSettings.validateUrl('https://cloud.example/dav'), isNull);
    expect(WebDavSettings.validateUrl('http://192.168.1.5/dav'), isNull);
    expect(WebDavSettings.validateUrl('http://cloud.example/dav'), 'insecure');
    expect(WebDavSettings.validateUrl('nonsense'), 'invalid');
  });
}
