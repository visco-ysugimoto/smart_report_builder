import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:smart_report_preview/image_library.dart';
import 'package:smart_report_preview/layout_result.dart';
import 'package:smart_report_preview/roi_persist.dart';
import 'package:smart_report_preview/state/app_state.dart';

/// Python IPC 層の薄いラッパ。すべての操作は AppState を更新する。
///
/// 1 つの ReportSession を使い、各コマンドの実行後に layout / project JSON を反映する。
class ReportService {
  ReportService(this._state) {
    reportLayoutReady = (_) {};
  }

  final AppState _state;
  Directory? _tempDirectory;
  int _tempCounter = 0;

  /// 新規プロジェクトを作って開く。
  ///
  /// [paper] は '16x9' / 'portrait' / 'landscape'。
  Future<void> createProject({
    required String directory,
    required String paper,
    String preset = 'horizontal-2',
    bool replace = false,
  }) async {
    final python = _requirePython(directory);
    final projectPath = _joinPath(directory, 'project.json');
    final layoutPath = _joinPath(directory, 'layout.json');
    final pptxPath = _joinPath(directory, 'report.pptx');
    _state.setBusy(true, status: '新規プロジェクトを作成中');
    try {
      // 既存の new-project コマンド。horizontal 2 枚 + 説明文で始める。
      final res = await reportSession.run(python, [
        'new-project',
        directory,
        '--paper',
        paper,
        if (replace) '--replace',
      ]);
      _throwOnError(res, 'プロジェクトを作れません');
      await reportSession.open(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
      );
      _state.setProject(
        directory: directory,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
      );
      await _refresh();
      _state.setPreset(preset);
      if (preset != 'horizontal-2') {
        await pickLayout(preset: preset);
      }
      _state.setStep(WorkflowStep.master);
      _state.setStatus('プロジェクトを作成しました');
    } catch (exc) {
      _state.setError(exc.toString());
      rethrow;
    } finally {
      _state.setBusy(false);
    }
  }

  /// 既存プロジェクトを開く。
  Future<void> openProject(String projectPath) async {
    final directory = File(projectPath).parent.path;
    final layoutPath = _joinPath(directory, 'layout.json');
    final pptxPath = _joinPath(directory, 'report.pptx');
    final python = _requirePython(directory);
    _state.setBusy(true, status: 'プロジェクトを開いています');
    try {
      await reportSession.open(
        pythonExecutable: python,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
      );
      _state.setProject(
        directory: directory,
        projectPath: projectPath,
        layoutPath: layoutPath,
        pptxPath: pptxPath,
      );
      await _refresh();
      restoreLibraryFromProject();
      _state.setStep(
        (_state.slideCount > 1) ? WorkflowStep.expand : WorkflowStep.master,
      );
      _state.setStatus('プロジェクトを開きました');
    } catch (exc) {
      _state.setError(exc.toString());
      rethrow;
    } finally {
      _state.setBusy(false);
    }
  }

  Future<void> undo() async {
    if (!_state.hasOpenProject || _state.busy || !_state.canUndo) return;
    final projectPath = _state.projectPath!;
    final python = _requirePython(_state.projectDirectory!);
    _state.setBusy(true, status: '元に戻しています');
    try {
      final res = await reportSession.run(python, [
        'undo',
        projectPath,
        '--layout',
        _state.layoutPath!,
        '--pptx',
        _state.pptxPath!,
      ]);
      _throwOnError(res, '操作を戻せません');
      await _refresh();
      final active = _activeSlideId();
      if (active != null) _state.selectSlide(active);
      _state.setStatus('元に戻しました');
    } catch (exc) {
      _state.setError(exc.toString());
    } finally {
      _state.setBusy(false);
    }
  }

