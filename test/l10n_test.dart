import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:terminal_agent/l10n/l10n.dart';
import 'package:terminal_agent/l10n/strings_en.dart';
import 'package:terminal_agent/l10n/strings_ru.dart';
import 'package:terminal_agent/l10n/strings_zh.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    L10n.notifier.value = AppLang.es;
  });

  group('tr', () {
    test('Spanish is the source language, so it never looks anything up', () {
      expect(tr('Conectar'), 'Conectar');
      expect(tr('No existe en ningún diccionario'),
          'No existe en ningún diccionario');
    });

    test('translates through the English table', () async {
      await L10n.setLang(AppLang.en);
      expect(tr('Conectar'), 'Connect');
      expect(tr('Cancelar'), 'Cancel');
    });

    test('an untranslated key falls back to the Spanish text', () async {
      await L10n.setLang(AppLang.en);
      expect(tr('Una cadena que nadie tradujo'), 'Una cadena que nadie tradujo');
    });

    test('fills positional placeholders in both languages', () async {
      expect(tr('{0} activos', [3]), '3 activos');
      await L10n.setLang(AppLang.en);
      expect(tr('{0} activos', [3]), '3 running');
      expect(tr('No se pudo abrir el túnel {0}: {1}', ['-L 80', 'boom']),
          'Could not open tunnel -L 80: boom');
    });

    test('placeholders are filled even when the key is untranslated', () async {
      await L10n.setLang(AppLang.en);
      expect(tr('Sin traducir {0}', ['x']), 'Sin traducir x');
    });
  });

  // Every table mirrors the Spanish key set, so the same invariants have to
  // hold for each one — a third language must not be able to regress quietly.
  const tables = <String, Map<String, String>>{
    'strings_en.dart': enStrings,
    'strings_zh.dart': zhStrings,
    'strings_ru.dart': ruStrings,
  };

  tables.forEach((name, table) {
    group(name, () {
      test('keeps every placeholder of the Spanish key', () {
        final placeholder = RegExp(r'\{\d+\}');
        final broken = <String>[];
        table.forEach((es, translated) {
          final a = placeholder.allMatches(es).map((m) => m[0]!).toSet();
          final b =
              placeholder.allMatches(translated).map((m) => m[0]!).toSet();
          if (a.length != b.length || !a.containsAll(b)) broken.add(es);
        });
        expect(broken, isEmpty,
            reason: 'la traducción perdió o inventó un placeholder');
      });

      test('has no empty translations', () {
        expect(
            table.entries
                .where((e) => e.value.trim().isEmpty)
                .map((e) => e.key),
            isEmpty);
      });

      test('covers exactly the same keys as every other table', () {
        for (final other in tables.entries) {
          expect(table.keys.toSet(), other.value.keys.toSet(),
              reason: '$name y ${other.key} no cubren las mismas claves');
        }
      });
    });
  });

  test('AppLang round-trips through its stored code', () {
    for (final lang in AppLang.values) {
      expect(AppLang.fromCode(lang.code), lang);
    }
    expect(AppLang.fromCode(null), AppLang.es);
    expect(AppLang.fromCode('klingon'), AppLang.es);
  });

  group('device language', () {
    tearDown(() {
      L10n.systemLocales = () => const [Locale('es')];
      L10n.followsSystem.value = true;
    });

    test('matches on the language code, in preference order', () {
      expect(AppLang.fromLocales(const [Locale('ru', 'RU')]), AppLang.ru);
      expect(AppLang.fromLocales(const [Locale('en', 'GB')]), AppLang.en);
      expect(
          AppLang.fromLocales(const [
            Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')
          ]),
          AppLang.zh);
      expect(AppLang.fromLocales(const [Locale('de'), Locale('ru')]),
          AppLang.ru);
    });

    test('falls back to Spanish when nothing is supported', () {
      expect(AppLang.fromLocales(const [Locale('de'), Locale('fr')]),
          AppLang.es);
      expect(AppLang.fromLocales(const []), AppLang.es);
    });

    test('first launch follows the device', () async {
      L10n.systemLocales = () => const [Locale('ru', 'RU')];
      await L10n.load();
      expect(L10n.lang, AppLang.ru);
      expect(L10n.followsSystem.value, isTrue);
    });

    test('an unsupported device language keeps the Spanish default', () async {
      L10n.systemLocales = () => const [Locale('de', 'DE')];
      await L10n.load();
      expect(L10n.lang, AppLang.es);
    });

    test('an explicit choice wins over the device language', () async {
      SharedPreferences.setMockInitialValues({'app_language': 'en'});
      L10n.systemLocales = () => const [Locale('ru')];
      await L10n.load();
      expect(L10n.lang, AppLang.en);
      expect(L10n.followsSystem.value, isFalse);
      L10n.onSystemLocalesChanged();
      expect(L10n.lang, AppLang.en);
    });

    test('"System" is persisted and tracks device changes', () async {
      L10n.systemLocales = () => const [Locale('zh')];
      await L10n.setLang(AppLang.en);
      await L10n.useSystem();
      expect(L10n.lang, AppLang.zh);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_language'), L10n.systemCode);

      L10n.systemLocales = () => const [Locale('ru')];
      L10n.onSystemLocalesChanged();
      expect(L10n.lang, AppLang.ru);

      L10n.systemLocales = () => const [Locale('en')];
      await L10n.load();
      expect(L10n.lang, AppLang.en);
      expect(L10n.followsSystem.value, isTrue);
    });
  });
}
