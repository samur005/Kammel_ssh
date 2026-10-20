import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A settings row with a dropdown on the right — the multi-value sibling of
/// `ToggleRow`.
class ChoiceRow<T> extends StatelessWidget {
  final String label;
  final String description;
  final List<T> values;
  final T value;
  final String Function(T) labelFor;
  final ValueChanged<T> onChanged;

  const ChoiceRow({
    super.key,
    required this.label,
    required this.description,
    required this.values,
    required this.value,
    required this.labelFor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final items = values.contains(value) ? values : [value, ...values];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppText.label(9, color: AppColors.muted)),
                const SizedBox(height: 5),
                Text(description,
                    style: AppText.label(8.5,
                        color: AppColors.faint, spacing: 0.3)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              dropdownColor: AppColors.panel,
              style: AppText.mono(11, color: AppColors.bone),
              items: [
                for (final v in items)
                  DropdownMenuItem(value: v, child: Text(labelFor(v))),
              ],
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}
