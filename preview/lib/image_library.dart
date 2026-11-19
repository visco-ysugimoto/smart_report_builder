import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// この PC の VTV（viscotech）が置く task フォルダ。
const defaultVtvTaskRoot = r'C:\viscotech\task';

/// 一覧に一度に載せる画像の上限。
const maxLibraryImages = 2000;

const maxZipEntryBytes = 512 * 1024 * 1024;

const libraryImageExtensions = {
  '.png',
  '.jpg',
  '.jpeg',
  '.bmp',
  '.gif',
  '.tif',
  '.tiff',
  '.webp',
};

enum LibrarySourceKind { folder, files, vtv, taskFile }

class LibraryImage {
  const LibraryImage({
    required this.id,
    required this.name,
    required this.sourceId,
    this.filePath,
    this.archiveEntry,
    this.group = '',
    this.task = '',
    this.listName = '',
    this.listComment,
    this.listIndex,
    this.note = '',
    this.source = '',
  });

  final String id;
  final String name;
  final String sourceId;
  final String? filePath;
  final String? archiveEntry;
  final String group;
  final String task;
  final String listName;
  final String? listComment;
  final int? listIndex;
  final String note;
  final String source;
}

class LibraryGroup {
  const LibraryGroup({
    required this.id,
    required this.label,
    required this.images,
  });

  final String id;
  final String label;
  final List<LibraryImage> images;
}

class LibrarySource {
  const LibrarySource({
    required this.id,
    required this.kind,
    required this.label,
    required this.origin,
    required this.groups,
    this.zipCatalog,
    this.truncated = false,
  });

  final String id;
  final LibrarySourceKind kind;
  final String label;
  final String origin;
  final List<LibraryGroup> groups;
  final ZipCatalog? zipCatalog;
  final bool truncated;

  int get imageCount =>
      groups.fold(0, (sum, group) => sum + group.images.length);
}

class NamedGroup {
  const NamedGroup(
    this.label,
    this.names, {
    this.listName = '',
    this.listComment,
    this.indexes = const {},
    this.notes = const {},
  });

  final String label;
  final List<String> names;
  final String listName;
  final String? listComment;
  final Map<String, int> indexes;
  final Map<String, String> notes;
}

class TaskReference {
  const TaskReference({
    required this.listName,
    required this.refs,
    this.listComment,
    this.fileNotes = const {},
  });

  final String listName;
  final String? listComment;
  final List<String> refs;
  /// FILE= のあとに書かれた Comment=。キーは FILE= の表記。
  final Map<String, String> fileNotes;

  String displayName(String baseLabel) {
    final comment = listComment?.trim() ?? '';
    if (comment.isEmpty) {
      return listName.isEmpty ? baseLabel : '$baseLabel / $listName';
    }
    return '$baseLabel / $comment';
  }
}

class ZipEntry {
  const ZipEntry({
    required this.name,
    required this.method,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
    required this.encrypted,
  });

  final String name;
  final int method;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
  final bool encrypted;
}

class ZipCatalog {
  ZipCatalog({required this.filePath, required List<ZipEntry> entries})
    : byName = {for (final entry in entries) entry.name: entry};

  final String filePath;
  final Map<String, ZipEntry> byName;
}

bool isLibraryImagePath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  final dot = normalized.lastIndexOf('.');
  if (dot < 0 || dot < slash) {
    return false;
  }
  return libraryImageExtensions.contains(
    normalized.substring(dot).toLowerCase(),
  );
}

String libraryBaseName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}

