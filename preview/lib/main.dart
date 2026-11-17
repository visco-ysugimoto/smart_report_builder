import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:smart_report_preview/image_library.dart';
import 'package:smart_report_preview/image_library_panel.dart';
import 'package:smart_report_preview/ordered_lists.dart';
import 'package:smart_report_preview/layout_path.dart';
import 'package:smart_report_preview/layout_result.dart';
import 'package:smart_report_preview/roi_geometry.dart';
import 'package:smart_report_preview/roi_links.dart';
import 'package:smart_report_preview/roi_persist.dart';
import 'package:smart_report_preview/slide_preview.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final initialPath = args.isNotEmpty ? args.first : defaultLayoutPath();
  runApp(PreviewApp(initialPath: initialPath));
}

class _TableCell {
  const _TableCell({
    required this.elementId,
    required this.row,
    required this.column,
    required this.text,
  });

  final String elementId;
  final int row;
  final int column;
  final String text;

  String get key => '$elementId:$row:$column';

  String get label => '${row + 1}行${column + 1}列 $text';
}

class PreviewApp extends StatelessWidget {
  const PreviewApp({required this.initialPath, super.key});

  final String initialPath;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Report Builder プレビュー',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: slideFrameColor),
        scaffoldBackgroundColor: const Color(0xFFF4F7FB),
      ),
      home: PreviewHome(initialPath: initialPath),
    );
  }
}

class PreviewHome extends StatefulWidget {
  const PreviewHome({required this.initialPath, super.key});

  final String initialPath;

  @override
  State<PreviewHome> createState() => _PreviewHomeState();
}

class _PreviewHomeState extends State<PreviewHome> {
  late final TextEditingController _path = TextEditingController(
    text: widget.initialPath,
  );
  final TextEditingController _roiName = TextEditingController();
  final TextEditingController _roiNote = TextEditingController();
  final TextEditingController _tableCell = TextEditingController();
  final TextEditingController _datasetName = TextEditingController();
  LayoutResult? _result;
  LayoutResult? _saved;
  String? _error;
  String? _status;
  String? _selectedRoiId;
  String? _zoomTargetId;
  Map<String, String?> _zoomByRoi = {};
  Map<String, String> _noteByRoi = {};
  Set<String> _manualNoteIds = {};
  String? _assignTargetId;
  String? _removeFrameId;
  String? _assetTargetId;
  String? _shareAssetId;
  List<RegisteredAsset> _unassignedAssets = [];
  List<AssignedAsset> _assignedAssets = [];
  List<AssignmentCandidate> _candidates = [];
  String? _candidateKey;
  List<AssetDataset> _datasets = [];
  String? _datasetId;
  List<LayoutProposal> _variants = [];
  String? _variantId;
  int _newImageCount = 2;
  String _newArrangement = 'horizontal';
  String _newTemplate = 'images';
  String _newPaper = '16x9';
  final TextEditingController _pageTitle = TextEditingController();
  final FocusNode _pageTitleFocus = FocusNode();
  final TextEditingController _finding = TextEditingController();
  final FocusNode _findingFocus = FocusNode();
  List<ReportPage> _pages = [];
  List<ReportLayoutOption> _layouts = [];
  String? _activePageId;
  String? _tableElementId;
  int? _tableRow;
  int? _tableColumn;
  bool _saving = false;
  bool _unsaved = false;
  bool _haveDocument = false;
  String? _documentJson;
  final List<LibrarySource> _librarySources = [];
  final Map<String, String> _materialized = {};
  Directory? _libraryTemp;
  String? _libraryImageId;
  String? _libraryMessage;
  bool _libraryLoading = false;
  int _librarySerial = 0;
  int _loadTicket = 0;
  LibrarySourceKind? _taskPickerKind;
  String? _taskPickerOrigin;
  final TextEditingController _taskGroup = TextEditingController(text: '1');
  final TextEditingController _taskNumber = TextEditingController(text: '1');
  final TextEditingController _ruleOffset = TextEditingController(text: '1');
  final TextEditingController _ruleStride = TextEditingController(text: '2');
  final TextEditingController _rulePerSlide = TextEditingController(text: '2');
  final TextEditingController _ruleNumbers = TextEditingController(text: '1,2');
  String _ruleMode = 'pattern';
  bool _pinThisSlide = false;
  final Map<String, TextEditingController> _frameItems = {};
  final Map<String, String> _frameLists = {};
  String _orderedGroup = '';
  String _orderedTask = '';
  String _orderedList = '';
  List<OrderedCandidate> _orderedCandidates = [];
  List<String> _orderedWarnings = [];

  @override
  void initState() {
    super.initState();
    reportLayoutReady = _onReportLayoutReady;
    _pageTitleFocus.addListener(() {
      if (!_pageTitleFocus.hasFocus) {
        _onSavePageTitle();
      }
    });
    _findingFocus.addListener(() {
      if (!_findingFocus.hasFocus) {
        _onSaveFinding();
      }
    });
    _finding.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
    _load();
  }

  @override
  void dispose() {
    if (reportLayoutReady == _onReportLayoutReady) {
      reportLayoutReady = null;
    }
    final temp = _libraryTemp;
    if (temp != null) {
      try {
        temp.deleteSync(recursive: true);
      } on FileSystemException {
        // 一時ファイルが残っても、次に開いたときには使いません。
      }
    }
    _path.dispose();
    _roiName.dispose();
    _roiNote.dispose();
    _tableCell.dispose();
    _datasetName.dispose();
    _taskGroup.dispose();
    _taskNumber.dispose();
    _ruleOffset.dispose();
    _ruleStride.dispose();
    _rulePerSlide.dispose();
    _ruleNumbers.dispose();
    for (final controller in _frameItems.values) {
      controller.dispose();
    }
    _pageTitle.dispose();
    _pageTitleFocus.dispose();
    _finding.dispose();
    _findingFocus.dispose();
    reportSession.close();
    super.dispose();
  }

  void _onReportLayoutReady(String layoutPath) {
    if (!mounted || layoutPath != _path.text.trim()) {
      return;
    }
    _load();
  }

  Future<void> _onOpen() async {
    if (_saving) {
      return;
    }
    final current = _path.text.trim();
    final parent = current.isEmpty ? null : File(current).parent;
    final initialDirectory = parent != null && parent.existsSync() ? parent.path : null;
    setState(() {
      _status = 'ファイルを選択しています';
      _error = null;
    });
    String? selected;
    try {
      selected = await pickPreviewFile(initialDirectory: initialDirectory);
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    }
    if (!mounted) {
      return;
    }
    if (selected == null) {
      setState(() => _status = null);
      return;
    }
    if (!reportSession.covers(selected) && !await _resolveUnsaved()) {
      if (mounted) {
        setState(() => _status = null);
      }
      return;
    }
    _path.text = selected;
    await _load();
  }