  Future<void> redo() async {
    if (!_state.hasOpenProject || _state.busy || !_state.canRedo) return;
    final projectPath = _state.projectPath!;
    final python = _requirePython(_state.projectDirectory!);
    _state.setBusy(true, status: 'やり直しています');
    try {
      final res = await reportSession.run(python, [
        'redo',
        projectPath,
        '--layout',
        _state.layoutPath!,
        '--pptx',
        _state.pptxPath!,
      ]);
      _throwOnError(res, '操作をやり直せません');
      await _refresh();
      final active = _activeSlideId();
      if (active != null) _state.selectSlide(active);
      _state.setStatus('やり直しました');
    } catch (exc) {
      _state.setError(exc.toString());
    } finally {
      _state.setBusy(false);
    }
  }

  Future<void> save() async {
    if (!_state.hasOpenProject) return;
    _state.setBusy(true, status: '保存しています');
    try {
      await reportSession.save();
      await _refresh();
      _state.setStatus('保存しました');
    } catch (exc) {
      _state.setError(exc.toString());
    } finally {
      _state.setBusy(false);
    }
  }

  /// レイアウトプリセットを変える。
  ///
  /// [perSlide] のときは表示中のスライドだけ。無いときは 1 枚目の型と、それを共有しているスライド。
  Future<void> pickLayout({
    required String preset,
    String? caption,
    String? slideId,
    bool perSlide = false,
  }) async {
    final target = perSlide ? (slideId ?? _firstSlideId()) : null;
    if (perSlide && (target == null || target.isEmpty)) {
      _state.setError('スライドが選ばれていません');
      return;
    }
    final projectPath = _state.projectPath!;
    final python = _requirePython(_state.projectDirectory!);
    _state.setBusy(true, status: '型を更新しています');
    try {
      final res = await reportSession.run(python, [
        'pick-layout',
        projectPath,
        '--preset',
        preset,
        if (target != null) ...['--slide', target],
        if (caption != null) ...['--caption', caption],
        '--layout',
        _state.layoutPath!,
        '--pptx',
        _state.pptxPath!,
      ]);
      _throwOnError(res, '型の変更に失敗しました');
      if (target != null) {
        _state.setSlidePreset(target, preset);
        _state.selectSlide(target);
      } else {
        _state.setPreset(preset);
      }
      await _refresh();
      _state.setStatus('型を更新しました');
    } catch (exc) {
      _state.setError(exc.toString());
    } finally {
      _state.setBusy(false);
    }
  }

  /// 画像枠の役割を変える。
  Future<void> pickRole({required String frameId, required String role}) async {
    final projectPath = _state.projectPath!;
    final python = _requirePython(_state.projectDirectory!);
    _state.setBusy(true, status: '役割を更新しています');
    try {
      final res = await reportSession.run(python, [
        'pick-roles',
        projectPath,
        '--frame',
        frameId,
        '--role',
        role,
        '--layout',
        _state.layoutPath!,
        '--pptx',
        _state.pptxPath!,
      ]);
      _throwOnError(res, '役割の変更に失敗しました');
      await _refresh();
    } catch (exc) {
      _state.setError(exc.toString());
    } finally {
      _state.setBusy(false);
    }
  }

  /// タイトル・見解のテンプレートを保存する。
  Future<void> setTemplates({String? title, String? caption}) async {
    if (!_state.hasOpenProject) return;
    final projectPath = _state.projectPath!;
    final python = _requirePython(_state.projectDirectory!);
    try {
      final res = await reportSession.run(python, [
        'set-templates',
        projectPath,
        if (title != null) ...['--title', title],
        if (caption != null) ...['--caption', caption],
        '--layout',
        _state.layoutPath!,
        '--pptx',
        _state.pptxPath!,
      ]);
      _throwOnError(res, 'テンプレートの保存に失敗しました');
      _state.setTemplates(title: title, caption: caption);
      await _refresh();
    } catch (exc) {
      _state.setError(exc.toString());
    }
  }