/// FILE= の並びを優先し、載っていない画像は名前順で後ろに足す。
/// 参照リストが複数あるときはリストごとに分け、残りを「その他」にする。
List<NamedGroup> arrangeImageGroups({
  required String baseLabel,
  required List<String> names,
  required List<TaskReference> references,
}) {
  final usable = [
    for (final reference in references)
      if (reference.refs.isNotEmpty) reference,
  ];
  if (usable.isEmpty) {
    final sorted = _sortNames(names);
    return [NamedGroup(baseLabel, sorted, indexes: _positionalIndexes(sorted))];
  }
  if (usable.length == 1) {
    final reference = usable.single;
    final comment = reference.listComment?.trim() ?? '';
    final ordered = _orderByRefs(names, reference.refs);
    return [
      NamedGroup(
        comment.isEmpty ? baseLabel : '$baseLabel / $comment',
        ordered,
        listName: reference.listName,
        listComment: comment.isEmpty ? null : comment,
        indexes: _fileOrderIndexes(names, reference.refs),
        notes: _notesForNames(names, reference.fileNotes),
      ),
    ];
  }
  final used = <String>{};
  final groups = <NamedGroup>[];
  for (final reference in usable) {
    final ordered = <String>[];
    final byLower = {
      for (final name in names) libraryBaseName(name).toLowerCase(): name,
    };
    for (final ref in reference.refs) {
      final match = byLower[libraryBaseName(ref).toLowerCase()];
      if (match != null && used.add(match)) {
        ordered.add(match);
      }
    }
    if (ordered.isNotEmpty) {
      groups.add(
        NamedGroup(
          reference.displayName(baseLabel),
          ordered,
          listName: reference.listName,
          listComment: reference.listComment,
          indexes: _fileOrderIndexes(names, reference.refs),
          notes: _notesForNames(ordered, reference.fileNotes),
        ),
      );
    }
  }
  final rest = [for (final name in names) if (!used.contains(name)) name];
  if (rest.isNotEmpty) {
    final sorted = _sortNames(rest);
    groups.add(NamedGroup('$baseLabel / その他', sorted, indexes: _positionalIndexes(sorted)));
  }
  if (groups.isEmpty) {
    return [NamedGroup(baseLabel, _sortNames(names))];
  }
  return groups;
}

/// 最初の FILE= より前の Comment= は一覧名。FILE= のあと次の FILE= までの Comment= はその画像のコメント。
/// それ以外の行は使わない。
TaskReference parseTaskListText(List<int> bytes, {String listName = ''}) {
  final text = _decodeTaskText(bytes);
  final comments = <String>[];
  final files = <String>[];
  final notes = <String, List<String>>{};
  String? currentFile;
  var seenFile = false;
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final commentAt = line.indexOf('Comment=');
    final fileAt = line.indexOf('FILE=');
    if (commentAt >= 0 && (fileAt < 0 || commentAt < fileAt)) {
      final value = line.substring(commentAt + 'Comment='.length).trim();
      if (value.isEmpty) {
        continue;
      }
      if (!seenFile || currentFile == null) {
        comments.add(value);
      } else {
        notes.putIfAbsent(currentFile, () => []).add(value);
      }
      continue;
    }
    if (fileAt < 0) {
      continue;
    }
    final name = line.substring(fileAt + 'FILE='.length).trim();
    if (name.isEmpty) {
      continue;
    }
    seenFile = true;
    currentFile = name;
    files.add(name);
  }
  return TaskReference(
    listName: listName,
    listComment: comments.isEmpty ? null : comments.join(' / '),
    refs: files,
    fileNotes: {
      for (final entry in notes.entries) entry.key: entry.value.join(' / '),
    },
  );
}

Map<String, String> _notesForNames(List<String> names, Map<String, String> fileNotes) {
  if (fileNotes.isEmpty) {
    return const {};
  }
  final byBase = <String, String>{};
  for (final entry in fileNotes.entries) {
    byBase[libraryBaseName(entry.key).toLowerCase()] = entry.value;
  }
  return {
    for (final name in names)
      if (byBase.containsKey(libraryBaseName(name).toLowerCase()))
        name: byBase[libraryBaseName(name).toLowerCase()]!,
  };
}

List<String> parseFileReferences(List<int> bytes) {
  return parseTaskListText(bytes).refs;
}

/// `viscotech/task/g01/03/img/a.bmp` を `g01/03` にする。
String taskGroupLabel(String entryName) {
  final normalized = entryName.replaceAll('\\', '/');
  final match = RegExp(
    r'(?:^|/)viscotech/task/(g\d+)/([^/]+)(?:/([^/]+))?/',
    caseSensitive: false,
  ).firstMatch(normalized);
  if (match == null) {
    final slash = normalized.lastIndexOf('/');
    if (slash <= 0) {
      return '画像';
    }
    return normalized.substring(0, slash);
  }
  final group = match.group(1)!;
  final task = match.group(2)!;
  final middle = match.group(3);
  if (middle == null || middle.isEmpty || middle.toLowerCase() == 'img') {
    return '$group/$task';
  }
  return '$group/$task/$middle';
}

String? resolveVtvTaskRoot(String input) {
  final direct = Directory(input);
  if (!direct.existsSync()) {
    return null;
  }
  if (_isTaskRoot(direct)) {
    return direct.path;
  }
  final nested = Directory(_join(direct.path, 'task'));
  if (nested.existsSync() && _isTaskRoot(nested)) {
    return nested.path;
  }
  return null;
}

