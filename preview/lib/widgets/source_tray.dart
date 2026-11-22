import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:smart_report_preview/image_library.dart';
import 'package:smart_report_preview/roi_persist.dart'
    show pickFolder, pickImageFiles, pickTaskFile;
import 'package:smart_report_preview/state/app_scope.dart';
import 'package:smart_report_preview/state/app_state.dart';

/// 左ペイン: 画像ソースの統合トレイ。
///
/// VTV / フォルダ / タスクファイルの 3 種を 3 つのアイコンから追加し、
/// 取り込んだ画像をサムネイル縦リストで表示する。ドラッグで枠へ渡す。
class SourceTray extends StatefulWidget {
  const SourceTray({super.key, this.scope = 'tray'});

  /// 画面を切り替えても同じキーが衝突しないようにする識別子。
  final String scope;

  @override
  State<SourceTray> createState() => _SourceTrayState();
}

class _SourceTrayState extends State<SourceTray> {
  final TextEditingController _search = TextEditingController();
  final TextEditingController _vtvGroup = TextEditingController(text: '1');
  final TextEditingController _vtvTask = TextEditingController(text: '1');
  int _serial = 0;
  int _ordinal = 1;
  bool _loading = false;

  @override
  void dispose() {
    _search.dispose();
    _vtvGroup.dispose();
    _vtvTask.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.stateOf(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.photo_library_outlined, size: 20),
                const SizedBox(width: 8),
                Text(
                  '画像ソース',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const Spacer(),
                Text(
                  state.totalLibraryImages == 0 ? '-' : '${state.totalLibraryImages} 枚',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _ActionRow(
              loading: _loading,
              onFolder: _addFolder,
              onFiles: _addFiles,
              onVtv: () => _showVtvPicker(context),
              onTaskFile: _addTaskFile,
            ),
            const SizedBox(height: 10),
            TextField(
              key: Key('${widget.scope}-search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: '名前で絞り込み',
              ),
            ),
            const SizedBox(height: 10),
            if (state.totalLibraryImages > 0)
              _InclusionBar(
                scope: widget.scope,
                maxOrdinal: _maxOrdinal(state),
                ordinal: _ordinal,
                onOrdinal: (value) => setState(() => _ordinal = value),
                onAll: () => state.setLibraryImageIdsIncluded(_allIds(state), included: true),
                onNone: () => state.setLibraryImageIdsIncluded(_allIds(state), included: false),
                onOnlyOrdinal: () {
                  final ordinal = _clampedOrdinal(state);
                  state.setLibraryImageIdsIncluded(
                    _idsAtOrdinal(state, ordinal),
                    included: true,
                    onlyThese: true,
                  );
                },
                onAddOrdinal: () {
                  final ordinal = _clampedOrdinal(state);
                  state.setLibraryImageIdsIncluded(
                    _idsAtOrdinal(state, ordinal),
                    included: true,
                  );
                },
              ),
            Expanded(child: _buildList(state)),
            if (state.librarySources.isNotEmpty) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                key: Key('${widget.scope}-clear'),
                onPressed: _loading ? null : state.clearLibrary,
                icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                label: const Text('トレイを空にする'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildList(AppState state) {
    final query = _search.text.trim().toLowerCase();
    final sources = state.librarySources;
    if (sources.isEmpty) {
      return _EmptyPlaceholder();
    }
    return ListView.builder(
      key: Key('${widget.scope}-list'),
      itemCount: sources.length,
      itemBuilder: (context, sourceIndex) {
        final source = sources[sourceIndex];
        final visibleGroups = [
          for (final group in source.groups)
            LibraryGroup(
              id: group.id,
              label: group.label,
              images: query.isEmpty
                  ? group.images
                  : group.images
                      .where((image) => image.name.toLowerCase().contains(query))
                      .toList(),
            ),
        ].where((group) => group.images.isNotEmpty).toList();
        if (visibleGroups.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      source.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  IconButton(
                    key: Key('tray-remove:${source.id}'),
                    icon: const Icon(Icons.close, size: 16),
                    tooltip: 'このソースを外す',
                    onPressed: () => state.removeLibrarySource(source.id),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                  ),
                ],
              ),
            ),
            for (final group in source.groups)
              if (visibleGroups.any((item) => item.id == group.id)) ...[
                _GroupHeader(
                  scope: widget.scope,
                  sourceId: source.id,
                  group: group,
                  onIncluded: (included) => state.setLibraryImageIdsIncluded(
                    {for (final image in group.images) image.id},
                    included: included,
                  ),
                ),
                _ThumbnailGrid(
                  scope: widget.scope,
                  images: visibleGroups.firstWhere((item) => item.id == group.id).images,
                  selectedId: state.selectedLibraryImageId,
                  onTap: state.selectLibraryImage,
                  onIncluded: state.setLibraryImageIncluded,
                  source: source,
                ),
              ],
          ],
        );
      },
    );
  }

