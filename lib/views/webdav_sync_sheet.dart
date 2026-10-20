import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/format.dart';
import '../l10n/l10n.dart';
import '../providers/app_state.dart';
import '../services/backup_crypto.dart';
import '../services/backup_service.dart';
import '../services/webdav_sync.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive_sheet.dart';
import '../widgets/swiss.dart';

/// Settings and "sync now" for the encrypted WebDAV sync.
void showWebDavSyncSheet(BuildContext context) {
  showAdaptiveSheet(
    context,
    backgroundColor: AppColors.panel,
    isScrollControlled: true,
    maxWidth: 560,
    builder: (_) => const _WebDavSyncSheet(),
  );
}

class _WebDavSyncSheet extends StatefulWidget {
  const _WebDavSyncSheet();

  @override
  State<_WebDavSyncSheet> createState() => _WebDavSyncSheetState();
}

class _WebDavSyncSheetState extends State<_WebDavSyncSheet> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _syncPass = TextEditingController();
  bool _includeSecrets = false;
  bool _configured = false;
  bool _busy = false;
  String? _message;
  bool _error = false;
  SyncState _state = const SyncState();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await WebDavSettings.load();
    final st = await WebDavSettings.loadState();
    if (!mounted) return;
    setState(() {
      _url.text = s.url;
      _user.text = s.username;
      _includeSecrets = s.includeSecrets;
      _configured = s.configured;
      _state = st;
    });
  }

  @override
  void dispose() {
    for (final c in [_url, _user, _pass, _syncPass]) {
      c.dispose();
    }
    super.dispose();
  }

  void _say(String msg, {bool error = false}) => setState(() {
        _message = msg;
        _error = error;
        _busy = false;
      });

  Future<bool> _save() async {
    final v = WebDavSettings.validateUrl(_url.text);
    if (v == 'invalid') {
      _say(tr('La URL de WebDAV no es válida.'), error: true);
      return false;
    }
    if (v == 'insecure') {
      _say(tr('Usa https://. Sólo se permite http:// en la red local.'),
          error: true);
      return false;
    }
    final hasSyncPw = _syncPass.text.isNotEmpty ||
        (await WebDavSettings.syncPassword())?.isNotEmpty == true;
    if (!hasSyncPw) {
      _say(tr('Elige una contraseña de cifrado para la sincronización.'),
          error: true);
      return false;
    }
    await WebDavSettings(
      url: _url.text.trim(),
      username: _user.text.trim(),
      includeSecrets: _includeSecrets,
    ).save(
      password: _pass.text.isEmpty ? null : _pass.text,
      syncPassword: _syncPass.text.isEmpty ? null : _syncPass.text,
    );
    _pass.clear();
    _syncPass.clear();
    setState(() => _configured = true);
    return true;
  }

  Future<SyncConflictChoice?> _askConflict() {
    return showDialog<SyncConflictChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(tr('CONFLICTO DE SINCRONIZACIÓN'),
            style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
        content: Text(
            tr('Este dispositivo y la nube cambiaron desde la última sincronización. ¿Qué versión quieres conservar?'),
            style: AppText.body(12, color: AppColors.muted)),
        actions: [
          GhostButton(
              label: tr('Cancelar'),
              dense: true,
              onPressed: () => Navigator.of(ctx).pop()),
          GhostButton(
              label: tr('Ambas'),
              dense: true,
              onPressed: () =>
                  Navigator.of(ctx).pop(SyncConflictChoice.keepBoth)),
          GhostButton(
              label: tr('La de la nube'),
              dense: true,
              onPressed: () =>
                  Navigator.of(ctx).pop(SyncConflictChoice.keepCloud)),
          InvertedButton(
              label: tr('La de este dispositivo'),
              dense: true,
              onPressed: () =>
                  Navigator.of(ctx).pop(SyncConflictChoice.keepLocal)),
        ],
      ),
    );
  }

  Future<void> _syncNow() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    if (!await _save()) return;
    final settings = await WebDavSettings.load();
    final pw = await WebDavSettings.password() ?? '';
    final syncPw = await WebDavSettings.syncPassword() ?? '';
    if (!mounted) return;
    final appState = context.read<AppState>();
    final engine = WebDavSyncEngine(
      dav: WebDavClient(
          folder: Uri.parse(settings.url),
          username: settings.username,
          password: pw),
      syncPassword: syncPw,
      buildLocal: () =>
          BackupService.build(includeSecrets: settings.includeSecrets),
      applyRemote: (envelope) async {
        final r = await BackupService.restore(envelope);
        if (r.error != null) throw Exception(r.error);
        await appState.reloadFromDisk();
      },
      resolveConflict: _askConflict,
      loadState: WebDavSettings.loadState,
      saveState: WebDavSettings.saveState,
    );
    try {
      final outcome = await engine.sync();
      final st = await WebDavSettings.loadState();
      if (!mounted) return;
      _state = st;
      _say(switch (outcome) {
        SyncOutcome.upToDate => tr('Todo está sincronizado.'),
        SyncOutcome.uploaded => tr('Cambios subidos a la nube.'),
        SyncOutcome.downloaded => tr('Cambios descargados de la nube.'),
        SyncOutcome.keptLocal => tr('Se conservó la versión de este dispositivo.'),
        SyncOutcome.keptCloud => tr('Se conservó la versión de la nube.'),
        SyncOutcome.keptBoth => tr('Se aplicó la versión de la nube y la de este dispositivo se guardó como copia en conflicto.'),
        SyncOutcome.cancelled => tr('Sincronización cancelada.'),
      });
    } on WebDavError catch (e) {
      _say(
          e.isAuth
              ? tr('Usuario o contraseña de WebDAV incorrectos.')
              : tr('El servidor WebDAV respondió HTTP {0}.', [e.status]),
          error: true);
    } on BackupCryptoError catch (e) {
      _say(BackupService.describeCryptoError(e), error: true);
    } catch (e) {
      _say(tr('No se pudo contactar con el servidor WebDAV: {0}', [e]),
          error: true);
    }
  }

  Future<void> _forget() async {
    await WebDavSettings.forget();
    _url.clear();
    _user.clear();
    setState(() {
      _configured = false;
      _state = const SyncState();
    });
    _say(tr('Configuración de WebDAV eliminada de este dispositivo.'));
  }

  @override
  Widget build(BuildContext context) {
    final last = _state.lastSync;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('SINCRONIZACIÓN WEBDAV'),
                style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
            const SizedBox(height: 10),
            Text(
                tr('Sincroniza la copia de seguridad cifrada con tu servidor WebDAV (Nextcloud, Yandex Disk, Synology…). El servidor sólo ve un archivo cifrado.'),
                style: AppText.body(12, color: AppColors.muted)),
            const SizedBox(height: 14),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                  labelText: tr('URL DE LA CARPETA WEBDAV'),
                  hintText: 'https://cloud.example.com/remote.php/dav/files/me/absssh/'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _user,
              autocorrect: false,
              decoration: InputDecoration(labelText: tr('USUARIO')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _pass,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                  labelText: _configured
                      ? tr('CONTRASEÑA WEBDAV (VACÍO = NO CAMBIAR)')
                      : tr('CONTRASEÑA WEBDAV')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _syncPass,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                  labelText: _configured
                      ? tr('CONTRASEÑA DE CIFRADO (VACÍO = NO CAMBIAR)')
                      : tr('CONTRASEÑA DE CIFRADO')),
            ),
            const SizedBox(height: 6),
            Text(
                tr('Usa la misma contraseña de cifrado en todos tus dispositivos. Si la pierdes, los datos de la nube no se pueden recuperar.'),
                style: AppText.body(11, color: AppColors.faint)),
            Hairline(),
            ToggleRow(
              label: tr('INCLUIR CONTRASEÑAS Y LLAVES'),
              description:
                  tr('Las credenciales viajan dentro de la copia cifrada.'),
              value: _includeSecrets,
              onChanged: (v) => setState(() => _includeSecrets = v),
            ),
            Hairline(),
            const SizedBox(height: 10),
            Text(
                last == null
                    ? tr('Nunca sincronizado')
                    : tr('Última sincronización: {0}', [relativeTime(last)]),
                style: AppText.mono(10, color: AppColors.muted)),
            const SizedBox(height: 12),
            InvertedButton(
              label: tr('Sincronizar ahora'),
              icon: Icons.sync,
              expand: true,
              onPressed: _busy ? null : _syncNow,
            ),
            if (_configured) ...[
              const SizedBox(height: 10),
              GhostButton(
                label: tr('Olvidar configuración'),
                icon: Icons.link_off,
                danger: true,
                onPressed: _busy ? null : _forget,
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: 14),
              Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: AppColors.muted),
                ),
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 14),
              Text(_message!,
                  style: AppText.mono(10,
                      color: _error ? AppColors.danger : AppColors.accent)),
            ],
          ],
        ),
      ),
    );
  }
}