Future<LibrarySource> loadFolderImages({
  required String sourceId,
  required String folderPath,
  int maxImages = maxLibraryImages,
}) async {
  final root = Directory(folderPath);
  if (!root.existsSync()) {
    throw const FormatException('フォルダが見つかりません');
  }
  final files = <File>[];
  var truncated = false;
  await _walkImages(root, 0, (file) {
    if (files.length >= maxImages) {
      truncated = true;
      return false;
    }
    files.add(file);
    return true;
  });
  if (files.isEmpty) {
    throw const FormatException('フォルダ内に画像がありません');
  }
  final byDir = <String, List<File>>{};
  for (final file in files) {
    byDir.putIfAbsent(_relativeDir(root.path, file.path), () => []).add(file);
  }
  final keys = byDir.keys.toList()..sort();
  final groups = <LibraryGroup>[];
  for (final key in keys) {
    final label = key.isEmpty ? libraryBaseName(root.path) : key;
    final images = [
      for (final file in byDir[key]!)
        LibraryImage(
          id: '$sourceId:${file.path}',
          name: libraryBaseName(file.path),
          sourceId: sourceId,
          filePath: file.path,
        ),
    ];
    groups.add(
      LibraryGroup(id: '$sourceId:$key', label: label, images: images),
    );
  }
  return LibrarySource(
    id: sourceId,
    kind: LibrarySourceKind.folder,
    label: root.path,
    origin: root.path,
    groups: groups,
    truncated: truncated,
  );
}

LibrarySource sourceFromFiles({
  required String sourceId,
  required List<String> paths,
}) {
  final images = [
    for (final path in paths)
      if (isLibraryImagePath(path))
        LibraryImage(
          id: '$sourceId:$path',
          name: libraryBaseName(path),
          sourceId: sourceId,
          filePath: path,
        ),
  ];
  if (images.isEmpty) {
    throw const FormatException('画像ファイルがありません');
  }
  final label = images.length == 1
      ? images.single.name
      : 'ファイル ${images.length} 件';
  return LibrarySource(
    id: sourceId,
    kind: LibrarySourceKind.files,
    label: label,
    origin: paths.join('|'),
    groups: [
      LibraryGroup(id: '$sourceId:files', label: label, images: images),
    ],
  );
}

Future<LibrarySource> loadVtvImages({
  required String sourceId,
  required String root,
  required String groupNumber,
  required String taskNumber,
  int maxImages = maxLibraryImages,
}) async {
  final taskRoot = resolveVtvTaskRoot(root);
  if (taskRoot == null) {
    throw const FormatException('VTVのtaskフォルダが見つかりません');
  }
  final located = findVtvTaskImageDirectory(
    taskRoot,
    groupNumber: groupNumber,
    taskNumber: taskNumber,
  );
  if (located == null) {
    throw FormatException(
      'グループ $groupNumber、タスク $taskNumber の画像フォルダが見つかりません',
    );
  }
  final files = await _imageFilesIn(located.img);
  if (files.isEmpty) {
    throw FormatException(
      'グループ $groupNumber、タスク $taskNumber に画像がありません',
    );
  }
  final refs = await _txtReferences(located.img);
  final label = '${libraryBaseName(located.group.path)}/${libraryBaseName(located.task.path)}';
  final arranged = arrangeImageGroups(
    baseLabel: label,
    names: [for (final file in files) file.path],
    references: refs,
  );
  final parts = _groupAndTask(label);
  final built = _groupsFromNames(
    sourceId: sourceId,
    arranged: arranged,
    maxImages: maxImages,
    fileForName: (name) => name,
    group: parts.$1,
    task: parts.$2,
    source: 'folder',
  );
  return LibrarySource(
    id: sourceId,
    kind: LibrarySourceKind.vtv,
    label: label,
    origin: taskRoot,
    groups: built.groups,
    truncated: built.truncated,
  );
}

class VtvTaskLocation {
  const VtvTaskLocation({
    required this.group,
    required this.task,
    required this.img,
  });

  final Directory group;
  final Directory task;
  final Directory img;
}

