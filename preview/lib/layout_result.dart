import 'dart:convert';
import 'dart:math' as math;

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
    this.zoomElementId,
    this.textAnchor,
    this.labelFrame,
    this.fontPt,
    this.renderedText,
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
  final String? zoomElementId;
  final String? textAnchor;
  final SlideRect? labelFrame;
  final double? fontPt;
  final String? renderedText;

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
      zoomElementId: zoomElementId,
      textAnchor: textAnchor,
      labelFrame: labelFrame,
      fontPt: fontPt,
      renderedText: renderedText,
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
      zoomElementId: json['zoomElementId'] as String?,
      textAnchor: json['textAnchor'] as String?,
      labelFrame: json['labelFrame'] == null
          ? null
          : SlideRect.fromJson(Map<String, dynamic>.from(json['labelFrame'] as Map)),
      fontPt: (json['fontPt'] as num?)?.toDouble(),
      renderedText: json['renderedText'] as String?,
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

/// 枠の中で実際に画像が描かれている範囲。未割当のときは枠そのもの。
SlideRect pictureBox(PlacedElement element) => element.contentRect ?? element.frame;

/// 見出しを含めた保存用の枠。移動はこの大きさのまま行う。
SlideRect frameSlot(PlacedElement element) {
  final image = element.frame;
  final label = element.labelFrame;
  if (label == null) return image;
  final left = math.min(image.x, label.x);
  final top = math.min(image.y, label.y);
  final right = math.max(image.x + image.width, label.x + label.width);
  final bottom = math.max(image.y + image.height, label.y + label.height);
  return SlideRect(x: left, y: top, width: right - left, height: bottom - top);
}

/// 見えている画像の外側に、今の見出し帯を足す。
///
/// 見出しを除いた矩形を枠として保存すると、次の配置で見出しの分だけ画像が縮む。
SlideRect slotAroundPicture(SlideRect picture, PlacedElement element) {
  final label = element.labelFrame;
  if (label == null || label.height <= 0) return picture;
  final below = element.textAnchor == 'below';
  return SlideRect(
    x: picture.x,
    y: below ? picture.y : picture.y - label.height,
    width: picture.width,
    height: picture.height + label.height,
  );
}

/// 画像の縦横比を保ったまま、親の範囲の中で拡大・縮小する。
SlideRect scalePicture(SlideRect box, SlideRect limit, double factor) {
  if (box.width <= 0 || box.height <= 0 || limit.width <= 0 || limit.height <= 0) {
    return box;
  }
  return _placePicture(
    SlideRect(
      x: box.x + box.width * (1 - factor) / 2,
      y: box.y + box.height * (1 - factor) / 2,
      width: box.width * factor,
      height: box.height * factor,
    ),
    limit,
    box.width / box.height,
  );
}

/// 画像を親の範囲から出さないように動かす。
SlideRect movePicture(SlideRect box, SlideRect limit, double dx, double dy) {
  if (limit.width <= 0 || limit.height <= 0) return box;
  final width = math.min(box.width, limit.width);
  final height = math.min(box.height, limit.height);
  return SlideRect(
    x: (box.x + dx).clamp(limit.x, limit.x + limit.width - width),
    y: (box.y + dy).clamp(limit.y, limit.y + limit.height - height),
    width: width,
    height: height,
  );
}

/// 辺や角のドラッグで、画像の縦横比を保って大きさを変える。
SlideRect resizePicture(
  SlideRect box,
  SlideRect limit, {
  required double dx,
  required double dy,
  required int horizontal,
  required int vertical,
}) {
  if (box.width <= 0 || box.height <= 0 || limit.width <= 0 || limit.height <= 0) {
    return box;
  }
  final aspect = box.width / box.height;
  var width = box.width;
  var height = box.height;
  if (horizontal != 0 && vertical != 0) {
    final dw = horizontal * dx;
    final dh = vertical * dy;
    if (dw.abs() >= dh.abs() * aspect) {
      width = box.width + dw;
      height = width / aspect;
    } else {
      height = box.height + dh;
      width = height * aspect;
    }
  } else if (horizontal != 0) {
    width = box.width + horizontal * dx;
    height = width / aspect;
  } else if (vertical != 0) {
    height = box.height + vertical * dy;
    width = height * aspect;
  }
  final right = box.x + box.width;
  final bottom = box.y + box.height;
  width = math.max(width, 1);
  height = math.max(height, 1);
  return _placePicture(
    SlideRect(
      x: horizontal < 0
          ? right - width
          : horizontal > 0
          ? box.x
          : box.x + (box.width - width) / 2,
      y: vertical < 0
          ? bottom - height
          : vertical > 0
          ? box.y
          : box.y + (box.height - height) / 2,
      width: width,
      height: height,
    ),
    limit,
    aspect,
  );
}