  /// ライブラリの画像をプロジェクト素材として登録する。
  ///
  /// `records` は各画像の `path`, `group`, `task`, `listName`, `listComment`,
  /// `listIndex`, `fileName`, `note` を含む。
  Future<bool> registerLibrary({
    required List<LibraryImage> images,
    bool replace = true,
    bool keepBindings = false,
  }) async {
    if (images.isEmpty) return true;
    if (!_state.hasOpenProject) return false;
    final projectPath = _state.projectPath!;
    final python = _requirePython(_state.projectDirectory!);
    _state.setBusy(true, status: '画像を登録しています');
    try {
      final startIndex = replace ? 1 : (_maxListIndex() + 1);
      final materialized = <Map<String, Object?>>[];
      for (var index = 0; index < images.length; index++) {
        final image = images[index];
        final path = await _materialize(image);
        materialized.add({
          'path': path,
          'source': image.filePath != null ? 'folder' : 'task-file',
          'listIndex': image.listIndex ?? (startIndex + index),
          'listName': image.listName,
          'listComment': image.listComment,
          'group': image.group,
          'task': image.task,
          'fileName': image.name,
          'note': image.note,
        });
      }
      final tempDir = await _ensureTempDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final recordsFile = File(
        '${tempDir.path}${Platform.pathSeparator}records_$stamp.json',
      );
      await recordsFile.writeAsString(jsonEncode(materialized));
      final res = await reportSession.run(python, [
        'register-source',
        projectPath,
        '--records',
        recordsFile.path,
        if (replace) '--replace',
        if (keepBindings) '--keep-bindings',
        '--layout',
        _state.layoutPath!,
        '--pptx',
        _state.pptxPath!,
      ]);
      _throwOnError(res, '画像の登録に失敗しました');
      try {
        await recordsFile.delete();
      } on FileSystemException {
        // 一時ファイルの残存は致命ではない。
      }
      await _refresh();
      _state.setStatus('${images.length} 件を登録しました');
      return true;
    } catch (exc) {
      _state.setError(exc.toString());
      return false;
    } finally {
      _state.setBusy(false);
    }
  }

  /// チェックが入っている画像だけを登録してから展開する。
  Future<void> expandUsingLibrary({int? rangeTo}) async {
    final included = _state.includedLibraryImages;
    if (_state.totalLibraryImages > 0 && included.isEmpty) {
      _state.setError('使う画像にチェックを入れてください');
      return;
    }
    if (included.isNotEmpty) {
      final registered = await registerLibrary(
        images: included,
        replace: true,
        keepBindings: true,
      );
      if (!registered) return;
    }
    await expand(rangeTo: rangeTo);
  }

  Future<void> setHeading({
    required String frameId,
    required String text,
    String? slideId,
  }) async {
    await editSlide(
      slideId:
          slideId ?? _state.selectedSlideId ?? _firstSlideId() ?? 'slide-1',
      heading: (frameId, text),
    );
  }

  Future<void> setHeadingPlace({
    required String frameId,
    required String place,
    String? slideId,
  }) async {
    await editSlide(
      slideId:
          slideId ?? _state.selectedSlideId ?? _firstSlideId() ?? 'slide-1',
      headingPlace: (frameId, place),
    );
  }

  Future<void> setCaptionPlace(String place) async {
    await editSlide(
      slideId: _state.selectedSlideId ?? _firstSlideId() ?? 'slide-1',
      captionPlace: place,
    );
  }

  Future<void> setCaptionShown(bool shown) async {
    await editSlide(
      slideId: _state.selectedSlideId ?? _firstSlideId() ?? 'slide-1',
      captionShown: shown,
    );
  }

  Future<void> setCaptionHeight(double height, {String? slideId}) async {
    await editSlide(
      slideId: slideId ?? _state.selectedSlideId ?? _firstSlideId() ?? 'slide-1',
      captionHeight: height,
    );
  }

  Future<void> setHeadingSize({
    required String frameId,
    required double size,
    String? slideId,
  }) async {
    await editSlide(
      slideId:
          slideId ?? _state.selectedSlideId ?? _firstSlideId() ?? 'slide-1',
      headingSize: (frameId, size),
    );
  }

  Future<void> setTextSize({
    required String textId,
    required double size,
    String? slideId,
  }) async {
    await editSlide(
      slideId:
          slideId ?? _state.selectedSlideId ?? _firstSlideId() ?? 'slide-1',
      textSize: (textId, size),
    );
  }

