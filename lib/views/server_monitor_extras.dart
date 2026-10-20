import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/server_controller.dart';
import '../services/server_metrics.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive_sheet.dart';
import '../widgets/swiss.dart';

/// Extra monitor content under the CPU/RAM/disk gauges: swap, inodes,
/// network, uptime, top processes, listening ports, and entry points to the
/// journal, network checks and threshold alerts.
class MonitorExtras extends StatelessWidget {
  final ServerController server;
  const MonitorExtras({super.key, required this.server});

  @override
  Widget build(BuildContext context) {
    final e = server.extended;
    String pct(double? v) => v == null ? '—' : '${(v * 100).toStringAsFixed(0)}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Stat(tr('SWAP'), pct(e?.swapPercent), e?.swapText ?? '—',
                warn: (e?.swapPercent ?? 0) > 0.8),
            _Stat(tr('INODOS'), pct(e?.inodePercent), e?.inodeText ?? '—',
                warn: (e?.inodePercent ?? 0) > 0.9),
            _Stat(tr('RED ↓'), formatBytesRate(e?.rxRate), tr('recepción')),
            _Stat(tr('RED ↑'), formatBytesRate(e?.txRate), tr('envío')),
            _Stat(tr('ACTIVO'), formatUptime(e?.uptimeSeconds),
                tr('{0} núcleos', [e?.cores ?? '—'])),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _IntervalPicker(server: server),
            GhostButton(
                label: tr('Journal'),
                icon: Icons.receipt_long_outlined,
                dense: true,
                onPressed: () => _open(context, _JournalSheet(server: server))),
            GhostButton(
                label: tr('Red'),
                icon: Icons.network_check,
                dense: true,
                onPressed: () =>
                    _open(context, _NetCheckSheet(server: server))),
            GhostButton(
                label: tr('Umbrales'),
                icon: Icons.notifications_active_outlined,
                dense: true,
                onPressed: () =>
                    _open(context, _ThresholdSheet(server: server))),
          ],
        ),
        if (e != null && e.processes.isNotEmpty) ...[
          const SizedBox(height: 14),
          SwissPanel(
            title: tr('PROCESOS (POR CPU)'),
            margin: EdgeInsets.zero,
            children: [
              for (final p in e.processes)
                _MonoLine(
                    '${p.pid.padLeft(6)} ${p.cpu.padLeft(5)}% ${p.mem.padLeft(5)}%  ${p.user.padRight(9)} ${p.command}'),
            ],
          ),
        ],
        if (e != null) ...[
          const SizedBox(height: 14),
          SwissPanel(
            title: tr('PUERTOS EN ESCUCHA'),
            margin: EdgeInsets.zero,
            children: [
              if (!e.portsAvailable)
                _MonoLine(tr('ss/netstat no está disponible en este servidor.'))
              else if (e.ports.isEmpty)
                _MonoLine(tr('Ninguno visible (puede requerir sudo para ver procesos).'))
              else
                for (final p in e.ports)
                  _MonoLine(
                      '${p.proto.padRight(5)} ${p.address.padRight(24)} ${p.process}'),
            ],
          ),
        ],
      ],
    );
  }

  static void _open(BuildContext context, Widget sheet) => showAdaptiveSheet(
        context,
        backgroundColor: AppColors.panel,
        isScrollControlled: true,
        maxWidth: 640,
        builder: (_) => sheet,
      );
}

