import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Thin wrapper over [FlutterSecureStorage] for connection secrets
/// (passwords and private keys). On Android these land in the Keystore-backed
/// EncryptedSharedPreferences; on Linux in libsecret. Profile *metadata* still
/// lives in plain shared_preferences — only the secrets go here, keyed by the
/// owning profile's id.
class SecureStore {
  SecureStore._();
  static final SecureStore instance = SecureStore._();

  static const _storage = FlutterSecureStorage();

  static String _pwKey(String id) => 'pw_$id';
  static String _pkKey(String id) => 'pk_$id';

  Future<String?> readPassword(String id) => _storage.read(key: _pwKey(id));
  Future<String?> readPrivateKey(String id) => _storage.read(key: _pkKey(id));

  /// Writes (or clears, when [value] is null/empty) a single secret.
  Future<void> _put(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: value);
    }
  }

  Future<void> writeSecrets(String id,
      {String? password, String? privateKey}) async {
    await _put(_pwKey(id), password);
    await _put(_pkKey(id), privateKey);
  }

  Future<void> deleteSecrets(String id) async {
    await _storage.delete(key: _pwKey(id));
    await _storage.delete(key: _pkKey(id));
    await _storage.delete(key: _ppKey(id));
  }

  // ---- Generic secrets (WebDAV credentials, sync password…) ---------------
  Future<String?> read(String key) => _storage.read(key: key);
  Future<void> write(String key, String? value) => _put(key, value);

  // ---- Key passphrases ------------------------------------------------------
  // Only stored when the user ticks "remember"; otherwise asked each time.
  static String _ppKey(String id) => 'pp_$id';
  Future<String?> readPassphrase(String id) => _storage.read(key: _ppKey(id));
  Future<void> writePassphrase(String id, String? value) =>
      _put(_ppKey(id), value);

  // ---- Device SSH key -------------------------------------------------------
  // The phone's own ed25519 identity (see DeviceKey). One per device, not tied
  // to any profile.
  static const _deviceKeyKey = 'device_ssh_key';

  Future<String?> readDeviceKey() => _storage.read(key: _deviceKeyKey);
  Future<void> writeDeviceKey(String pem) =>
      _storage.write(key: _deviceKeyKey, value: pem);
}
