import 'dart:convert';

/// 枠の変形に合わせて、中の画像矩形を同じ比率で追従させる。
SlideRect? scaleContainedRect(SlideRect oldFrame, SlideRect newFrame, SlideRect? content) {
  if (content == null || oldFrame.width == 0 || oldFrame.height == 0) {
    return content;
  }
  final scaleX = newFrame.width / oldFrame.width;
  final scaleY = newFrame.height / oldFrame.height;
  return SlideRect(
    x: newFrame.x + (content.x - oldFrame.x) * scaleX,
    y: newFrame.y + (content.y - oldFrame.y) * scaleY,
    width: content.width * scaleX,
    height: content.height * scaleY,
  );
}

/// LayoutResult の読み取り専用モデル。配置の再計算はしない。
class LayoutResult {
  const LayoutResult({
    required this.schemaVersion,
    required this.slideWidthPt,
    required this.slideHeightPt,
    required this.elements,
    required this.violations,
    required this.skippedElementIds,
    required this.previewMode,
    this.chromeImage,
    this.titleText,
    this.titleFrame,
    this.titleFontPt,
    this.titleColor,
  });

  static const supportedSchemaVersion = 1;

  final int schemaVersion;
  final double slideWidthPt;
  final double slideHeightPt;
  final List<PlacedElement> elements;
  final List<LayoutViolation> violations;
  final List<String> skippedElementIds;
  final String previewMode;
  final String? chromeImage;
  final String? titleText;
  final SlideRect? titleFrame;
  final double? titleFontPt;
  final String? titleColor;

  factory LayoutResult.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version is! num || version != supportedSchemaVersion) {
      throw FormatException('unsupported schemaVersion: $version');
    }
    final rawElements = _list(json, 'elements');
    final elements = <PlacedElement>[];
    final skipped = <String>[];
    for (final item in rawElements) {
      if (item is! Map) {
        throw const FormatException('element がオブジェクトではない');
      }
      final data = Map<String, dynamic>.from(item);
      final kind = _string(data, 'kind');
      final elementId = _string(data, 'elementId');
      if (kind != 'image_frame' &&
          kind != 'text' &&
          kind != 'roi' &&
          kind != 'roi_label' &&
          kind != 'connector' &&
          kind != 'table') {
        skipped.add(elementId);
        continue;
      }
      elements.add(PlacedElement.fromJson(data));
    }
    return LayoutResult(
      schemaVersion: version.toInt(),
      slideWidthPt: _number(json, 'slideWidthPt'),
      slideHeightPt: _number(json, 'slideHeightPt'),
      elements: elements,
      violations: [
        for (final item in _list(json, 'violations'))
          LayoutViolation.fromJson(Map<String, dynamic>.from(item as Map)),
      ],
      skippedElementIds: skipped,
      previewMode: _previewMode(json, elements),
      chromeImage: json['chromeImage'] as String?,
      titleText: json['titleText'] as String?,
      titleFrame: json['titleFrame'] == null
          ? null
          : SlideRect.fromJson(Map<String, dynamic>.from(json['titleFrame'] as Map)),
      titleFontPt: json['titleFontPt'] == null ? null : _number(json, 'titleFontPt'),
      titleColor: json['titleColor'] as String?,
    );
  }

  LayoutResult replaceFrame(String elementId, SlideRect frame) {
    return LayoutResult(
      schemaVersion: schemaVersion,
      slideWidthPt: slideWidthPt,
      slideHeightPt: slideHeightPt,
      elements: [
        for (final element in elements)
          if (element.elementId == elementId)
            element.copyWith(frame: frame)
          else
            element,
      ],
      violations: violations,
      skippedElementIds: skippedElementIds,
      previewMode: previewMode,
      chromeImage: chromeImage,
      titleText: titleText,
      titleFrame: titleFrame,
      titleFontPt: titleFontPt,
      titleColor: titleColor,
    );
  }

  LayoutResult replaceImageFrame(String elementId, SlideRect frame) {
    return LayoutResult(
      schemaVersion: schemaVersion,
      slideWidthPt: slideWidthPt,
      slideHeightPt: slideHeightPt,
      elements: [
        for (final element in elements)
          if (element.elementId == elementId && element.kind == 'image_frame')
            element.copyWith(
              frame: frame,
              contentRect: scaleContainedRect(element.frame, frame, element.contentRect),
            )
          else
            element,
      ],
      violations: violations,
      skippedElementIds: skippedElementIds,
      previewMode: previewMode,
      chromeImage: chromeImage,
      titleText: titleText,
      titleFrame: titleFrame,
      titleFontPt: titleFontPt,
      titleColor: titleColor,
    );
  }
}

class PlacedElement {
  const PlacedElement({
    required this.elementId,
    required this.kind,
    required this.roleId,
    required this.displayName,
    required this.frame,
    required this.contentRect,
    required this.text,
    required this.assetPath,
    required this.fitMode,
    required this.crop,
    this.sourceElementId,
    this.lineStart,
    this.lineEnd,
    this.tableRows,
    this.groupFrame,
  });