  Future<bool> _resolveUnsaved() async {
    if (!_unsaved) {
      return true;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('未保存の変更'),
          content: const Text('保存していない変更があります。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'discard'),
              child: const Text('破棄'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'save'),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    if (!mounted) {
      return false;
    }
    if (choice == 'save') {
      await _onSave();
      return !_unsaved;
    }
    if (choice == 'discard') {
      reportSession.forgetSnapshot();
      setState(() => _unsaved = false);
      return true;
    }
    return false;
  }

  Future<void> _onSubmitPath() async {
    final next = _path.text.trim();
    if (reportSession.covers(next)) {
      await _load();
      return;
    }
    if (!await _resolveUnsaved()) {
      final opened = reportSession.openedLayoutPath;
      if (opened != null && mounted) {
        _path.text = opened;
      }
      return;
    }
    await _load();
  }

  Future<void> _onSave() async {
    if (_saving || !_unsaved) {
      return;
    }
    setState(() {
      _saving = true;
      _status = '保存しています';
      _error = null;
    });
    try {
      await reportSession.save();
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _unsaved = reportSession.dirty;
      _status = 'プロジェクトと PPTX を保存しました。';
    });
  }

  Future<void> _load() async {
    final ticket = ++_loadTicket;
    var filePath = _path.text.trim();
    if (filePath.length >= 2 && filePath.startsWith('"') && filePath.endsWith('"')) {
      filePath = filePath.substring(1, filePath.length - 1);
    }
    var useMemory = false;
    try {
      if (filePath.toLowerCase().endsWith('.pptx')) {
        if (mounted) {
          setState(() {
            _status = 'PPTX を読み込んでいます';
            _error = null;
          });
        }
        filePath = await _layoutForPptx(filePath);
        if (!mounted || ticket != _loadTicket) {
          return;
        }
        _path.text = filePath;
      }
      useMemory = reportSession.covers(filePath);
      final file = File(filePath);
      if (!useMemory && !file.existsSync()) {
        throw const FormatException('配置ファイルが見つからない');
      }
      _haveDocument = true;
      _documentJson = useMemory
          ? reportSession.projectJson
          : await _readProjectFile(filePath);
      final result = parseLayoutResult(
        useMemory ? reportSession.layoutJson! : await file.readAsString(),
      );
      final links = await _readZoomLinks(filePath);
      final notes = await _readRoiNotes(filePath);
      final manualNotes = await _readManualNoteIds(filePath);
      final unassignedAssets = await _readUnassignedAssets(filePath);
      final assignedAssets = await _readAssignedAssets(filePath);
      final candidates = await _readCandidates(filePath);
      final datasets = await _readDatasets(filePath);
      final pages = await _readReportPages(filePath);
      if (!mounted || ticket != _loadTicket) {
        return;
      }
      setState(() {
        _result = result;
        _saved = result;
        _zoomByRoi = links;
        _noteByRoi = notes;
        _manualNoteIds = manualNotes;
        _zoomTargetId = _keptZoomTarget(result, links);
        _assignTargetId = _keptAssignTarget(result);
        _removeFrameId = _keptRemoveTarget(result);
        _unassignedAssets = unassignedAssets;
        _assetTargetId = _keptAssetTarget(unassignedAssets);
        _assignedAssets = assignedAssets;
        _shareAssetId = _keptShareTarget(assignedAssets);
        _candidates = candidates;
        _candidateKey = _keptCandidate(candidates);
        _orderedCandidates = [];
        _orderedWarnings = [];
        _datasets = datasets;
        _datasetId = _keptDataset(datasets);
        _pages = pages.pages;
        _layouts = pages.layouts;
        _activePageId = pages.activeId;
        _variants = [];
        _variantId = null;
        _error = null;
        _unsaved = useMemory && reportSession.dirty;
        if (!_hasRoi(result, _selectedRoiId)) {
          _selectedRoiId = null;
        }
      });
      _applyRoiNameField(result);
      _applyRoiNoteField();
      _applyTableCellField(result);
      _applyPageTitle(result);
      _applyFinding(result);
      if (!useMemory) {
        await _syncSession(filePath, ticket);
      }
    } on FormatException catch (error) {
      if (!mounted || ticket != _loadTicket) {
        return;
      }
      setState(() {
        _result = null;
        _saved = null;
        _selectedRoiId = null;
        _zoomTargetId = null;
        _assignTargetId = null;
        _removeFrameId = null;
        _assetTargetId = null;
        _shareAssetId = null;
        _zoomByRoi = {};
        _noteByRoi = {};
        _manualNoteIds = {};
        _unassignedAssets = [];
        _assignedAssets = [];
        _candidates = [];
        _candidateKey = null;
        _datasets = [];
        _datasetId = null;
        _pages = [];
        _layouts = [];
        _activePageId = null;
        _variants = [];
        _variantId = null;
        _unsaved = false;
        _error = error.message;
      });
      if (useMemory) {
        reportSession.forgetSnapshot();
      }
      _applyRoiNameField(null);
      _applyRoiNoteField();
      _applyTableCellField(null);
    } finally {
      _haveDocument = false;
      _documentJson = null;
    }
  }

  Future<String?> _readProjectFile(String layoutPath) async {
    final projectPath = projectPathForLayout(layoutPath);
    if (projectPath == null) {
      return null;
    }
    final file = File(projectPath);
    if (!file.existsSync()) {
      return null;
    }
    return file.readAsString();
  }

  Future<String?> _projectDocument(String layoutPath) async {
    if (_haveDocument) {
      return _documentJson;
    }
    return _readProjectFile(layoutPath);
  }

  Future<void> _syncSession(String layoutPath, int ticket) async {
    final python = pythonExecutableNearLayout(layoutPath);
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    if (python == null || projectPath == null || pptxPath == null) {
      return;
    }
    if (!File(projectPath).existsSync()) {
      return;
    }
    try {
      await reportSession.open(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
      );
    } on FormatException catch (error) {
      if (!mounted || ticket != _loadTicket) {
        return;
      }
      setState(() => _error = error.message);
      return;
    }
    if (!mounted || ticket != _loadTicket) {
      return;
    }
    setState(() => _unsaved = reportSession.dirty);
  }

  Future<void> _onNewProjectDialog() async {
    if (_saving) {
      return;
    }
    final created = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            return AlertDialog(
              title: const Text('新規プロジェクト'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButton<String>(
                    key: const Key('new-paper'),
                    value: _newPaper,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: '16x9', child: Text('16:9')),
                      DropdownMenuItem(value: 'portrait', child: Text('評価レポート縦')),
                      DropdownMenuItem(value: 'landscape', child: Text('評価レポート横')),
                    ],
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() => _newPaper = value);
                      setLocal(() {});
                    },
                  ),
                  DropdownButton<String>(
                    key: const Key('new-template'),
                    value: _newTemplate,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: 'images', child: Text('画像と説明')),
                      DropdownMenuItem(value: 'overall-zoom', child: Text('全体と拡大')),
                    ],
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() => _newTemplate = value);
                      setLocal(() {});
                    },
                  ),
                  if (_newTemplate == 'images')
                    DropdownButton<int>(
                      key: const Key('new-image-count'),
                      value: _newImageCount,
                      isExpanded: true,
                      items: const [
                        DropdownMenuItem(value: 2, child: Text('2枚')),
                        DropdownMenuItem(value: 3, child: Text('3枚')),
                        DropdownMenuItem(value: 4, child: Text('4枚')),
                      ],
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setState(() => _newImageCount = value);
                        setLocal(() {});
                      },
                    ),
                  DropdownButton<String>(
                    key: const Key('new-arrangement'),
                    value: _newArrangement,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: 'horizontal', child: Text('横')),
                      DropdownMenuItem(value: 'vertical', child: Text('縦')),
                      DropdownMenuItem(value: 'grid', child: Text('格子')),
                    ],
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() => _newArrangement = value);
                      setLocal(() {});
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('キャンセル'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('作成'),
                ),
              ],
            );
          },
        );
      },
    );
    if (created == true && mounted) {
      await _onNewProject();
    }
  }

  Future<String?> _askText({
    required String title,
    required TextEditingController controller,
    String confirm = '保存',
  }) async {
    final original = controller.text;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            onSubmitted: (_) => Navigator.pop(context, true),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirm),
            ),
          ],
        );
      },
    );
    if (accepted != true) {
      controller.text = original;
      return null;
    }
    return controller.text;
  }

  Future<void> _editRoiName() async {
    if (await _askText(title: 'ROIの名前', controller: _roiName) == null) {
      return;
    }
    await _onRoiRename();
  }

  Future<void> _editRoiNote() async {
    if (await _askText(title: 'ROIの注釈', controller: _roiNote) == null) {
      return;
    }
    await _onSaveNote();
  }

  Future<void> _editTableCell() async {
    if (await _askText(title: 'セルの文字', controller: _tableCell) == null) {
      return;
    }
    await _onSaveTableCell();
  }

  Future<void> _promptDataset() async {
    final name = TextEditingController();
    final entered = await _askText(title: 'グループ名', controller: name, confirm: '作成');
    if (entered == null || !mounted) {
      name.dispose();
      return;
    }
    _datasetName.text = entered;
    name.dispose();
    await _onCreateDataset();
  }

  Future<void> _pickVariant() async {
    await _onShowVariants();
    if (!mounted || _variants.length < 2) {
      return;
    }
    final id = await showDialog<String>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: const Text('レイアウト案'),
          children: [
            for (final item in _variants)
              if (!item.selected)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, item.id),
                  child: Text('${item.name}: ${item.reason}'),
                ),
          ],
        );
      },
    );
    if (id == null || !mounted) {
      return;
    }
    setState(() => _variantId = id);
    await _onApplyVariant();
  }

  Future<void> _onNewProject() async {
    if (_saving) {
      return;
    }
    final python = pythonExecutableNearLayout(_path.text.trim());
    if (python == null) {
      setState(() => _error = 'Python が見つからないため、プロジェクトを作成できません');
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    if (projectPath != null &&
        pptxPath != null &&
        File(projectPath).existsSync()) {
      await _addLayout(python, projectPath, layoutPath, pptxPath);
      return;
    }
    if (!await _resolveUnsaved()) {
      return;
    }
    String? directory;
    try {
      directory = await pickFolder();
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.message);
      return;
    }
    if (directory == null || !mounted) {
      return;
    }
    setState(() {
      _saving = true;
      _status = '作成しています';
      _error = null;
    });
    try {
      await createReportProject(
        pythonExecutable: python,
        directory: directory,
        imageCount: _newImageCount,
        arrangement: _newArrangement,
        template: _newTemplate,
        paper: _newPaper,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    final separator = Platform.pathSeparator;
    _path.text = '$directory$separator' 'layout.json';
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(
      () => _status = '新しいプロジェクトを作りました。画像はまだ割り当てていません。',
    );
  }

  Future<void> _addLayout(
    String python,
    String projectPath,
    String layoutPath,
    String pptxPath,
  ) async {
    setState(() {
      _saving = true;
      _status = 'レイアウトを追加しています';
      _error = null;
    });
    try {
      await addReportLayout(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        imageCount: _newImageCount,
        arrangement: _newArrangement,
        template: _newTemplate,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(
      () => _status = 'レイアウトを追加し、それを使うスライドを足しました。${_pages.length} 枚あります。',
    );
  }

  Future<void> _onActivatePage(String? pageId) async {
    if (pageId == null || pageId == _activePageId || _saving) {
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、スライドを切り替えられません');
      return;
    }
    setState(() {
      _saving = true;
      _status = null;
      _error = null;
    });
    try {
      await activateReportLayout(
        pythonExecutable: python,
        projectPath: projectPath,
        pageId: pageId,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(() => _status = '表示するスライドを切り替えました。');
  }

  Future<void> _onRemovePage() async {
    if (_saving || _pages.length < 2) {
      return;
    }
    final pageId = _pages.any((page) => page.id == _activePageId)
        ? _activePageId!
        : _pages[_shownPageIndex].id;
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、スライドを削除できません');
      return;
    }
    setState(() {
      _saving = true;
      _status = null;
      _error = null;
    });
    try {
      await removeReportLayout(
        pythonExecutable: python,
        projectPath: projectPath,
        pageId: pageId,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(
      () => _status = 'スライドを削除しました。同じプロジェクトに ${_pages.length} 枚あります。',
    );
  }

  int get _shownPageIndex {
    final index = _pages.indexWhere((page) => page.id == _activePageId);
    return index < 0 ? 0 : index;
  }

  Widget _layoutSwitcher() {
    final index = _shownPageIndex;
    final selected = _pages.any((page) => page.id == _activePageId)
        ? _activePageId
        : _pages.first.id;
    final layoutId = _shownLayoutId();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          DropdownButton<String>(
            key: const Key('layout-page'),
            value: selected,
            items: [
              for (var number = 0; number < _pages.length; number++)
                DropdownMenuItem(
                  value: _pages[number].id,
                  child: Text(
                    '${number + 1}. ${_pages[number].name}（${_layoutName(_pages[number].layoutId)}）',
                  ),
                ),
            ],
            onChanged: _saving || _pages.length < 2 ? null : _onActivatePage,
          ),
          Text(
            '${index + 1} / ${_pages.length}',
            key: const Key('layout-page-count'),
          ),
          DropdownButton<String>(
            key: const Key('slide-layout'),
            value: layoutId,
            items: [
              for (final layout in _layouts)
                DropdownMenuItem(
                  value: layout.id,
                  child: Text(layout.name),
                ),
            ],
            onChanged: _saving || _layouts.length < 2 ? null : _onSetSlideLayout,
          ),
        ],
      ),
    );
  }

  String _layoutName(String layoutId) {
    for (final layout in _layouts) {
      if (layout.id == layoutId) {
        return layout.name;
      }
    }
    return layoutId;
  }

  String? _shownLayoutId() {
    if (_pages.isEmpty) {
      return null;
    }
    final slide = _pages[_shownPageIndex];
    if (_layouts.any((layout) => layout.id == slide.layoutId)) {
      return slide.layoutId;
    }
    if (_layouts.isEmpty) {
      return null;
    }
    return _layouts.first.id;
  }

  Future<void> _openPreviewMenu(
    LayoutResult result,
    Offset slidePoint,
    Offset global,
  ) async {
    if (_saving || !mounted) {
      return;
    }
    final hit = previewHitAt(result, slidePoint.dx, slidePoint.dy);
    setState(() {
      if (hit?.kind == 'roi') {
        _selectedRoiId = hit!.elementId;
        final linked = _zoomByRoi[hit.elementId];
        if (_zoomFrames(result).any((frame) => frame.elementId == linked)) {
          _zoomTargetId = linked;
        }
      } else if (hit?.kind == 'image_frame') {
        _removeFrameId = hit!.elementId;
        if (hit.fitMode == 'contain') {
          _assignTargetId = hit.elementId;
        }
      } else if (hit?.kind == 'table') {
        _selectTableCellAt(hit!, slidePoint);
      }
    });
    if (hit?.kind == 'table') {
      _applyTableCellField(result);
    }
    _applyRoiNameField(result);
    _applyRoiNoteField();
    final items = _previewMenuItems(result, hit);
    if (items.isEmpty || !mounted) {
      return;
    }
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final menuPoint = overlay.globalToLocal(global);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(menuPoint.dx, menuPoint.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
    if (action == null || !mounted || _saving) {
      return;
    }
    await _runPreviewAction(action);
  }

  List<PopupMenuEntry<String>> _previewMenuItems(
    LayoutResult result,
    PlacedElement? hit,
  ) {
    final items = <PopupMenuEntry<String>>[];
    void add(String id, String label) {
      items.add(PopupMenuItem(value: id, child: Text(label)));
    }

    if (_canUndo()) {
      add('undo', '元に戻す');
    }
    if (_canRedo()) {
      add('redo', 'やり直す');
    }
    if (hit == null) {
      if (items.isNotEmpty) {
        items.add(const PopupMenuDivider());
      }
      add('add-slide', 'スライドを追加');
      add('layout|images|2|horizontal', 'レイアウトを追加: 画像2枚 横');
      add('layout|images|2|vertical', 'レイアウトを追加: 画像2枚 縦');
      add('layout|images|4|grid', 'レイアウトを追加: 画像4枚 格子');
      add('layout|overall-zoom|2|horizontal', 'レイアウトを追加: 全体と拡大');
      add('add-frame', '画像枠を追加');
      add('add-table', '表を追加');
      add('register-folder', 'フォルダから登録');
      add('variants', 'レイアウト案');
      if (_unassignedAssets.isNotEmpty) {
        add('dataset', '未割当をグループにする');
        for (final asset in _unassignedAssets) {
          add('drop-asset|${asset.id}', '記録を削除: ${asset.name}');
        }
      }
      final dataset = _chosenDataset() ??
          (_datasets.isEmpty ? null : _datasets.first);
      if (dataset != null) {
        for (final asset in _unassignedAssets) {
          if (!dataset.contains(asset.id)) {
            add(
              'dataset-add|${dataset.id}|${asset.id}',
              '${asset.name}を${dataset.name}へ',
            );
          }
        }
        for (final assetId in dataset.assetIds) {
          add(
            'dataset-remove|${dataset.id}|$assetId',
            '${_assetName(assetId)}をグループから外す',
          );
        }
      }
      if (_candidates.any((item) => item.canAcceptAll)) {
        add('accept-ready', '確定候補をすべて採用');
      }
      for (final candidate in _candidates) {
        add(
          'candidate|${candidate.key}',
          assignmentCandidateLabel(
            candidate,
            frameName: _frameName(candidate.frameId),
          ),
        );
      }
      if (_pages.length >= 2) {
        add('remove-slide', 'このスライドを削除');
      }
    } else if (hit.kind == 'image_frame') {
      items.add(const PopupMenuDivider());
      for (final kind in const [
        ('image', '画像'),
        ('overall', '全体画像'),
        ('comparison', '比較画像'),
        ('zoom', '拡大'),
      ]) {
        if (imageFrameKind(hit) == kind.$1) {
          continue;
        }
        add('kind|${kind.$1}', '種類を${kind.$2}にする');
      }
      if (hit.fitMode == 'contain') {
        add('assign-file', '画像ファイルを割り当て');
        if (_selectedLibraryImage != null) {
          add('assign-library', '一覧で選んだ画像を割り当て');
        }
        if (_canUnassign(result)) {
          add('unassign', '割当を外す');
        }
        for (final asset in _assignedAssets) {
          add('share|${asset.id}', '共有: ${asset.name}');
        }
        for (final asset in _unassignedAssets) {
          add('use-asset|${asset.id}', '未割当を入れる: ${asset.name}');
        }
      }
      add('remove-frame', 'この枠を削除');
    } else if (hit.kind == 'roi') {
      items.add(const PopupMenuDivider());
      add('roi-duplicate', '複製');
      add('roi-delete', '削除');
      add('roi-rename', '名前を変更');
      add('roi-note', '注釈を編集');
      if (_canResetNote()) {
        add('roi-note-reset', '注釈を自動位置へ');
      }
      final linkedTarget = _chosenZoomTarget(result);
      if (_canLink(result) && linkedTarget != null) {
        add('link|$linkedTarget', '拡大へ連動');
      }
      for (final frame in _zoomFrames(result)) {
        if (frame.elementId == linkedTarget) {
          continue;
        }
        add('link|${frame.elementId}', '拡大へ連動: ${frame.displayName}');
      }
      if (_canUnlink(result)) {
        add('unlink', '連動を外す');
      }
      if (_hasAnyRoi(result)) {
        add('arrange|horizontal', '拡大画像を横に並べる');
        add('arrange|vertical', '拡大画像を縦に並べる');
        add('arrange|grid', '拡大画像を格子に並べる');
      }
      add('capture-master', 'ROIをマスターに');
      add('apply-master', 'マスターをこの枠へ');
    } else if (hit.kind == 'table') {
      items.add(const PopupMenuDivider());
      add('add-row', '行を追加');
      add('add-column', '列を追加');
      if (_chosenTableCellKey(result) != null) {
        add('edit-cell', 'セルを編集');
      }
    }
    return items;
  }

  Future<void> _runPreviewAction(String action) async {
    final parts = action.split('|');
    switch (parts.first) {
      case 'undo':
        await _onUndo();
      case 'redo':
        await _onRedo();
      case 'add-slide':
        await _onAddSlide();
      case 'remove-slide':
        await _onRemovePage();
      case 'layout':
        setState(() {
          _newTemplate = parts[1];
          _newImageCount = int.parse(parts[2]);
          _newArrangement = parts[3];
        });
        await _onNewProject();
      case 'add-frame':
        await _onAddImageFrame();
      case 'add-table':
        await _onAddTable();
      case 'add-row':
        await _onAddTableRow();
      case 'add-column':
        await _onAddTableColumn();
      case 'edit-cell':
        await _editTableCell();
      case 'register-folder':
        await _onRegisterFolder();
      case 'variants':
        await _pickVariant();
      case 'dataset':
        await _promptDataset();
      case 'dataset-add':
        setState(() {
          _datasetId = parts[1];
          _assetTargetId = parts[2];
        });
        await _onAddDatasetAsset();
      case 'dataset-remove':
        setState(() {
          _datasetId = parts[1];
          _assetTargetId = parts[2];
        });
        await _onRemoveDatasetAsset();
      case 'kind':
        await _onFrameKind(parts[1]);
      case 'assign-file':
        await _onAssignImage();
      case 'assign-library':
        final image = _selectedLibraryImage;
        if (image != null) {
          await _onAssignLibraryImage(image);
        }
      case 'unassign':
        await _onUnassignImage();
      case 'remove-frame':
        await _onRemoveImageFrame(_chosenRemoveTarget(_result));
      case 'share':
        setState(() => _shareAssetId = parts[1]);
        await _onShareRegisteredAsset();
      case 'use-asset':
        setState(() => _assetTargetId = parts[1]);
        await _onAssignRegisteredAsset();
      case 'drop-asset':
        setState(() => _assetTargetId = parts[1]);
        await _onRemoveUnusedAsset();
      case 'accept-ready':
        await _onAcceptReady();
      case 'candidate':
        setState(() => _candidateKey = parts[1]);
        await _onApplyCandidate();
      case 'roi-duplicate':
        await _onRoiDuplicate();
      case 'roi-delete':
        await _onRoiDelete();
      case 'roi-rename':
        await _editRoiName();
      case 'roi-note':
        await _editRoiNote();
      case 'roi-note-reset':
        await _onResetNote();
      case 'link':
        setState(() => _zoomTargetId = parts[1]);
        await _onRoiZoom(true);
      case 'unlink':
        await _onRoiZoom(false);
      case 'arrange':
        setState(() => _newArrangement = parts[1]);
        await _onArrangeZooms();
      case 'capture-master':
        await _onCaptureMaster();
      case 'apply-master':
        await _onApplyMaster();
    }
  }

  Future<void> _onAddSlide() async {
    if (_saving || !_hasOpenProject()) {
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、スライドを追加できません');
      return;
    }
    setState(() {
      _saving = true;
      _status = 'スライドを追加しています';
      _error = null;
    });
    try {
      await addReportSlide(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(
      () => _status = 'スライドを追加しました。表示中のレイアウトを共有し、画像と ROI は空です。',
    );
  }

  Future<void> _onSetSlideLayout(String? layoutId) async {
    final slideId = _pages.any((page) => page.id == _activePageId)
        ? _activePageId
        : (_pages.isEmpty ? null : _pages[_shownPageIndex].id);
    if (layoutId == null || slideId == null || _saving) {
      return;
    }
    final slide = _pages.where((page) => page.id == slideId);
    if (slide.isNotEmpty && slide.first.layoutId == layoutId) {
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、レイアウトを割り当てられません');
      return;
    }
    setState(() {
      _saving = true;
      _status = 'スライドのレイアウトを変えています';
      _error = null;
    });
    try {
      await setReportSlideLayout(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        slideId: slideId,
        layoutId: layoutId,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(() => _status = 'このスライドのレイアウトを変えました。');
  }

  Future<String> _layoutForPptx(String pptxPath) async {
    final existing = existingLayoutForPptx(pptxPath);
    if (existing != null) {
      return existing;
    }
    final directory = previewDirectoryForPptx(pptxPath);
    final python = pythonExecutableNearLayout(pptxPath) ??
        pythonExecutableNearLayout(Directory.current.path);
    if (python == null) {
      throw const FormatException('Python が見つからないため、PPTX をプレビューできません');
    }
    await openPptxPreview(
      pythonExecutable: python,
      pptxPath: pptxPath,
      directory: directory,
    );
    final separator = Platform.pathSeparator;
    return '$directory${separator}layout.json';
  }

  bool _hasOpenProject() {
    final projectPath = projectPathForLayout(_path.text.trim());
    return projectPath != null && File(projectPath).existsSync();
  }

  Future<ReportPages> _readReportPages(String layoutPath) async {
    final text = await _projectDocument(layoutPath);
    if (text == null) {
      return const ReportPages(pages: [], layouts: []);
    }
    return parseReportPages(text);
  }

  void _onNoteFrameChanged(String roiId, SlideRect frame) {}

  Future<void> _onNoteFrameCommitted(String roiId, SlideRect frame) async {
    final saved = _saved;
    if (saved == null || _saving) {
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() {
        _result = saved;
        _error = '保存先が見つからないため、注釈の位置を保存できません';
      });
      return;
    }
    setState(() {
      _saving = true;
      _status = '保存しています';
      _error = null;
    });
    try {
      await placeRoiNote(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        roiId: roiId,
        frame: frame,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _result = _saved;
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _result = _saved;
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(() => _status = '注釈の位置を保存しました。文字と ROI の矩形は変えていません。');
  }

  void _onRoiFrameChanged(String roiId, SlideRect frame) {}

  Future<void> _onRoiFrameCommitted(String roiId, SlideRect frame) async {
    final saved = _saved;
    if (saved == null || _saving) {
      return;
    }
    final source = _contentRect(saved, _sourceId(saved, roiId));
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (source == null ||
        projectPath == null ||
        pptxPath == null ||
        python == null) {
      setState(() {
        _result = saved;
        _error = '保存先または元画像が見つからないため、移動を取り消しました';
      });
      return;
    }
    setState(() {
      _saving = true;
      _status = '保存しています';
      _error = null;
    });
    try {
      await persistNormalizedRoi(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        roiId: roiId,
        normalized: normalizedRoi(frame, source),
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _result = _saved;
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _result = _saved;
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(() => _status = 'ROI をプロジェクトへ保存しました');
  }

  Future<void> _onRoiCreated(String sourceId, SlideRect frame) async {
    final saved = _saved;
    if (saved == null || _saving) {
      return;
    }
    final source = _contentRect(saved, sourceId);
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (source == null ||
        projectPath == null ||
        pptxPath == null ||
        python == null) {
      setState(() => _error = '保存先または元画像が見つからないため、ROIを追加できません');
      return;
    }
    setState(() {
      _saving = true;
      _status = '保存しています';
      _error = null;
    });
    late final String zoomLabel;
    try {
      zoomLabel = await createNormalizedRoi(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        sourceElementId: sourceId,
        normalized: normalizedRoi(frame, source),
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(() => _status = _createdStatus(zoomLabel));
  }

  Future<Map<String, String?>> _readZoomLinks(String layoutPath) async {
    final text = await _projectDocument(layoutPath);
    if (text == null) {
      return {};
    }
    return parseRoiZoomLinks(text);
  }

  Future<Map<String, String>> _readRoiNotes(String layoutPath) async {
    final text = await _projectDocument(layoutPath);
    if (text == null) {
      return {};
    }
    return parseRoiNotes(text);
  }

  Future<Set<String>> _readManualNoteIds(String layoutPath) async {
    final text = await _projectDocument(layoutPath);
    if (text == null) {
      return {};
    }
    return parseManualNoteIds(text);
  }

  Future<List<RegisteredAsset>> _readUnassignedAssets(String layoutPath) async {
    final text = await _projectDocument(layoutPath);
    if (text == null) {
      return [];
    }
    return parseUnassignedAssets(text);
  }

  Future<List<AssignedAsset>> _readAssignedAssets(String layoutPath) async {
    final text = await _projectDocument(layoutPath);
    if (text == null) {
      return [];
    }
    return parseAssignedAssets(text);
  }

  Future<List<AssignmentCandidate>> _readCandidates(String layoutPath) async {
    final python = pythonExecutableNearLayout(layoutPath);
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    if (python != null &&
        projectPath != null &&
        pptxPath != null &&
        File(projectPath).existsSync()) {
      if (!reportSession.covers(layoutPath)) {
        await reportSession.open(
          pythonExecutable: python,
          projectPath: projectPath,
          layoutPath: layoutPath,
          pptxPath: pptxPath,
        );
      }
      return listAssignmentCandidates(
        pythonExecutable: python,
        projectPath: projectPath,
      );
    }
    final text = await _projectDocument(layoutPath);
    if (text == null) {
      return [];
    }
    return parseAssignmentCandidates(text);
  }

  Future<List<AssetDataset>> _readDatasets(String layoutPath) async {
    final text = await _projectDocument(layoutPath);
    if (text == null) {
      return [];
    }
    return parseDatasets(text);
  }

  Future<void> _onRoiZoom(bool linked) async {
    final saved = _saved;
    final roiId = _selectedRoiId;
    if (saved == null || roiId == null || _saving || !_hasRoi(saved, roiId)) {
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、拡大枠の連動を変更できません');
      return;
    }
    setState(() {
      _saving = true;
      _status = '保存しています';
      _error = null;
    });
    late final ZoomUpdate update;
    try {
      update = await setRoiZoom(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        roiId: roiId,
        linked: linked,
        zoomElementId: linked ? _zoomTargetId : null,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(
      () =>
          _status = linked ? _linkStatus(update) : '拡大枠との連動を外しました。ROI の枠は残します。',
    );
  }

  bool _canUndo() {
    final snapshot = undoPathForProject(
      projectPathForLayout(_path.text.trim()),
    );
    return snapshot != null && File(snapshot).existsSync();
  }

  Future<void> _onUndo() async {
    if (_saving || !_canUndo()) {
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、ROIの操作を戻せません');
      return;
    }
    setState(() {
      _saving = true;
      _status = '元に戻しています';
      _error = null;
    });
    try {
      await undoLastRoiEdit(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(() => _status = '直前の ROI 操作を元に戻しました。');
  }

  bool _canRedo() {
    final snapshot = redoPathForProject(
      projectPathForLayout(_path.text.trim()),
    );
    return snapshot != null && File(snapshot).existsSync();
  }

  Future<void> _onRedo() async {
    if (_saving || !_canRedo()) {
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、ROIの操作をやり直せません');
      return;
    }
    setState(() {
      _saving = true;
      _status = 'やり直しています';
      _error = null;
    });
    try {
      await redoLastRoiEdit(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(() => _status = '元に戻した ROI 操作をやり直しました。');
  }

  Future<void> _onRoiDuplicate() async {
    final saved = _saved;
    final roiId = _selectedRoiId;
    if (saved == null || roiId == null || _saving || !_hasRoi(saved, roiId)) {
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、ROIを複製できません');
      return;
    }
    setState(() {
      _saving = true;
      _status = '複製しています';
      _error = null;
    });
    late final DuplicateResult created;
    try {
      created = await duplicateRoi(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        roiId: roiId,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    _selectedRoiId = created.roiId;
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(
      () => _status = created.shifted
          ? 'ROI を複製しました。右下へ少しずらし、拡大枠の連動はコピーしていません。'
          : 'ROI を複製しました。ずらす余地がないため同じ位置に重ね、拡大枠の連動はコピーしていません。',
    );
  }

  Future<void> _onRoiDelete() async {
    final saved = _saved;
    final roiId = _selectedRoiId;
    if (saved == null || roiId == null || _saving || !_hasRoi(saved, roiId)) {
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、ROIを削除できません');
      return;
    }
    setState(() {
      _saving = true;
      _status = '削除しています';
      _error = null;
    });
    try {
      await deleteRoi(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        roiId: roiId,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(() => _status = 'ROI を削除しました。拡大に使っていた場合は、その拡大枠も空に戻します。');
  }

  void _onRoiEditCancelled() {
    final saved = _saved;
    if (saved == null || _saving) {
      return;
    }
    setState(() => _result = saved);
  }

  LibraryImage? get _selectedLibraryImage {
    final id = _libraryImageId;
    if (id == null) {
      return null;
    }
    for (final source in _librarySources) {
      for (final group in source.groups) {
        for (final image in group.images) {
          if (image.id == id) {
            return image;
          }
        }
      }
    }
    return null;
  }

  LibrarySource? _librarySourceById(String sourceId) {
    for (final source in _librarySources) {
      if (source.id == sourceId) {
        return source;
      }
    }
    return null;
  }

  String _nextLibraryId() {
    final id = 'lib-$_librarySerial';
    _librarySerial += 1;
    return id;
  }

  void _putLibrarySource(LibrarySource source) {
    if (source.kind != LibrarySourceKind.files) {
      final previous = [
        for (final item in _librarySources)
          if (item.kind == source.kind && item.origin == source.origin) item,
      ];
      for (final item in previous) {
        _dropMaterialized(item);
      }
      _librarySources.removeWhere(
        (item) => item.kind == source.kind && item.origin == source.origin,
      );
    }
    _librarySources.insert(0, source);
  }

  void _dropMaterialized(LibrarySource source) {
    for (final group in source.groups) {
      for (final image in group.images) {
        final path = _materialized.remove(image.id);
        if (path == null) {
          continue;
        }
        try {
          File(path).deleteSync();
        } on FileSystemException {
          // 一時ファイルが残っても、次に開いたときには使いません。
        }
      }
    }
  }

  void _removeLibrarySource(String sourceId) {
    final source = _librarySourceById(sourceId);
    if (source == null) {
      return;
    }
    final selectedHere = source.groups.any(
      (group) => group.images.any((image) => image.id == _libraryImageId),
    );
    setState(() {
      _dropMaterialized(source);
      _librarySources.removeWhere((item) => item.id == sourceId);
      if (selectedHere) {
        _libraryImageId = null;
      }
      _libraryMessage = null;
    });
  }

  void _clearLibrary() {
    setState(() {
      for (final source in _librarySources) {
        _dropMaterialized(source);
      }
      _librarySources.clear();
      _libraryImageId = null;
      _libraryMessage = null;
    });
  }

  String _librarySummary(LibrarySource source) {
    final limited = source.truncated ? '表示は先頭 $maxLibraryImages 件です。' : '';
    return '${source.label} から画像を ${source.imageCount} 件読み込みました。$limited';
  }

  Future<void> _onAddLibraryFolder() async {
    await _withLibraryPicker(
      picking: 'フォルダを選択しています',
      pick: pickFolder,
      load: (path) => loadFolderImages(sourceId: _nextLibraryId(), folderPath: path),
    );
  }

  Future<void> _onAddLibraryFiles() async {
    if (_saving || _libraryLoading) {
      return;
    }
    setState(() {
      _libraryLoading = true;
      _libraryMessage = 'ファイルを選択しています';
      _error = null;
    });
    List<String> paths;
    try {
      paths = await pickImageFiles();
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _libraryLoading = false;
        _libraryMessage = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _libraryLoading = false;
        _libraryMessage = null;
        _error = '$error';
      });
      return;
    }
    if (!mounted) {
      return;
    }
    if (paths.isEmpty) {
      setState(() {
        _libraryLoading = false;
        _libraryMessage = null;
      });
      return;
    }
    try {
      final source = sourceFromFiles(sourceId: _nextLibraryId(), paths: paths);
      setState(() {
        _putLibrarySource(source);
        _libraryLoading = false;
        _libraryMessage = _librarySummary(source);
      });
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _libraryLoading = false;
        _libraryMessage = null;
        _error = error.message;
      });
    }
  }

  Future<void> _onOpenDefaultVtv() async {
    if (!Directory(defaultVtvTaskRoot).existsSync()) {
      setState(() {
        _libraryMessage = null;
        _error = r'C:\viscotech\task が見つかりません。VTVのフォルダを指定してください';
      });
      return;
    }
    await _useTaskPicker(kind: LibrarySourceKind.vtv, origin: defaultVtvTaskRoot);
  }

  Future<void> _onPickVtv() async {
    await _withLibraryPicker(
      picking: 'VTVのフォルダを選択しています',
      pick: pickFolder,
      load: (path) async {
        final root = resolveVtvTaskRoot(path);
        if (root == null) {
          throw const FormatException('VTVのtaskフォルダが見つかりません');
        }
        _taskPickerKind = LibrarySourceKind.vtv;
        _taskPickerOrigin = root;
        return _loadPickedTask(root);
      },
    );
  }

  Future<void> _onAddLibraryTaskFile() async {
    await _withLibraryPicker(
      picking: 'タスクファイルを選択しています',
      pick: pickTaskFile,
      load: (path) async {
        _taskPickerKind = LibrarySourceKind.taskFile;
        _taskPickerOrigin = path;
        return _loadPickedTask(path);
      },
    );
  }

  Future<void> _useTaskPicker({
    required LibrarySourceKind kind,
    required String origin,
  }) async {
    setState(() {
      _taskPickerKind = kind;
      _taskPickerOrigin = origin;
    });
    await _showPickedTask();
  }

  Future<void> _showPickedTask() async {
    final origin = _taskPickerOrigin;
    final kind = _taskPickerKind;
    if (origin == null || kind == null || _saving || _libraryLoading) {
      return;
    }
    final groupNumber = _taskGroup.text.trim();
    final taskNumber = _taskNumber.text.trim();
    if (groupNumber.isEmpty || taskNumber.isEmpty) {
      setState(() {
        _libraryMessage = null;
        _error = 'グループ番号とタスク番号を入力してください';
      });
      return;
    }
    setState(() {
      _libraryLoading = true;
      _libraryMessage = 'グループ $groupNumber、タスク $taskNumber を読み込んでいます';
      _error = null;
    });
    try {
      final source = await _loadPickedTask(origin);
      if (!mounted) {
        return;
      }
      setState(() {
        _putLibrarySource(source);
        _libraryLoading = false;
        _libraryMessage = _librarySummary(source);
      });
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _libraryLoading = false;
        _libraryMessage = null;
        _error = error.message;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _libraryLoading = false;
        _libraryMessage = null;
        _error = '$error';
      });
    }
  }

  Future<LibrarySource> _loadPickedTask(String origin) {
    final groupNumber = _taskGroup.text.trim();
    final taskNumber = _taskNumber.text.trim();
    if (groupNumber.isEmpty || taskNumber.isEmpty) {
      throw const FormatException('グループ番号とタスク番号を入力してください');
    }
    if (_taskPickerKind == LibrarySourceKind.taskFile) {
      return loadTaskFileImages(
        sourceId: _nextLibraryId(),
        filePath: origin,
        groupNumber: groupNumber,
        taskNumber: taskNumber,
      );
    }
    return loadVtvImages(
      sourceId: _nextLibraryId(),
      root: origin,
      groupNumber: groupNumber,
      taskNumber: taskNumber,
    );
  }

  Future<void> _withLibraryPicker({
    required String picking,
    required Future<String?> Function() pick,
    required Future<LibrarySource> Function(String path) load,
  }) async {
    if (_saving || _libraryLoading) {
      return;
    }
    setState(() {
      _libraryLoading = true;
      _libraryMessage = picking;
      _error = null;
    });
    String? path;
    try {
      path = await pick();
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _libraryLoading = false;
        _libraryMessage = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _libraryLoading = false;
        _libraryMessage = null;
        _error = '$error';
      });
      return;
    }
    if (!mounted) {
      return;
    }
    if (path == null) {
      setState(() {
        _libraryLoading = false;
        _libraryMessage = null;
      });
      return;
    }
    setState(() => _libraryMessage = '画像を読み込んでいます');
    try {
      final source = await load(path);
      if (!mounted) {
        return;
      }
      setState(() {
        _putLibrarySource(source);
        _libraryLoading = false;
        _libraryMessage = _librarySummary(source);
      });
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _libraryLoading = false;
        _libraryMessage = null;
        _error = error.message;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _libraryLoading = false;
        _libraryMessage = null;
        _error = '$error';
      });
    }
  }

  Future<Uint8List> _loadArchiveBytes(LibraryImage image) {
    final catalog = _librarySourceById(image.sourceId)?.zipCatalog;
    final entry = image.archiveEntry;
    if (catalog == null || entry == null) {
      return Future.error(const FormatException('タスクファイル内の画像が見つかりません'));
    }
    return Future(() => readZipEntryBytes(catalog, entry));
  }

  Future<void> _onAssignLibraryImage(LibraryImage image) async {
    if (_saving || _libraryLoading) {
      return;
    }
    final frameId = _chosenAssignTarget(_result);
    if (frameId == null) {
      setState(() => _libraryMessage = '右の画像枠を選んでから割り当ててください');
      return;
    }
    final path = image.filePath ?? await _materializeLibraryImage(image);
    if (!mounted || path == null) {
      return;
    }
    setState(() => _libraryMessage = null);
    await _commitFrameImage(frameId, path);
  }

  Future<String?> _materializeLibraryImage(LibraryImage image) async {
    final cached = _materialized[image.id];
    if (cached != null && File(cached).existsSync()) {
      return cached;
    }
    final catalog = _librarySourceById(image.sourceId)?.zipCatalog;
    final entry = image.archiveEntry;
    if (catalog == null || entry == null) {
      setState(() => _error = '画像の場所が分かりません');
      return null;
    }
    setState(() {
      _libraryLoading = true;
      _libraryMessage = 'タスクファイルから画像を取り出しています';
      _error = null;
    });
    try {
      final bytes = readZipEntryBytes(catalog, entry);
      final directory = _libraryTemp ??= await Directory.systemTemp.createTemp(
        'smart_report_library_',
      );
      if (!mounted) {
        return null;
      }
      final path = await writeTempLibraryImage(
        directory: directory,
        fileName: image.name,
        index: _materialized.length,
        bytes: bytes,
      );
      _materialized[image.id] = path;
      return path;
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _libraryMessage = null;
          _error = error.message;
        });
      }
      return null;
    } catch (error) {
      if (mounted) {
        setState(() {
          _libraryMessage = null;
          _error = '$error';
        });
      }
      return null;
    } finally {
      if (mounted) {
        setState(() => _libraryLoading = false);
      }
    }
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final sharedLines = sharedAssetLines(
      assets: _assignedAssets,
      frameNames: {
        for (final element in result?.elements ?? const <PlacedElement>[])
          element.elementId: element.displayName,
      },
    );
    final displacedName = assetLeftUnassignedByShare(
      frameId: _chosenAssignTarget(result),
      shareAssetId: _chosenShareTarget(),
      assets: _assignedAssets,
    );
    final libraryBusy = _saving || _libraryLoading;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          _onSave();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      appBar: AppBar(title: const Text('Smart Report Builder プレビュー')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final libraryWidth = constraints.maxWidth < 980
                ? math.max(240.0, constraints.maxWidth * 0.34)
                : 360.0;
            final optionsMax = math.min(
              380.0,
              math.max(160.0, (constraints.maxHeight - 24) * 0.42),
            );
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: libraryWidth,
                  child: ImageLibraryPanel(
                    key: const Key('image-library'),
                    sources: _librarySources,
                    selectedImageId: _libraryImageId,
                    loading: _libraryLoading,
                    message: _libraryMessage,
                    canAssign:
                        !libraryBusy &&
                        _chosenAssignTarget(result) != null &&
                        _selectedLibraryImage != null,
                    onSelect: (image) {
                      if (_saving) {
                        return;
                      }
                      setState(() {
                        _libraryImageId = image.id;
                        _libraryMessage = null;
                      });
                    },
                    onAssign: _onAssignLibraryImage,
                    onAddFolder: libraryBusy ? null : _onAddLibraryFolder,
                    onAddFiles: libraryBusy ? null : _onAddLibraryFiles,
                    onOpenDefaultVtv: libraryBusy ? null : _onOpenDefaultVtv,
                    onPickVtv: libraryBusy ? null : _onPickVtv,
                    onAddTaskFile: libraryBusy ? null : _onAddLibraryTaskFile,
                    onRegisterList: libraryBusy ? null : _onRegisterLibraryList,
                    onRemoveSource: _removeLibrarySource,
                    onClear: libraryBusy ? null : _clearLibrary,
                    loadArchiveBytes: _loadArchiveBytes,
                    taskGroup: _taskPickerOrigin == null ? null : _taskGroup,
                    taskNumber: _taskPickerOrigin == null ? null : _taskNumber,
                    onShowTask: libraryBusy || _taskPickerOrigin == null
                        ? null
                        : _showPickedTask,
                  ),
                ),
                const VerticalDivider(width: 17),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_status != null) ...[
                        Text(_status!, key: const Key('save-status')),
                        const SizedBox(height: 8),
                      ],
                      if (_error != null) ...[
                        Text(
                          _error!,
                          key: const Key('load-error'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: optionsMax),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Theme.of(context).colorScheme.outlineVariant,
                            ),
                          ),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _sectionLabel('プロジェクト'),
            if (!_hasOpenProject())
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  key: const Key('new-project'),
                  onPressed: _saving ? null : _onNewProjectDialog,
                  child: const Text('新規プロジェクト'),
                ),
              ),
            if (_result?.titleText != null) ...[
              const SizedBox(height: 8),
              TextField(
                key: const Key('page-title'),
                controller: _pageTitle,
                focusNode: _pageTitleFocus,
                decoration: const InputDecoration(
                  labelText: 'ページタイトル',
                  border: OutlineInputBorder(),
                  isDense: true,
                  helperText: 'Enter か欄の外で保存します',
                ),
                onSubmitted: (_) => _onSavePageTitle(),
              ),
            ],
            if (_findingElement(result) != null) ...[
              const SizedBox(height: 8),
              TextField(
                key: const Key('finding-text'),
                controller: _finding,
                focusNode: _findingFocus,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'このスライドの見解',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                  helperText: 'このスライドだけに保存します。長い文章は省略しません。欄の外か「見解を反映」でプレビューへ出します。',
                ),
              ),
              if (_findingIsPending(result)) ...[
                const SizedBox(height: 4),
                const Text(
                  'この見解はまだスライドに反映していません。',
                  key: Key('finding-pending'),
                ),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  key: const Key('finding-apply'),
                  onPressed: _saving || !_findingIsPending(result)
                      ? null
                      : _onSaveFinding,
                  child: const Text('見解を反映'),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('layout-path'),
                    controller: _path,
                    decoration: const InputDecoration(
                      labelText: '配置 JSON または PPTX',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _onSubmitPath(),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  key: const Key('open-preview'),
                  onPressed: _saving ? null : _onOpen,
                  child: const Text('開く'),
                ),
                if (_result != null) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('save-project'),
                    onPressed: _saving || !_unsaved ? null : _onSave,
                    child: const Text('保存'),
                  ),
                ],
              ],
            ),
            if (_unsaved) ...[
              const SizedBox(height: 8),
              const Text(
                '未保存の変更があります。保存すると JSON と PPTX をまとめて書き出します。',
                key: Key('unsaved-changes'),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'スライドを右クリックすると、追加や削除、画像の種類、ROI、表を操作できます。',
              key: const Key('preview-menu-hint'),
            ),
            if (sharedLines.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '共有中の素材:\n${sharedLines.join('\n')}',
                key: const Key('shared-assets'),
              ),
            ],
            if (_datasets.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'グループ:\n${_datasetLines().join('\n')}',
                key: const Key('dataset-groups'),
              ),
            ],
            _assignmentCandidates(),
            _orderedRulePanel(),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_pages.isNotEmpty) _layoutSwitcher(),
                      Expanded(
                        child: KeyedSubtree(
                          key: const Key('preview-pane'),
                          child: result == null
                              ? const Center(
                                  child: Text(
                                    '配置を開くと、ここにスライドが出ます',
                                    key: Key('preview-placeholder'),
                                  ),
                                )
                              : Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      '${previewModeLabel(result.previewMode)} / '
                                      'スライド ${result.slideWidthPt} x ${result.slideHeightPt} pt'
                                      ' / 要素 ${result.elements.length}',
                                      key: const Key('preview-mode'),
                                    ),
                                    Text(
                                      _linkedSummary(result),
                                      key: const Key('linked-rois'),
                                    ),
                                    if (result.violations.isNotEmpty)
                                      Text(
                                        result.violations
                                            .map(
                                              (item) =>
                                                  '${item.code}: ${item.message}',
                                            )
                                            .join('\n'),
                                        key: const Key('violations'),
                                      ),
                                    if (result.skippedElementIds.isNotEmpty)
                                      Text(
                                        '未対応の要素は描画していません: ${result.skippedElementIds.join(', ')}',
                                        key: const Key('skipped-elements'),
                                      ),
                                    const SizedBox(height: 12),
                                    Expanded(
                                      child: SlidePreview(
                  result: result,
                  onRoiFrameChanged: _onRoiFrameChanged,
                  onRoiFrameCommitted: _onRoiFrameCommitted,
                  onRoiEditCancelled: _onRoiEditCancelled,
                  onRoiCreated: _onRoiCreated,
                  onNoteFrameChanged: _onNoteFrameChanged,
                  onNoteFrameCommitted: _onNoteFrameCommitted,
                  onImageFileDropped: _onImageFileDropped,
                  onImageDropRejected: (message) {
                    if (_saving) {
                      return;
                    }
                    setState(() {
                      _status = null;
                      _error = message;
                    });
                  },
                  selectedRoiId: _selectedRoiId,
                  selectedFrameId: _chosenRemoveTarget(result),
                  onImageFrameCommitted: _onImageFrameCommitted,
                  onContainFrameSelected: (frameId) {
                    if (_saving) {
                      return;
                    }
                    setState(() {
                      _removeFrameId = frameId;
                      if (_containFrames(result).any(
                        (frame) => frame.elementId == frameId,
                      )) {
                        _assignTargetId = frameId;
                      }
                    });
                  },
                  highlightedFrameIds: selectedAssetFrameIds(
                    assetId: _chosenShareTarget(),
                    assets: _assignedAssets,
                  ),
                  highlightedAssetName: selectedAssetName(
                    assetId: _chosenShareTarget(),
                    assets: _assignedAssets,
                  ),
                  displacedAssetName: displacedName,
                  onTableCellSelected: (elementId, row, column) {
                    if (_saving) {
                      return;
                    }
                    setState(() {
                      _tableElementId = elementId;
                      _tableRow = row;
                      _tableColumn = column;
                    });
                    _applyTableCellField(result);
                  },
                  shareTargetFrameId: shareDestinationFrameId(
                    frameId: _chosenAssignTarget(result),
                    shareAssetChosen: _chosenShareTarget() != null,
                    assetFrameIds: selectedAssetFrameIds(
                      assetId: _chosenShareTarget(),
                      assets: _assignedAssets,
                    ),
                  ),
                  onContextMenu: (slidePoint, global) =>
                      _openPreviewMenu(result, slidePoint, global),
                  onRoiSelected: (roiId) {
                    if (_saving) {
                      return;
                    }
                    setState(() {
                      _selectedRoiId = roiId;
                      final linked = _zoomByRoi[roiId];
                      if (_zoomFrames(
                        result,
                      ).any((frame) => frame.elementId == linked)) {
                        _zoomTargetId = linked;
                      }
                    });
                    _applyRoiNameField(result);
                    _applyRoiNoteField();
                  },
                                    ),
                                  ),
                                ],
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
        ),
      ),
    );
  }

  bool _canUnassign(LayoutResult? layout) {
    final frameId = _chosenAssignTarget(layout);
    final assigned = _containFrames(layout).any(
      (frame) =>
          frame.elementId == frameId &&
          frame.assetPath != null &&
          frame.assetPath!.isNotEmpty,
    );
    return canUnassignImage(frameId: frameId, assigned: assigned);
  }

  Future<void> _onUnassignImage() async {
    final frameId = _chosenAssignTarget(_result);
    if (frameId == null || _saving || !_canUnassign(_result)) {
      return;
    }
    final sharedFrame = frameSharesAsset(
      frameId: frameId,
      assets: _assignedAssets,
    );
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、画像の割当を外せません');
      return;
    }
    setState(() {
      _saving = true;
      _status = '保存しています';
      _error = null;
    });
    try {
      await clearFrameImage(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        elementId: frameId,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(
      () => _status = sharedFrame
          ? 'この枠の共有を外しました。ほかの枠の画像と元のファイル、ROI の保存座標は残しています。'
          : '画像の割当を外しました。枠と元ファイル、ROI の保存座標は残しています。',
    );
  }

  bool _canAssignRegistered(LayoutResult? layout) {
    final frameId = _chosenAssignTarget(layout);
    final assetId = _chosenAssetTarget();
    return canAssignRegisteredAsset(
      frameId: frameId,
      assetId: assetId,
      containFrame: _containFrames(layout).any(
        (frame) => frame.elementId == frameId,
      ),
      unassignedAsset: _unassignedAssets.any((asset) => asset.id == assetId),
    );
  }

  Future<void> _onAssignRegisteredAsset() async {
    final frameId = _chosenAssignTarget(_result);
    final assetId = _chosenAssetTarget();
    if (frameId == null ||
        assetId == null ||
        _saving ||
        !_canAssignRegistered(_result)) {
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、素材を割り当てられません');
      return;
    }
    setState(() {
      _saving = true;
      _status = '保存しています';
      _error = null;
    });
    try {
      await assignRegisteredAsset(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        elementId: frameId,
        assetId: assetId,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(
      () => _status = '登録済みの素材を割り当てました。元のファイルと ROI の保存座標は変えていません。',
    );
  }

  bool _canShare(LayoutResult? layout) {
    final frameId = _chosenAssignTarget(layout);
    final assetId = _chosenShareTarget();
    final matches = _assignedAssets.where((asset) => asset.id == assetId);
    return canShareRegisteredAsset(
      frameId: frameId,
      assetId: assetId,
      containFrame: _containFrames(layout).any(
        (frame) => frame.elementId == frameId,
      ),
      frameIds: matches.isEmpty ? const [] : matches.first.frameIds,
    );
  }

  Future<void> _onShareRegisteredAsset() async {
    final frameId = _chosenAssignTarget(_result);
    final assetId = _chosenShareTarget();
    if (frameId == null || assetId == null || _saving || !_canShare(_result)) {
      return;
    }
    final displacedId = assetDisplacedByShare(
      frameId: frameId,
      shareAssetId: assetId,
      assets: _assignedAssets,
    )?.id;
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、素材を共有できません');
      return;
    }
    setState(() {
      _saving = true;
      _status = '保存しています';
      _error = null;
    });
    try {
      await shareRegisteredAsset(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        elementId: frameId,
        assetId: assetId,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    if (displacedId != null) {
      _assetTargetId = displacedId;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    final selectedDisplaced = displacedId != null && _chosenAssetTarget() == displacedId;
    setState(
      () => _status = selectedDisplaced
          ? '選んだ枠でも、この素材を使うようにしました。未割当になった素材を削除の選択に入れました。記録の削除は別の操作で、元のファイルは残します。'
          : '選んだ枠でも、この素材を使うようにしました。元のファイルと ROI の保存座標は変えていません。',
    );
  }

  bool _canRemoveAsset() {
    final assetId = _chosenAssetTarget();
    return canRemoveUnusedAsset(
      assetId: assetId,
      unassignedAsset: _unassignedAssets.any((asset) => asset.id == assetId),
    );
  }

  Future<void> _onRemoveUnusedAsset() async {
    final assetId = _chosenAssetTarget();
    if (assetId == null || _saving || !_canRemoveAsset()) {
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、素材の記録を削除できません');
      return;
    }
    setState(() {
      _saving = true;
      _status = '保存しています';
      _error = null;
    });
    try {
      await removeUnusedAsset(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        assetId: assetId,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(() => _status = '素材の記録を削除しました。元のファイルは残しています。');
  }

  bool _canAssign(LayoutResult? layout) {
    final frameId = _chosenAssignTarget(layout);
    return canAssignImage(
      frameId: frameId,
      containFrame: _containFrames(layout).any(
        (frame) => frame.elementId == frameId,
      ),
    );
  }

  Future<void> _onRegisterFolder() async {
    if (_saving) {
      return;
    }
    setState(() {
      _saving = true;
      _status = 'フォルダを選択しています';
      _error = null;
    });
    String? folderPath;
    try {
      folderPath = await pickFolder();
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        _status = null;
        _error = '$error';
      });
      return;
    }
    if (!mounted) {
      return;
    }
    if (folderPath == null) {
      setState(() {
        _saving = false;
        _status = null;
      });
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() {
        _saving = false;
        _status = null;
        _error = '保存先が見つからないため、画像を登録できません';
      });
      return;
    }
    setState(() => _status = '保存しています');
    FolderRegistration registration;
    try {
      registration = await registerFolderImages(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        folderPath: folderPath,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    final skipped = registration.skipped == 0
        ? ''
        : '読めないファイルは ${registration.skipped} 件スキップしました。';
    final summary = registration.added == 0
        ? '新しい画像はありません。枠への割当はしていません。$skipped'
        : '画像を ${registration.added} 件登録しました。枠への割当はしていません。$skipped';
    setState(() => _status = summary);
  }

  Future<void> _onAssignImage() async {
    final frameId = _chosenAssignTarget(_result);
    if (frameId == null || _saving || !_canAssign(_result)) {
      return;
    }
    setState(() {
      _saving = true;
      _status = '画像を選択しています';
      _error = null;
    });
    String? imagePath;
    try {
      imagePath = await pickImageFile();
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        _status = null;
        _error = '$error';
      });
      return;
    }
    if (!mounted) {
      return;
    }
    if (imagePath == null) {
      setState(() {
        _saving = false;
        _status = null;
      });
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _saving = false);
    await _commitFrameImage(frameId, imagePath);
  }

  void _onImageFileDropped(String frameId, String imagePath) {
    final frame = _result?.elements.where(
      (element) => element.elementId == frameId && acceptsImageDrop(element),
    );
    if (_saving || frame == null || frame.isEmpty) {
      return;
    }
    _commitFrameImage(frameId, imagePath);
  }

  Future<void> _commitFrameImage(String frameId, String imagePath) async {
    if (_saving) {
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() {
        _saving = false;
        _status = null;
        _error = '保存先が見つからないため、画像を割り当てられません';
      });
      return;
    }
    setState(() {
      _saving = true;
      _status = '保存しています';
      _error = null;
    });
    try {
      await assignFrameImage(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        elementId: frameId,
        imagePath: imagePath,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(() => _status = '画像を割り当てました。元のファイルと ROI の保存座標は変えていません。');
  }

  bool _canRename(LayoutResult? layout) {
    final roiId = _selectedRoiId;
    return canRenameRoi(
      knownRoi:
          roiId != null &&
          _hasRoi(layout, roiId) &&
          _zoomByRoi.containsKey(roiId),
      currentName: _selectedDisplayName(layout),
      editedName: _roiName.text,
    );
  }

  String _selectedDisplayName(LayoutResult? layout) {
    final roiId = _selectedRoiId;
    if (layout == null || roiId == null) {
      return '';
    }
    for (final element in layout.elements) {
      if (element.elementId == roiId && element.kind == 'roi') {
        return element.displayName;
      }
    }
    return '';
  }

  bool _canResetNote() {
    final roiId = _selectedRoiId;
    return canResetNotePosition(
      knownRoi: roiId != null && _noteByRoi.containsKey(roiId),
      currentNote: roiId == null ? '' : (_noteByRoi[roiId] ?? ''),
      manualPosition: roiId != null && _manualNoteIds.contains(roiId),
    );
  }

  Future<void> _onResetNote() async {
    final roiId = _selectedRoiId;
    if (roiId == null || _saving || !_canResetNote()) {
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、注釈を自動位置へ戻せません');
      return;
    }
    setState(() {
      _saving = true;
      _status = '保存しています';
      _error = null;
    });
    try {
      await resetRoiNote(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        roiId: roiId,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(() => _status = '注釈を自動位置へ戻しました。文字と ROI の矩形は変えていません。');
  }

  bool _canSaveNote() {
    final roiId = _selectedRoiId;
    return canSaveNote(
      knownRoi: roiId != null && _noteByRoi.containsKey(roiId),
      currentNote: roiId == null ? '' : (_noteByRoi[roiId] ?? ''),
      editedNote: _roiNote.text,
    );
  }

  void _applyRoiNoteField() {
    final roiId = _selectedRoiId;
    final note = roiId == null ? '' : (_noteByRoi[roiId] ?? '');
    if (_roiNote.text == note) {
      return;
    }
    _roiNote.text = note;
  }

  Future<void> _onSaveNote() async {
    final roiId = _selectedRoiId;
    final note = _roiNote.text.trim();
    if (roiId == null || _saving || !_canSaveNote()) {
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、ROIの注釈を保存できません');
      return;
    }
    setState(() {
      _saving = true;
      _status = '保存しています';
      _error = null;
    });
    try {
      await setRoiNote(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        roiId: roiId,
        note: note,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(() => _status = '注釈を保存しました。ROI の矩形と拡大の連動は変えていません。');
  }

  void _selectTableCellAt(PlacedElement table, Offset point) {
    final rows = table.tableRows;
    if (rows == null || rows.isEmpty || table.frame.height <= 0 || table.frame.width <= 0) {
      return;
    }
    final relY = (point.dy - table.frame.y).clamp(0.0, table.frame.height - 0.001);
    final relX = (point.dx - table.frame.x).clamp(0.0, table.frame.width - 0.001);
    final row = (relY / table.frame.height * rows.length).floor().clamp(0, rows.length - 1);
    final width = rows[row].length;
    if (width == 0) {
      return;
    }
    final column = (relX / table.frame.width * width).floor().clamp(0, width - 1);
    _tableElementId = table.elementId;
    _tableRow = row;
    _tableColumn = column;
  }

  List<_TableCell> _tableCells(LayoutResult layout) {
    final cells = <_TableCell>[];
    for (final element in layout.elements) {
      final rows = element.tableRows;
      if (element.kind != 'table' || rows == null) {
        continue;
      }
      for (var row = 0; row < rows.length; row++) {
        for (var column = 0; column < rows[row].length; column++) {
          cells.add(
            _TableCell(
              elementId: element.elementId,
              row: row,
              column: column,
              text: rows[row][column],
            ),
          );
        }
      }
    }
    return cells;
  }

  String? _chosenTableCellKey(LayoutResult layout) {
    final id = _tableElementId;
    final row = _tableRow;
    final column = _tableColumn;
    if (id == null || row == null || column == null) {
      return null;
    }
    final key = '$id:$row:$column';
    if (_tableCells(layout).any((cell) => cell.key == key)) {
      return key;
    }
    return null;
  }

  bool _canSaveTableCell(LayoutResult layout) {
    final current = _selectedTableCell(layout);
    return canSaveTableCell(
      knownCell: current != null,
      currentText: current?.text ?? '',
      editedText: _tableCell.text,
    );
  }

  _TableCell? _selectedTableCell(LayoutResult layout) {
    final key = _chosenTableCellKey(layout);
    if (key == null) {
      return null;
    }
    for (final cell in _tableCells(layout)) {
      if (cell.key == key) {
        return cell;
      }
    }
    return null;
  }

  PlacedElement? _findingElement(LayoutResult? result) {
    if (result == null) {
      return null;
    }
    PlacedElement? fallback;
    for (final element in result.elements) {
      if (element.kind != 'text') {
        continue;
      }
      if (element.roleId == 'caption') {
        return element;
      }
      fallback ??= element;
    }
    return fallback;
  }

  bool _findingIsPending(LayoutResult? result) {
    final element = _findingElement(result);
    if (element == null) {
      return false;
    }
    return _finding.text != (element.text ?? '');
  }

  void _applyFinding(LayoutResult result) {
    if (_findingFocus.hasFocus) {
      return;
    }
    final element = _findingElement(result);
    if (element == null) {
      return;
    }
    final text = element.text ?? '';
    if (_finding.text != text) {
      _finding.text = text;
    }
  }

  Future<void> _onSaveFinding() async {
    final element = _findingElement(_result);
    if (element == null || _saving || !_findingIsPending(_result)) {
      return;
    }
    final text = _finding.text;
    await _runProjectCommand(
      '見解を反映しています',
      (python, projectPath, layoutPath, pptxPath) => setSlideFinding(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        elementId: element.elementId,
        text: text,
      ),
      'このスライドの見解を反映しました。保存すると JSON と PPTX に残ります。',
    );
  }

  void _applyPageTitle(LayoutResult result) {
    final title = result.titleText;
    if (title == null || _pageTitleFocus.hasFocus) {
      return;
    }
    if (_pageTitle.text != title) {
      _pageTitle.text = title;
    }
  }

  Future<void> _onSavePageTitle() async {
    final title = _pageTitle.text.trim();
    final current = _result?.titleText;
    if (title.isEmpty || title == current || _saving) {
      return;
    }
    await _runProjectCommand(
      'ページタイトルを保存しています',
      (python, projectPath, layoutPath, pptxPath) => setReportPageTitle(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        title: title,
      ),
      'ページタイトルを保存しました',
    );
  }

  void _applyTableCellField(LayoutResult? layout) {
    if (layout == null || _chosenTableCellKey(layout) == null) {
      _tableElementId = null;
      _tableRow = null;
      _tableColumn = null;
      if (_tableCell.text.isNotEmpty) {
        _tableCell.text = '';
      }
      return;
    }
    final text = _selectedTableCell(layout)?.text ?? '';
    if (_tableCell.text != text) {
      _tableCell.text = text;
    }
  }

  Future<void> _onSaveTableCell() async {
    final layout = _result;
    final cell = layout == null ? null : _selectedTableCell(layout);
    if (cell == null || _saving || !_canSaveTableCell(layout!)) {
      return;
    }
    final text = _tableCell.text;
    await _runProjectCommand(
      'セルを保存しています',
      (python, projectPath, layoutPath, pptxPath) => setTableCell(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        elementId: cell.elementId,
        row: cell.row,
        column: cell.column,
        text: text,
      ),
      'セルを保存しました。文字は短縮していません。',
    );
  }

  void _applyRoiNameField(LayoutResult? layout) {
    final name = _selectedDisplayName(layout);
    if (_roiName.text == name) {
      return;
    }
    _roiName.text = name;
  }

  Future<void> _onRoiRename() async {
    final saved = _saved;
    final roiId = _selectedRoiId;
    final name = _roiName.text.trim();
    if (saved == null || roiId == null || _saving || !_canRename(saved)) {
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、ROIの名前を保存できません');
      return;
    }
    setState(() {
      _saving = true;
      _status = '保存しています';
      _error = null;
    });
    try {
      await renameRoi(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        roiId: roiId,
        name: name,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(() => _status = 'ROI の名前を保存しました。矩形と拡大の連動は変えていません。');
  }

  bool _canLink(LayoutResult? layout) {
    final roiId = _selectedRoiId;
    return canLinkSelection(
      knownRoi: roiId != null && _zoomByRoi.containsKey(roiId),
      currentZoomId: roiId == null ? null : _zoomByRoi[roiId],
      targetZoomId: _chosenZoomTarget(layout),
    );
  }

  bool _canUnlink(LayoutResult? layout) {
    final roiId = _selectedRoiId;
    return canUnlinkSelection(
      knownRoi:
          roiId != null &&
          _hasRoi(layout, roiId) &&
          _zoomByRoi.containsKey(roiId),
      currentZoomId: roiId == null ? null : _zoomByRoi[roiId],
    );
  }

  List<PlacedElement> _containFrames(LayoutResult? layout) {
    if (layout == null) {
      return const [];
    }
    return [
      for (final element in layout.elements)
        if (element.kind == 'image_frame' && element.fitMode == 'contain')
          element,
    ];
  }

  List<PlacedElement> _imageFrames(LayoutResult? layout) {
    if (layout == null) {
      return const [];
    }
    return [
      for (final element in layout.elements)
        if (element.kind == 'image_frame') element,
    ];
  }

  String? _chosenRemoveTarget(LayoutResult? layout) {
    final target = _removeFrameId;
    if (target == null) {
      return null;
    }
    for (final frame in _imageFrames(layout)) {
      if (frame.elementId == target) {
        return target;
      }
    }
    return null;
  }

  String? _keptRemoveTarget(LayoutResult layout) {
    final frames = _imageFrames(layout);
    final ids = {for (final frame in frames) frame.elementId};
    if (_removeFrameId != null && ids.contains(_removeFrameId)) {
      return _removeFrameId;
    }
    if (frames.length == 1) {
      return frames.single.elementId;
    }
    return null;
  }

  String? _chosenAssignTarget(LayoutResult? layout) {
    final target = _assignTargetId;
    if (target == null) {
      return null;
    }
    for (final frame in _containFrames(layout)) {
      if (frame.elementId == target) {
        return target;
      }
    }
    return null;
  }

  String? _chosenAssetTarget() {
    final target = _assetTargetId;
    if (target == null) {
      return null;
    }
    for (final asset in _unassignedAssets) {
      if (asset.id == target) {
        return target;
      }
    }
    return null;
  }

  AssignmentCandidate? _chosenCandidate() {
    final key = _candidateKey;
    if (key == null) {
      return null;
    }
    for (final item in _candidates) {
      if (item.key == key) {
        return item;
      }
    }
    return null;
  }

  String? _keptCandidate(List<AssignmentCandidate> candidates) {
    final current = _candidateKey;
    if (current != null && candidates.any((item) => item.key == current)) {
      return current;
    }
    final ready = candidates.where((item) => item.status == 'ready').toList();
    if (ready.length == 1) {
      return ready.single.key;
    }
    return null;
  }

  LayoutProposal? _chosenVariant() {
    final id = _variantId;
    if (id == null) {
      return null;
    }
    for (final item in _variants) {
      if (item.id == id) {
        return item;
      }
    }
    return null;
  }

  String _frameName(String frameId) {
    for (final element in _result?.elements ?? const <PlacedElement>[]) {
      if (element.elementId == frameId) {
        return element.displayName;
      }
    }
    return frameId;
  }

  int _activeOrdinal() {
    if (_pages.isEmpty) {
      return 0;
    }
    final index = _pages.indexWhere((page) => page.id == _activePageId);
    return index < 0 ? 0 : index;
  }

  String _projectBody() {
    return reportSession.projectJson ?? '';
  }

  Widget _orderedRulePanel() {
    if (_result == null) {
      return const SizedBox.shrink();
    }
    final frames = _containFrames(_result);
    final assets = parseOrderedAssets(_projectBody());
    final lists = catalogLists(assets);
    final options = listOptions(lists);
    final ordinal = _activeOrdinal();
    return Column(
      key: const Key('ordered-rule'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        const Text('割付ルール'),
        const Text('各枠に、リストと番号を指定します。Comment= が無いリストは txt 名で出します。'),
        if (lists.isEmpty)
          const Text(
            '先に「一覧を登録」で、2つの txt の画像を素材にしてください。',
            key: Key('ordered-need-lists'),
          ),
        TextField(
          key: const Key('ordered-stride'),
          controller: _ruleStride,
          decoration: const InputDecoration(
            labelText: '次のスライドへ進む数',
            isDense: true,
            helperText: '1 なら各リストの 1,2,3…。2 なら 1,3,5…',
          ),
        ),
        for (var index = 0; index < frames.length; index++)
          _frameRuleRow(frames[index], index, options, assets, ordinal),
        CheckboxListTile(
          key: const Key('ordered-pin-slide'),
          contentPadding: EdgeInsets.zero,
          value: _pinThisSlide,
          onChanged: (value) => setState(() => _pinThisSlide = value ?? false),
          title: const Text('このスライドだけ別の番号にする'),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              key: const Key('ordered-expand'),
              onPressed: _saving || frames.isEmpty || lists.isEmpty ? null : _onExpandAssignment,
              child: const Text('スライドへ広げる'),
            ),
            TextButton(
              key: const Key('ordered-accept-all'),
              onPressed: _saving || !_orderedCandidates.any((item) => item.status == 'ready')
                  ? null
                  : () => _onAcceptOrdered(),
              child: const Text('すべて採用'),
            ),
          ],
        ),
        for (final warning in _orderedWarnings)
          Text(warning, key: Key('ordered-warning:$warning')),
        for (final candidate in _orderedCandidates)
          Row(
            children: [
              Expanded(
                child: Text(
                  '${candidate.label} スライド${candidate.slideOrdinal + 1} 枠${candidate.frameIndex + 1} '
                  '#${candidate.itemNumber} ${candidate.assetName} ${candidate.reason}',
                  key: Key('ordered-line:${candidate.key}'),
                ),
              ),
              if (candidate.status == 'ready')
                TextButton(
                  key: Key('ordered-accept:${candidate.key}'),
                  onPressed: _saving
                      ? null
                      : () => _onAcceptOrdered(ordinal: candidate.slideOrdinal, frame: candidate.frameIndex),
                  child: const Text('この候補を採用'),
                ),
            ],
          ),
      ],
    );
  }

  Widget _frameRuleRow(
    PlacedElement frame,
    int index,
    List<ListOption> options,
    List<OrderedAsset> assets,
    int ordinal,
  ) {
    final stored = _frameLists[frame.elementId];
    final choice = stored != null && options.any((option) => option.value == stored)
        ? stored
        : (options.isEmpty ? '' : (index < options.length ? options[index].value : options.first.value));
    if (choice.isNotEmpty) {
      _frameLists[frame.elementId] = choice;
    }
    final selected = choice.isEmpty ? null : choice;
    final itemController = _frameItems.putIfAbsent(frame.elementId, () => TextEditingController(text: '1'));
    final itemNumber = int.tryParse(itemController.text.trim()) ?? 1;
    final parsed = _splitListChoice(selected ?? '');
    final shownNumber = itemNumber + ordinal * (int.tryParse(_ruleStride.text.trim()) ?? 1);
    final resolved = parsed == null
        ? const ResolvedPick(status: 'missing', name: '', reason: 'リストがありません')
        : resolvePick(assets, parsed.$1, parsed.$2, shownNumber);
    final preview = resolved.status == 'ready' ? resolved.name : resolved.reason;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(frame.displayName, key: Key('frame-rule-name:${frame.elementId}')),
          if (options.isNotEmpty)
            DropdownButton<String>(
              key: Key('frame-list:${frame.elementId}'),
              isExpanded: true,
              value: selected,
              items: [
                for (final option in options)
                  DropdownMenuItem(value: option.value, child: Text(option.label)),
              ],
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                setState(() => _frameLists[frame.elementId] = value);
              },
            ),
          TextField(
            key: Key('frame-item:${frame.elementId}'),
            controller: itemController,
            decoration: const InputDecoration(labelText: '番号', isDense: true),
            onChanged: (_) => setState(() {}),
          ),
          Text(
            'このスライドでは $preview',
            key: Key('frame-preview:${frame.elementId}'),
          ),
        ],
      ),
    );
  }

  (String, String)? _splitListChoice(String value) {
    final split = value.indexOf(':');
    if (split <= 0) {
      return null;
    }
    return (value.substring(0, split), value.substring(split + 1));
  }

  Map<String, Object> _patternPayload() {
    final frames = _containFrames(_result);
    final ordinal = _activeOrdinal();
    final step = int.tryParse(_ruleStride.text.trim()) ?? 1;
    final pattern = <Map<String, Object>>[];
    final overrideFrames = <Map<String, Object>>[];
    for (var index = 0; index < frames.length; index++) {
      final frame = frames[index];
      final parsed = _splitListChoice(_frameLists[frame.elementId] ?? '');
      final base = int.tryParse(_frameItems[frame.elementId]?.text.trim() ?? '') ?? 1;
      if (parsed == null || base < 1) {
        continue;
      }
      pattern.add({
        'elementId': frame.elementId,
        'frameIndex': index,
        'listBy': parsed.$1,
        'listKey': parsed.$2,
        'itemNumber': base,
      });
      overrideFrames.add({
        'elementId': frame.elementId,
        'frameIndex': index,
        'listBy': parsed.$1,
        'listKey': parsed.$2,
        'itemNumber': base + ordinal * step,
      });
    }
    return {
      'step': step,
      'pattern': pattern,
      if (_pinThisSlide)
        'overrides': [
          {'slideOrdinal': ordinal, 'frames': overrideFrames},
        ],
    };
  }

  Future<void> _onExpandAssignment() async {
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = 'Python が見つからないため、スライドへ広げられません');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _status = 'スライドへ広げています';
    });
    try {
      final proposal = await expandAssignment(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        payload: jsonEncode(_patternPayload()),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _orderedCandidates = proposal.candidates;
        _orderedWarnings = proposal.warnings;
        _unsaved = reportSession.dirty;
        _status = '候補をスライド分だけ出しました。すべて採用するまで枠は変わりません。';
      });
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _onAcceptOrdered({int? ordinal, int? frame}) async {
    await _runProjectCommand(
      '割付候補を採用しています',
      (python, projectPath, layoutPath, pptxPath) => acceptOrderedAssignment(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        group: '',
        task: '',
        listName: '',
        ordinal: ordinal,
        frame: frame,
      ),
      ordinal == null ? '候補を採用しました。未割当の番号はそのままです。' : '選んだ候補を採用しました。',
    );
  }


  Widget _assignmentCandidates() {
    final candidates = _candidates;
    if (candidates.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      key: const Key('assignment-candidates'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        const Text('割当候補'),
        for (final candidate in candidates)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    assignmentCandidateLabel(
                      candidate,
                      frameName: _frameName(candidate.frameId),
                    ),
                    key: Key('candidate-line:${candidate.key}'),
                  ),
                ),
                TextButton(
                  key: Key('accept-candidate:${candidate.key}'),
                  onPressed: _saving
                      ? null
                      : () {
                          setState(() => _candidateKey = candidate.key);
                          _onApplyCandidate();
                        },
                  child: const Text('この候補を採用'),
                ),
              ],
            ),
          ),
        if (candidates.any((item) => item.canAcceptAll))
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('accept-ready-candidates'),
              onPressed: _saving ? null : _onAcceptReady,
              child: const Text('確定候補をすべて採用'),
            ),
          ),
      ],
    );
  }

  Future<void> _onAcceptReady() async {
    if (_saving || !_candidates.any((item) => item.canAcceptAll)) {
      return;
    }
    await _runProjectCommand(
      '確定候補を割り当てています',
      (python, projectPath, layoutPath, pptxPath) => acceptReadyAssignments(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
      ),
      '確定候補を割り当てました。確認推奨と競合はそのままです。',
    );
  }

  Future<void> _onApplyCandidate() async {
    final candidate = _chosenCandidate();
    if (candidate == null || _saving) {
      return;
    }
    await _runProjectCommand(
      '候補を割り当てています',
      (python, projectPath, layoutPath, pptxPath) => applyAssignmentCandidate(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        elementId: candidate.frameId,
        assetId: candidate.assetId,
      ),
      '候補を割り当てました。ほかの候補はまだ枠へ入れていません。',
    );
  }

  Future<void> _onShowVariants() async {
    if (_saving) {
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、レイアウト案を読めません');
      return;
    }
    setState(() {
      _saving = true;
      _status = '案を読んでいます';
      _error = null;
    });
    try {
      final variants = await loadLayoutProposals(
        pythonExecutable: python,
        projectPath: projectPath,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _variants = variants;
        _variantId = variants.length == 1 ? variants.single.id : null;
        _status = variants.length <= 1
            ? '標準案のままです。はみ出しはないため、別案は出していません。'
            : 'レイアウト案を ${variants.length} 件出しました。選ぶまで配置は変えません。';
      });
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _onApplyVariant() async {
    final variant = _chosenVariant();
    if (variant == null || variant.selected || _saving) {
      return;
    }
    await _runProjectCommand(
      '案を適用しています',
      (python, projectPath, layoutPath, pptxPath) => applyLayoutProposal(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        variantId: variant.id,
      ),
      '選んだレイアウト案を適用しました。',
    );
  }

  Future<void> _onCaptureMaster() async {
    final roiId = _selectedRoiId;
    if (roiId == null || _saving) {
      return;
    }
    await _runProjectCommand(
      'マスターにしています',
      (python, projectPath, layoutPath, pptxPath) => captureMasterRoi(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        roiId: roiId,
      ),
      'この ROI をマスターにしました。ほかの枠へは、まだ展開していません。',
    );
  }

  Future<void> _onApplyMaster() async {
    final frameId = _chosenAssignTarget(_result);
    if (frameId == null || _saving) {
      setState(() => _error = '展開先の通常表示の画像枠を選んでください');
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    if (projectPath == null) {
      setState(() => _error = '保存先が見つからないため、マスター ROI を展開できません');
      return;
    }
    final masters = parseMasterRoiIds(await File(projectPath).readAsString());
    if (masters.isEmpty) {
      setState(() => _error = 'マスター ROI がありません');
      return;
    }
    await _runProjectCommand(
      '展開しています',
      (python, project, layout, pptx) => applyMasterRoi(
        pythonExecutable: python,
        projectPath: project,
        layoutPath: layout,
        pptxPath: pptx,
        masterId: masters.last,
        elementId: frameId,
      ),
      'マスター ROI を選んだ枠へ継承で展開しました。補正済みは上書きしていません。',
    );
  }

  Future<void> _onAddTable() async {
    await _runProjectCommand(
      '表を追加しています',
      (python, projectPath, layoutPath, pptxPath) => addMeasurementTable(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
      ),
      '測定の表を追加しました。文字は短縮していません。',
    );
  }

  PlacedElement? _firstTable(LayoutResult? layout) {
    if (layout == null) {
      return null;
    }
    for (final element in layout.elements) {
      if (element.kind == 'table') {
        return element;
      }
    }
    return null;
  }

  Future<void> _onAddTableRow() async {
    final table = _firstTable(_result);
    final rows = table?.tableRows;
    if (table == null || rows == null || _saving) {
      return;
    }
    final elementId = table.elementId;
    final nextRow = rows.length;
    await _runProjectCommand(
      '行を追加しています',
      (python, projectPath, layoutPath, pptxPath) async {
        await addTableRow(
          pythonExecutable: python,
          projectPath: projectPath,
          layoutPath: layoutPath,
          pptxPath: pptxPath,
          elementId: elementId,
        );
        _tableElementId = elementId;
        _tableRow = nextRow;
        _tableColumn = 0;
      },
      '表に空の行を追加しました。既存の文字は変えていません。',
    );
  }

  Future<void> _onAddTableColumn() async {
    final table = _firstTable(_result);
    final rows = table?.tableRows;
    if (table == null || rows == null || rows.isEmpty || _saving) {
      return;
    }
    final elementId = table.elementId;
    final nextColumn = rows.first.length;
    await _runProjectCommand(
      '列を追加しています',
      (python, projectPath, layoutPath, pptxPath) async {
        await addTableColumn(
          pythonExecutable: python,
          projectPath: projectPath,
          layoutPath: layoutPath,
          pptxPath: pptxPath,
          elementId: elementId,
        );
        _tableElementId = elementId;
        _tableRow = 0;
        _tableColumn = nextColumn;
      },
      '表に空の列を追加しました。既存の文字は変えていません。',
    );
  }


  Future<void> _onImageFrameCommitted(String frameId, SlideRect frame) async {
    final layout = _result;
    if (layout == null || _saving) {
      return;
    }
    PlacedElement? element;
    for (final item in layout.elements) {
      if (item.elementId == frameId && item.kind == 'image_frame') {
        element = item;
      }
    }
    if (element == null) {
      return;
    }
    final group = imageFrameBounds(layout, element);
    if (group.width <= 0 || group.height <= 0) {
      return;
    }
    final normalized = normalizedRoi(frame, group);
    await _runProjectCommand(
      '画像枠の大きさを変えています',
      (python, projectPath, layoutPath, pptxPath) => resizeImageFrame(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        elementId: frameId,
        normalized: normalized,
      ),
      '画像枠の大きさを変えました。中の画像は枠に収まるように置いています。',
    );
  }

  Future<void> _onArrangeZooms() async {
    if (_saving || !_hasAnyRoi(_result)) {
      return;
    }
    final arrangement = _newArrangement;
    await _runProjectCommand(
      '拡大画像を並べています',
      (python, projectPath, layoutPath, pptxPath) => arrangeRoiZooms(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        arrangement: arrangement,
      ),
      _arrangedStatus(arrangement),
    );
  }

  PlacedElement? _selectedImageFrame(LayoutResult? layout) {
    final target = _chosenRemoveTarget(layout);
    if (target == null) {
      return null;
    }
    for (final frame in _imageFrames(layout)) {
      if (frame.elementId == target) {
        return frame;
      }
    }
    return null;
  }

  Future<void> _onFrameKind(String kind) async {
    final frame = _selectedImageFrame(_result);
    if (frame == null || _saving || imageFrameKind(frame) == kind) {
      return;
    }
    final elementId = frame.elementId;
    await _runProjectCommand(
      '画像の種類を変えています',
      (python, projectPath, layoutPath, pptxPath) => setImageFrameKind(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        elementId: elementId,
        kind: kind,
      ),
      _frameKindStatus(kind),
    );
  }

  String _frameKindStatus(String kind) {
    switch (kind) {
      case 'zoom':
        return '拡大にしました。この枠に描いていた ROI は外しました。割り当てていた画像は、画像に戻すと再び表示します。';
      case 'overall':
        return '全体画像にしました。拡大先になっていた場合は、その連動だけ外しました。';
      case 'comparison':
        return '比較画像にしました。拡大先になっていた場合は、その連動だけ外しました。';
      default:
        return '画像にしました。拡大先になっていた場合は、その連動だけ外しました。';
    }
  }

  Future<void> _onAddImageFrame() async {
    if (_saving) {
      return;
    }
    await _runProjectCommand(
      '画像枠を追加しています',
      (python, projectPath, layoutPath, pptxPath) async {
        final frameId = await addImageFrame(
          pythonExecutable: python,
          projectPath: projectPath,
          layoutPath: layoutPath,
          pptxPath: pptxPath,
        );
        _assignTargetId = frameId;
      },
      '通常表示の画像枠を追加しました。画像はまだ割り当てていません。説明文は変えていません。',
    );
  }

  Future<void> _onRemoveImageFrame(String? frameId) async {
    final frame = _imageFrames(_result).where((item) => item.elementId == frameId);
    if (frameId == null || frame.isEmpty || _saving) {
      return;
    }
    final zoom = frame.first.fitMode == 'roi';
    await _runProjectCommand(
      '画像枠を削除しています',
      (python, projectPath, layoutPath, pptxPath) => removeImageFrame(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        elementId: frameId,
      ),
      zoom
          ? '拡大画像の枠を削除しました。ROI の矩形は残し、拡大との連動だけ外しました。素材ファイルは残しています。'
          : '選んだ画像枠を削除しました。その枠の ROI は消し、素材の記録と元ファイルは残しています。',
    );
  }

  AssetDataset? _chosenDataset() {
    final target = _datasetId;
    if (target == null) {
      return null;
    }
    for (final dataset in _datasets) {
      if (dataset.id == target) {
        return dataset;
      }
    }
    return null;
  }

  String? _keptDataset(List<AssetDataset> datasets) {
    final target = _datasetId;
    if (target != null && datasets.any((dataset) => dataset.id == target)) {
      return target;
    }
    if (datasets.length == 1) {
      return datasets.single.id;
    }
    return null;
  }

  String _assetName(String assetId) {
    for (final asset in _unassignedAssets) {
      if (asset.id == assetId) {
        return asset.name;
      }
    }
    for (final asset in _assignedAssets) {
      if (asset.id == assetId) {
        return asset.name;
      }
    }
    return assetId;
  }

  List<String> _datasetLines() {
    return [
      for (final dataset in _datasets)
        '${dataset.name}: ${dataset.assetIds.map(_assetName).join('、')}',
    ];
  }

  bool _canAddDatasetAsset() {
    final dataset = _chosenDataset();
    final assetId = _chosenAssetTarget();
    return dataset != null && assetId != null && !dataset.contains(assetId);
  }

  bool _canRemoveDatasetAsset() {
    final dataset = _chosenDataset();
    final assetId = _chosenAssetTarget();
    return dataset != null && assetId != null && dataset.contains(assetId);
  }

  Future<void> _onCreateDataset() async {
    if (_saving ||
        !canCreateDataset(
          name: _datasetName.text,
          assetCount: _unassignedAssets.length,
        )) {
      return;
    }
    final name = _datasetName.text;
    final assetIds = [for (final asset in _unassignedAssets) asset.id];
    await _runProjectCommand(
      'グループを作っています',
      (python, projectPath, layoutPath, pptxPath) async {
        final datasetId = await createDataset(
          pythonExecutable: python,
          projectPath: projectPath,
          layoutPath: layoutPath,
          pptxPath: pptxPath,
          name: name,
          assetIds: assetIds,
        );
        _datasetId = datasetId;
        _datasetName.text = '';
      },
      '未割当の素材をグループにしました。枠へは割り当てていません。',
    );
  }

  Future<void> _onAddDatasetAsset() async {
    final dataset = _chosenDataset();
    final assetId = _chosenAssetTarget();
    if (dataset == null || assetId == null || _saving || !_canAddDatasetAsset()) {
      return;
    }
    await _runProjectCommand(
      'グループに加えています',
      (python, projectPath, layoutPath, pptxPath) => addDatasetAsset(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        datasetId: dataset.id,
        assetId: assetId,
      ),
      '選んだ素材をグループに加えました。枠へは割り当てていません。',
    );
  }

  Future<void> _onRemoveDatasetAsset() async {
    final dataset = _chosenDataset();
    final assetId = _chosenAssetTarget();
    if (dataset == null || assetId == null || _saving || !_canRemoveDatasetAsset()) {
      return;
    }
    await _runProjectCommand(
      'グループから外しています',
      (python, projectPath, layoutPath, pptxPath) => removeDatasetAsset(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
        datasetId: dataset.id,
        assetId: assetId,
      ),
      '選んだ素材をグループから外しました。素材の記録と元ファイルは残しています。',
    );
  }

  Future<void> _runProjectCommand(
    String progress,
    Future<void> Function(String python, String projectPath, String layoutPath, String pptxPath) action,
    String success,
  ) async {
    if (_saving) {
      return;
    }
    final layoutPath = _path.text.trim();
    final projectPath = projectPathForLayout(layoutPath);
    final pptxPath = pptxPathForLayout(layoutPath);
    final python = pythonExecutableNearLayout(layoutPath);
    if (projectPath == null || pptxPath == null || python == null) {
      setState(() => _error = '保存先が見つからないため、操作できません');
      return;
    }
    setState(() {
      _saving = true;
      _status = progress;
      _error = null;
    });
    try {
      await action(python, projectPath, layoutPath, pptxPath);
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = null;
        _error = '$error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) {
      return;
    }
    await _load();
    if (!mounted || _error != null) {
      return;
    }
    setState(() => _status = success);
  }

  String? _keptAssetTarget(List<RegisteredAsset> assets) {
    final ids = {for (final asset in assets) asset.id};
    if (_assetTargetId != null && ids.contains(_assetTargetId)) {
      return _assetTargetId;
    }
    if (assets.length == 1) {
      return assets.single.id;
    }
    return null;
  }

  String? _chosenShareTarget() {
    final target = _shareAssetId;
    if (target == null) {
      return null;
    }
    for (final asset in _assignedAssets) {
      if (asset.id == target) {
        return target;
      }
    }
    return null;
  }

  String? _keptShareTarget(List<AssignedAsset> assets) {
    final ids = {for (final asset in assets) asset.id};
    if (_shareAssetId != null && ids.contains(_shareAssetId)) {
      return _shareAssetId;
    }
    if (assets.length == 1) {
      return assets.single.id;
    }
    return null;
  }

  String? _keptAssignTarget(LayoutResult layout) {
    final frames = _containFrames(layout);
    final ids = {for (final frame in frames) frame.elementId};
    if (_assignTargetId != null && ids.contains(_assignTargetId)) {
      return _assignTargetId;
    }
    if (frames.length == 1) {
      return frames.single.elementId;
    }
    return null;
  }

  List<PlacedElement> _zoomFrames(LayoutResult? layout) {
    if (layout == null) {
      return const [];
    }
    return [
      for (final element in layout.elements)
        if (element.kind == 'image_frame' && element.fitMode == 'roi') element,
    ];
  }

  String? _chosenZoomTarget(LayoutResult? layout) {
    final target = _zoomTargetId;
    if (target == null) {
      return null;
    }
    for (final frame in _zoomFrames(layout)) {
      if (frame.elementId == target) {
        return target;
      }
    }
    return null;
  }

  String? _keptZoomTarget(LayoutResult layout, Map<String, String?> links) {
    final frames = _zoomFrames(layout);
    final ids = {for (final frame in frames) frame.elementId};
    if (_zoomTargetId != null && ids.contains(_zoomTargetId)) {
      return _zoomTargetId;
    }
    final selectedLink = _selectedRoiId == null ? null : links[_selectedRoiId];
    if (selectedLink != null && ids.contains(selectedLink)) {
      return selectedLink;
    }
    if (frames.length == 1) {
      return frames.single.elementId;
    }
    return null;
  }

  String _linkStatus(ZoomUpdate update) {
    final target = _elementName(_result, update.zoomLabel);
    final replaced = update.replacedRoiId;
    if (replaced == null) {
      return '選択した ROI を$targetへ連動しました。';
    }
    return '選択した ROI を$targetへ連動しました。$replaced の連動は外し、枠は残しました。';
  }

  String _elementName(LayoutResult? layout, String elementId) {
    if (layout == null) {
      return elementId;
    }
    for (final element in layout.elements) {
      if (element.elementId == elementId) {
        return element.displayName;
      }
    }
    return elementId;
  }

  String _linkedSummary(LayoutResult layout) {
    final names = <String>[];
    for (final entry in _zoomByRoi.entries) {
      if (entry.value == null) {
        continue;
      }
      var name = entry.key;
      for (final element in layout.elements) {
        if (element.elementId == entry.key) {
          name = element.displayName;
          break;
        }
      }
      names.add(name);
    }
    if (names.isEmpty) {
      return '拡大枠に連動している ROI はありません。';
    }
    return '拡大に連動中: ${names.join('、')}';
  }
}

bool _hasAnyRoi(LayoutResult? layout) {
  if (layout == null) {
    return false;
  }
  for (final element in layout.elements) {
    if (element.kind == 'roi') {
      return true;
    }
  }
  return false;
}

String _arrangedStatus(String arrangement) {
  switch (arrangement) {
    case 'vertical':
      return 'ROI の拡大画像を縦に並べました。';
    case 'grid':
      return 'ROI の拡大画像を格子に並べました。';
    default:
      return 'ROI の拡大画像を横に並べました。';
  }
}

bool _hasRoi(LayoutResult? layout, String? roiId) {
  if (layout == null || roiId == null) {
    return false;
  }
  for (final element in layout.elements) {
    if (element.elementId == roiId && element.kind == 'roi') {
      return true;
    }
  }
  return false;
}

String _createdStatus(String zoomLabel) {
  if (zoomLabel == '-') {
    return 'ROI を追加しました。空いている拡大枠がないため、枠だけを保存しました。';
  }
  if (zoomLabel == 'ambiguous') {
    return 'ROI を追加しました。拡大枠が複数あるため、連動先は自動では選んでいません。';
  }
  return 'ROI を追加し、拡大枠へ連動しました。';
}

String? _sourceId(LayoutResult layout, String roiId) {
  for (final element in layout.elements) {
    if (element.elementId == roiId) {
      return element.sourceElementId;
    }
  }
  return null;
}

SlideRect? _contentRect(LayoutResult layout, String? elementId) {
  if (elementId == null) {
    return null;
  }
  for (final element in layout.elements) {
    if (element.elementId == elementId) {
      return element.contentRect;
    }
  }
  return null;
}