  Future<void> addFreeText({String text = 'テキスト', String? slideId}) async {
    await editSlide(
      slideId:
          slideId ?? _state.selectedSlideId ?? _firstSlideId() ?? 'slide-1',
      addText: true,
      newText: text,
    );
  }

  Future<void> moveFreeText({
    required String textId,
    required double x,
    required double y,
    required double width,
    required double height,
    String? slideId,
  }) async {
    await editSlide(
      slideId:
          slideId ?? _state.selectedSlideId ?? _firstSlideId() ?? 'slide-1',
      textBox: (textId, x, y, width, height),
    );
  }

  Future<void> deleteFreeText({required String textId, String? slideId}) async {
    await editSlide(
      slideId:
          slideId ?? _state.selectedSlideId ?? _firstSlideId() ?? 'slide-1',
      removeText: textId,
    );
    _state.selectFrame(null);
  }

  Future<void> setFreeText({
    required String textId,
    required String text,
    String? slideId,
  }) async {
    await editSlide(
      slideId:
          slideId ?? _state.selectedSlideId ?? _firstSlideId() ?? 'slide-1',
      textBody: (textId, text),
    );
  }

  /// 展開後に 1 枚目の編集へ戻る。画像一覧がメモリから落ちていれば素材から戻す。
  Future<void> returnToMaster() async {
    restoreLibraryFromProject();
    _state.setStep(WorkflowStep.master);
    final id = _firstSlideId();
    if (id == null || id.isEmpty) return;
    await activateSlide(id);
  }

  /// トレイが空のとき、登録済み素材から画像一覧を作り直す。
  void restoreLibraryFromProject() {
    if (_state.librarySources.isNotEmpty) return;
    final projectJson = _state.projectJson;
    final directory = _state.projectDirectory;
    if (projectJson == null || directory == null) return;
    try {
      final source = librarySourceFromProject(
        projectJson: projectJson,
        projectDirectory: directory,
      );
      if (source == null) return;
      _state.addLibrarySource(source);
    } on FormatException {
      return;
    }
  }

  /// 現在のテンプレートとソースを使って N 枚のスライドへ展開する。
  Future<void> expand({int? rangeTo}) async {
    if (!_state.hasOpenProject) return;
    final projectPath = _state.projectPath!;
    final python = _requirePython(_state.projectDirectory!);
    _state.setBusy(true, status: 'スライドを展開しています');
    try {
      final res = await reportSession.run(python, [
        'expand-slides',
        projectPath,
        if (rangeTo != null) ...['--range-to', rangeTo.toString()],
        '--overwrite-labels',
        '--layout',
        _state.layoutPath!,
        '--pptx',
        _state.pptxPath!,
      ]);
      _throwOnError(res, '展開に失敗しました');
      _state.clearSlidePresets();
      await _refresh();
      _state.setStep(WorkflowStep.expand);
      _state.selectSlide(_firstSlideId());
      _state.setStatus('${_state.slideCount} 枚のスライドに展開しました');
    } catch (exc) {
      _state.setError(exc.toString());
    } finally {
      _state.setBusy(false);
    }
  }

  /// タイムラインで選んだスライドを、表示中のレイアウトにする。
  Future<void> activateSlide(String slideId) async {
    if (!_state.hasOpenProject || slideId.isEmpty) return;
    if (_state.selectedSlideId == slideId && _state.result != null) {
      final current = _activeSlideId();
      if (current == null || current == slideId) return;
    }
    final projectPath = _state.projectPath!;
    final python = _requirePython(_state.projectDirectory!);
    _state.setBusy(true, status: 'スライドを表示しています');
    try {
      final res = await reportSession.run(python, [
        'activate-slide',
        projectPath,
        slideId,
        '--layout',
        _state.layoutPath!,
        '--pptx',
        _state.pptxPath!,
      ]);
      _throwOnError(res, 'スライドを表示できません');
      _state.selectSlide(slideId);
      await _refresh();
    } catch (exc) {
      _state.setError(exc.toString());
    } finally {
      _state.setBusy(false);
    }
  }