  void _showVtvPicker(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('VTV から画像を取り込む'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                r'C:\viscotech\task のグループとタスクを指定します',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('vtv-group'),
                      controller: _vtvGroup,
                      decoration: const InputDecoration(
                        labelText: 'グループ',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const Key('vtv-task'),
                      controller: _vtvTask,
                      decoration: const InputDecoration(
                        labelText: 'タスク',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              key: const Key('vtv-load'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _loadVtv();
              },
              child: const Text('取り込む'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _loadVtv() async {
    final group = _vtvGroup.text.trim();
    final task = _vtvTask.text.trim();
    if (group.isEmpty || task.isEmpty) return;
    await _withLoading(() async {
      final source = await loadVtvImages(
        sourceId: _nextSourceId(),
        root: defaultVtvTaskRoot,
        groupNumber: group,
        taskNumber: task,
      );
      if (!mounted) return;
      AppScope.stateOf(context).addLibrarySource(source);
    });
  }

  Future<void> _addFolder() async {
    final path = await pickFolder();
    if (path == null) return;
    await _withLoading(() async {
      final source = await loadFolderImages(
        sourceId: _nextSourceId(),
        folderPath: path,
      );
      if (!mounted) return;
      AppScope.stateOf(context).addLibrarySource(source);
    });
  }

  Future<void> _addFiles() async {
    final files = await pickImageFiles();
    if (files.isEmpty) return;
    await _withLoading(() async {
      final source = sourceFromFiles(
        sourceId: _nextSourceId(),
        paths: files,
      );
      if (!mounted) return;
      AppScope.stateOf(context).addLibrarySource(source);
    });
  }

  Future<void> _addTaskFile() async {
    final path = await pickTaskFile();
    if (path == null) return;
    await _withLoading(() async {
      final source = await loadTaskFileImages(
        sourceId: _nextSourceId(),
        filePath: path,
        groupNumber: _vtvGroup.text.trim().isEmpty ? '1' : _vtvGroup.text.trim(),
        taskNumber: _vtvTask.text.trim().isEmpty ? '1' : _vtvTask.text.trim(),
      );
      if (!mounted) return;
      AppScope.stateOf(context).addLibrarySource(source);
    });
  }

  int _maxOrdinal(AppState state) {
    var maxOrdinal = 0;
    for (final source in state.librarySources) {
      for (final group in source.groups) {
        if (group.images.length > maxOrdinal) maxOrdinal = group.images.length;
      }
    }
    return maxOrdinal;
  }

  int _clampedOrdinal(AppState state) {
    final maxOrdinal = _maxOrdinal(state);
    if (maxOrdinal < 1) return 1;
    if (_ordinal > maxOrdinal) return maxOrdinal;
    return _ordinal < 1 ? 1 : _ordinal;
  }

  Set<String> _allIds(AppState state) {
    return {
      for (final source in state.librarySources)
        for (final group in source.groups)
          for (final image in group.images) image.id,
    };
  }

  /// 各コメント（グループ）の、表示順で n 番目の画像。
  Set<String> _idsAtOrdinal(AppState state, int ordinal) {
    return {
      for (final source in state.librarySources)
        for (final group in source.groups)
          if (ordinal >= 1 && ordinal <= group.images.length) group.images[ordinal - 1].id,
    };
  }

  String _nextSourceId() {
    _serial += 1;
    return 'src-$_serial';
  }

  Future<void> _withLoading(Future<void> Function() body) async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      await body();
    } on FormatException catch (exc) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(exc.message)),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.loading,
    required this.onFolder,
    required this.onFiles,
    required this.onVtv,
    required this.onTaskFile,
  });

  final bool loading;
  final VoidCallback onFolder;
  final VoidCallback onFiles;
  final VoidCallback onVtv;
  final VoidCallback onTaskFile;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _IconAction(
          key: const Key('tray-add-vtv'),
          icon: Icons.memory,
          label: 'VTV',
          onPressed: loading ? null : onVtv,
        ),
        _IconAction(
          key: const Key('tray-add-folder'),
          icon: Icons.folder_outlined,
          label: 'フォルダ',
          onPressed: loading ? null : onFolder,
        ),
        _IconAction(
          key: const Key('tray-add-files'),
          icon: Icons.image_outlined,
          label: 'ファイル',
          onPressed: loading ? null : onFiles,
        ),
        _IconAction(
          key: const Key('tray-add-task'),
          icon: Icons.archive_outlined,
          label: 'タスク',
          onPressed: loading ? null : onTaskFile,
        ),
      ],
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 60,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            Icon(icon, size: 22, color: enabled ? scheme.primary : scheme.outline),
            const SizedBox(height: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: enabled ? scheme.onSurface : scheme.outline,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InclusionBar extends StatelessWidget {
  const _InclusionBar({
    required this.scope,
    required this.maxOrdinal,
    required this.ordinal,
    required this.onOrdinal,
    required this.onAll,
    required this.onNone,
    required this.onOnlyOrdinal,
    required this.onAddOrdinal,
  });

  final String scope;
  final int maxOrdinal;
  final int ordinal;
  final ValueChanged<int> onOrdinal;
  final VoidCallback onAll;
  final VoidCallback onNone;
  final VoidCallback onOnlyOrdinal;
  final VoidCallback onAddOrdinal;

  @override
  Widget build(BuildContext context) {
    final shown = maxOrdinal < 1 ? 1 : ordinal.clamp(1, maxOrdinal);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _CompactButton(
              buttonKey: Key('$scope-include-all'),
              label: 'すべて使う',
              onPressed: onAll,
            ),
            _CompactButton(
              buttonKey: Key('$scope-include-none'),
              label: 'すべて外す',
              onPressed: onNone,
            ),
          ],
        ),
        if (maxOrdinal >= 2) ...[
          const SizedBox(height: 4),
          Text(
            '各コメントの同じ番目',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: DropdownButton<int>(
                  key: Key('$scope-ordinal'),
                  value: shown,
                  isDense: true,
                  isExpanded: true,
                  items: [
                    for (var number = 1; number <= maxOrdinal; number++)
                      DropdownMenuItem(value: number, child: Text('$number枚目')),
                  ],
                  onChanged: (value) {
                    if (value != null) onOrdinal(value);
                  },
                ),
              ),
              _CompactButton(
                buttonKey: Key('$scope-ordinal-only'),
                label: 'だけ使う',
                tooltip: 'この番目だけを使い、ほかは外します',
                onPressed: onOnlyOrdinal,
              ),
              _CompactButton(
                buttonKey: Key('$scope-ordinal-add'),
                label: '追加',
                tooltip: 'この番目も使う対象に加えます',
                onPressed: onAddOrdinal,
              ),
            ],
          ),
        ],
        const SizedBox(height: 6),
      ],
    );
  }
}

