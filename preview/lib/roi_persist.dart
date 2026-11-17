import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:smart_report_preview/layout_result.dart';
import 'package:smart_report_preview/roi_links.dart';

/// 配置 JSON がディスクに書かれたとき。PPTX の書き出し完了は待たない。
void Function(String layoutPath)? reportLayoutReady;

/// 開いているプロジェクトの編集を、保存までメモリに留める。
final reportSession = ReportSession();

const _sessionDirectCommands = {'new-project', 'open-pptx', 'export-pptx'};

class ReportSession {
  Process? _process;
  Future<void> _queue = Future<void>.value();
  Completer<String>? _waiter;
  String? _layoutPath;
  String? layoutJson;
  String? projectJson;
  bool dirty = false;
  bool _opened = false;

  String? get openedLayoutPath => _layoutPath;

  bool covers(String layoutPath) {
    final opened = _layoutPath;
    if (!_opened || opened == null || layoutJson == null || projectJson == null) {
      return false;
    }
    return _samePath(opened, layoutPath);
  }

  void forgetSnapshot() {
    _layoutPath = null;
    layoutJson = null;
    projectJson = null;
    dirty = false;
  }

  Future<void> open({
    required String pythonExecutable,
    required String projectPath,
    required String layoutPath,
    required String pptxPath,
  }) {
    return _enqueue(() async {
      await _ensure(pythonExecutable);
      final reply = await _request({
        'op': 'open',
        'project': projectPath,
        'layout': layoutPath,
        'pptx': pptxPath,
      });
      _opened = reply['code'] == 0;
      if (!_opened) {
        throw FormatException(_replyError(reply, 'プロジェクトを開けません'));
      }
      _layoutPath = layoutPath;
      _takeDocuments(reply);
    });
  }

  Future<void> save() {
    return _enqueue(() async {
      await _requireProcess();
      final reply = await _request({'op': 'save'});
      if (reply['code'] != 0) {
        throw FormatException(_replyError(reply, '保存に失敗しました'));
      }
      _takeDocuments(reply);
      dirty = false;
    });
  }

  void close() {
    final process = _process;
    _process = null;
    _opened = false;
    forgetSnapshot();
    process?.kill();
  }

  Future<ProcessResult> run(String executable, List<String> arguments) {
    return _enqueue(() async {
      final args = _roiEditArgs(arguments);
      final command = args.isEmpty ? null : args.first;
      await _ensure(executable);
      if (!_opened && (command == null || !_sessionDirectCommands.contains(command))) {
        throw const FormatException('プロジェクトの準備が終わっていません');
      }
      final reply = await _request({'op': 'run', 'args': args});
      _takeDocuments(reply);
      return ProcessResult(
        _process?.pid ?? 0,
        reply['code'] is int ? reply['code'] as int : 1,
        reply['stdout']?.toString() ?? '',
        reply['stderr']?.toString() ?? '',
      );
    });
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _ensure(String python) async {
    if (_process != null) {
      return;
    }
    final process = await Process.start(
      python,
      ['-m', 'smart_report_builder.roi_edit', 'session'],
      environment: const {
        'PYTHONIOENCODING': 'utf-8',
        'PYTHONUTF8': '1',
      },
    );
    _process = process;
    _opened = false;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final waiter = _waiter;
          if (waiter != null && !waiter.isCompleted && line.isNotEmpty) {
            waiter.complete(line);
          }
        });
    process.exitCode.then((_) {
      if (identical(_process, process)) {
        _process = null;
        _opened = false;
      }
    });
  }

  Future<void> _requireProcess() async {
    if (_process == null || !_opened) {
      throw const FormatException('プロジェクトの準備が終わっていません');
    }
  }

  Future<Map<String, dynamic>> _request(Map<String, dynamic> body) async {
    final process = _process;
    if (process == null) {
      throw const FormatException('編集処理が起動していません');
    }
    final waiter = Completer<String>();
    _waiter = waiter;
    process.stdin.writeln(jsonEncode(body));
    await process.stdin.flush();
    final line = await waiter.future.timeout(
      const Duration(minutes: 3),
      onTimeout: () => throw const FormatException('編集処理が応答しません'),
    );
    final decoded = jsonDecode(line);
    if (decoded is! Map) {
      throw const FormatException('編集処理の応答を読めません');
    }
    return Map<String, dynamic>.from(decoded);
  }

  void _takeDocuments(Map<String, dynamic> reply) {
    if (reply['project'] is Map) {
      projectJson = jsonEncode(reply['project']);
    }
    if (reply['layout'] is Map) {
      layoutJson = jsonEncode(reply['layout']);
    }
    if (reply.containsKey('dirty')) {
      dirty = reply['dirty'] == true;
    }
  }
}