  /// 特定スライドの要素（タイトル / 説明 / 画像 / 役割）を更新する。
  Future<void> editSlide({
    required String slideId,
    String? title,
    String? caption,
    (String frameId, String assetId)? bind,
    String? unbind,
    (String frameId, String role)? role,
    (String zoomFrameId, String sourceFrameId)? zoomFrom,
    (String zoomFrameId, double x, double y, double width, double height)?
    zoomRect,
    (String frameId, String text)? heading,
    (String frameId, String place)? headingPlace,
    (String frameId, double size)? headingSize,
    String? captionPlace,
    bool? captionShown,
    double? captionHeight,
    (String textId, double size)? textSize,
    bool addText = false,
    String? newText,
    (String textId, double x, double y, double width, double height)? textBox,
    (String textId, String text)? textBody,
    String? removeText,
  }) async {
    if (!_state.hasOpenProject) return;
    final projectPath = _state.projectPath!;
    final python = _requirePython(_state.projectDirectory!);
    _state.setBusy(true, status: 'スライドを更新しています');
    try {
      final res = await reportSession.run(python, [
        'edit-slide',
        projectPath,
        '--slide',
        slideId,
        if (title != null) ...['--title', title],
        if (caption != null) ...['--caption', caption],
        if (bind != null) ...['--bind', bind.$1, bind.$2],
        if (unbind != null) ...['--unbind', unbind],
        if (role != null) ...['--role', role.$1, role.$2],
        if (zoomFrom != null) ...['--zoom-from', zoomFrom.$1, zoomFrom.$2],
        if (zoomRect != null) ...[
          '--zoom-rect',
          zoomRect.$1,
          zoomRect.$2.toStringAsFixed(6),
          zoomRect.$3.toStringAsFixed(6),
          zoomRect.$4.toStringAsFixed(6),
          zoomRect.$5.toStringAsFixed(6),
        ],
        if (heading != null) ...['--heading', heading.$1, heading.$2],
        if (headingPlace != null) ...[
          '--heading-place',
          headingPlace.$1,
          headingPlace.$2,
        ],
        if (headingSize != null) ...[
          '--heading-size',
          headingSize.$1,
          headingSize.$2.round().toString(),
        ],
        if (captionPlace != null) ...['--caption-place', captionPlace],
        if (captionShown != null) ...[
          '--caption-use',
          captionShown ? 'on' : 'off',
        ],
        if (captionHeight != null) ...[
          '--caption-height',
          captionHeight.toStringAsFixed(1),
        ],
        if (textSize != null) ...[
          '--text-size',
          textSize.$1,
          textSize.$2.round().toString(),
        ],
        if (addText) ...['--add-text', '--text', newText ?? 'テキスト'],
        if (textBox != null) ...[
          '--text-box',
          textBox.$1,
          textBox.$2.toStringAsFixed(2),
          textBox.$3.toStringAsFixed(2),
          textBox.$4.toStringAsFixed(2),
          textBox.$5.toStringAsFixed(2),
        ],
        if (textBody != null) ...['--text-body', textBody.$1, textBody.$2],
        if (removeText != null) ...['--remove-text', removeText],
        '--layout',
        _state.layoutPath!,
        '--pptx',
        _state.pptxPath!,
      ]);
      _throwOnError(res, 'スライドの更新に失敗しました');
      await _refresh();
    } catch (exc) {
      _state.setError(exc.toString());
    } finally {
      _state.setBusy(false);
    }
  }

