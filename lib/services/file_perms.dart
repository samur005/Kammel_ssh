/// Helpers for showing and editing Unix permissions in the SFTP explorer.
library;

/// `0o755` → `rwxr-xr-x` (only the low 9 bits; setuid/sticky shown as s/t).
String formatMode(int mode) {
  const chars = 'rwxrwxrwx';
  final b = StringBuffer();
  for (var i = 0; i < 9; i++) {
    b.write((mode & (1 << (8 - i))) != 0 ? chars[i] : '-');
  }
  var s = b.toString().split('');
  if (mode & 0x800 != 0) s[2] = s[2] == 'x' ? 's' : 'S';
  if (mode & 0x400 != 0) s[5] = s[5] == 'x' ? 's' : 'S';
  if (mode & 0x200 != 0) s[8] = s[8] == 'x' ? 't' : 'T';
  return s.join();
}

/// `0o755` → `755` (or `4755` when special bits are set).
String formatOctal(int mode) {
  final m = mode & 0xFFF;
  return m.toRadixString(8).padLeft(3, '0');
}

/// Parses `755` / `0755` / `4755`. Null when not 3–4 octal digits.
int? parseOctalMode(String text) {
  final t = text.trim();
  if (!RegExp(r'^[0-7]{3,4}$').hasMatch(t)) return null;
  return int.parse(t, radix: 8);
}

/// Owner and group names from an `ls -l` style SFTP longname
/// (`-rw-r--r--    1 root     wheel   1234 Jan  1 00:00 name`).
/// Falls back to the numeric ids when the longname is not in that form.
(String, String)? ownerFromLongname(String longname, {int? uid, int? gid}) {
  final parts = longname.trim().split(RegExp(r'\s+'));
  if (parts.length >= 4 && RegExp(r'^[dlcbps-][rwxsStT-]{9}').hasMatch(parts[0])) {
    return (parts[2], parts[3]);
  }
  if (uid != null && gid != null) return ('$uid', '$gid');
  return null;
}
