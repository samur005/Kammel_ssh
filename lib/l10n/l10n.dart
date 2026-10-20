import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'strings_en.dart';
import 'strings_ru.dart';
import 'strings_zh.dart';

/// Languages the UI ships with. Spanish is the source language: every `tr()`
/// key *is* the Spanish text, so `AppLang.es` needs no dictionary and can never
/// show a missing translation.
enum AppLang {
  es('es', 'Español'),
  en('en', 'English'),
  zh('zh', '中文'),
  ru('ru', 'Русский');

  const AppLang(this.code, this.label);

  /// ISO-639-1 code, also what gets persisted.
  final String code;

  /// Name shown in the language picker, always in its own language.
  final String label;

  static AppLang fromCode(String? code) =>
      AppLang.values.firstWhere((l) => l.code == code, orElse: () => AppLang.es);

  /// The first of [locales] (the device's preference order) that the UI
  /// ships, matched on the language code only — `ru_RU`, `zh_Hant_TW` and
  /// `en_GB` all count. Spanish when none of them is supported.
  static AppLang fromLocales(Iterable<Locale> locales) {
    for (final locale in locales) {
      final code = locale.languageCode.toLowerCase();
      for (final lang in AppLang.values) {
        if (lang.code == code) return lang;
      }
    }
    return AppLang.es;
  }
}

/// Runtime language switch.
///
/// Deliberately *not* part of [AppState]: `tr()` is called from services and
/// models that have no `BuildContext` and no provider, so the active language
/// has to be reachable as global state. [notifier] exists only so the widget
/// tree can be remounted when it changes (see `main.dart`).
class L10n {
  L10n._();

  static const _prefsKey = 'app_language';

  /// Stored instead of a language code when the user picked "System".
  static const systemCode = 'system';

  /// Listen to this to rebuild UI after a language change.
  static final ValueNotifier<AppLang> notifier = ValueNotifier(AppLang.es);

  /// True while the language follows the device instead of an explicit
  /// choice. That is the state until the user picks a language in Settings.
  static final ValueNotifier<bool> followsSystem = ValueNotifier(true);

  static AppLang get lang => notifier.value;

  /// The device's languages, in preference order. Overridable for tests.
  @visibleForTesting
  static List<Locale> Function() systemLocales =
      () => PlatformDispatcher.instance.locales;

  /// The language "System" resolves to right now.
  static AppLang get systemLang => AppLang.fromLocales(systemLocales());

  /// Reads the stored language. Call before `runApp` so the first frame is
  /// already in the right language. Nothing stored (first launch, or a user
  /// who never touched the setting) means: follow the device.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);
    final explicit = AppLang.values.any((l) => l.code == stored);
    followsSystem.value = !explicit;
    notifier.value = explicit ? AppLang.fromCode(stored) : systemLang;
  }

  /// An explicit choice: it wins over the device language from now on.
  static Future<void> setLang(AppLang lang) async {
    followsSystem.value = false;
    notifier.value = lang;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, lang.code);
  }

  /// Go back to following the device language.
  static Future<void> useSystem() async {
    followsSystem.value = true;
    notifier.value = systemLang;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, systemCode);
  }

  /// Re-resolve after the device language changed while the app was running.
  /// No-op when the user made an explicit choice.
  static void onSystemLocalesChanged() {
    if (followsSystem.value) notifier.value = systemLang;
  }
}

/// Translates [source] (Spanish, the source language) into the active language.
///
/// The Spanish text doubles as the lookup key, so an untranslated string falls
/// back to Spanish instead of showing a raw identifier.
///
/// [args] fills positional `{0}`, `{1}`… placeholders — use them instead of
/// string interpolation, otherwise the interpolated value ends up baked into
/// the key and the lookup never matches:
///
/// ```dart
/// Text(tr('Conectado a {0}', [host]))
/// ```
String tr(String source, [List<Object?>? args]) {
  var out = source;
  if (L10n.lang != AppLang.es) {
    final table = _tables[L10n.lang];
    final hit = table?[source];
    if (hit != null) {
      out = hit;
    } else {
      assert(() {
        if (!_reported.contains(source)) {
          _reported.add(source);
          debugPrint('[l10n] falta traducción (${L10n.lang.code}): $source');
        }
        return true;
      }());
    }
  }
  if (args != null) {
    for (var i = 0; i < args.length; i++) {
      out = out.replaceAll('{$i}', '${args[i]}');
    }
  }
  return out;
}

const Map<AppLang, Map<String, String>> _tables = {
  AppLang.en: enStrings,
  AppLang.zh: zhStrings,
  AppLang.ru: ruStrings,
};

/// Debug-only, so the same missing key isn't logged on every rebuild.
final Set<String> _reported = {};
