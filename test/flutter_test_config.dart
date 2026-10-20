import 'dart:async';
import 'dart:ui' show Locale;

import 'package:terminal_agent/l10n/l10n.dart';

/// Runs before every test file. The UI follows the device language when none
/// was chosen, and the test host's locale is whatever the machine running the
/// suite uses — so pin the "device" to Spanish, the source language most
/// tests assert against. Tests about language detection override it.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  L10n.systemLocales = () => const [Locale('es')];
  await testMain();
}