  /// 画像を、親の並びの中の 0〜1 の矩形へ合わせる。
  Future<void> resizeFrame({
    required String frameId,
    required double x,
    required double y,
    required double width,
    required double height,
    String? slideId,
  }) async {
    if (!_state.hasOpenProject) return;
    final projectPath = _state.projectPath!;
    final python = _requirePython(_state.projectDirectory!);
    _state.setBusy(true, status: '画像の大きさを更新しています');
    try {
      final res = await reportSession.run(python, [
        'resize-frame',
        projectPath,
        frameId,
        x.toStringAsFixed(6),
        y.toStringAsFixed(6),
        width.toStringAsFixed(6),
        height.toStringAsFixed(6),
        if (slideId != null && slideId.isNotEmpty) ...['--slide', slideId],
        '--layout',
        _state.layoutPath!,
        '--pptx',
        _state.pptxPath!,
      ]);
      _throwOnError(res, '画像の大きさの変更に失敗しました');
      await _refresh();
    } catch (exc) {
      _state.setError(exc.toString());
    } finally {
      _state.setBusy(false);
    }
  }

  /// 拡大範囲を、元画像に対する 0〜1 の矩形で置き換える。
  Future<void> moveZoomRegion({
    required String zoomFrameId,
    required double x,
    required double y,
    required double width,
    required double height,
    String? slideId,
  }) async {
    await editSlide(
      slideId:
          slideId ?? _state.selectedSlideId ?? _firstSlideId() ?? 'slide-1',
      zoomRect: (zoomFrameId, x, y, width, height),
    );
  }

  /// 拡大枠が、どの画像枠を拡大するかを決める。
  Future<void> linkZoomSource({
    required String zoomFrameId,
    required String sourceFrameId,
    String? slideId,
  }) async {
    await editSlide(
      slideId:
          slideId ?? _state.selectedSlideId ?? _firstSlideId() ?? 'slide-1',
      zoomFrom: (zoomFrameId, sourceFrameId),
    );
  }

  /// 指定パスへ PPTX を書き出す。
  Future<void> exportPptx(String destination) async {
    if (!_state.hasOpenProject) return;
    // まず未保存の変更を保存して layout / pptx を揃える。
    await save();
    final projectPath = _state.projectPath!;
    final python = _requirePython(_state.projectDirectory!);
    _state.setBusy(true, status: 'PPTX を書き出しています');
    try {
      final res = await reportSession.run(python, [
        'save-pptx',
        projectPath,
        '--out',
        destination,
      ]);
      _throwOnError(res, 'PPTX の書き出しに失敗しました');
      _state.setStatus('PPTX を書き出しました: $destination');
    } catch (exc) {
      _state.setError(exc.toString());
    } finally {
      _state.setBusy(false);
    }
  }

  /// 画像 1 枚を特定の画像枠へ割り当てる。マスター / 展開どちらでも使う。
  ///
  /// トレイの画像がまだ素材として登録されていない場合は、まずその 1 枚だけを
  /// 追記モード (`--replace` なし) で登録してから割り当てる。これにより
  /// 「取り込み → ドラッグ」の操作だけで配置が完結する。
  Future<void> assignLibraryImage({
    required String frameId,
    required LibraryImage image,
    String? slideId,
  }) async {
    if (!_state.hasOpenProject) return;
    var assetId = _findAssetIdForPath(image);
    if (assetId == null) {
      final registered = await registerLibrary(images: [image], replace: false);
      if (!registered) return;
      assetId = _findAssetIdForPath(image);
    }
    if (assetId == null) {
      _state.setError('この画像を素材として登録できませんでした');
      return;
    }
    await editSlide(
      slideId:
          slideId ?? _state.selectedSlideId ?? _firstSlideId() ?? 'slide-1',
      bind: (frameId, assetId),
    );
  }

  Future<void> _refresh() async {
    final layoutJson = reportSession.layoutJson;
    final projectJson = reportSession.projectJson;
    LayoutResult? layout;
    if (layoutJson != null) {
      try {
        layout = parseLayoutResult(layoutJson);
      } on FormatException {
        layout = null;
      }
    }
    _state.updateDocuments(layout: layout, projectJson: projectJson);
    _state.setHistory(canUndo: reportSession.canUndo, canRedo: reportSession.canRedo);
  }

  void _throwOnError(ProcessResult res, String fallback) {
    if (res.exitCode == 0) return;
    final message = res.stderr.toString().trim();
    throw FormatException(message.isEmpty ? fallback : message);
  }

