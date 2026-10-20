import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/services/file_perms.dart';
import 'package:terminal_agent/theme/app_theme.dart';

void main() {
  test('formatMode', () {
    expect(formatMode(0x1ED), 'rwxr-xr-x'); // 0755
    expect(formatMode(0x1A4), 'rw-r--r--'); // 0644
    expect(formatMode(0x9ED), 'rwsr-xr-x'); // 4755
    expect(formatMode(0x3FF), 'rwxrwxrwt'); // 1777
  });
  test('octal round trip', () {
    expect(formatOctal(0x1ED), '755');
    expect(parseOctalMode('0644'), 0x1A4);
    expect(parseOctalMode('4755'), 0x9ED);
    expect(parseOctalMode('9a'), isNull);
    expect(parseOctalMode('77777'), isNull);
  });
  test('owner from longname', () {
    expect(ownerFromLongname('-rw-r--r--    1 root     wheel  12 Jan  1 00:00 a'),
        ('root', 'wheel'));
    expect(ownerFromLongname('garbage', uid: 0, gid: 10), ('0', '10'));
    expect(ownerFromLongname(''), isNull);
  });
  test('custom palette encode/decode', () {
    final pal = AppTerminalTheme.paletteOf(AppTerminalTheme.monokai);
    final hex = AppTerminalTheme.encodePalette(pal);
    expect(hex.first, '#F8F8F2');
    final back = AppTerminalTheme.decodePalette(hex)!;
    expect(AppTerminalTheme.encodePalette(back), hex);
    expect(AppTerminalTheme.decodePalette(['#zzz']), isNull);
    expect(AppTerminalTheme.fromPalette(back).background, pal[1]);
    expect(AppTerminalTheme.schemes.containsKey('monokai'), isTrue);
  });
}