VtvTaskLocation? findVtvTaskImageDirectory(
  String taskRoot, {
  required String groupNumber,
  required String taskNumber,
}) {
  final group = _matchNumberedDirectory(
    Directory(taskRoot),
    groupNumber,
    prefix: 'g',
  );
  if (group == null) {
    return null;
  }
  final task = _matchNumberedDirectory(group, taskNumber, prefix: '');
  if (task == null) {
    return null;
  }
  final img = Directory(_join(task.path, 'img'));
  if (!img.existsSync()) {
    return null;
  }
  return VtvTaskLocation(group: group, task: task, img: img);
}

Future<LibrarySource> loadTaskFileImages({
  required String sourceId,
  required String filePath,
  required String groupNumber,
  required String taskNumber,
  int maxImages = maxLibraryImages,
}) async {
  final catalog = readZipCatalog(filePath);
  final imagesByDir = <String, List<ZipEntry>>{};
  final txtByDir = <String, List<ZipEntry>>{};
  for (final entry in catalog.byName.values) {
    if (entry.encrypted || entry.name.endsWith('/')) {
      continue;
    }
    if (!_entryInTask(entry.name, groupNumber, taskNumber)) {
      continue;
    }
    final directory = _entryDir(entry.name);
    if (entry.name.toLowerCase().endsWith('.txt')) {
      txtByDir.putIfAbsent(directory, () => []).add(entry);
      continue;
    }
    if (!isLibraryImagePath(entry.name)) {
      continue;
    }
    imagesByDir.putIfAbsent(directory, () => []).add(entry);
  }
  final directories = imagesByDir.keys.toList()..sort();
  final groups = <LibraryGroup>[];
  var count = 0;
  var truncated = false;
  for (final directory in directories) {
    final entries = imagesByDir[directory]!;
    final references = <TaskReference>[];
    final txts = txtByDir[directory] ?? const <ZipEntry>[];
    txts.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    for (final txt in txts) {
      if (txt.uncompressedSize > 1024 * 1024) {
        continue;
      }
      final stem = libraryBaseName(txt.name);
      final dot = stem.lastIndexOf('.');
      final listName = dot > 0 ? stem.substring(0, dot) : stem;
      final parsed = parseTaskListText(readZipEntry(catalog.filePath, txt), listName: listName);
      if (parsed.refs.isEmpty) {
        continue;
      }
      references.add(parsed);
    }
    final sample = entries.first.name;
    final arranged = arrangeImageGroups(
      baseLabel: taskGroupLabel(sample),
      names: [for (final entry in entries) entry.name],
      references: references,
    );
    final parts = _groupAndTask(taskGroupLabel(sample));
    for (final arrangedGroup in arranged) {
      final images = <LibraryImage>[];
      for (var index = 0; index < arrangedGroup.names.length; index++) {
        final name = arrangedGroup.names[index];
        if (count >= maxImages) {
          truncated = true;
          break;
        }
        count += 1;
        images.add(
          _orderedImage(
            sourceId: sourceId,
            storedName: name,
            listIndex: arrangedGroup.indexes[name] ?? index + 1,
            arranged: arrangedGroup,
            group: parts.$1,
            task: parts.$2,
            source: 'task-file',
            archiveEntry: name,
          ),
        );
      }
      if (images.isNotEmpty) {
        groups.add(
          LibraryGroup(
            id: '$sourceId:$directory:${arrangedGroup.label}',
            label: arrangedGroup.label,
            images: images,
          ),
        );
      }
      if (truncated) {
        break;
      }
    }
    if (truncated) {
      break;
    }
  }
  if (groups.isEmpty) {
    throw FormatException(
      'グループ $groupNumber、タスク $taskNumber の画像がありません',
    );
  }
  return LibrarySource(
    id: sourceId,
    kind: LibrarySourceKind.taskFile,
    label: '${groups.first.label.split(' / ').first} ${libraryBaseName(filePath)}',
    origin: filePath,
    groups: groups,
    zipCatalog: catalog,
    truncated: truncated,
  );
}

