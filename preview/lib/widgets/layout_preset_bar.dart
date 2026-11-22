import 'package:flutter/material.dart';
import 'package:smart_report_preview/state/app_scope.dart';

/// 中央上のプリセットチップ。選んだ瞬間に Python へ pick-layout を送る。
class LayoutPresetBar extends StatelessWidget {
  const LayoutPresetBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.stateOf(context);
    final service = AppScope.serviceOf(context);
    final presets = const [
      ('horizontal-2', '横 2 枚', Icons.view_agenda_outlined),
      ('horizontal-3', '横 3 枚', Icons.view_week_outlined),
      ('horizontal-4', '横 4 枚', Icons.view_column_outlined),
      ('vertical-2', '縦 2 枚', Icons.view_stream_outlined),
      ('vertical-3', '縦 3 枚', Icons.vertical_split_outlined),
      ('grid-2x2', '2×2', Icons.grid_view_outlined),
      ('grid-2x3', '2×3', Icons.grid_on_outlined),
      ('grid-3x2', '3×2', Icons.apps_outlined),
      ('grid-3x3', '3×3', Icons.dashboard_outlined),
      ('overall-zoom', '画像 + 拡大', Icons.aspect_ratio_outlined),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Text(
            '枠の並び',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(
              spacing: 6,
              children: [
                for (final preset in presets)
                  ChoiceChip(
                    key: Key('preset:${preset.$1}'),
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(preset.$3, size: 14),
                        const SizedBox(width: 4),
                        Text(preset.$2),
                      ],
                    ),
                    selected: state.currentPreset == preset.$1,
                    onSelected: state.busy
                        ? null
                        : (_) => service.pickLayout(preset: preset.$1),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