String _replyError(Map<String, dynamic> reply, String fallback) {
  final message = reply['stderr']?.toString().trim() ?? '';
  return message.isEmpty ? fallback : message;
}

List<String> _roiEditArgs(List<String> arguments) {
  final args = [...arguments];
  if (args.isNotEmpty && args.first == '-m') {
    args.removeAt(0);
  }
  if (args.isNotEmpty && args.first == 'smart_report_builder.roi_edit') {
    args.removeAt(0);
  }
  return args;
}

bool _samePath(String left, String right) {
  return left.replaceAll('\\', '/').toLowerCase() ==
      right.replaceAll('\\', '/').toLowerCase();
}

Future<ProcessResult> runReportCommand(
  String executable,
  List<String> arguments,
) {
  return reportSession.run(executable, arguments);
}

/// 新しい ROI を追加する。戻り値は拡大枠 ID、`-`、`ambiguous` のいずれか。
Future<String> createNormalizedRoi({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String sourceElementId,
  required SlideRect normalized,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'create',
    projectPath,
    sourceElementId,
    _number(normalized.x),
    _number(normalized.y),
    _number(normalized.width),
    _number(normalized.height),
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'ROI の追加に失敗しました' : message);
  }
  return _zoomLabel('${result.stdout}');
}

String _zoomLabel(String stdout) {
  for (final line in stdout.split('\n')) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('zoom ')) {
      continue;
    }
    final value = trimmed.substring('zoom '.length).trim();
    return value.isEmpty ? '-' : value;
  }
  return '-';
}

class ZoomUpdate {
  const ZoomUpdate({required this.zoomLabel, required this.replacedRoiId});

  final String zoomLabel;
  final String? replacedRoiId;
}

/// 選択した ROI の拡大枠への連動を付け替える。
Future<ZoomUpdate> setRoiZoom({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String roiId,
  required bool linked,
  String? zoomElementId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    linked ? 'link' : 'unlink',
    projectPath,
    roiId,
    if (linked && zoomElementId != null) ...['--zoom', zoomElementId],
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'ROI の連動を変更できません' : message);
  }
  return _zoomUpdate('${result.stdout}');
}

ZoomUpdate _zoomUpdate(String stdout) {
  var zoomLabel = '-';
  String? replaced;
  for (final line in stdout.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('zoom ')) {
      final value = trimmed.substring('zoom '.length).trim();
      zoomLabel = value.isEmpty ? '-' : value;
    } else if (trimmed.startsWith('replaced ')) {
      final value = trimmed.substring('replaced '.length).trim();
      replaced = value.isEmpty || value == '-' ? null : value;
    }
  }
  return ZoomUpdate(zoomLabel: zoomLabel, replacedRoiId: replaced);
}

class DuplicateResult {
  const DuplicateResult({required this.roiId, required this.shifted});

  final String roiId;
  final bool shifted;
}

/// `duplicate` コマンドの標準出力から、新しい ID と移動の有無を読む。
DuplicateResult parseDuplicateResult(String stdout) {
  String? roiId;
  var shifted = true;
  for (final line in stdout.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('duplicated ')) {
      roiId = trimmed.substring('duplicated '.length).trim();
    } else if (trimmed == 'shift no') {
      shifted = false;
    } else if (trimmed == 'shift yes') {
      shifted = true;
    }
  }
  if (roiId == null || roiId.isEmpty) {
    throw const FormatException('複製した ROI の ID がありません');
  }
  return DuplicateResult(roiId: roiId, shifted: shifted);
}