  String? _findAssetIdForPath(LibraryImage image) {
    final json = _state.projectJson;
    if (json == null) return null;
    final decoded = jsonDecode(json);
    if (decoded is! Map || decoded['assets'] is! List) return null;
    final target = image.filePath;
    final name = image.name.toLowerCase();
    for (final raw in decoded['assets'] as List) {
      if (raw is! Map) continue;
      final path = (raw['path'] ?? '').toString();
      final file = (raw['fileName'] ?? '').toString().toLowerCase();
      final displayName = (raw['displayName'] ?? '').toString().toLowerCase();
      if (target != null && path.isNotEmpty) {
        if (path.replaceAll('\\', '/').toLowerCase() ==
                target.replaceAll('\\', '/').toLowerCase() ||
            path.endsWith(target.split(Platform.pathSeparator).last)) {
          return raw['id']?.toString();
        }
      }
      if (file == name ||
          displayName == name.replaceAll(RegExp(r'\.[^.]+$'), '')) {
        return raw['id']?.toString();
      }
    }
    return null;
  }

  int _maxListIndex() {
    final json = _state.projectJson;
    if (json == null) return 0;
    final decoded = jsonDecode(json);
    if (decoded is! Map) return 0;
    final assets = decoded['assets'];
    if (assets is! List) return 0;
    var max = 0;
    for (final raw in assets) {
      if (raw is! Map) continue;
      final value = raw['listIndex'];
      if (value is int && value > max) max = value;
      if (value is num && value > max) max = value.toInt();
    }
    return max;
  }

  String? _activeSlideId() {
    final json = _state.projectJson;
    if (json == null) return null;
    final decoded = jsonDecode(json);
    if (decoded is! Map) return null;
    final active = decoded['activeSlideId'];
    if (active != null) return active.toString();
    return _firstSlideId();
  }

  String? _firstSlideId() {
    final json = _state.projectJson;
    if (json == null) return null;
    final decoded = jsonDecode(json);
    if (decoded is! Map) return null;
    final slides = decoded['slides'];
    if (slides is List && slides.isNotEmpty) {
      final first = slides.first;
      if (first is Map && first['id'] != null) return first['id'].toString();
    }
    return decoded['slide']?['id']?.toString();
  }

  Future<Directory> _ensureTempDirectory() async {
    final existing = _tempDirectory;
    if (existing != null && await existing.exists()) return existing;
    final created = await Directory.systemTemp.createTemp('srb-');
    _tempDirectory = created;
    return created;
  }

  Future<String> _materialize(LibraryImage image) async {
    final path = image.filePath;
    if (path != null && await File(path).exists()) return path;
    final entry = image.archiveEntry;
    if (entry == null) {
      throw const FormatException('画像の実体がありません');
    }
    // タスクファイルの中の画像は、Zip から取り出して一時フォルダへ置く。
    final sources = _state.librarySources
        .where((source) => source.id == image.sourceId)
        .toList();
    if (sources.isEmpty) {
      throw const FormatException('ソースが見つかりません');
    }
    final catalog = sources.first.zipCatalog;
    if (catalog == null) {
      throw const FormatException('タスクファイルの一覧がありません');
    }
    final bytes = readZipEntryBytes(catalog, entry);
    final temp = await _ensureTempDirectory();
    _tempCounter += 1;
    final extension = image.name.contains('.')
        ? image.name.substring(image.name.lastIndexOf('.'))
        : '.bin';
    final counter = _tempCounter;
    final target = File(
      '${temp.path}${Platform.pathSeparator}img_$counter$extension',
    );
    await target.writeAsBytes(bytes);
    return target.path;
  }

  String _requirePython(String directory) {
    final python = pythonExecutableNearLayout(
      '$directory${Platform.pathSeparator}layout.json',
    );
    if (python == null) {
      throw const FormatException('Python 仮想環境が見つかりません。.venv を作ってください');
    }
    return python;
  }

  String _joinPath(String directory, String name) {
    final separator = Platform.pathSeparator;
    if (directory.endsWith(separator)) return '$directory$name';
    return '$directory$separator$name';
  }
}
