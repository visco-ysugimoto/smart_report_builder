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

  WorkflowStep get step => _step;
  String? get projectDirectory => _projectDirectory;
  String? get projectPath => _projectPath;
  String? get layoutPath => _layoutPath;
  String? get pptxPath => _pptxPath;
  LayoutResult? get result => _result;
  String? get projectJson => _projectJson;
  bool get busy => _busy;
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
    notifyListeners();
  }

  void addLibrarySource(LibrarySource source) {
    _librarySources.removeWhere((item) => item.id == source.id);
    _librarySources.add(source);
    notifyListeners();
  }

  void removeLibrarySource(String id) {
    _librarySources.removeWhere((source) => source.id == id);
    if (_selectedLibraryImageId != null &&
        selectedLibraryImage == null) {
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