ZipCatalog readZipCatalog(String filePath) {
  final file = File(filePath);
  if (!file.existsSync()) {
    throw const FormatException('タスクファイルが見つかりません');
  }
  final length = file.lengthSync();
  if (length < 22) {
    throw const FormatException('タスクファイルを読めません');
  }
  final handle = file.openSync();
  try {
    final tailSize = length < 22 + 65535 ? length : 22 + 65535;
    final tail = _readAt(handle, length - tailSize, tailSize);
    final eocd = _findEocd(tail, length - tailSize, length);
    if (eocd < 0) {
      throw const FormatException('タスクファイルを読めません');
    }
    final entryCount = _u16(tail, eocd + 10);
    var cdSize = _u32(tail, eocd + 12);
    var cdOffset = _u32(tail, eocd + 16);
    if (entryCount == 0xFFFF ||
        cdSize == 0xFFFFFFFF ||
        cdOffset == 0xFFFFFFFF) {
      final located = _readZip64(handle, length - tailSize + eocd);
      cdSize = located.size;
      cdOffset = located.offset;
    }
    if (cdSize < 0 || cdOffset < 0 || cdOffset > length) {
      throw const FormatException('タスクファイルを読めません');
    }
    if (cdSize > 32 * 1024 * 1024) {
      throw const FormatException('タスクファイルの目録が大きすぎます');
    }
    final directory = _readAt(handle, cdOffset, cdSize);
    final entries = _parseCentralDirectory(directory);
    return ZipCatalog(filePath: filePath, entries: entries);
  } on FormatException {
    rethrow;
  } on FileSystemException catch (error) {
    throw FormatException(
      error.message.isEmpty ? 'タスクファイルを読めません' : error.message,
    );
  } finally {
    handle.closeSync();
  }
}

Uint8List readZipEntry(String filePath, ZipEntry entry) {
  if (entry.encrypted) {
    throw const FormatException('暗号化された画像は読めません');
  }
  if (entry.uncompressedSize > maxZipEntryBytes ||
      entry.compressedSize > maxZipEntryBytes) {
    throw const FormatException('画像が大きすぎて読み込めません');
  }
  if (entry.method != 0 && entry.method != 8) {
    throw const FormatException('この圧縮形式の画像は読めません');
  }
  final handle = File(filePath).openSync();
  try {
    final header = _readAt(handle, entry.localHeaderOffset, 30);
    if (_u32(header, 0) != 0x04034b50) {
      throw const FormatException('タスクファイル内の画像が見つかりません');
    }
    final nameLength = _u16(header, 26);
    final extraLength = _u16(header, 28);
    final dataOffset = entry.localHeaderOffset + 30 + nameLength + extraLength;
    final compressed = _readAt(handle, dataOffset, entry.compressedSize);
    if (entry.method == 0) {
      return compressed;
    }
    try {
      return Inflate(
        compressed,
        uncompressedSize: entry.uncompressedSize,
        throwOnError: true,
      ).getBytes();
    } on ArchiveException {
      throw const FormatException('画像を展開できません');
    }
  } finally {
    handle.closeSync();
  }
}

Uint8List readZipEntryBytes(ZipCatalog catalog, String entryName) {
  final entry = catalog.byName[entryName];
  if (entry == null) {
    throw const FormatException('タスクファイル内の画像が見つかりません');
  }
  return readZipEntry(catalog.filePath, entry);
}

