import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:smart_report_preview/image_library.dart';
import 'package:smart_report_preview/layout_result.dart';

/// 3 ステップのどこにいるか。
enum WorkflowStep { start, master, expand }

/// プロジェクトの状態を 1 箇所に集める ChangeNotifier。
///
/// 画面間で同じ状態を共有し、Python IPC の結果を反映する。
/// UI 層はこのクラスをリッスンして再描画する。
class AppState extends ChangeNotifier {
  AppState();

  WorkflowStep _step = WorkflowStep.start;
  String? _projectDirectory;
  String? _projectPath;
  String? _layoutPath;
  String? _pptxPath;
  LayoutResult? _result;
  String? _projectJson;
  bool _busy = false;
  bool _canUndo = false;
  bool _canRedo = false;
  String? _statusMessage;
  String? _errorMessage;
  final List<LibrarySource> _librarySources = [];
  String? _selectedLibraryImageId;
  String? _selectedFrameId;
  String? _selectedSlideId;
  int _slideCount = 1;
  String _titleTemplate = '';
  String _captionTemplate = '';
  String _currentPreset = 'horizontal-2';
  final Map<String, String> _slidePresets = {};

  WorkflowStep get step => _step;
  String? get projectDirectory => _projectDirectory;
  String? get projectPath => _projectPath;
  String? get layoutPath => _layoutPath;
  String? get pptxPath => _pptxPath;
  LayoutResult? get result => _result;
  String? get projectJson => _projectJson;
  bool get busy => _busy;
  bool get canUndo => _canUndo;
  bool get canRedo => _canRedo;
  String? get statusMessage => _statusMessage;
  String? get errorMessage => _errorMessage;
  List<LibrarySource> get librarySources => List.unmodifiable(_librarySources);
  String? get selectedLibraryImageId => _selectedLibraryImageId;
  String? get selectedFrameId => _selectedFrameId;
  String? get selectedSlideId => _selectedSlideId;
  int get slideCount => _slideCount;
  String get titleTemplate => _titleTemplate;
  String get captionTemplate => _captionTemplate;
  String get currentPreset => _currentPreset;

  /// 展開後にそのスライドだけ変えた並び。未設定なら 1 枚目の型に従う。
  String? slidePreset(String? slideId) {
    if (slideId == null) return null;
    return _slidePresets[slideId];
  }

  bool get hasOpenProject => _projectPath != null && _result != null;

  LibraryImage? get selectedLibraryImage {
    final id = _selectedLibraryImageId;
    if (id == null) return null;
    for (final source in _librarySources) {
      for (final group in source.groups) {
        for (final image in group.images) {
          if (image.id == id) return image;
        }
      }
    }
    return null;
  }

  int get totalLibraryImages =>
      _librarySources.fold(0, (sum, source) => sum + source.imageCount);

  List<LibraryImage> get includedLibraryImages => [
    for (final source in _librarySources)
      for (final group in source.groups)
        for (final image in group.images)
          if (image.included) image,
  ];

  void setStep(WorkflowStep step) {
    if (_step == step) return;
    _step = step;
    notifyListeners();
  }

  void setBusy(bool value, {String? status}) {
    _busy = value;
    if (status != null) {
      _statusMessage = status;
      _errorMessage = null;
    }
    notifyListeners();
  }

  void setError(String? message) {
    _errorMessage = message;
    _busy = false;
    notifyListeners();
  }

  void setStatus(String? message) {
    _statusMessage = message;
    notifyListeners();
  }

  void setProject({
    required String directory,
    required String projectPath,
    required String layoutPath,
    required String pptxPath,
  }) {
    _projectDirectory = directory;
    _projectPath = projectPath;
    _layoutPath = layoutPath;
    _pptxPath = pptxPath;
    _selectedFrameId = null;
    _selectedSlideId = null;
    notifyListeners();
  }

