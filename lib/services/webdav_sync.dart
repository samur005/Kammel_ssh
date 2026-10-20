import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'backup_crypto.dart';
import 'backup_service.dart';
import 'secure_store.dart';

/// Minimal WebDAV client: just what sync needs (HEAD/GET/PUT/DELETE with
/// ETag preconditions). Works with Nextcloud/ownCloud, Yandex Disk
/// (webdav.yandex.ru), Synology, Apache mod_dav, rclone serve webdav…
class WebDavClient {
  final Uri folder;
  final String username;
  final String password;
  final http.Client _http;
  final Duration timeout;

  WebDavClient({
    required this.folder,
    required this.username,
    required this.password,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _http = client ?? http.Client();

  Map<String, String> get _auth => {
        'Authorization':
            'Basic ${base64.encode(utf8.encode('$username:$password'))}',
      };

  Uri fileUri(String name) {
    final base = folder.toString().endsWith('/') ? '$folder' : '$folder/';
    return Uri.parse(base).resolve(Uri.encodeComponent(name));
  }

  void _check(http.BaseResponse r, {Set<int> ok = const {200, 201, 204}}) {
    if (ok.contains(r.statusCode)) return;
    throw WebDavError(r.statusCode);
  }

  /// ETag of [name], or null when it does not exist.
  Future<String?> etag(String name) async {
    final r = await _http.head(fileUri(name), headers: _auth).timeout(timeout);
    if (r.statusCode == 404) return null;
    _check(r);
    return r.headers['etag'] ?? r.headers['last-modified'] ?? '';
  }

  Future<({String body, String? etag})?> get(String name) async {
    final r = await _http.get(fileUri(name), headers: _auth).timeout(timeout);
    if (r.statusCode == 404) return null;
    _check(r);
    return (
      body: utf8.decode(r.bodyBytes),
      etag: r.headers['etag'] ?? r.headers['last-modified']
    );
  }

  /// Uploads. [ifMatch] only overwrites that exact version; [mustNotExist]
  /// only creates. A failed precondition throws [WebDavConflict].
  Future<String?> put(String name, String body,
      {String? ifMatch, bool mustNotExist = false}) async {
    final headers = {
      ..._auth,
      'Content-Type': 'application/json; charset=utf-8',
      // Only a real entity tag can be a precondition (some servers expose
      // only Last-Modified, which we use as a change marker but not here).
      if (ifMatch != null &&
          (ifMatch.startsWith('"') || ifMatch.startsWith('W/')))
        'If-Match': ifMatch,
      if (mustNotExist) 'If-None-Match': '*',
    };
    final r = await _http
        .put(fileUri(name), headers: headers, body: utf8.encode(body))
        .timeout(timeout);
    if (r.statusCode == 412) throw const WebDavConflict();
    _check(r);
    return r.headers['etag'] ?? await etag(name);
  }
}

class WebDavError implements Exception {
  final int status;
  const WebDavError(this.status);
  bool get isAuth => status == 401 || status == 403;
  @override
  String toString() => 'WebDAV HTTP $status';
}

class WebDavConflict implements Exception {
  const WebDavConflict();
}

/// What to do when both this device and the cloud changed since last sync.
enum SyncConflictChoice { keepLocal, keepCloud, keepBoth }

enum SyncOutcome { upToDate, uploaded, downloaded, keptLocal, keptCloud, keptBoth, cancelled }

/// Persisted between syncs (device-local; not part of backups).
class SyncState {
  final String? etag;
  final String? localHash;
  final DateTime? lastSync;
  const SyncState({this.etag, this.localHash, this.lastSync});

  Map<String, dynamic> toJson() => {
        'etag': etag,
        'localHash': localHash,
        'lastSync': lastSync?.toIso8601String(),
      };
  factory SyncState.fromJson(Map<String, dynamic> j) => SyncState(
        etag: j['etag'] as String?,
        localHash: j['localHash'] as String?,
        lastSync: DateTime.tryParse('${j['lastSync']}'),
      );
}

/// Two-way sync of the encrypted backup with one file on a WebDAV server.
///
/// Three-way decision, using the last synced ETag and content hash as the
/// common ancestor: only-local-changed uploads, only-cloud-changed downloads,
/// both-changed asks the user. Uploads carry `If-Match` / `If-None-Match` so
/// a concurrent write by another device is detected rather than overwritten.
/// The server only ever sees the encrypted container.
class WebDavSyncEngine {
  static const remoteName = 'absssh-sync.enc.json';

  /// File written by versions before the ABSssh rename. Read (once) when the
  /// new file does not exist yet; the next upload goes to [remoteName].
  static const legacyRemoteName = 'kammel-sync.enc.json';

  String _readName = remoteName;

  final WebDavClient dav;
  final String syncPassword;
  final Future<Map<String, dynamic>> Function() buildLocal;
  final Future<void> Function(Map<String, dynamic> envelope) applyRemote;
  final Future<SyncConflictChoice?> Function() resolveConflict;
  final Future<SyncState> Function() loadState;
  final Future<void> Function(SyncState) saveState;
  final Future<Map<String, dynamic>> Function(String, String) encrypt;
  final Future<String> Function(Map<String, dynamic>, String) decrypt;
  final DateTime Function() now;

  WebDavSyncEngine({
    required this.dav,
    required this.syncPassword,
    required this.buildLocal,
    required this.applyRemote,
    required this.resolveConflict,
    required this.loadState,
    required this.saveState,
    this.encrypt = BackupCrypto.encryptInBackground,
    this.decrypt = BackupCrypto.decryptInBackground,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  Future<SyncOutcome> sync({bool retried = false}) async {
    try {
      return await _sync();
    } on WebDavConflict {
      // Someone wrote between our read and our write: decide again, once.
      if (retried) rethrow;
      return sync(retried: true);
    }
  }

  Future<SyncOutcome> _sync() async {
    final state = await loadState();
    _readName = remoteName;
    var remoteTag = await dav.etag(remoteName);
    if (remoteTag == null) {
      final legacyTag = await dav.etag(legacyRemoteName);
      if (legacyTag != null) {
        _readName = legacyRemoteName;
        remoteTag = legacyTag;
      }
    }
    final local = await buildLocal();
    final localHash = BackupService.contentHash(local);
    final localChanged = state.localHash != localHash;

    if (remoteTag == null) {
      await _upload(local, localHash, mustNotExist: true);
      return SyncOutcome.uploaded;
    }
    final remoteChanged = state.etag == null || state.etag != remoteTag;

    if (!remoteChanged && !localChanged) {
      await saveState(SyncState(
          etag: remoteTag, localHash: localHash, lastSync: now()));
      return SyncOutcome.upToDate;
    }
    if (!remoteChanged) {
      await _upload(local, localHash, ifMatch: remoteTag);
      return SyncOutcome.uploaded;
    }

    final remote = await _download();
    final remoteHash = BackupService.contentHash(remote.envelope);
    if (remoteHash == localHash) {
      await saveState(SyncState(
          etag: remote.etag ?? remoteTag, localHash: localHash, lastSync: now()));
      return SyncOutcome.upToDate;
    }
    if (!localChanged) {
      await _apply(remote.envelope, remote.etag ?? remoteTag);
      return SyncOutcome.downloaded;
    }

    final choice = await resolveConflict();
    switch (choice) {
      case null:
        return SyncOutcome.cancelled;
      case SyncConflictChoice.keepLocal:
        await _upload(local, localHash, ifMatch: remote.etag ?? remoteTag);
        return SyncOutcome.keptLocal;
      case SyncConflictChoice.keepCloud:
        await _apply(remote.envelope, remote.etag ?? remoteTag);
        return SyncOutcome.keptCloud;
      case SyncConflictChoice.keepBoth:
        final stamp =
            now().toUtc().toIso8601String().replaceAll(':', '-').split('.').first;
        await dav.put('absssh-sync-conflict-$stamp.enc.json',
            json.encode(await encrypt(json.encode(local), syncPassword)));
        await _apply(remote.envelope, remote.etag ?? remoteTag);
        return SyncOutcome.keptBoth;
    }
  }

  Future<void> _upload(Map<String, dynamic> local, String localHash,
      {String? ifMatch, bool mustNotExist = false}) async {
    final container = await encrypt(json.encode(local), syncPassword);
    if (_readName != remoteName) {
      // Migrating from the legacy file: the new one must not exist yet.
      ifMatch = null;
      mustNotExist = true;
    }
    final tag = await dav.put(remoteName, json.encode(container),
        ifMatch: ifMatch, mustNotExist: mustNotExist);
    await saveState(
        SyncState(etag: tag, localHash: localHash, lastSync: now()));
  }

  Future<({Map<String, dynamic> envelope, String? etag})> _download() async {
    final got = await dav.get(_readName);
    if (got == null) throw const WebDavError(404);
    final container = json.decode(got.body) as Map<String, dynamic>;
    final clear = await decrypt(container, syncPassword);
    return (envelope: json.decode(clear) as Map<String, dynamic>, etag: got.etag);
  }

  Future<void> _apply(Map<String, dynamic> envelope, String etag) async {
    await applyRemote(envelope);
    // Hash what this device now holds, so the next sync sees "no change".
    final after = BackupService.contentHash(await buildLocal());
    await saveState(SyncState(etag: etag, localHash: after, lastSync: now()));
  }
}

/// Settings + secrets for the sync screen.
class WebDavSettings {
  static const _cfgKey = 'webdav_config';
  static const _stateKey = 'webdav_sync_state';
  static const _pwKey = 'webdav_password';
  static const _syncPwKey = 'webdav_sync_password';

  final String url;
  final String username;
  final bool includeSecrets;
  const WebDavSettings(
      {this.url = '', this.username = '', this.includeSecrets = false});

  bool get configured => url.isNotEmpty;

  static Future<WebDavSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cfgKey);
    if (raw == null) return const WebDavSettings();
    try {
      final j = json.decode(raw) as Map<String, dynamic>;
      return WebDavSettings(
        url: j['url'] as String? ?? '',
        username: j['username'] as String? ?? '',
        includeSecrets: j['includeSecrets'] as bool? ?? false,
      );
    } catch (_) {
      return const WebDavSettings();
    }
  }

  Future<void> save({String? password, String? syncPassword}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _cfgKey,
        json.encode({
          'url': url,
          'username': username,
          'includeSecrets': includeSecrets,
        }));
    if (password != null) await SecureStore.instance.write(_pwKey, password);
    if (syncPassword != null) {
      await SecureStore.instance.write(_syncPwKey, syncPassword);
    }
  }

  static Future<String?> password() => SecureStore.instance.read(_pwKey);
  static Future<String?> syncPassword() => SecureStore.instance.read(_syncPwKey);

  static Future<void> forget() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cfgKey);
    await prefs.remove(_stateKey);
    await SecureStore.instance.write(_pwKey, null);
    await SecureStore.instance.write(_syncPwKey, null);
  }

  static Future<SyncState> loadState() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_stateKey);
    if (raw == null) return const SyncState();
    try {
      return SyncState.fromJson(json.decode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const SyncState();
    }
  }

  static Future<void> saveState(SyncState s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_stateKey, json.encode(s.toJson()));
  }

  /// Only https (or plain http to a LAN/loopback host) is accepted, so the
  /// Basic-auth password never crosses the internet in the clear.
  static String? validateUrl(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || !u.hasScheme || u.host.isEmpty) return 'invalid';
    if (u.scheme == 'https') return null;
    if (u.scheme == 'http' && _isLocalHost(u.host)) return null;
    return 'insecure';
  }

  static bool _isLocalHost(String h) =>
      h == 'localhost' ||
      h.startsWith('127.') ||
      h.startsWith('10.') ||
      h.startsWith('192.168.') ||
      RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(h) ||
      h.endsWith('.local');
}