/// 選択した ROI を複製し、配置と PPTX を計算し直す。
Future<DuplicateResult> duplicateRoi({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String roiId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'duplicate',
    projectPath,
    roiId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'ROI の複製に失敗しました' : message);
  }
  return parseDuplicateResult('${result.stdout}');
}

/// 選択した ROI の表示名だけを変え、配置と PPTX を計算し直す。
Future<void> renameRoi({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String roiId,
  required String name,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'rename',
    projectPath,
    roiId,
    '--name',
    name.trim(),
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'ROI の名前を保存できません' : message);
  }
}

/// 直前の ROI 操作を一つ戻し、配置と PPTX を計算し直す。
Future<void> undoLastRoiEdit({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'undo',
    projectPath,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'ROI の操作を戻せません' : message);
  }
}

/// 元に戻した直前の ROI 操作をやり直し、配置と PPTX を計算し直す。
Future<void> redoLastRoiEdit({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'redo',
    projectPath,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'ROI の操作をやり直せません' : message);
  }
}

/// 画像ファイルを選ぶ。キャンセルしたときは null。元ファイルは開かない。
Future<String?> pickImageFile() async {
  const script = r'''
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Filter = '画像|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff;*.webp|すべてのファイル|*.*'
$dialog.CheckFileExists = $true
$result = $dialog.ShowDialog()
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::Out.WriteLine($dialog.FileName)
}
''';
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-STA',
    '-Command',
    script,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '画像を選択できません' : message);
  }
  final path = '${result.stdout}'.trim();
  if (path.isEmpty) {
    return null;
  }
  return path;
}

/// 画像ファイルを複数選ぶ。キャンセルしたときは空。
Future<List<String>> pickImageFiles() async {
  const script = r'''
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Filter = '画像|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff;*.webp|すべてのファイル|*.*'
$dialog.Multiselect = $true
$dialog.CheckFileExists = $true
$result = $dialog.ShowDialog()
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
  foreach ($name in $dialog.FileNames) {
    [Console]::Out.WriteLine($name)
  }
}
''';
  final output = await _dialogOutput(script, '画像を選択できません');
  return [
    for (final line in output.split(RegExp(r'\r?\n')))
      if (line.trim().isNotEmpty) line.trim(),
  ];
}

/// プレビューする PPTX か配置 JSON を選ぶ。キャンセルしたときは null。
Future<String?> pickPreviewFile({String? initialDirectory}) async {
  final start = (initialDirectory ?? '').replaceAll("'", "''");
  final script = r'''
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = 'プレビューを開く'
$dialog.Filter = 'PPTX と配置|*.pptx;*.json|PowerPoint|*.pptx|配置 JSON|*.json'
$dialog.CheckFileExists = $true
$dialog.InitialDirectory = '__INITIAL__'
$owner = New-Object System.Windows.Forms.Form
$owner.TopMost = $true
$owner.ShowInTaskbar = $false
$owner.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$owner.StartPosition = 'CenterScreen'
$owner.Size = New-Object System.Drawing.Size(1, 1)
$owner.Opacity = 0.01
$owner.Show()
$owner.Activate()
$result = $dialog.ShowDialog($owner)
$owner.Dispose()
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::Out.WriteLine($dialog.FileName)
}
'''.replaceAll('__INITIAL__', start);
  final output = (await _dialogOutput(script, 'ファイルを選択できません')).trim();
  if (output.isEmpty) {
    return null;
  }
  return output;
}