class _CompactButton extends StatelessWidget {
  const _CompactButton({
    required this.buttonKey,
    required this.label,
    required this.onPressed,
    this.tooltip,
  });

  final Key buttonKey;
  final String label;
  final String? tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final button = TextButton(
      key: buttonKey,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: onPressed,
      child: Text(label),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip, child: button);
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.scope,
    required this.sourceId,
    required this.group,
    required this.onIncluded,
  });

  final String scope;
  final String sourceId;
  final LibraryGroup group;
  final ValueChanged<bool> onIncluded;

  @override
  Widget build(BuildContext context) {
    final all = group.images.every((image) => image.included);
    final any = group.images.any((image) => image.included);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: Checkbox(
              key: Key('$scope-group:$sourceId:${group.id}'),
              tristate: true,
              value: all ? true : (any ? null : false),
              visualDensity: VisualDensity.compact,
              onChanged: (_) => onIncluded(!all),
            ),
          ),
          Expanded(
            child: Text(
              group.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _ThumbnailGrid extends StatelessWidget {
  const _ThumbnailGrid({
    required this.scope,
    required this.images,
    required this.selectedId,
    required this.onTap,
    required this.onIncluded,
    required this.source,
  });

  final String scope;
  final List<LibraryImage> images;
  final String? selectedId;
  final ValueChanged<String?> onTap;
  final void Function(String imageId, bool included) onIncluded;
  final LibrarySource source;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final image in images)
          _Thumbnail(
            key: Key('$scope:${image.id}'),
            image: image,
            selected: image.id == selectedId,
            onTap: () => onTap(image.id),
            onIncluded: (included) => onIncluded(image.id, included),
            source: source,
          ),
      ],
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    super.key,
    required this.image,
    required this.selected,
    required this.onTap,
    required this.onIncluded,
    required this.source,
  });

  final LibraryImage image;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<bool> onIncluded;
  final LibrarySource source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tile = Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: _Preview(image: image, source: source),
    );
    final thumb = Opacity(opacity: image.included ? 1 : 0.35, child: tile);
    return Draggable<LibraryImage>(
      data: image,
      feedback: Material(
        color: Colors.transparent,
        elevation: 6,
        child: SizedBox(width: 72, height: 72, child: thumb),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: thumb),
      child: GestureDetector(
        onTap: onTap,
        child: Tooltip(
          message: image.included ? image.name : '${image.name}（使わない）',
          child: SizedBox(
            width: 72,
            height: 72,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                thumb,
                Positioned(
                  right: -6,
                  top: -8,
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: Checkbox(
                      value: image.included,
                      visualDensity: VisualDensity.compact,
                      onChanged: (value) => onIncluded(value ?? false),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.image, required this.source});

  final LibraryImage image;
  final LibrarySource source;

  @override
  Widget build(BuildContext context) {
    final path = image.filePath;
    if (path != null) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        cacheWidth: 144,
        errorBuilder: (_, _, _) => const _Fallback(),
      );
    }
    final entry = image.archiveEntry;
    final catalog = source.zipCatalog;
    if (entry != null && catalog != null) {
      return FutureBuilder<Uint8List>(
        future: Future(() => readZipEntryBytes(catalog, entry)),
        builder: (context, snapshot) {
          if (snapshot.hasError || !snapshot.hasData) return const _Fallback();
          return Image.memory(
            snapshot.data!,
            fit: BoxFit.cover,
            cacheWidth: 144,
            errorBuilder: (_, _, _) => const _Fallback(),
          );
        },
      );
    }
    return const _Fallback();
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade200,
      alignment: Alignment.center,
      child: const Icon(Icons.image_not_supported_outlined, size: 20, color: Colors.grey),
    );
  }
}

class _EmptyPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.collections_outlined, size: 40, color: scheme.outline),
            const SizedBox(height: 10),
            Text(
              '上のアイコンから\n画像を取り込みます',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

// AppDims はテーマから読む。source_tray はカードの中で描かれるため追加は不要。