  void updateDocuments({LayoutResult? layout, String? projectJson}) {
    if (layout != null) _result = layout;
    if (projectJson != null) {
      _projectJson = projectJson;
      final templates = _readTemplates(projectJson);
      if (templates != null) {
        _titleTemplate = templates.$1;
        _captionTemplate = templates.$2;
      }
    }
    _slideCount = _parseSlideCount(projectJson ?? _projectJson);
    notifyListeners();
  }

  (String, String)? _readTemplates(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return null;
      final master = decoded['contentMaster'];
      if (master is! Map) return null;
      final rule = master['assignmentRule'];
      if (rule is! Map) return ('', '');
      final texts = rule['textTemplates'];
      var caption = '';
      if (texts is List) {
        for (final item in texts) {
          if (item is Map && item['template'] is String) {
            caption = item['template'] as String;
            break;
          }
        }
      }
      return ('${rule['titleTemplate'] ?? ''}', caption);
    } on FormatException {
      return null;
    }
  }

  void setHistory({required bool canUndo, required bool canRedo}) {
    if (_canUndo == canUndo && _canRedo == canRedo) return;
    _canUndo = canUndo;
    _canRedo = canRedo;
    notifyListeners();
  }

  void closeProject() {
    _projectDirectory = null;
    _projectPath = null;
    _layoutPath = null;
    _pptxPath = null;
    _result = null;
    _projectJson = null;
    _step = WorkflowStep.start;
    _selectedFrameId = null;
    _selectedSlideId = null;
    _slideCount = 1;
    _canUndo = false;
    _canRedo = false;
    notifyListeners();
  }

  void addLibrarySource(LibrarySource source) {
    _librarySources.removeWhere((item) => item.id == source.id);
    _librarySources.add(source);
    notifyListeners();
  }

  /// コメント分類へ画像を足す。同じパスは足さない。追加した枚数を返す。
  int appendLibraryImages({
    required String sourceId,
    required String groupId,
    required List<String> paths,
  }) {
    final index = _librarySources.indexWhere((source) => source.id == sourceId);
    if (index < 0 || paths.isEmpty) return 0;
    final source = _librarySources[index];
    final group = source.groups.where((item) => item.id == groupId);
    if (group.isEmpty) return 0;
    final images = imagesForGroup(
      sourceId: sourceId,
      group: group.first,
      paths: paths,
      existingPaths: libraryPathsIn(source),
    );
    if (images.isEmpty) return 0;
    _librarySources[index] = LibrarySource(
      id: source.id,
      kind: source.kind,
      label: source.label,
      origin: source.origin,
      zipCatalog: source.zipCatalog,
      truncated: source.truncated,
      groups: [
        for (final item in source.groups)
          if (item.id != groupId)
            item
          else
            LibraryGroup(
              id: item.id,
              label: item.label,
              images: [...item.images, ...images],
            ),
      ],
    );
    notifyListeners();
    return images.length;
  }

  /// 分類を足す。同じ名前があるときや空のときは、その理由を返す。
  String? addLibraryGroup({required String sourceId, required String name}) {
    final label = name.trim();
    if (label.isEmpty) return '分類名を入力してください';
    final index = _librarySources.indexWhere((item) => item.id == sourceId);
    if (index < 0) return '画像の一覧が見つかりません';
    final source = _librarySources[index];
    if (source.groups.any((group) => _sameClassification(group, label))) {
      return '同じ名前の分類があります';
    }
    final group = LibraryGroup(
      id: _freshGroupId(source, label),
      label: label,
      images: const [],
    );
    final groups = [...source.groups];
    final otherAt = groups.indexWhere(isCatchAllGroup);
    if (otherAt < 0) {
      groups.add(group);
    } else {
      groups.insert(otherAt, group);
    }
    _librarySources[index] = _copySource(source, groups);
    notifyListeners();
    return null;
  }

  /// 分類を外す。中の画像は「その他」へ移し、移した枚数を返す。その他自体は外せない。
  int removeLibraryGroup({required String sourceId, required String groupId}) {
    final index = _librarySources.indexWhere((item) => item.id == sourceId);
    if (index < 0) return -1;
    final source = _librarySources[index];
    final targets = source.groups.where((group) => group.id == groupId);
    if (targets.isEmpty || isCatchAllGroup(targets.first)) return -1;
    final removed = targets.first;
    final displaced = [
      for (final image in removed.images) image.copyWith(clearComment: true),
    ];
    final groups = [
      for (final group in source.groups)
        if (group.id != groupId) group,
    ];
    if (displaced.isNotEmpty) {
      final otherAt = groups.indexWhere(isCatchAllGroup);
      if (otherAt < 0) {
        groups.add(
          LibraryGroup(
            id: _freshGroupId(source, 'その他'),
            label: _catchAllLabel(source),
            images: _numbered(displaced),
          ),
        );
      } else {
        final other = groups[otherAt];
        groups[otherAt] = LibraryGroup(
          id: other.id,
          label: other.label,
          images: _numbered([...other.images, ...displaced]),
        );
      }
    }
    if (groups.isEmpty) {
      _librarySources.removeAt(index);
    } else {
      _librarySources[index] = _copySource(source, groups);
    }
    notifyListeners();
    return displaced.length;
  }

  /// ファイル名ごとの分類結果で、同じソースの画像を振り直す。移した枚数を返す。
  int reclassifyLibrary({
    required String sourceId,
    required Map<String, String> categoryByName,
  }) {
    final index = _librarySources.indexWhere((item) => item.id == sourceId);
    if (index < 0 || categoryByName.isEmpty) return 0;
    final source = _librarySources[index];
    final wanted = <String, String>{};
    for (final entry in categoryByName.entries) {
      final name = entry.key.trim().toLowerCase();
      final category = entry.value.trim();
      if (name.isEmpty || category.isEmpty) continue;
      wanted[name] = category;
    }
    if (wanted.isEmpty) return 0;
    final shells = <LibraryGroup>[
      for (final group in source.groups)
        LibraryGroup(id: group.id, label: group.label, images: const []),
    ];
    final staying = <String, List<LibraryImage>>{
      for (final group in shells) group.id: <LibraryImage>[],
    };
    final incoming = <String, List<LibraryImage>>{};
    var moved = 0;
    for (final group in source.groups) {
      for (final image in group.images) {
        final category = wanted[image.name.trim().toLowerCase()];
        final target = category == null
            ? group
            : _ensureClassification(source, shells, incoming, category);
        final comment = isCatchAllGroup(target)
            ? null
            : (commentToken(target) ?? target.label);
        final next = image.copyWith(listComment: comment, clearComment: comment == null);
        if (target.id == group.id) {
          staying.putIfAbsent(target.id, () => []).add(next);
        } else {
          moved += 1;
          incoming.putIfAbsent(target.id, () => []).add(next);
        }
      }
    }
    if (moved == 0) return 0;
    _librarySources[index] = _copySource(source, [
      for (final group in shells)
        LibraryGroup(
          id: group.id,
          label: group.label,
          images: _numbered([
            ...staying[group.id] ?? const [],
            ...incoming[group.id] ?? const [],
          ]),
        ),
    ]);
    notifyListeners();
    return moved;
  }

  LibraryGroup _ensureClassification(
    LibrarySource source,
    List<LibraryGroup> shells,
    Map<String, List<LibraryImage>> incoming,
    String category,
  ) {
    final catchAll = category == 'その他';
    if (catchAll) {
      for (final group in shells) {
        if (isCatchAllGroup(group)) return group;
      }
    } else {
      for (final group in shells) {
        if (_sameClassification(group, category)) return group;
      }
    }
    final label = catchAll ? _catchAllLabel(source) : category;
    final created = LibraryGroup(
      id: _freshGroupId(
        LibrarySource(
          id: source.id,
          kind: source.kind,
          label: source.label,
          origin: source.origin,
          groups: shells,
        ),
        catchAll ? 'その他' : category,
      ),
      label: label,
      images: const [],
    );
    if (catchAll) {
      shells.add(created);
    } else {
      final otherAt = shells.indexWhere(isCatchAllGroup);
      if (otherAt < 0) {
        shells.add(created);
      } else {
        shells.insert(otherAt, created);
      }
    }
    incoming[created.id] = <LibraryImage>[];
    return created;
  }

  bool _sameClassification(LibraryGroup group, String label) {
    if (isCatchAllGroup(group) && label == 'その他') return true;
    final token = commentToken(group);
    final existing = (token ?? group.label).trim().toLowerCase();
    return existing == label.toLowerCase();
  }

  String _freshGroupId(LibrarySource source, String label) {
    final slug = label.toLowerCase().replaceAll(RegExp(r'\s+'), '-');
    final base = label == 'その他' ? '${source.id}:other' : '${source.id}:$slug';
    if (!source.groups.any((group) => group.id == base)) return base;
    var number = 2;
    while (source.groups.any((group) => group.id == '$base:$number')) {
      number += 1;
    }
    return '$base:$number';
  }

  String _catchAllLabel(LibrarySource source) {
    for (final group in source.groups) {
      final at = group.label.lastIndexOf(' / ');
      if (at > 0) return '${group.label.substring(0, at)} / その他';
    }
    return 'その他';
  }

  LibrarySource _copySource(LibrarySource source, List<LibraryGroup> groups) {
    return LibrarySource(
      id: source.id,
      kind: source.kind,
      label: source.label,
      origin: source.origin,
      zipCatalog: source.zipCatalog,
      truncated: source.truncated,
      groups: groups,
    );
  }

  /// 同じソースの別の分類へ画像を移す。移した画像は先の分類の末尾になり、番号は並び直す。
  void moveLibraryImage({
    required String imageId,
    required String sourceId,
    required String groupId,
  }) {
    final index = _librarySources.indexWhere((item) => item.id == sourceId);
    if (index < 0) return;
    final source = _librarySources[index];
    LibraryGroup? origin;
    LibraryImage? image;
    for (final group in source.groups) {
      for (final item in group.images) {
        if (item.id == imageId) {
          origin = group;
          image = item;
        }
      }
    }
    if (image == null || origin == null || origin.id == groupId) return;
    final targets = source.groups.where((group) => group.id == groupId);
    if (targets.isEmpty) return;
    final comment = _commentForGroup(targets.first);
    final moved = image.copyWith(listComment: comment, clearComment: comment == null);
    _librarySources[index] = LibrarySource(
      id: source.id,
      kind: source.kind,
      label: source.label,
      origin: source.origin,
      zipCatalog: source.zipCatalog,
      truncated: source.truncated,
      groups: [
        for (final group in source.groups)
          LibraryGroup(
            id: group.id,
            label: group.label,
            images: _numbered(
              group.id == groupId
                  ? [...group.images, moved]
                  : [
                      for (final item in group.images)
                        if (item.id != imageId) item,
                    ],
            ),
          ),
      ],
    );
    notifyListeners();
  }

  String? _commentForGroup(LibraryGroup group) {
    final token = commentToken(group);
    if (token != null) return token;
    final label = group.label.trim();
    if (label.isEmpty || label == 'その他') return null;
    return label;
  }

  List<LibraryImage> _numbered(List<LibraryImage> images) {
    return [
      for (var index = 0; index < images.length; index++)
        images[index].copyWith(listIndex: index + 1),
    ];
  }

  /// 一覧から画像を 1 枚外す。コメント分類は空でも残し、それ以外は空になったソースを外す。
  void removeLibraryImage(String imageId) {
    for (var index = 0; index < _librarySources.length; index++) {
      final source = _librarySources[index];
      final keepEmpty = sourceGroupsByComment(source);
      final nextGroups = <LibraryGroup>[];
      var removed = false;
      for (final group in source.groups) {
        final images = [
          for (final image in group.images)
            if (image.id != imageId) image,
        ];
        if (images.length != group.images.length) removed = true;
        if (images.isEmpty && !keepEmpty) continue;
        nextGroups.add(
          LibraryGroup(id: group.id, label: group.label, images: images),
        );
      }
      if (!removed) continue;
      if (nextGroups.isEmpty) {
        _librarySources.removeAt(index);
      } else {
        _librarySources[index] = LibrarySource(
          id: source.id,
          kind: source.kind,
          label: source.label,
          origin: source.origin,
          zipCatalog: source.zipCatalog,
          truncated: source.truncated,
          groups: nextGroups,
        );
      }
      if (_selectedLibraryImageId == imageId) {
        _selectedLibraryImageId = null;
      }
      notifyListeners();
      return;
    }
  }

  void removeLibrarySource(String id) {
    _librarySources.removeWhere((source) => source.id == id);
    if (_selectedLibraryImageId != null && selectedLibraryImage == null) {
      _selectedLibraryImageId = null;
    }
    notifyListeners();
  }

  void clearLibrary() {
    _librarySources.clear();
    _selectedLibraryImageId = null;
    notifyListeners();
  }

  void setLibraryImageIncluded(String imageId, bool included) {
    setLibraryImageIdsIncluded({imageId}, included: included);
  }

  /// 指定した画像の使用有無をまとめて変える。
  ///
  /// [onlyThese] のときは一致した画像だけを使い、それ以外は外す。
  void setLibraryImageIdsIncluded(
    Set<String> imageIds, {
    required bool included,
    bool onlyThese = false,
  }) {
    if (imageIds.isEmpty && !onlyThese) return;
    var changed = false;
    for (var index = 0; index < _librarySources.length; index++) {
      final source = _librarySources[index];
      _librarySources[index] = LibrarySource(
        id: source.id,
        kind: source.kind,
        label: source.label,
        origin: source.origin,
        zipCatalog: source.zipCatalog,
        truncated: source.truncated,
        groups: [
          for (final group in source.groups)
            LibraryGroup(
              id: group.id,
              label: group.label,
              images: [
                for (final image in group.images)
                  _withInclusion(
                    image,
                    imageIds.contains(image.id),
                    included: included,
                    onlyThese: onlyThese,
                    changed: () => changed = true,
                  ),
              ],
            ),
        ],
      );
    }
    if (changed) notifyListeners();
  }

  LibraryImage _withInclusion(
    LibraryImage image,
    bool hit, {
    required bool included,
    required bool onlyThese,
    required void Function() changed,
  }) {
    final next = onlyThese ? hit : (hit ? included : image.included);
    if (next == image.included) return image;
    changed();
    return image.copyWith(included: next);
  }

  void selectLibraryImage(String? id) {
    _selectedLibraryImageId = id;
    notifyListeners();
  }

  void selectFrame(String? id) {
    _selectedFrameId = id;
    notifyListeners();
  }

  void selectSlide(String? id) {
    _selectedSlideId = id;
    notifyListeners();
  }

  void setTemplates({String? title, String? caption}) {
    if (title != null) _titleTemplate = title;
    if (caption != null) _captionTemplate = caption;
    notifyListeners();
  }

  void setPreset(String preset) {
    _currentPreset = preset;
    notifyListeners();
  }

  void setSlidePreset(String slideId, String preset) {
    _slidePresets[slideId] = preset;
    notifyListeners();
  }

  void clearSlidePresets() {
    if (_slidePresets.isEmpty) return;
    _slidePresets.clear();
    notifyListeners();
  }

  int _parseSlideCount(String? json) {
    if (json == null) return 1;
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map && decoded['slides'] is List) {
        final count = (decoded['slides'] as List).length;
        if (count > 0) return count;
      }
    } on FormatException {
      return 1;
    }
    return 1;
  }
}
