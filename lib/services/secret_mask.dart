/// Masks secrets before they are shown on screen (docker inspect env, URLs).
///
/// Heuristic on purpose: a value is hidden when its *name* looks like a
/// credential, and credentials embedded in URLs (`scheme://user:pass@host`)
/// are hidden wherever they appear.
library;

const String kMask = '••••••';

final RegExp _secretName = RegExp(
    r'(pass(word|wd)?|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credential|auth|session|cookie|signature|salt|dsn)',
    caseSensitive: false);

final RegExp _urlCreds = RegExp(r'([a-zA-Z][a-zA-Z0-9+.-]*://[^:/@\s]+:)([^@\s/]+)(@)');

bool looksSecretName(String name) => _secretName.hasMatch(name);

/// Hides `user:password@` in any URL inside [text].
String maskUrlCredentials(String text) =>
    text.replaceAllMapped(_urlCreds, (m) => '${m[1]}$kMask${m[3]}');

/// `KEY=value` → `KEY=••••••` when KEY looks like a secret; URL credentials
/// are masked in any value.
String maskEnvEntry(String entry) {
  final eq = entry.indexOf('=');
  if (eq <= 0) return maskUrlCredentials(entry);
  final name = entry.substring(0, eq);
  final value = entry.substring(eq + 1);
  if (value.isEmpty) return entry;
  if (looksSecretName(name)) return '$name=$kMask';
  return '$name=${maskUrlCredentials(value)}';
}
