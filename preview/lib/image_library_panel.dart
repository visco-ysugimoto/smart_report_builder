import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:smart_report_preview/image_library.dart';

class ImageLibraryPanel extends StatelessWidget {
  const ImageLibraryPanel({
    required this.sources,
    required this.selectedImageId,
    required this.loading,
    required this.message,
    required this.canAssign,
    required this.onSelect,
    required this.onAssign,
    required this.onAddFolder,
    required this.onAddFiles,
    required this.onOpenDefaultVtv,
    required this.onPickVtv,
    required this.onAddTaskFile,
    required this.onRemoveSource,
    required this.onClear,
    required this.loadArchiveBytes,
    this.taskGroup,
    this.taskNumber,
    this.onShowTask,
    super.key,
  });

  final List<LibrarySource> sources;
  final String? selectedImageId;
  final bool loading;
  final String? message;
  final bool canAssign;
  final ValueChanged<LibraryImage> onSelect;
  final ValueChanged<LibraryImage> onAssign;
  final VoidCallback? onAddFolder;
  final VoidCallback? onAddFiles;
  final VoidCallback? onOpenDefaultVtv;
  final VoidCallback? onPickVtv;
  final VoidCallback? onAddTaskFile;
  final ValueChanged<String> onRemoveSource;
  final VoidCallback? onClear;
  final Future<Uint8List> Function(LibraryImage image) loadArchiveBytes;
  final TextEditingController? taskGroup;
  final TextEditingController? taskNumber;
  final VoidCallback? onShowTask;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selectedImage();
    final total = sources.fold(0, (sum, source) => sum + source.imageCount);
    return Material(
      color: scheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('画像一覧', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              total == 0 ? '追加した画像がここに並びます' : '全 $total 件',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _action(
                  key: const Key('library-add-folder'),
                  label: 'フォルダ',
                  tooltip: 'フォルダ内の画像を追加します',
                  onPressed: onAddFolder,
                ),
                _action(
                  key: const Key('library-add-files'),
                  label: 'ファイル',
                  tooltip: '画像ファイルを追加します',
                  onPressed: onAddFiles,
                ),
                _action(
                  key: const Key('library-add-vtv'),
                  label: 'VTV',
                  tooltip: r'C:\viscotech\task から、指定したグループとタスクを読み込みます',
                  onPressed: onOpenDefaultVtv,
                ),
                _action(
                  key: const Key('library-add-vtv-folder'),
                  label: 'VTVを指定',
                  tooltip: 'viscotech フォルダ、または task フォルダを指定します',
                  onPressed: onPickVtv,
                ),
                _action(
                  key: const Key('library-add-task'),
                  label: 'タスクファイル',
                  tooltip: 'タスクファイルから、指定したグループとタスクを読み込みます',
                  onPressed: onAddTaskFile,
                ),
                if (sources.isNotEmpty)
                  _action(
                    key: const Key('library-clear'),
                    label: '一覧をクリア',
                    tooltip: '読み込んだ一覧を外します',
                    onPressed: onClear,
                  ),
              ],
            ),
            if (loading) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
            if (taskGroup != null && taskNumber != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('library-task-group'),
                      controller: taskGroup,
                      enabled: onShowTask != null,
                      decoration: const InputDecoration(
                        labelText: 'グループ',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const Key('library-task-number'),
                      controller: taskNumber,
                      enabled: onShowTask != null,
                      decoration: const InputDecoration(
                        labelText: 'タスク',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('library-show-task'),
                    onPressed: onShowTask,
                    child: const Text('表示'),
                  ),
                ],
              ),
            ],
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message!, key: const Key('library-message')),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: sources.isEmpty
                  ? const Align(
                      alignment: Alignment.topLeft,
                      child: Text(
                        'フォルダとファイルはそのまま追加できます。'
                        'VTVとタスクファイルは、グループ番号とタスク番号を指定して表示します。',
                        key: Key('library-empty'),
                      ),
                    )
                  : ListView(
                      children: [
                        for (var index = 0; index < sources.length; index++)
                          _SourceTile(
                            source: sources[index],
                            expanded: index == 0,
                            selectedImageId: selectedImageId,
                            onSelect: onSelect,
                            onRemove: () => onRemoveSource(sources[index].id),
                            loadArchiveBytes: loadArchiveBytes,
                          ),
                      ],
                    ),
            ),
            if (selected != null) ...[
              const Divider(height: 16),
              Text(
                selected.name,
                key: const Key('library-selected-name'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  key: const Key('library-assign'),
                  onPressed: canAssign ? () => onAssign(selected) : null,
                  child: const Text('この枠へ'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  LibraryImage? _selectedImage() {
    for (final source in sources) {
      for (final group in source.groups) {
        for (final image in group.images) {
          if (image.id == selectedImageId) {
            return image;
          }
        }
      }
    }
    return null;
  }

  Widget _action({
    required Key key,
    required String label,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: FilledButton.tonal(
        key: key,
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.source,
    required this.expanded,
    required this.selectedImageId,
    required this.onSelect,
    required this.onRemove,
    required this.loadArchiveBytes,
  });

  final LibrarySource source;
  final bool expanded;
  final String? selectedImageId;
  final ValueChanged<LibraryImage> onSelect;
  final VoidCallback onRemove;
  final Future<Uint8List> Function(LibraryImage image) loadArchiveBytes;

  @override
  Widget build(BuildContext context) {
    final kind = switch (source.kind) {
      LibrarySourceKind.folder => 'フォルダ',
      LibrarySourceKind.files => 'ファイル',
      LibrarySourceKind.vtv => 'VTV',
      LibrarySourceKind.taskFile => 'タスク',
    };
    return ExpansionTile(
      key: ValueKey(source.id),
      initiallyExpanded: expanded,
      tilePadding: EdgeInsets.zero,
      title: Row(
        children: [
          Expanded(
            child: Text(
              '$kind ${source.label} (${source.imageCount})',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'この一覧を外す',
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
      subtitle: source.truncated ? const Text('一部だけ表示しています') : null,
      children: [
        if (source.groups.length == 1)
          _ImageGrid(
            images: source.groups.single.images,
            selectedImageId: selectedImageId,
            onSelect: onSelect,
            loadArchiveBytes: loadArchiveBytes,
          )
        else
          for (var index = 0; index < source.groups.length; index++)
            ExpansionTile(
              key: ValueKey(source.groups[index].id),
              initiallyExpanded: index == 0,
              tilePadding: const EdgeInsets.only(left: 8),
              title: Text(
                '${source.groups[index].label} (${source.groups[index].images.length})',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              children: [
                _ImageGrid(
                  images: source.groups[index].images,
                  selectedImageId: selectedImageId,
                  onSelect: onSelect,
                  loadArchiveBytes: loadArchiveBytes,
                ),
              ],
            ),
      ],
    );
  }
}

class _ImageGrid extends StatelessWidget {
  const _ImageGrid({
    required this.images,
    required this.selectedImageId,
    required this.onSelect,
    required this.loadArchiveBytes,
  });

  final List<LibraryImage> images;
  final String? selectedImageId;
  final ValueChanged<LibraryImage> onSelect;
  final Future<Uint8List> Function(LibraryImage image) loadArchiveBytes;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cross = constraints.maxWidth >= 420 ? 3 : 2;
        final dense = images.length > cross * 4;
        final grid = GridView.builder(
          shrinkWrap: !dense,
          physics: dense
              ? const ClampingScrollPhysics()
              : const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.82,
          ),
          itemCount: images.length,
          itemBuilder: (context, index) {
            final image = images[index];
            return _ImageTile(
              image: image,
              selected: image.id == selectedImageId,
              onSelect: () => onSelect(image),
              loadArchiveBytes: loadArchiveBytes,
            );
          },
        );
        if (!dense) {
          return grid;
        }
        return SizedBox(height: 440, child: grid);
      },
    );
  }
}

class _ImageTile extends StatelessWidget {
  const _ImageTile({
    required this.image,
    required this.selected,
    required this.onSelect,
    required this.loadArchiveBytes,
  });

  final LibraryImage image;
  final bool selected;
  final VoidCallback onSelect;
  final Future<Uint8List> Function(LibraryImage image) loadArchiveBytes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: Key('library-image-${image.id}'),
        borderRadius: BorderRadius.circular(8),
        onTap: onSelect,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              children: [
                Expanded(child: _thumbnail(context)),
                const SizedBox(height: 4),
                Text(
                  image.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _thumbnail(BuildContext context) {
    final path = image.filePath;
    if (path != null) {
      return Image.file(
        File(path),
        fit: BoxFit.contain,
        cacheWidth: 180,
        errorBuilder: (context, error, stackTrace) => _broken(context),
      );
    }
    return _ArchiveThumbnail(
      image: image,
      loadArchiveBytes: loadArchiveBytes,
    );
  }

  Widget _broken(BuildContext context) {
    return Icon(
      Icons.broken_image_outlined,
      color: Theme.of(context).colorScheme.outline,
    );
  }
}

class _ArchiveThumbnail extends StatefulWidget {
  const _ArchiveThumbnail({
    required this.image,
    required this.loadArchiveBytes,
  });

  final LibraryImage image;
  final Future<Uint8List> Function(LibraryImage image) loadArchiveBytes;

  @override
  State<_ArchiveThumbnail> createState() => _ArchiveThumbnailState();
}

class _ArchiveThumbnailState extends State<_ArchiveThumbnail> {
  late Future<Uint8List> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = widget.loadArchiveBytes(widget.image);
  }

  @override
  void didUpdateWidget(covariant _ArchiveThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.id != widget.image.id) {
      _bytes = widget.loadArchiveBytes(widget.image);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Icon(
            Icons.broken_image_outlined,
            color: Theme.of(context).colorScheme.outline,
          );
        }
        final bytes = snapshot.data;
        if (bytes == null) {
          return const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return Image.memory(
          bytes,
          fit: BoxFit.contain,
          cacheWidth: 180,
          errorBuilder: (context, error, stackTrace) => Icon(
            Icons.broken_image_outlined,
            color: Theme.of(context).colorScheme.outline,
          ),
        );
      },
    );
  }
}
