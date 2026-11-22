import 'package:flutter/material.dart';
import 'package:smart_report_preview/state/app_scope.dart';
import 'package:smart_report_preview/state/app_state.dart';
import 'package:smart_report_preview/theme/app_theme.dart';

/// 画面上部の 3 ステップ進捗バー + タイトル + 右端のアクション。
class StepHeader extends StatelessWidget {
  const StepHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.stateOf(context);
    final service = AppScope.serviceOf(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: AppDims.stepHeaderHeight,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.auto_awesome_mosaic, color: Colors.white, size: 18),
              ),
              const SizedBox(width: 10),
              Text(
                'Smart Report Builder',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
          const SizedBox(width: 32),
          Expanded(child: _StepIndicator(step: state.step)),
          const SizedBox(width: 16),
          if (state.hasOpenProject) ...[
            if (state.step != WorkflowStep.start)
              OutlinedButton.icon(
                key: const Key('header-close-project'),
                onPressed: state.busy
                    ? null
                    : () {
                        state.closeProject();
                      },
                icon: const Icon(Icons.close, size: 16),
                label: const Text('閉じる'),
              ),
            const SizedBox(width: 8),
            FilledButton.icon(
              key: const Key('header-save'),
              onPressed: state.busy ? null : () => service.save(),
              icon: const Icon(Icons.save, size: 16),
              label: const Text('保存'),
            ),
          ],
        ],
      ),
    );
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.step});

  final WorkflowStep step;

  @override
  Widget build(BuildContext context) {
    final steps = const [
      (WorkflowStep.start, '1', '開始・ソース登録'),
      (WorkflowStep.master, '2', '1枚目を型として編集'),
      (WorkflowStep.expand, '3', '展開して個別調整'),
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          _StepDot(
            number: steps[i].$2,
            label: steps[i].$3,
            active: steps[i].$1 == step,
            completed: _isCompleted(step, steps[i].$1),
          ),
          if (i < steps.length - 1)
            Container(
              width: 36,
              height: 1,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
        ],
      ],
    );
  }

  bool _isCompleted(WorkflowStep current, WorkflowStep candidate) {
    const order = {
      WorkflowStep.start: 0,
      WorkflowStep.master: 1,
      WorkflowStep.expand: 2,
    };
    return order[current]! > order[candidate]!;
  }
}

class _StepDot extends StatelessWidget {
  const _StepDot({
    required this.number,
    required this.label,
    required this.active,
    required this.completed,
  });

  final String number;
  final String label;
  final bool active;
  final bool completed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = active
        ? scheme.primary
        : completed
            ? scheme.primaryContainer
            : Colors.white;
    final border = active || completed ? scheme.primary : scheme.outlineVariant;
    final numberColor = active
        ? Colors.white
        : completed
            ? scheme.primary
            : scheme.onSurfaceVariant;
    return Row(
      children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: fill,
            shape: BoxShape.circle,
            border: Border.all(color: border, width: 1.5),
          ),
          alignment: Alignment.center,
          child: completed && !active
              ? Icon(Icons.check, size: 14, color: numberColor)
              : Text(
                  number,
                  style: TextStyle(
                    color: numberColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            color: active ? scheme.primary : scheme.onSurfaceVariant,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}
