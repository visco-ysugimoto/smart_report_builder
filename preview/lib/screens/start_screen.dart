import 'dart:io';

import 'package:flutter/material.dart';
import 'package:smart_report_preview/roi_persist.dart' show pickFolder, pickPreviewFile;
import 'package:smart_report_preview/state/app_scope.dart';
import 'package:smart_report_preview/theme/app_theme.dart';

/// Step 1: 新規プロジェクトを作るか、既存を開くかの入り口。
class StartScreen extends StatefulWidget {
  const StartScreen({super.key});

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  String _paper = 'landscape';
  String _preset = 'horizontal-2';
  bool _choosing = false;

  Future<void> _runOnce(Future<void> Function() action) async {
    if (_choosing) return;
    setState(() => _choosing = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.stateOf(context);
    final service = AppScope.serviceOf(context);
    final busy = state.busy || _choosing;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: Padding(
          padding: const EdgeInsets.all(AppDims.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              Text(
                'レポートを素早く作る',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 6),
              Text(
                '1 枚目を型として完成させれば、画像一覧から後続のスライドを自動で展開します。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _NewProjectCard(
                        paper: _paper,
                        preset: _preset,
                        busy: busy,
                        onPaperChanged: (value) => setState(() => _paper = value),
                        onPresetChanged: (value) => setState(() => _preset = value),
                        onCreate: () => _runOnce(() async {
                          final path = await pickFolder();
                          if (path == null || !mounted) return;
                          final projectFile = File('$path${Platform.pathSeparator}project.json');
                          if (await projectFile.exists()) {
                            if (!context.mounted) return;
                            final choice = await _askExistingProject(context);
                            if (!mounted || choice == null) return;
                            if (choice == 'open') {
                              await service.openProject(projectFile.path);
                              return;
                            }
                            await service.createProject(
                              directory: path,
                              paper: _paper,
                              preset: _preset,
                              replace: true,
                            );
                            return;
                          }
                          await service.createProject(
                            directory: path,
                            paper: _paper,
                            preset: _preset,
                          );
                        }),
                      ),
                    ),
                    const SizedBox(width: AppDims.gutter),
                    Expanded(
                      child: _OpenProjectCard(
                        busy: busy,
                        onOpen: () => _runOnce(() async {
                          final file = await pickPreviewFile();
                          if (file == null || !mounted) return;
                          final target = file.toLowerCase().endsWith('.json') ? file : _asProjectJson(file);
                          await service.openProject(target);
                        }),
                      ),
                    ),
                  ],
                ),
              ),
              if (state.errorMessage != null) ...[
                const SizedBox(height: 12),
                _ErrorBanner(message: state.errorMessage!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _askExistingProject(BuildContext context) {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('このフォルダにはプロジェクトがあります'),
          content: const Text(
            '既存のプロジェクトを開くか、project.json と report.pptx を置き換えて新しく作ります。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('キャンセル'),
            ),
            TextButton(
              key: const Key('start-open-existing'),
              onPressed: () => Navigator.of(dialogContext).pop('open'),
              child: const Text('既存を開く'),
            ),
            FilledButton(
              key: const Key('start-replace-existing'),
              onPressed: () => Navigator.of(dialogContext).pop('replace'),
              child: const Text('新しく作り直す'),
            ),
          ],
        );
      },
    );
  }

  String _asProjectJson(String pptx) {
    // PPTX を選んだときは隣の project.json を推定する。
    final directory = File(pptx).parent.path;
    return '$directory${Platform.pathSeparator}project.json';
  }
}

class _NewProjectCard extends StatelessWidget {
  const _NewProjectCard({
    required this.paper,
    required this.preset,
    required this.busy,
    required this.onPaperChanged,
    required this.onPresetChanged,
    required this.onCreate,
  });

  final String paper;
  final String preset;
  final bool busy;
  final ValueChanged<String> onPaperChanged;
  final ValueChanged<String> onPresetChanged;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.add_circle_outline),
                const SizedBox(width: 8),
                Text(
                  '新規プロジェクト',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('用紙', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ChoiceChip(
                  label: '16:9 (ブランク)',
                  selected: paper == '16x9',
                  onSelected: () => onPaperChanged('16x9'),
                ),
                _ChoiceChip(
                  label: '評価レポート 横',
                  selected: paper == 'landscape',
                  onSelected: () => onPaperChanged('landscape'),
                ),
                _ChoiceChip(
                  label: '評価レポート 縦',
                  selected: paper == 'portrait',
                  onSelected: () => onPaperChanged('portrait'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text('1 枚目の型', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ChoiceChip(
                  label: '横 2 枚',
                  selected: preset == 'horizontal-2',
                  onSelected: () => onPresetChanged('horizontal-2'),
                ),
                _ChoiceChip(
                  label: '横 3 枚',
                  selected: preset == 'horizontal-3',
                  onSelected: () => onPresetChanged('horizontal-3'),
                ),
                _ChoiceChip(
                  label: '2×2 グリッド',
                  selected: preset == 'grid-2x2',
                  onSelected: () => onPresetChanged('grid-2x2'),
                ),
                _ChoiceChip(
                  label: '画像 + 拡大',
                  selected: preset == 'overall-zoom',
                  onSelected: () => onPresetChanged('overall-zoom'),
                ),
              ],
            ),
            const Spacer(),
            Row(
              children: [
                const Icon(Icons.folder_outlined, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '保存先フォルダを選び、プロジェクトを作成します',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('start-create'),
              onPressed: busy ? null : onCreate,
              icon: const Icon(Icons.rocket_launch, size: 18),
              label: const Text('フォルダを選んで作成'),
            ),
          ],
        ),
      ),
    );
  }
}

class _OpenProjectCard extends StatelessWidget {
  const _OpenProjectCard({required this.busy, required this.onOpen});

  final bool busy;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.folder_open_outlined),
                const SizedBox(width: 8),
                Text(
                  '既存を開く',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'project.json を選ぶと、同じフォルダの layout.json と report.pptx を使って続きから始められます。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const Spacer(),
            FilledButton.icon(
              key: const Key('start-open'),
              onPressed: busy ? null : onOpen,
              icon: const Icon(Icons.file_open_outlined, size: 18),
              label: const Text('プロジェクトを開く'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({required this.label, required this.selected, required this.onSelected});

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.error),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              key: const Key('start-error'),
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