Future<String> writeTempLibraryImage({
  required Directory directory,
  required String fileName,
  required int index,
  required Uint8List bytes,
}) async {
  final safe = fileName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  final file = File(
    '${directory.path}${Platform.pathSeparator}${index}_$safe',
  );
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

(String, String) _groupAndTask(String label) {
  final slash = label.indexOf('/');
  if (slash <= 0) {
    return (label, '');
  }
  final task = label.substring(slash + 1).split('/').first;
  return (label.substring(0, slash), task);
}

LibraryImage _orderedImage({
  required String sourceId,
  required String storedName,
  required int listIndex,
  required NamedGroup arranged,
  required String group,
  required String task,
  required String source,
  String? filePath,
  String? archiveEntry,
}) {
  return LibraryImage(
    id: '$sourceId:$storedName',
    name: libraryBaseName(storedName),
    sourceId: sourceId,
    filePath: filePath,
    archiveEntry: archiveEntry,
    group: group,
    task: task,
    listName: arranged.listName,
    listComment: arranged.listComment,
    listIndex: listIndex,
    note: arranged.notes[storedName] ?? '',
    source: source,
  );
}

({List<LibraryGroup> groups, bool truncated}) _groupsFromNames({
  required String sourceId,
  required List<NamedGroup> arranged,
  required int maxImages,
  required String Function(String name) fileForName,
  String group = '',
  String task = '',
  String source = '',
}) {
  final groups = <LibraryGroup>[];
  var count = 0;
  var truncated = false;
  for (final arrangedGroup in arranged) {
    final images = <LibraryImage>[];
    for (var index = 0; index < arrangedGroup.names.length; index++) {
      final name = arrangedGroup.names[index];
      if (count >= maxImages) {
        truncated = true;
        break;
      }
      count += 1;
      final filePath = fileForName(name);
      images.add(
        _orderedImage(
          sourceId: sourceId,
          storedName: name,
          listIndex: arrangedGroup.indexes[name] ?? index + 1,
          arranged: arrangedGroup,
          group: group,
          task: task,
          source: source,
          filePath: filePath,
        ),
      );
    }
    if (images.isNotEmpty) {
      groups.add(
        LibraryGroup(
          id: '$sourceId:${arrangedGroup.label}:$count',
          label: arrangedGroup.label,
          images: images,
        ),
      );
    }
    if (truncated) {
      break;
    }
  }
  return (groups: groups, truncated: truncated);
}

Directory? _matchNumberedDirectory(
  Directory parent,
  String number, {
  required String prefix,
}) {
  final wanted = int.tryParse(number.trim());
  if (wanted == null && number.trim().isEmpty) {
    return null;
  }
  for (final child in _childDirs(parent)) {
    final name = libraryBaseName(child.path);
    if (wanted != null) {
      final body = prefix.isEmpty
          ? name
          : (name.toLowerCase().startsWith(prefix.toLowerCase())
                ? name.substring(prefix.length)
                : null);
      if (body != null && int.tryParse(body) == wanted) {
        return child;
      }
    }
    if (name.toLowerCase() == '$prefix${number.trim()}'.toLowerCase()) {
      return child;
    }
  }
  return null;
}

bool _entryInTask(String name, String groupNumber, String taskNumber) {
  final label = taskGroupLabel(name);
  final slash = label.indexOf('/');
  if (slash <= 0) {
    return false;
  }
  final group = label.substring(0, slash);
  final task = label.substring(slash + 1).split('/').first;
  return _sameTaskNumber(group, groupNumber) &&
      _sameTaskNumber(task, taskNumber);
}

bool _sameTaskNumber(String left, String right) {
  final a = _taskInt(left);
  final b = _taskInt(right);
  if (a != null && b != null) {
    return a == b;
  }
  return left.trim().toLowerCase() == right.trim().toLowerCase();
}

int? _taskInt(String raw) {
  final text = raw.trim().replaceFirst(RegExp(r'^g', caseSensitive: false), '');
  if (text.isEmpty) {
    return null;
  }
  return int.tryParse(text);
}

List<String> _orderByRefs(List<String> names, List<String> refs) {
  final byLower = {
    for (final name in names) libraryBaseName(name).toLowerCase(): name,
  };
  final ordered = <String>[];
  final used = <String>{};
  for (final ref in refs) {
    final match = byLower[libraryBaseName(ref).toLowerCase()];
    if (match != null && used.add(match)) {
      ordered.add(match);
    }
  }
  final rest = [for (final name in names) if (!used.contains(name)) name];
  return [...ordered, ..._sortNames(rest)];
}

Map<String, int> _fileOrderIndexes(List<String> names, List<String> refs) {
  final byLower = {
    for (final name in names) libraryBaseName(name).toLowerCase(): name,
  };
  final indexes = <String, int>{};
  for (var index = 0; index < refs.length; index++) {
    final match = byLower[libraryBaseName(refs[index]).toLowerCase()];
    if (match != null) {
      indexes[match] = index + 1;
    }
  }
  var next = refs.length + 1;
  for (final name in _sortNames(names)) {
    indexes.putIfAbsent(name, () => next++);
  }
  return indexes;
}

Map<String, int> _positionalIndexes(List<String> names) {
  return {for (var index = 0; index < names.length; index++) names[index]: index + 1};
}

List<String> _sortNames(List<String> names) {
  final sorted = [...names]..sort(
    (a, b) => libraryBaseName(
      a,
    ).toLowerCase().compareTo(libraryBaseName(b).toLowerCase()),
  );
  return sorted;
}

String _decodeTaskText(List<int> bytes) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  if (data.length >= 3 &&
      data[0] == 0xEF &&
      data[1] == 0xBB &&
      data[2] == 0xBF) {
    return utf8.decode(data.sublist(3), allowMalformed: true);
  }
  return utf8.decode(data, allowMalformed: true);
}

bool _isTaskRoot(Directory dir) {
  try {
    return dir.listSync(followLinks: false).whereType<Directory>().any((
      child,
    ) {
      return RegExp(
        r'^g\d+$',
        caseSensitive: false,
      ).hasMatch(libraryBaseName(child.path));
    });
  } on FileSystemException {
    return false;
  }
}

