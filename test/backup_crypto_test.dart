import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/services/backup_crypto.dart';

/// Independent vector generated with argon2-cffi (reference Argon2 C code) and
/// PyNaCl (libsodium XChaCha20-Poly1305), not with this implementation.
const _vector = <String, dynamic>{
  'kammel_encrypted_backup': 1,
  'kdf': {
    'name': 'argon2id',
    'memoryKiB': 64,
    'iterations': 1,
    'parallelism': 1
  },
  'aead': 'xchacha20-poly1305',
  'salt': 'AAECAwQFBgcICQoLDA0ODw==',
  'nonce': 'ZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7',
  'ciphertext':
      'njRwgJ4Gsm0DQ6+vZ3hYcqqcQKM9vq+eSOZEmIn4ZM9vRuzCURog81x9hPDltuiF',
  'mac': 'SFb3PgxHYbneI7NMBeHYSw==',
};
const _password = 'correct horse battery staple';
const _plain = '{"kammel_backup":1,"prefs":{"x":"Привет"}}';
const _fast = KdfParams(memoryKiB: 64, iterations: 1, parallelism: 1);

Matcher _fails(BackupCryptoFailure f) => throwsA(
    isA<BackupCryptoError>().having((e) => e.failure, 'failure', f));

void main() {
  test('decrypts the libsodium/argon2 reference vector', () async {
    expect(await BackupCrypto.decrypt(_vector, _password), _plain);
  });

  test('reproduces the reference vector byte for byte', () async {
    final out = await BackupCrypto.encrypt(_plain, _password,
        params: _fast,
        salt: List.generate(16, (i) => i),
        nonce: List.generate(24, (i) => 100 + i));
    expect(out, _vector);
  });

  test('round-trips with the production parameters', () async {
    final c = await BackupCrypto.encrypt('hola', 'pw');
    expect(c['kdf']['memoryKiB'], 19456);
    expect(await BackupCrypto.decrypt(c, 'pw'), 'hola');
  });

  test('a fresh salt and nonce every time', () async {
    final a = await BackupCrypto.encrypt('x', 'pw', params: _fast);
    final b = await BackupCrypto.encrypt('x', 'pw', params: _fast);
    expect(a['salt'], isNot(b['salt']));
    expect(a['nonce'], isNot(b['nonce']));
  });

  test('wrong password is rejected', () async {
    expect(BackupCrypto.decrypt(_vector, 'nope'),
        _fails(BackupCryptoFailure.wrongPasswordOrCorrupt));
  });

  test('tampered ciphertext or mac is rejected', () async {
    final bad = Map<String, dynamic>.from(_vector)
      ..['mac'] = 'AAAAAAAAAAAAAAAAAAAAAA==';
    expect(BackupCrypto.decrypt(bad, _password),
        _fails(BackupCryptoFailure.wrongPasswordOrCorrupt));
  });

  test('tampered KDF parameters fail authentication', () async {
    final bad = Map<String, dynamic>.from(_vector)
      ..['kdf'] = {
        'name': 'argon2id',
        'memoryKiB': 64,
        'iterations': 2,
        'parallelism': 1
      };
    expect(BackupCrypto.decrypt(bad, _password),
        _fails(BackupCryptoFailure.wrongPasswordOrCorrupt));
  });

  test('newer format and unknown algorithms are refused', () async {
    expect(
        BackupCrypto.decrypt(
            Map<String, dynamic>.from(_vector)..['kammel_encrypted_backup'] = 2,
            _password),
        _fails(BackupCryptoFailure.unsupportedVersion));
    expect(
        BackupCrypto.decrypt(
            Map<String, dynamic>.from(_vector)..['aead'] = 'aes-ecb', _password),
        _fails(BackupCryptoFailure.unsupportedAlgorithm));
  });

  test('absurd KDF cost from a crafted file is refused before deriving',
      () async {
    final bad = Map<String, dynamic>.from(_vector)
      ..['kdf'] = {
        'name': 'argon2id',
        'memoryKiB': 1 << 30,
        'iterations': 1,
        'parallelism': 1
      };
    expect(BackupCrypto.decrypt(bad, _password),
        _fails(BackupCryptoFailure.malformed));
  });

  test('empty password is refused', () {
    expect(BackupCrypto.encrypt('x', ''),
        _fails(BackupCryptoFailure.emptyPassword));
  });
}