  final String elementId;
  final String kind;
  final String roleId;
  final String displayName;
  final SlideRect frame;
  final SlideRect? contentRect;
  final String? text;
  final String? assetPath;
  final String fitMode;
  final SlideRect? crop;
  final String? sourceElementId;
  final LayoutPoint? lineStart;
  final LayoutPoint? lineEnd;
  final List<List<String>>? tableRows;
  final SlideRect? groupFrame;

  PlacedElement copyWith({
    SlideRect? frame,
    SlideRect? contentRect,
    LayoutPoint? lineStart,
    LayoutPoint? lineEnd,
  }) {
    return PlacedElement(
      elementId: elementId,
      kind: kind,
      roleId: roleId,
      displayName: displayName,
      frame: frame ?? this.frame,
      contentRect: contentRect ?? this.contentRect,
      text: text,
      assetPath: assetPath,
      fitMode: fitMode,
      crop: crop,
      sourceElementId: sourceElementId,
      lineStart: lineStart ?? this.lineStart,
      lineEnd: lineEnd ?? this.lineEnd,
      tableRows: tableRows,
      groupFrame: groupFrame,
    );
  }

  factory PlacedElement.fromJson(Map<String, dynamic> json) {
    final content = json['contentRect'];
    final crop = json['crop'];
    return PlacedElement(
      elementId: _string(json, 'elementId'),
      kind: _string(json, 'kind'),
      roleId: _string(json, 'roleId'),
      displayName: _string(json, 'displayName'),
      frame: SlideRect.fromJson(Map<String, dynamic>.from(_map(json, 'frame'))),
      contentRect: content == null
          ? null
          : SlideRect.fromJson(Map<String, dynamic>.from(content as Map)),
      text: json['text'] as String?,
      assetPath: json['assetPath'] as String?,
      fitMode: _string(json, 'fitMode'),
      crop: crop == null
          ? null
          : SlideRect.fromJson(Map<String, dynamic>.from(crop as Map)),
      sourceElementId: json['sourceElementId'] as String?,
      lineStart: _point(json['lineStart']),
      lineEnd: _point(json['lineEnd']),
      tableRows: _tableRows(json['tableRows']),
      groupFrame: json['groupFrame'] == null
          ? null
          : SlideRect.fromJson(Map<String, dynamic>.from(json['groupFrame'] as Map)),
    );
  }
}

class LayoutPoint {
  const LayoutPoint(this.x, this.y);

  final double x;
  final double y;
}

class LayoutViolation {
  const LayoutViolation({
    required this.code,
    required this.elementId,
    required this.message,
  });

  final String code;
  final String elementId;
  final String message;

  factory LayoutViolation.fromJson(Map<String, dynamic> json) {
    return LayoutViolation(
      code: _string(json, 'code'),
      elementId: _string(json, 'elementId'),
      message: _string(json, 'message'),
    );
  }
}

class SlideRect {
  const SlideRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  factory SlideRect.fromJson(Map<String, dynamic> json) {
    return SlideRect(
      x: _number(json, 'x'),
      y: _number(json, 'y'),
      width: _number(json, 'width'),
      height: _number(json, 'height'),
    );
  }
}

String previewModeOf(List<PlacedElement> elements) {
  final contain = [
    for (final element in elements)
      if (element.kind == 'image_frame' && element.fitMode == 'contain') element,
  ];
  final filled = [
    for (final element in contain)
      if (element.contentRect != null) element,
  ];
  if (contain.isEmpty || filled.isEmpty) {
    return 'provisional';
  }
  if (filled.length == contain.length) {
    return 'real';
  }
  return 'partial';
}

String previewModeLabel(String mode) {
  switch (mode) {
    case 'real':
      return '実データプレビュー';
    case 'partial':
      return '一部が実データ';
    default:
      return '仮プレビュー';
  }
}

String _previewMode(Map<String, dynamic> json, List<PlacedElement> elements) {
  final raw = json['previewMode'];
  if (raw == 'provisional' || raw == 'real' || raw == 'partial') {
    return raw;
  }
  return previewModeOf(elements);
}

LayoutResult parseLayoutResult(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map) {
    throw const FormatException('JSON オブジェクトではない');
  }
  return LayoutResult.fromJson(Map<String, dynamic>.from(decoded));
}

List<dynamic> _list(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List) {
    throw FormatException('missing field: $key');
  }
  return value;
}

Map<dynamic, dynamic> _map(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! Map) {
    throw FormatException('missing field: $key');
  }
  return value;
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('missing field: $key');
  }
  return value;
}

List<List<String>>? _tableRows(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! List) {
    throw const FormatException('tableRows が配列ではない');
  }
  return [
    for (final row in value)
      if (row is List) [for (final cell in row) '$cell'] else <String>[],
  ];
}

LayoutPoint? _point(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! Map) {
    throw const FormatException('線の端がオブジェクトではない');
  }
  final data = Map<String, dynamic>.from(value);
  return LayoutPoint(_number(data, 'x'), _number(data, 'y'));
}

double _number(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num) {
    throw FormatException('missing field: $key');
  }
  return value.toDouble();
}