/// タスクファイルを選ぶ。キャンセルしたときは null。
Future<String?> pickTaskFile() async {
  const script = r'''
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Filter = 'タスクファイル|*.ziq;*.zit;*.zii;*.zig;*.zia;*.zip|すべてのファイル|*.*'
$dialog.CheckFileExists = $true
$result = $dialog.ShowDialog()
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::Out.WriteLine($dialog.FileName)
}
''';
  final output = (await _dialogOutput(script, 'タスクファイルを選択できません')).trim();
  if (output.isEmpty) {
    return null;
  }
  return output;
}

Future<String> _dialogOutput(String script, String fallback) async {
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-STA',
    '-Command',
    script,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? fallback : message);
  }
  return '${result.stdout}';
}

class FolderRegistration {
  const FolderRegistration({required this.added, required this.skipped});

  final int added;
  final int skipped;
}

FolderRegistration parseFolderRegistration(String output) {
  final match = RegExp(
    r'^registered (\d+) skipped (\d+)$',
  ).firstMatch(output.trim());
  if (match == null) {
    throw const FormatException('登録結果を読めません');
  }
  return FolderRegistration(
    added: int.parse(match.group(1)!),
    skipped: int.parse(match.group(2)!),
  );
}

/// フォルダを選ぶ。キャンセルしたときは null。
Future<String?> pickFolder() async {
  const script = r'''
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
$result = $dialog.ShowDialog()
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::Out.WriteLine($dialog.SelectedPath)
}
''';
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-STA',
    '-Command',
    script,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'フォルダを選択できません' : message);
  }
  final path = '${result.stdout}'.trim();
  if (path.isEmpty) {
    return null;
  }
  return path;
}

class ReportLayoutOption {
  const ReportLayoutOption({required this.id, required this.name});

  final String id;
  final String name;
}

class ReportPage {
  const ReportPage({
    required this.id,
    required this.name,
    required this.layoutId,
  });

  final String id;
  final String name;
  final String layoutId;
}

class ReportPages {
  const ReportPages({
    required this.pages,
    required this.layouts,
    this.activeId,
  });

  final List<ReportPage> pages;
  final List<ReportLayoutOption> layouts;
  final String? activeId;
}

ReportPages parseReportPages(String projectJson) {
  final decoded = jsonDecode(projectJson);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('プロジェクトの形式が違います');
  }
  final slides = decoded['slides'];
  final layouts = decoded['layouts'];
  if (slides is List && layouts is List) {
    return ReportPages(
      pages: [
        for (final item in slides)
          if (item is Map)
            ReportPage(
              id: '${item['id']}',
              name: '${item['name']}',
              layoutId: '${item['layoutId']}',
            ),
      ],
      layouts: [
        for (final item in layouts)
          if (item is Map)
            ReportLayoutOption(id: '${item['id']}', name: '${item['name']}'),
      ],
      activeId: decoded['activeSlideId'] == null
          ? null
          : '${decoded['activeSlideId']}',
    );
  }
  final raw = decoded['pages'];
  if (raw is List) {
    final pages = <ReportPage>[];
    final options = <ReportLayoutOption>[];
    var number = 1;
    for (final item in raw) {
      if (item is! Map) {
        continue;
      }
      final layoutId = 'layout-$number';
      options.add(ReportLayoutOption(id: layoutId, name: '${item['name']}'));
      pages.add(
        ReportPage(
          id: '${item['id']}',
          name: '${item['name']}',
          layoutId: layoutId,
        ),
      );
      number += 1;
    }
    final active = decoded['activePageId'];
    return ReportPages(
      pages: pages,
      layouts: options,
      activeId: active == null ? null : '$active',
    );
  }
  final master = decoded['contentMaster'];
  final name = master is Map ? master['name'] : null;
  if (name == null) {
    return const ReportPages(pages: [], layouts: []);
  }
  return ReportPages(
    pages: [
      const ReportPage(id: 'slide-1', name: 'スライド1', layoutId: 'layout-1'),
    ],
    layouts: [ReportLayoutOption(id: 'layout-1', name: '$name')],
    activeId: 'slide-1',
  );
}