class _Stat extends StatelessWidget {
  final String label, value, detail;
  final bool warn;
  const _Stat(this.label, this.value, this.detail, {this.warn = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 104,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: warn ? AppColors.danger : AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.label(8, color: AppColors.muted)),
          const SizedBox(height: 4),
          Text(value,
              style: AppText.mono(13,
                  color: warn ? AppColors.danger : AppColors.bone,
                  weight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(detail,
              style: AppText.mono(8, color: AppColors.faint),
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

class _MonoLine extends StatelessWidget {
  final String text;
  const _MonoLine(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: SelectableText(text,
            maxLines: 1, style: AppText.mono(9.5, color: AppColors.bone)),
      );
}

class _IntervalPicker extends StatelessWidget {
  final ServerController server;
  const _IntervalPicker({required this.server});
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.timer_outlined, size: 14, color: AppColors.muted),
        const SizedBox(width: 6),
        DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            value: ServerController.monitorIntervalChoices
                    .contains(server.monitorIntervalSeconds)
                ? server.monitorIntervalSeconds
                : 30,
            dropdownColor: AppColors.panel,
            style: AppText.mono(10, color: AppColors.bone),
            items: [
              for (final v in ServerController.monitorIntervalChoices)
                DropdownMenuItem(
                    value: v,
                    child: Text(v == 0
                        ? tr('Manual')
                        : v >= 60
                            ? tr('Cada {0} min', [v ~/ 60])
                            : tr('Cada {0} s', [v]))),
            ],
            onChanged: (v) {
              if (v != null) server.setMonitorInterval(v);
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _JournalSheet extends StatefulWidget {
  final ServerController server;
  const _JournalSheet({required this.server});
  @override
  State<_JournalSheet> createState() => _JournalSheetState();
}

class _JournalSheetState extends State<_JournalSheet> {
  final _unit = TextEditingController();
  bool _errorsOnly = true;
  bool _loading = false;
  String _out = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _unit.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final unit = _unit.text.trim();
    final out = await widget.server
        .fetchJournal(unit: unit.isEmpty ? null : unit, errorsOnly: _errorsOnly);
    if (!mounted) return;
    setState(() {
      _out = out;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text(tr('JOURNAL DEL SISTEMA'),
                style: AppText.label(10, color: AppColors.bone, spacing: 1.2)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _unit,
                    autocorrect: false,
                    decoration: InputDecoration(
                        labelText: tr('UNIDAD (OPCIONAL)'),
                        hintText: 'nginx.service'),
                    onSubmitted: (_) => _load(),
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: Text(tr('Sólo errores'),
                      style: AppText.mono(9, color: AppColors.bone)),
                  selected: _errorsOnly,
                  onSelected: (v) {
                    setState(() => _errorsOnly = v);
                    _load();
                  },
                ),
                IconButton(
                    icon: const Icon(Icons.refresh, size: 16),
                    color: AppColors.bone,
                    onPressed: _loading ? null : _load),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              color: AppColors.ink,
              padding: const EdgeInsets.all(12),
              child: _loading
                  ? const Center(
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 1.5)))
                  : SingleChildScrollView(
                      child: SelectableText(_out,
                          style: AppText.mono(9.5, color: AppColors.bone))),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _NetCheckSheet extends StatefulWidget {
  final ServerController server;
  const _NetCheckSheet({required this.server});
  @override
  State<_NetCheckSheet> createState() => _NetCheckSheetState();
}

class _NetCheckSheetState extends State<_NetCheckSheet> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '443');
  NetCheckKind _kind = NetCheckKind.dns;
  bool _running = false;
  String? _result;
  bool _ok = false;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (!isSafeHost(host)) {
      setState(() {
        _ok = false;
        _result = tr('Nombre de host o IP no válido.');
      });
      return;
    }
    if (_kind != NetCheckKind.dns && !isValidPort(port)) {
      setState(() {
        _ok = false;
        _result = tr('El puerto debe estar entre 1 y 65535.');
      });
      return;
    }
    setState(() {
      _running = true;
      _result = null;
    });
    final r = await widget.server.netCheck(_kind, host, port: port);
    if (!mounted) return;
    setState(() {
      _running = false;
      _ok = r?.ok ?? false;
      _result = _describe(r, host, port);
    });
  }

  String _describe(NetCheckResult? r, String host, int? port) {
    if (r == null) return tr('Nombre de host o IP no válido.');
    if (r.toolMissing) {
      return switch (_kind) {
        NetCheckKind.dns =>
          tr('No hay getent, dig ni nslookup en el servidor.'),
        NetCheckKind.tcp => tr('No hay nc ni bash+timeout en el servidor.'),
        NetCheckKind.tls => tr('openssl no está instalado en el servidor.'),
      };
    }
    switch (_kind) {
      case NetCheckKind.dns:
        return r.ok
            ? tr('{0} resuelve a:\n{1}', [host, r.lines.join('\n')])
            : tr('{0} no resuelve desde el servidor.', [host]);
      case NetCheckKind.tcp:
        return r.ok
            ? tr('{0}:{1} acepta conexiones TCP.', [host, port])
            : tr('{0}:{1} no responde (cerrado o filtrado).', [host, port]);
      case NetCheckKind.tls:
        if (!r.ok) {
          return tr('No se pudo obtener el certificado TLS de {0}:{1}.',
              [host, port]);
        }
        final days = r.daysLeft(DateTime.now().toUtc()) ?? 0;
        final head = days < 0
            ? tr('CERTIFICADO CADUCADO hace {0} días.', [-days])
            : tr('El certificado caduca en {0} días.', [days]);
        return '$head\n${r.lines.join('\n')}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('COMPROBACIONES DE RED'),
                style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
            const SizedBox(height: 6),
            Text(tr('Se ejecutan desde el servidor, con las herramientas que tenga instaladas.'),
                style: AppText.body(11, color: AppColors.muted)),
            const SizedBox(height: 12),
            SegmentedButton<NetCheckKind>(
              segments: [
                ButtonSegment(value: NetCheckKind.dns, label: Text(tr('DNS'))),
                ButtonSegment(
                    value: NetCheckKind.tcp, label: Text(tr('PUERTO TCP'))),
                ButtonSegment(
                    value: NetCheckKind.tls, label: Text(tr('CERTIFICADO TLS'))),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() {
                _kind = s.first;
                _result = null;
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _host,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(labelText: tr('HOST / IP')),
            ),
            if (_kind != NetCheckKind.dns) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: tr('PUERTO')),
              ),
            ],
            const SizedBox(height: 12),
            InvertedButton(
                label: tr('Comprobar'),
                icon: Icons.play_arrow,
                expand: true,
                onPressed: _running ? null : _run),
            if (_running) ...[
              const SizedBox(height: 12),
              const Center(
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 1.5))),
            ],
            if (_result != null) ...[
              const SizedBox(height: 12),
              SelectableText(_result!,
                  style: AppText.mono(10,
                      color: _ok ? AppColors.accent : AppColors.danger)),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _ThresholdSheet extends StatefulWidget {
  final ServerController server;
  const _ThresholdSheet({required this.server});
  @override
  State<_ThresholdSheet> createState() => _ThresholdSheetState();
}

class _ThresholdSheetState extends State<_ThresholdSheet> {
  late Thresholds _t = widget.server.thresholds;

  void _set(Thresholds t) {
    setState(() => _t = t);
    widget.server.setThresholds(t);
  }

  Widget _slider(String label, int value, ValueChanged<int> onChanged) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Row(
        children: [
          SizedBox(
              width: 64,
              child: Text(label,
                  style: AppText.label(9, color: AppColors.muted))),
          Expanded(
            child: Slider(
              value: value.toDouble(),
              min: 50,
              max: 100,
              divisions: 10,
              label: '$value%',
              onChanged: _t.enabled ? (v) => onChanged(v.round()) : null,
            ),
          ),
          SizedBox(
              width: 40,
              child: Text('$value%',
                  style: AppText.mono(10, color: AppColors.bone))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('ALERTAS POR UMBRAL'),
                style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
            const SizedBox(height: 10),
            ToggleRow(
              label: tr('AVISAR AL SUPERAR UN UMBRAL'),
              description: tr('Una notificación cuando una métrica cruza su límite; vuelve a avisar sólo después de bajar 5 puntos. Funciona mientras esta pantalla se actualiza.'),
              value: _t.enabled,
              onChanged: (v) => _set(_t.copyWith(enabled: v)),
            ),
            Hairline(),
            _slider(tr('CPU'), _t.cpuPercent, (v) => _set(_t.copyWith(cpu: v))),
            _slider(tr('RAM'), _t.ramPercent, (v) => _set(_t.copyWith(ram: v))),
            _slider(
                tr('DISCO'), _t.diskPercent, (v) => _set(_t.copyWith(disk: v))),
            _slider(
                tr('SWAP'), _t.swapPercent, (v) => _set(_t.copyWith(swap: v))),
            const SizedBox(height: 6),
            Text(tr('CPU = carga media de 1 minuto dividida entre los núcleos. El límite de disco se aplica también a los inodos.'),
                style: AppText.body(10.5, color: AppColors.faint)),
          ],
        ),
      ),
    );
  }
}
