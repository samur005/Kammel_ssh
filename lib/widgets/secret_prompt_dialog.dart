import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import 'swiss.dart';

/// Result of [showSecretPrompt].
typedef SecretPromptResult = ({String value, bool remember});

/// Asks for a password / passphrase. Returns null when cancelled.
///
/// [confirm] adds a second field that must match (for choosing a new
/// password). [rememberLabel] adds an opt-in "remember" checkbox, off by
/// default.
Future<SecretPromptResult?> showSecretPrompt(
  BuildContext context, {
  required String title,
  String? message,
  bool confirm = false,
  String? rememberLabel,
}) {
  return showDialog<SecretPromptResult>(
    context: context,
    builder: (_) => _SecretPrompt(
        title: title,
        message: message,
        confirm: confirm,
        rememberLabel: rememberLabel),
  );
}

class _SecretPrompt extends StatefulWidget {
  final String title;
  final String? message;
  final bool confirm;
  final String? rememberLabel;
  const _SecretPrompt(
      {required this.title,
      this.message,
      required this.confirm,
      this.rememberLabel});

  @override
  State<_SecretPrompt> createState() => _SecretPromptState();
}

class _SecretPromptState extends State<_SecretPrompt> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  bool _remember = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  void _submit() {
    if (_a.text.isEmpty) {
      setState(() => _error = tr('La contraseña no puede estar vacía.'));
      return;
    }
    if (widget.confirm && _a.text != _b.text) {
      setState(() => _error = tr('Las contraseñas no coinciden.'));
      return;
    }
    Navigator.of(context).pop((value: _a.text, remember: _remember));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.panel,
      title: Text(widget.title,
          style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.message != null) ...[
              Text(widget.message!,
                  style: AppText.body(12, color: AppColors.muted)),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _a,
              autofocus: true,
              obscureText: _obscure,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: tr('CONTRASEÑA'),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off,
                      size: 16),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              onSubmitted: (_) => widget.confirm ? null : _submit(),
            ),
            if (widget.confirm) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _b,
                obscureText: _obscure,
                enableSuggestions: false,
                autocorrect: false,
                decoration:
                    InputDecoration(labelText: tr('REPETIR CONTRASEÑA')),
                onSubmitted: (_) => _submit(),
              ),
            ],
            if (widget.rememberLabel != null)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _remember,
                onChanged: (v) => setState(() => _remember = v ?? false),
                title: Text(widget.rememberLabel!,
                    style: AppText.body(12, color: AppColors.muted)),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: AppText.body(11, color: AppColors.danger)),
            ],
          ],
        ),
      ),
      actions: [
        GhostButton(
            label: tr('Cancelar'),
            dense: true,
            onPressed: () => Navigator.of(context).pop()),
        InvertedButton(label: tr('Aceptar'), dense: true, onPressed: _submit),
      ],
    );
  }
}