/// 開いているプロジェクトへ、別のレイアウトを足す。ファイルは増やさない。
Future<void> addReportLayout({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required int imageCount,
  required String arrangement,
  required String template,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'add-layout',
    projectPath,
    '--images',
    '$imageCount',
    '--arrangement',
    arrangement,
    '--template',
    template,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'レイアウトを追加できません' : message);
  }
}

Future<void> addReportSlide({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'add-slide',
    projectPath,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'スライドを追加できません' : message);
  }
}

Future<void> setReportSlideLayout({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String slideId,
  required String layoutId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'set-slide-layout',
    projectPath,
    slideId,
    layoutId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'スライドのレイアウトを変更できません' : message);
  }
}

Future<void> activateReportLayout({
  required String pythonExecutable,
  required String projectPath,
  required String pageId,
  required String layoutPath,
  required String pptxPath,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'activate-layout',
    projectPath,
    pageId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'スライドを表示できません' : message);
  }
}

Future<void> removeReportLayout({
  required String pythonExecutable,
  required String projectPath,
  required String pageId,
  required String layoutPath,
  required String pptxPath,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'remove-layout',
    projectPath,
    pageId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'スライドを削除できません' : message);
  }
}

/// 元の PPTX は変えず、撮像スライドのプレビュー用プロジェクトを作る。
Future<void> openPptxPreview({
  required String pythonExecutable,
  required String pptxPath,
  required String directory,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'open-pptx',
    pptxPath,
    '--out',
    directory,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'PPTX をプレビューできません' : message);
  }
}

/// 撮像スライドのページタイトルを保存する。
Future<List<String>> registerOrderedAssets({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String payload,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'register-ordered',
    projectPath,
    '--payload',
    payload,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '一覧を登録できません' : message);
  }
  return [
    for (final line in '${result.stdout}'.split(RegExp(r'\r?\n')))
      if (line.startsWith('asset ')) line.substring('asset '.length).trim(),
  ];
}

Future<void> saveAssignmentRule({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String payload,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'set-assignment-rule',
    projectPath,
    '--payload',
    payload,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '割付ルールを保存できません' : message);
  }
}

class OrderedCandidate {
  const OrderedCandidate({
    required this.slideOrdinal,
    required this.slideId,
    required this.frameIndex,
    required this.elementId,
    required this.itemNumber,
    required this.assetId,
    required this.assetName,
    required this.status,
    required this.label,
    required this.reason,
  });

  final int slideOrdinal;
  final String slideId;
  final int frameIndex;
  final String elementId;
  final int itemNumber;
  final String? assetId;
  final String assetName;
  final String status;
  final String label;
  final String reason;

  String get key => '$slideOrdinal:$frameIndex';
}

class OrderedProposal {
  const OrderedProposal({required this.warnings, required this.candidates});

  final List<String> warnings;
  final List<OrderedCandidate> candidates;
}

OrderedProposal parseOrderedProposal(String stdout) {
  final line = stdout
      .split(RegExp(r'\r?\n'))
      .map((item) => item.trim())
      .lastWhere((item) => item.startsWith('{'), orElse: () => '');
  if (line.isEmpty) {
    return const OrderedProposal(warnings: [], candidates: []);
  }
  final decoded = jsonDecode(line);
  if (decoded is! Map) {
    throw const FormatException('割付候補を読めません');
  }
  final warnings = [
    for (final item in decoded['warnings'] as List? ?? const []) item.toString(),
  ];
  final candidates = <OrderedCandidate>[];
  for (final item in decoded['candidates'] as List? ?? const []) {
    if (item is! Map) {
      continue;
    }
    candidates.add(
      OrderedCandidate(
        slideOrdinal: (item['slideOrdinal'] as num).toInt(),
        slideId: item['slideId']?.toString() ?? '',
        frameIndex: (item['frameIndex'] as num).toInt(),
        elementId: item['elementId']?.toString() ?? '',
        itemNumber: (item['itemNumber'] as num).toInt(),
        assetId: item['assetId']?.toString(),
        assetName: item['assetName']?.toString() ?? '',
        status: item['status']?.toString() ?? '',
        label: item['label']?.toString() ?? '',
        reason: item['reason']?.toString() ?? '',
      ),
    );
  }
  return OrderedProposal(warnings: warnings, candidates: candidates);
}