/// 親の範囲に対する 0〜1 の位置へ直す。
SlideRect normalizePicture(SlideRect box, SlideRect group) {
  if (group.width <= 0 || group.height <= 0) {
    return const SlideRect(x: 0, y: 0, width: 1, height: 1);
  }
  final width = (box.width / group.width).clamp(0.02, 1.0);
  final height = (box.height / group.height).clamp(0.02, 1.0);
  return SlideRect(
    x: ((box.x - group.x) / group.width).clamp(0.0, 1 - width),
    y: ((box.y - group.y) / group.height).clamp(0.0, 1 - height),
    width: width,
    height: height,
  );
}

SlideRect _placePicture(SlideRect box, SlideRect limit, double aspect) {
  var width = box.width;
  var height = box.height;
  if (width <= 0 || height <= 0) return box;
  final fitted = math.min(limit.width / width, limit.height / height);
  if (fitted < 1) {
    width *= fitted;
    height *= fitted;
  }
  final minWidth = math.max(limit.width * 0.08, 1.0);
  final minHeight = minWidth / aspect;
  if (width < minWidth || height < minHeight) {
    final grow = math.max(minWidth / width, minHeight / height);
    width *= grow;
    height *= grow;
    final shrink = math.min(limit.width / width, limit.height / height);
    if (shrink < 1) {
      width *= shrink;
      height *= shrink;
    }
  }
  return SlideRect(
    x: box.x.clamp(limit.x, limit.x + limit.width - width),
    y: box.y.clamp(limit.y, limit.y + limit.height - height),
    width: width,
    height: height,
  );
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

/// 違反を、編集画面でそのまま読める文にする。
String describeViolation(LayoutViolation violation, List<PlacedElement> elements) {
  final name = _elementLabel(violation.elementId, elements);
  switch (violation.code) {
    case 'unassigned_image':
      return '$name に画像が割り当てられていません';
    case 'missing_asset':
      return '$name の画像ファイルが見つかりません';
    case 'text_overflow':
      return '$name の文章が枠に入りきりません。縦幅を広げるか、文字を小さくしてください';
    case 'overlap':
      final otherId = violation.message.split(' ').first;
      final other = _elementLabel(otherId, elements);
      return '$name が $other と重なっています';
    case 'roi_unmapped':
      return '拡大範囲を表示できません。拡大元の画像を割り当ててください';
    case 'roi_conflict':
      return '同じ拡大画像に拡大範囲が複数あるため、表示していません';
    case 'roi_out_of_bounds':
      return '拡大範囲が元画像の外にはみ出しています';
    case 'invalid_image_size':
      return '$name の画像サイズを読み取れません';
    default:
      if (violation.message.contains('小さすぎ')) return '$name の枠が小さすぎます';
      if (violation.message.contains('はみ出')) return '$name がスライドの外にはみ出しています';
      if (violation.message.contains('負')) return '$name を置く余白が足りません';
      if (name == violation.elementId) return violation.message;
      return '$name: ${violation.message}';
  }
}

String _elementLabel(String id, List<PlacedElement> elements) {
  String? name;
  for (final element in elements) {
    if (element.elementId == id) {
      name = element.displayName.trim();
      break;
    }
  }
  if (name == null || name.isEmpty) return id;
  final duplicates = elements.where((element) => element.displayName.trim() == name).length;
  if (duplicates > 1) return '$name（$id）';
  return name;
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
