import 'dart:io';

/// 起動時に開く配置ファイル。引数がないときはサンプルの LayoutResult を探す。
String defaultLayoutPath() {
  final current = Directory.current.path;
  final candidates = [
    layoutPathFrom(current, ['..', 'output', 'sample_a.layout.json']),
    layoutPathFrom(current, ['output', 'sample_a.layout.json']),
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return candidates.first;
}

/// すでにプレビューがある PPTX の配置ファイル。無いときは null。
String? existingLayoutForPptx(String pptxPath) {
  final name = _fileName(pptxPath);
  if (!name.toLowerCase().endsWith('.pptx')) {
    return null;
  }
  final stem = name.substring(0, name.length - 5);
  final directory = _directoryOf(pptxPath);
  final separator = Platform.pathSeparator;
  final candidates = <String>[
    if (name.toLowerCase() == 'report.pptx') '${directory}layout.json',
    '${directory}$stem.layout.json',
    '${directory}$stem.preview${separator}layout.json',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return null;
}

/// テンプレート PPTX から作るプレビュー用フォルダ。元の PPTX は変更しない。
String previewDirectoryForPptx(String pptxPath) {
  final name = _fileName(pptxPath);
  final stem = name.toLowerCase().endsWith('.pptx')
      ? name.substring(0, name.length - 5)
      : name;
  return '${_directoryOf(pptxPath)}$stem.preview';
}

String _fileName(String path) {
  final separator = path.lastIndexOf(Platform.pathSeparator);
  final slash = path.lastIndexOf('/');
  final index = separator > slash ? separator : slash;
  return index < 0 ? path : path.substring(index + 1);
}

String _directoryOf(String path) {
  final name = _fileName(path);
  return path.substring(0, path.length - name.length);
}

String layoutPathFrom(String directory, List<String> relativeParts) {
  final separator = Platform.pathSeparator;
  final base = directory.endsWith(separator)
      ? directory
      : '$directory$separator';
  return Uri.file(base).resolve(relativeParts.join('/')).toFilePath();
}