Future<OrderedProposal> proposeOrderedAssignment({
  required String pythonExecutable,
  required String projectPath,
  required String group,
  required String task,
  required String listName,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'propose-ordered',
    projectPath,
    '--group',
    group,
    '--task',
    task,
    '--list-name',
    listName,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '割付候補を作れません' : message);
  }
  return parseOrderedProposal('${result.stdout}');
}

Future<void> acceptOrderedAssignment({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String group,
  required String task,
  required String listName,
  int? ordinal,
  int? frame,
}) async {
  final arguments = <String>[
    '-m',
    'smart_report_builder.roi_edit',
    'accept-ordered',
    projectPath,
    '--group',
    group,
    '--task',
    task,
    '--list-name',
    listName,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ];
  if (ordinal != null && frame != null) {
    arguments.addAll(['--ordinal', '$ordinal', '--frame', '$frame']);
  }
  final result = await runReportCommand(pythonExecutable, arguments);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '割付候補を採用できません' : message);
  }
}

Future<void> setSlideFinding({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String elementId,
  required String text,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'set-finding',
    projectPath,
    '--element',
    elementId,
    '--text',
    text,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '見解を反映できません' : message);
  }
}

Future<void> setReportPageTitle({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String title,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'set-page-title',
    projectPath,
    '--text',
    title,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'ページタイトルを保存できません' : message);
  }
}

/// 画像を割り当てない新しいプロジェクトを、選んだフォルダへ作る。
Future<void> createReportProject({
  required String pythonExecutable,
  required String directory,
  required int imageCount,
  required String arrangement,
  required String template,
  String paper = '16x9',
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'new-project',
    directory,
    '--images',
    '$imageCount',
    '--arrangement',
    arrangement,
    '--template',
    template,
    '--paper',
    paper,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'プロジェクトを作成できません' : message);
  }
}

Future<List<AssignmentCandidate>> listAssignmentCandidates({
  required String pythonExecutable,
  required String projectPath,
  String? synonymsPath,
}) async {
  final arguments = <String>[
    '-m',
    'smart_report_builder.roi_edit',
    'suggest',
    projectPath,
  ];
  if (synonymsPath != null && synonymsPath.isNotEmpty) {
    arguments.addAll(['--synonyms', synonymsPath]);
  }
  final result = await runReportCommand(pythonExecutable, arguments);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '割当候補を読めません' : message);
  }
  return parseSuggestedAssignments('${result.stdout}');
}

Future<void> acceptReadyAssignments({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  String? synonymsPath,
}) async {
  final arguments = <String>[
    '-m',
    'smart_report_builder.roi_edit',
    'accept-ready',
    projectPath,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ];
  if (synonymsPath != null && synonymsPath.isNotEmpty) {
    arguments.addAll(['--synonyms', synonymsPath]);
  }
  final result = await runReportCommand(pythonExecutable, arguments);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '確定候補を割り当てできません' : message);
  }
}

Future<void> applyAssignmentCandidate({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String elementId,
  required String assetId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'apply-suggestion',
    projectPath,
    elementId,
    assetId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '候補を割り当てできません' : message);
  }
}

class LayoutProposal {
  const LayoutProposal({
    required this.id,
    required this.selected,
    required this.name,
    required this.reason,
  });

  final String id;
  final bool selected;
  final String name;
  final String reason;
}

List<LayoutProposal> parseLayoutProposals(String stdout) {
  final proposals = <LayoutProposal>[];
  for (final line in stdout.split(RegExp(r'\r?\n'))) {
    final parts = line.split('\t');
    if (parts.length < 4 || parts[0].isEmpty) {
      continue;
    }
    proposals.add(
      LayoutProposal(
        id: parts[0],
        selected: parts[1] == 'selected',
        name: parts[2],
        reason: parts.sublist(3).join('\t'),
      ),
    );
  }
  return proposals;
}

