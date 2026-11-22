import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:smart_report_preview/state/app_scope.dart';
import 'package:smart_report_preview/state/app_state.dart';

/// 右ペイン: 展開時の差し込みテンプレ（タイトル / 見解）。
///
/// 入力はデバウンスしてから Python へ送るので、タイピングのたびに IPC は走らない。
class _CaptionStyle {
  const _CaptionStyle({
    required this.id,
    required this.shown,
    required this.place,
    required this.fontPt,
  });

  final String id;
  final bool shown;
  final String place;
  final int fontPt;
}

class FindingEditor extends StatefulWidget {
  const FindingEditor({super.key});

  @override
  State<FindingEditor> createState() => _FindingEditorState();
}

class _FindingEditorState extends State<FindingEditor> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _caption = TextEditingController();
  Timer? _debounce;
  AppState? _state;
  String _seenTitle = '';
  String _seenCaption = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.stateOf(context);
    _state = state;
    if (state.titleTemplate != _seenTitle && _title.text == _seenTitle) {
      _title.text = state.titleTemplate;
    }
    if (state.captionTemplate != _seenCaption && _caption.text == _seenCaption) {
      _caption.text = state.captionTemplate;
    }
    _seenTitle = state.titleTemplate;
    _seenCaption = state.captionTemplate;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _title.dispose();
    _caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = AppScope.stateOf(context);
    final service = AppScope.serviceOf(context);
    final caption = _captionStyle(state.projectJson);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.edit_note_outlined, size: 20),
                const SizedBox(width: 8),
                Text(
                  '展開時のテンプレート',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '使える差し込み: {group}, {task}, {txt}, {comment}, {file}, {index}, {n}, {slide}',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Text('スライドタイトル', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            TextField(
              key: const Key('finding-title'),
              controller: _title,
              decoration: const InputDecoration(
                hintText: '例: g{group}/{task} - {comment}',
              ),
              onChanged: (_) => _schedule(),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text('説明文 / 見解', style: Theme.of(context).textTheme.labelMedium),
                ),
                Text('使う', style: Theme.of(context).textTheme.labelSmall),
                Switch(
                  key: const Key('caption-shown'),
                  value: caption.shown,
                  onChanged: state.busy ? null : (value) => service.setCaptionShown(value),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: TextField(
                key: const Key('finding-caption'),
                controller: _caption,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  hintText: '例: 検査結果 {index}: {comment}',
                ),
                onChanged: (_) => _schedule(),
              ),
            ),
            const SizedBox(height: 10),
            Text('説明文の位置', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            SegmentedButton<String>(
              key: const Key('caption-place'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'below', label: Text('画像の下')),
                ButtonSegment(value: 'above', label: Text('画像の上')),
              ],
              selected: {caption.place},
              onSelectionChanged: state.busy
                  ? null
                  : (value) {
                      final next = value.first;
                      if (next != caption.place) {
                        service.setCaptionPlace(next);
                      }
                    },
            ),
            const SizedBox(height: 8),
            Text('説明文のサイズ', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            DropdownButtonFormField<int>(
              key: Key('caption-size:${caption.fontPt}'),
              initialValue: caption.fontPt,
              decoration: const InputDecoration(isDense: true),
              items: const [
                DropdownMenuItem(value: 12, child: Text('12 pt')),
                DropdownMenuItem(value: 14, child: Text('14 pt')),
                DropdownMenuItem(value: 16, child: Text('16 pt')),
                DropdownMenuItem(value: 18, child: Text('18 pt')),
                DropdownMenuItem(value: 22, child: Text('22 pt')),
                DropdownMenuItem(value: 28, child: Text('28 pt')),
                DropdownMenuItem(value: 36, child: Text('36 pt')),
              ],
              onChanged: state.busy
                  ? null
                  : (value) {
                      if (value != null && value != caption.fontPt) {
                        service.setTextSize(textId: caption.id, size: value.toDouble());
                      }
                    },
            ),
            const SizedBox(height: 8),
            Text(
              '欄の外か 1 秒後に自動で保存されます',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  _CaptionStyle _captionStyle(String? projectJson) {
    const fallback = _CaptionStyle(id: 'text-caption', shown: true, place: 'below', fontPt: 16);
    if (projectJson == null) return fallback;
    try {
      final decoded = jsonDecode(projectJson);
      if (decoded is! Map) return fallback;
      final found = _findCaption(decoded['contentMaster']);
      return found ?? fallback;
    } catch (_) {
      return fallback;
    }
  }

  _CaptionStyle? _findCaption(Object? node) {
    if (node is! Map) return null;
    final root = node['root'] ?? node;
    if (root is! Map) return null;
    if (root['kind'] == 'text' && root['roleId'] == 'caption') {
      final size = root['fontPt'];
      final font = size is num ? size.round() : 16;
      return _CaptionStyle(
        id: root['id']?.toString() ?? 'text-caption',
        shown: root['shown'] != false,
        place: root['place'] == 'before' ? 'above' : 'below',
        fontPt: const {12, 14, 16, 18, 22, 28, 36}.contains(font) ? font : 16,
      );
    }
    final children = root['children'];
    if (children is List) {
      for (final child in children) {
        final found = _findCaption(child);
        if (found != null) return found;
      }
    }
    return null;
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), _commit);
  }

  Future<void> _commit() async {
    if (!mounted) return;
    final state = _state;
    if (state == null || !state.hasOpenProject) return;
    final service = AppScope.serviceOf(context);
    await service.setTemplates(
      title: _title.text,
      caption: _caption.text,
    );
  }
}
