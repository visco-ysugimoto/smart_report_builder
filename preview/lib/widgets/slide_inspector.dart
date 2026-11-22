import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:smart_report_preview/layout_result.dart';
import 'package:smart_report_preview/state/app_scope.dart';
import 'package:smart_report_preview/state/app_state.dart';

/// Step 3 の右ペイン: 選択スライドのタイトルと見解を編集する。
class SlideInspector extends StatefulWidget {
  const SlideInspector({super.key});

  @override
  State<SlideInspector> createState() => _SlideInspectorState();
}

class _SlideInspectorState extends State<SlideInspector> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _finding = TextEditingController();
  Timer? _debounce;
  String? _appliedSlideId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncFromState();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _title.dispose();
    _finding.dispose();
    super.dispose();
  }

  void _syncFromState() {
    final state = AppScope.stateOf(context);
    final slideId = state.selectedSlideId ?? _firstSlideId(state.projectJson);
    if (slideId == _appliedSlideId) return;
    _appliedSlideId = slideId;
    final info = _findSlide(state.projectJson, slideId);
    _title.text = info?.title ?? '';
    _finding.text = info?.caption ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.stateOf(context);
    final service = AppScope.serviceOf(context);
    final slideId = state.selectedSlideId ?? _firstSlideId(state.projectJson);
    if (slideId == null) {
      return Card(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'スライドを選ぶと、ここで編集できます',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'このスライドだけの編集',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              slideId,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            Text('ページタイトル', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            TextField(
              key: const Key('inspector-title'),
              controller: _title,
              onChanged: (_) => _schedule(slideId),
              decoration: const InputDecoration(),
            ),
            const SizedBox(height: 14),
            Text('見解・説明', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            Expanded(
              child: TextField(
                key: const Key('inspector-finding'),
                controller: _finding,
                onChanged: (_) => _schedule(slideId),
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('inspector-add-text'),
              onPressed: state.busy
                  ? null
                  : () => service.addFreeText(slideId: slideId),
              icon: const Icon(Icons.text_fields, size: 16),
              label: const Text('テキストを追加'),
            ),
            if (_selectedNote(state) case final note?) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: Key('inspector-delete-text:${note.elementId}'),
                onPressed: state.busy
                    ? null
                    : () => service.deleteFreeText(textId: note.elementId, slideId: slideId),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('選択中のテキストを削除'),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'タイトルと説明文はこのスライドだけに反映されます。画像の見出しは枠を選んで編集し、追加したテキストは枠の辺で幅を変えられます。',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  void _schedule(String slideId) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), () => _commit(slideId));
  }

  Future<void> _commit(String slideId) async {
    if (!mounted) return;
    final service = AppScope.serviceOf(context);
    await service.editSlide(
      slideId: slideId,
      title: _title.text,
      caption: _finding.text,
    );
  }

  PlacedElement? _selectedNote(AppState state) {
    final id = state.selectedFrameId;
    final elements = state.result?.elements;
    if (id == null || elements == null) return null;
    for (final element in elements) {
      if (element.elementId == id && element.roleId == 'note') return element;
    }
    return null;
  }

  String? _firstSlideId(String? json) {
    if (json == null) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return null;
      final slides = decoded['slides'];
      if (slides is List && slides.isNotEmpty) {
        return '${(slides.first as Map)['id']}';
      }
      return '${(decoded['slide'] as Map?)?['id'] ?? ''}';
    } on FormatException {
      return null;
    }
  }

  _SlideInfo? _findSlide(String? json, String? slideId) {
    if (json == null || slideId == null) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return null;
      final slides = decoded['slides'];
      Map<String, Object?>? slide;
      if (slides is List) {
        for (final raw in slides) {
          if (raw is Map && '${raw['id']}' == slideId) {
            slide = Map<String, Object?>.from(raw['slide'] as Map? ?? const {});
            break;
          }
        }
      } else if (decoded['slide'] is Map) {
        slide = Map<String, Object?>.from(decoded['slide'] as Map);
      }
      if (slide == null) return null;
      final bindings = slide['bindings'];
      String caption = '';
      if (bindings is List) {
        for (final raw in bindings) {
          if (raw is Map && raw['elementId'] == 'text-caption' && raw['text'] is String) {
            caption = raw['text'] as String;
            break;
          }
        }
      }
      return _SlideInfo(
        title: '${slide['title'] ?? ''}',
        caption: caption,
      );
    } on FormatException {
      return null;
    }
  }
}

class _SlideInfo {
  const _SlideInfo({required this.title, required this.caption});

  final String title;
  final String caption;
}