Future<List<LayoutProposal>> loadLayoutProposals({
  required String pythonExecutable,
  required String projectPath,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'variants',
    projectPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'レイアウト案を読めません' : message);
  }
  return parseLayoutProposals('${result.stdout}');
}

Future<void> applyLayoutProposal({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String variantId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'apply-variant',
    projectPath,
    variantId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'レイアウト案を適用できません' : message);
  }
}

Future<void> captureMasterRoi({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String roiId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'master-roi',
    projectPath,
    roiId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'マスター ROI を作れません' : message);
  }
}

Future<void> applyMasterRoi({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String masterId,
  required String elementId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'apply-master',
    projectPath,
    masterId,
    elementId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'マスター ROI を展開できません' : message);
  }
}

Future<void> addMeasurementTable({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'add-table',
    projectPath,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '表を追加できません' : message);
  }
}

Future<void> addTableRow({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String elementId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'add-table-row',
    projectPath,
    elementId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '行を追加できません' : message);
  }
}

Future<void> addTableColumn({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String elementId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'add-table-column',
    projectPath,
    elementId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '列を追加できません' : message);
  }
}

Future<void> resizeImageFrame({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String elementId,
  required SlideRect normalized,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'resize-frame',
    projectPath,
    elementId,
    normalized.x.toString(),
    normalized.y.toString(),
    normalized.width.toString(),
    normalized.height.toString(),
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '画像枠を変形できません' : message);
  }
}

Future<void> arrangeRoiZooms({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String arrangement,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'arrange-zooms',
    projectPath,
    '--arrangement',
    arrangement,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '拡大画像を並べられません' : message);
  }
}

Future<String> addImageFrame({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'add-frame',
    projectPath,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '画像枠を追加できません' : message);
  }
  final line = '${result.stdout}'.trim();
  final match = RegExp(r'^frame\s+(\S+)$').firstMatch(line);
  if (match == null) {
    throw const FormatException('画像枠を追加できません');
  }
  return match.group(1)!;
}

Future<void> removeImageFrame({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String elementId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'remove-frame',
    projectPath,
    elementId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '画像枠を削除できません' : message);
  }
}

Future<void> setImageFrameKind({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String elementId,
  required String kind,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'set-frame-kind',
    projectPath,
    elementId,
    '--kind',
    kind,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '画像の種類を変更できません' : message);
  }
}

Future<String> createDataset({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String name,
  required List<String> assetIds,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'create-dataset',
    projectPath,
    '--name',
    name,
    ...assetIds,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'グループを作れません' : message);
  }
  final line = '${result.stdout}'.trim();
  final match = RegExp(r'^dataset\s+(\S+)$').firstMatch(line);
  if (match == null) {
    throw const FormatException('グループを作れません');
  }
  return match.group(1)!;
}

Future<void> addDatasetAsset({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String datasetId,
  required String assetId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'add-dataset-asset',
    projectPath,
    datasetId,
    assetId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'グループに加えられません' : message);
  }
}

Future<void> removeDatasetAsset({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String datasetId,
  required String assetId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'remove-dataset-asset',
    projectPath,
    datasetId,
    assetId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'グループから外せません' : message);
  }
}

Future<void> setTableCell({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String elementId,
  required int row,
  required int column,
  required String text,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'set-table-cell',
    projectPath,
    elementId,
    '$row',
    '$column',
    '--text',
    text,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'セルを保存できません' : message);
  }
}

/// フォルダ以下の画像を素材として登録する。サブフォルダも含む。枠へは割り当てない。
Future<FolderRegistration> registerFolderImages({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String folderPath,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'register-folder',
    projectPath,
    folderPath,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '画像を登録できません' : message);
  }
  return parseFolderRegistration('${result.stdout}');
}

