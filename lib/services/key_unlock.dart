import 'package:dartssh2/dartssh2.dart';

/// Thrown when an encrypted private key could not be unlocked (the user
/// cancelled the prompt or ran out of attempts).
class KeyLockedError implements Exception {
  final bool cancelled;
  const KeyLockedError({required this.cancelled});
  @override
  String toString() => cancelled
      ? 'Private key passphrase prompt cancelled'
      : 'Wrong private key passphrase';
}

/// Asks the user for a passphrase. [retry] is true after a wrong one.
typedef PassphrasePrompt = Future<({String value, bool remember})?> Function(
    {required bool retry});

/// Parses [pem], unlocking it when it is encrypted.
///
/// Tries [candidates] first (a remembered passphrase, then — for profiles from
/// older versions — the profile password), then [ask]s up to [maxAttempts]
/// times. A passphrase the user asked to remember is handed to [remember].
Future<List<SSHKeyPair>> unlockPrivateKey(
  String pem, {
  List<String?> candidates = const [],
  PassphrasePrompt? ask,
  Future<void> Function(String passphrase)? remember,
  int maxAttempts = 3,
}) async {
  if (!SSHKeyPair.isEncryptedPem(pem)) return SSHKeyPair.fromPem(pem);

  List<SSHKeyPair>? attempt(String pass) {
    try {
      return SSHKeyPair.fromPem(pem, pass);
    } on SSHKeyDecryptError {
      return null;
    } on SSHKeyDecodeError {
      return null;
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    } on StateError {
      return null;
    }
  }

  for (final c in candidates) {
    if (c == null || c.isEmpty) continue;
    final keys = attempt(c);
    if (keys != null) return keys;
  }
  if (ask == null) throw const KeyLockedError(cancelled: false);
  for (var i = 0; i < maxAttempts; i++) {
    final r = await ask(retry: i > 0);
    if (r == null) throw const KeyLockedError(cancelled: true);
    final keys = attempt(r.value);
    if (keys != null) {
      if (r.remember) await remember?.call(r.value);
      return keys;
    }
  }
  throw const KeyLockedError(cancelled: false);
}
