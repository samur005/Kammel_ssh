import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Password-based encryption for backups and sync containers.
///
/// No home-made crypto: Argon2id (RFC 9106) derives a 256-bit key from the
/// password and XChaCha20-Poly1305 encrypts and authenticates the payload,
/// both from `package:cryptography`. The header (format, KDF parameters, AEAD
/// name) is bound to the ciphertext as associated data, so tampering with the
/// parameters fails authentication instead of silently weakening anything.
///
/// Container (JSON, every binary field base64):
///
/// ```json
/// {
///   "kammel_encrypted_backup": 1,
///   "kdf": {"name": "argon2id", "memoryKiB": 19456, "iterations": 2, "parallelism": 1},
///   "aead": "xchacha20-poly1305",
///   "salt": "…16 bytes…",
///   "nonce": "…24 bytes…",
///   "ciphertext": "…",
///   "mac": "…16 bytes…"
/// }
/// ```
///
/// A fresh random salt and nonce are drawn for every encryption. There is no
/// recovery: without the password the content cannot be read.
class BackupCrypto {
  BackupCrypto._();

  static const int formatVersion = 1;
  static const String marker = 'kammel_encrypted_backup';
  static const String aeadName = 'xchacha20-poly1305';

  /// OWASP's minimum recommended Argon2id profile (19 MiB, t=2, p=1): strong
  /// enough for a backup file, still a couple of seconds on a mid-range phone.
  static const KdfParams defaultParams =
      KdfParams(memoryKiB: 19456, iterations: 2, parallelism: 1);

  /// Hard caps when *reading*, so a crafted file can't make the app allocate
  /// gigabytes or spin for minutes.
  static const int _maxMemoryKiB = 262144;
  static const int _maxIterations = 10;

  /// True when [envelope] looks like an encrypted container (any version).
  static bool isEncrypted(Map<String, dynamic> envelope) =>
      envelope.containsKey(marker);

  static Uint8List _aad(KdfParams p) => Uint8List.fromList(utf8.encode(
      '$marker:$formatVersion|argon2id|m=${p.memoryKiB}|t=${p.iterations}'
      '|p=${p.parallelism}|$aeadName'));

  static Future<SecretKey> _deriveKey(
      String password, List<int> salt, KdfParams p) {
    final kdf = Argon2id(
      parallelism: p.parallelism,
      memory: p.memoryKiB,
      iterations: p.iterations,
      hashLength: 32,
    );
    return kdf.deriveKey(
        secretKey: SecretKey(utf8.encode(password)), nonce: salt);
  }

  /// Encrypts [plaintext] with [password]. [salt]/[nonce] exist for test
  /// vectors only; production callers must leave them null.
  static Future<Map<String, dynamic>> encrypt(
    String plaintext,
    String password, {
    KdfParams params = defaultParams,
    List<int>? salt,
    List<int>? nonce,
  }) async {
    if (password.isEmpty) {
      throw const BackupCryptoError(BackupCryptoFailure.emptyPassword);
    }
    final aead = Xchacha20.poly1305Aead();
    final s = salt ?? _random(16);
    final n = nonce ?? aead.newNonce();
    final key = await _deriveKey(password, s, params);
    final box = await aead.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: n,
      aad: _aad(params),
    );
    return {
      marker: formatVersion,
      'kdf': {
        'name': 'argon2id',
        'memoryKiB': params.memoryKiB,
        'iterations': params.iterations,
        'parallelism': params.parallelism,
      },
      'aead': aeadName,
      'salt': base64.encode(s),
      'nonce': base64.encode(box.nonce),
      'ciphertext': base64.encode(box.cipherText),
      'mac': base64.encode(box.mac.bytes),
    };
  }

  /// Decrypts a container produced by [encrypt]. Throws [BackupCryptoError].
  static Future<String> decrypt(
      Map<String, dynamic> container, String password) async {
    final version = container[marker];
    if (version is! int) {
      throw const BackupCryptoError(BackupCryptoFailure.malformed);
    }
    if (version > formatVersion) {
      throw const BackupCryptoError(BackupCryptoFailure.unsupportedVersion);
    }
    final kdf = container['kdf'];
    if (kdf is! Map ||
        kdf['name'] != 'argon2id' ||
        container['aead'] != aeadName) {
      throw const BackupCryptoError(BackupCryptoFailure.unsupportedAlgorithm);
    }
    final KdfParams params;
    final List<int> salt, nonce, cipherText, mac;
    try {
      params = KdfParams(
        memoryKiB: kdf['memoryKiB'] as int,
        iterations: kdf['iterations'] as int,
        parallelism: kdf['parallelism'] as int,
      );
      salt = base64.decode(container['salt'] as String);
      nonce = base64.decode(container['nonce'] as String);
      cipherText = base64.decode(container['ciphertext'] as String);
      mac = base64.decode(container['mac'] as String);
    } catch (_) {
      throw const BackupCryptoError(BackupCryptoFailure.malformed);
    }
    if (params.memoryKiB < 8 ||
        params.memoryKiB > _maxMemoryKiB ||
        params.iterations < 1 ||
        params.iterations > _maxIterations ||
        params.parallelism < 1 ||
        params.parallelism > 8 ||
        salt.length < 8 ||
        nonce.length != 24 ||
        mac.length != 16) {
      throw const BackupCryptoError(BackupCryptoFailure.malformed);
    }
    final key = await _deriveKey(password, salt, params);
    try {
      final clear = await Xchacha20.poly1305Aead().decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
        aad: _aad(params),
      );
      return utf8.decode(clear);
    } on SecretBoxAuthenticationError {
      // Wrong password and tampered data are indistinguishable by design.
      throw const BackupCryptoError(BackupCryptoFailure.wrongPasswordOrCorrupt);
    } on FormatException {
      throw const BackupCryptoError(BackupCryptoFailure.malformed);
    }
  }

  /// [encrypt] off the UI isolate: Argon2id is deliberately slow.
  static Future<Map<String, dynamic>> encryptInBackground(
          String plaintext, String password) =>
      Isolate.run(() => encrypt(plaintext, password));

  /// [decrypt] off the UI isolate.
  static Future<String> decryptInBackground(
          Map<String, dynamic> container, String password) =>
      Isolate.run(() => decrypt(container, password));

  static List<int> _random(int n) => SecretKeyData.random(length: n).bytes;
}

class KdfParams {
  final int memoryKiB;
  final int iterations;
  final int parallelism;
  const KdfParams(
      {required this.memoryKiB,
      required this.iterations,
      required this.parallelism});
}

enum BackupCryptoFailure {
  emptyPassword,
  malformed,
  unsupportedVersion,
  unsupportedAlgorithm,
  wrongPasswordOrCorrupt,
}

class BackupCryptoError implements Exception {
  final BackupCryptoFailure failure;
  const BackupCryptoError(this.failure);
  @override
  String toString() => 'BackupCryptoError(${failure.name})';
}