List<Directory> _childDirs(Directory dir) {
  try {
    return dir.listSync(followLinks: false).whereType<Directory>().toList();
  } on FileSystemException {
    return const [];
  }
}

Future<List<File>> _imageFilesIn(Directory dir) async {
  final files = <File>[];
  try {
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && isLibraryImagePath(entity.path)) {
        files.add(entity);
      }
    }
  } on FileSystemException {
    return const [];
  }
  files.sort(
    (a, b) => libraryBaseName(
      a.path,
    ).toLowerCase().compareTo(libraryBaseName(b.path).toLowerCase()),
  );
  return files;
}

Future<List<TaskReference>> _txtReferences(
  Directory dir,
) async {
  final txts = <File>[];
  try {
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && entity.path.toLowerCase().endsWith('.txt')) {
        txts.add(entity);
      }
    }
  } on FileSystemException {
    return const [];
  }
  txts.sort(
    (a, b) => libraryBaseName(
      a.path,
    ).toLowerCase().compareTo(libraryBaseName(b.path).toLowerCase()),
  );
  final references = <TaskReference>[];
  for (final txt in txts) {
    Uint8List bytes;
    try {
      bytes = await txt.readAsBytes();
    } on FileSystemException {
      continue;
    }
    if (bytes.length > 1024 * 1024) {
      continue;
    }
    final stem = libraryBaseName(txt.path);
    final dot = stem.lastIndexOf('.');
    final listName = dot > 0 ? stem.substring(0, dot) : stem;
    final parsed = parseTaskListText(bytes, listName: listName);
    if (parsed.refs.isEmpty) {
      continue;
    }
    references.add(parsed);
  }
  return references;
}

Future<bool> _walkImages(
  Directory dir,
  int depth,
  bool Function(File file) onFile,
) async {
  if (depth > 8) {
    return true;
  }
  final List<FileSystemEntity> children;
  try {
    children = await dir.list(followLinks: false).toList();
  } on FileSystemException {
    return true;
  }
  children.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
  for (final entity in children) {
    if (entity is File && isLibraryImagePath(entity.path)) {
      if (!onFile(entity)) {
        return false;
      }
    }
  }
  for (final entity in children) {
    if (entity is Directory) {
      final keepGoing = await _walkImages(entity, depth + 1, onFile);
      if (!keepGoing) {
        return false;
      }
    }
  }
  return true;
}

String _relativeDir(String root, String filePath) {
  final rootNorm = root.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  final fileNorm = filePath.replaceAll('\\', '/');
  final slash = fileNorm.lastIndexOf('/');
  final parent = slash < 0 ? '' : fileNorm.substring(0, slash);
  if (parent.toLowerCase() == rootNorm.toLowerCase()) {
    return '';
  }
  final prefix = '${rootNorm.toLowerCase()}/';
  if (parent.toLowerCase().startsWith(prefix)) {
    return parent.substring(rootNorm.length + 1);
  }
  return '';
}

String _entryDir(String name) {
  final normalized = name.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash < 0 ? '' : normalized.substring(0, slash);
}

String _join(String directory, String name) {
  if (directory.endsWith(Platform.pathSeparator)) {
    return '$directory$name';
  }
  return '$directory${Platform.pathSeparator}$name';
}

int _findEocd(Uint8List tail, int tailOffset, int fileLength) {
  for (var offset = tail.length - 22; offset >= 0; offset -= 1) {
    if (_u32(tail, offset) != 0x06054b50) {
      continue;
    }
    final commentLength = _u16(tail, offset + 20);
    if (tailOffset + offset + 22 + commentLength == fileLength) {
      return offset;
    }
  }
  return -1;
}

({int count, int size, int offset}) _readZip64(
  RandomAccessFile handle,
  int eocdOffset,
) {
  if (eocdOffset < 20) {
    throw const FormatException('このタスクファイルは読めません');
  }
  final locator = _readAt(handle, eocdOffset - 20, 20);
  if (_u32(locator, 0) != 0x07064b50) {
    throw const FormatException('このタスクファイルは読めません');
  }
  final zip64Offset = _u64(locator, 8);
  final record = _readAt(handle, zip64Offset, 56);
  if (_u32(record, 0) != 0x06064b50) {
    throw const FormatException('このタスクファイルは読めません');
  }
  final count = _u64(record, 32);
  final size = _u64(record, 40);
  final offset = _u64(record, 48);
  return (count: count, size: size, offset: offset);
}