/// 未割当の素材の記録を削除する。元ファイルは残す。
Future<void> removeUnusedAsset({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String assetId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'remove-asset',
    projectPath,
    assetId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '素材の記録を削除できません' : message);
  }
}

/// すでに枠へ割り当てた素材を、別の通常表示の画像枠でも使う。
Future<void> shareRegisteredAsset({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String elementId,
  required String assetId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'share-asset',
    projectPath,
    elementId,
    assetId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '素材を共有できません' : message);
  }
}

/// 登録済みで未割当の素材を、通常表示の画像枠へ割り当てる。
Future<void> assignRegisteredAsset({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String elementId,
  required String assetId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'assign-asset',
    projectPath,
    elementId,
    assetId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '素材を割り当てられません' : message);
  }
}

/// 通常表示の画像枠へ画像ファイルを割り当て、配置と PPTX を計算し直す。
Future<void> assignFrameImage({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String elementId,
  required String imagePath,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'assign',
    projectPath,
    elementId,
    imagePath,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '画像を割り当てられません' : message);
  }
}

/// 通常表示の画像枠から素材の割当を外し、配置と PPTX を計算し直す。
Future<void> clearFrameImage({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String elementId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'unassign',
    projectPath,
    elementId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '画像の割当を外せません' : message);
  }
}

/// 注釈枠の左上をスライドポイントで保存し、配置と PPTX を計算し直す。
Future<void> placeRoiNote({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String roiId,
  required SlideRect frame,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'place-note',
    projectPath,
    roiId,
    _number(frame.x),
    _number(frame.y),
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '注釈の位置を保存できません' : message);
  }
}

/// 保存した注釈のずれを消し、自動配置で配置と PPTX を計算し直す。
Future<void> resetRoiNote({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String roiId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'reset-note',
    projectPath,
    roiId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? '注釈を自動位置へ戻せません' : message);
  }
}

/// 選択した ROI の注釈だけを変え、配置と PPTX を計算し直す。
Future<void> setRoiNote({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String roiId,
  required String note,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'annotate',
    projectPath,
    roiId,
    '--text',
    note.trim(),
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'ROI の注釈を保存できません' : message);
  }
}

/// 指定した ROI をプロジェクトから外し、配置と PPTX を計算し直す。
Future<void> deleteRoi({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String roiId,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    'delete',
    projectPath,
    roiId,
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'ROI の削除に失敗しました' : message);
  }
}

/// 正規化座標を Python に渡し、プロジェクト・配置・PPTX を書き直す。
Future<void> persistNormalizedRoi({
  required String pythonExecutable,
  required String projectPath,
  required String layoutPath,
  required String pptxPath,
  required String roiId,
  required SlideRect normalized,
}) async {
  final result = await runReportCommand(pythonExecutable, [
    '-m',
    'smart_report_builder.roi_edit',
    projectPath,
    roiId,
    _number(normalized.x),
    _number(normalized.y),
    _number(normalized.width),
    _number(normalized.height),
    '--layout',
    layoutPath,
    '--pptx',
    pptxPath,
  ]);
  if (result.exitCode != 0) {
    final message = '${result.stderr}'.trim();
    throw FormatException(message.isEmpty ? 'ROI の保存に失敗しました' : message);
  }
}

/// 配置 JSON の隣にある仮想環境の Python。
/// 新しいプロジェクトを別のフォルダへ作ったあとも、プレビューの隣の仮想環境を使う。
String? pythonExecutableNearLayout(String layoutPath) {
  final nearLayout = _venvPython(File(layoutPath).parent.parent);
  if (nearLayout != null) {
    return nearLayout;
  }
  return _venvPython(Directory.current.parent);
}

String? _venvPython(Directory packageDir) {
  final candidate = File(
    [
      packageDir.path,
      '.venv',
      'Scripts',
      'python.exe',
    ].join(Platform.pathSeparator),
  );
  if (candidate.existsSync()) {
    return candidate.path;
  }
  return null;
}

String _number(double value) => value.toStringAsFixed(8);