List<ZipEntry> _parseCentralDirectory(Uint8List directory) {
  final entries = <ZipEntry>[];
  var cursor = 0;
  while (cursor + 46 <= directory.length && entries.length < 200000) {
    if (_u32(directory, cursor) != 0x02014b50) {
      break;
    }
    final flags = _u16(directory, cursor + 8);
    final method = _u16(directory, cursor + 10);
    var compressedSize = _u32(directory, cursor + 20);
    var uncompressedSize = _u32(directory, cursor + 24);
    final nameLength = _u16(directory, cursor + 28);
    final extraLength = _u16(directory, cursor + 30);
    final commentLength = _u16(directory, cursor + 32);
    var localHeaderOffset = _u32(directory, cursor + 42);
    final nameStart = cursor + 46;
    final extraStart = nameStart + nameLength;
    final next = extraStart + extraLength + commentLength;
    if (next > directory.length) {
      throw const FormatException('タスクファイルを読めません');
    }
    final extra = Uint8List.sublistView(directory, extraStart, extraStart + extraLength);
    final zip64 = _zip64Sizes(
      extra,
      compressedSize: compressedSize,
      uncompressedSize: uncompressedSize,
      localHeaderOffset: localHeaderOffset,
    );
    compressedSize = zip64.compressedSize;
    uncompressedSize = zip64.uncompressedSize;
    localHeaderOffset = zip64.localHeaderOffset;
    final name = _zipName(
      Uint8List.sublistView(directory, nameStart, nameStart + nameLength),
      flags,
    ).replaceAll('\\', '/');
    if (name.isNotEmpty && !name.endsWith('/')) {
      entries.add(
        ZipEntry(
          name: name.startsWith('/') ? name.substring(1) : name,
          method: method,
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
          localHeaderOffset: localHeaderOffset,
          encrypted: flags & 0x1 != 0,
        ),
      );
    }
    cursor = next;
  }
  return entries;
}

({int compressedSize, int uncompressedSize, int localHeaderOffset}) _zip64Sizes(
  Uint8List extra, {
  required int compressedSize,
  required int uncompressedSize,
  required int localHeaderOffset,
}) {
  var compressed = compressedSize;
  var uncompressed = uncompressedSize;
  var offset = localHeaderOffset;
  var at = 0;
  while (at + 4 <= extra.length) {
    final id = _u16(extra, at);
    final size = _u16(extra, at + 2);
    final start = at + 4;
    if (start + size > extra.length) {
      break;
    }
    if (id == 1) {
      var position = start;
      if (uncompressed == 0xFFFFFFFF && position + 8 <= start + size) {
        uncompressed = _u64(extra, position);
        position += 8;
      }
      if (compressed == 0xFFFFFFFF && position + 8 <= start + size) {
        compressed = _u64(extra, position);
        position += 8;
      }
      if (offset == 0xFFFFFFFF && position + 8 <= start + size) {
        offset = _u64(extra, position);
      }
    }
    at = start + size;
  }
  return (
    compressedSize: compressed,
    uncompressedSize: uncompressed,
    localHeaderOffset: offset,
  );
}

String _zipName(Uint8List nameBytes, int flags) {
  if (flags & 0x800 != 0) {
    return utf8.decode(nameBytes, allowMalformed: true);
  }
  try {
    return utf8.decode(nameBytes);
  } on FormatException {
    return latin1.decode(nameBytes);
  }
}

Uint8List _readAt(RandomAccessFile handle, int offset, int length) {
  if (offset < 0 || length < 0) {
    throw const FormatException('タスクファイルを読めません');
  }
  if (length == 0) {
    return Uint8List(0);
  }
  handle.setPositionSync(offset);
  final bytes = handle.readSync(length);
  if (bytes.length != length) {
    throw const FormatException('タスクファイルが途中で切れています');
  }
  return bytes;
}

int _u16(Uint8List bytes, int offset) {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

int _u32(Uint8List bytes, int offset) {
  return (bytes[offset] |
          (bytes[offset + 1] << 8) |
          (bytes[offset + 2] << 16) |
          (bytes[offset + 3] << 24)) &
      0xFFFFFFFF;
}

int _u64(Uint8List bytes, int offset) {
  return _u32(bytes, offset) + (_u32(bytes, offset + 4) << 32);
}
