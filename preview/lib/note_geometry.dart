import 'dart:math' as math;

import 'package:smart_report_preview/layout_result.dart';

/// ドラッグ中の注釈枠と接続線だけを動かす。配置の再計算ではない。
LayoutResult moveNoteLabel(LayoutResult result, String roiId, SlideRect label) {
  PlacedElement? roi;
  for (final element in result.elements) {
    if (element.elementId == roiId && element.kind == 'roi') {
      roi = element;
    }
  }
  if (roi == null) {
    return result;
  }
  final link = connectorEnds(roi.frame, label);
  final bounds = connectorBounds(link.start, link.end);
  return LayoutResult(
    schemaVersion: result.schemaVersion,
    slideWidthPt: result.slideWidthPt,
    slideHeightPt: result.slideHeightPt,
    violations: result.violations,
    skippedElementIds: result.skippedElementIds,
    previewMode: result.previewMode,
    chromeImage: result.chromeImage,
    titleText: result.titleText,
    titleFrame: result.titleFrame,
    titleFontPt: result.titleFontPt,
    titleColor: result.titleColor,
    elements: [
      for (final element in result.elements)
        if (element.elementId == '$roiId-note')
          element.copyWith(frame: label)
        else if (element.elementId == '$roiId-connector')
          element.copyWith(
            frame: bounds,
            lineStart: link.start,
            lineEnd: link.end,
          )
        else
          element,
    ],
  );
}

class ConnectorEnds {
  const ConnectorEnds(this.start, this.end);

  final LayoutPoint start;
  final LayoutPoint end;
}

/// ROI 枠と注釈枠の、向かい合う辺の中央を結ぶ。
ConnectorEnds connectorEnds(SlideRect roi, SlideRect label) {
  final roiCenterX = roi.x + roi.width / 2;
  final roiCenterY = roi.y + roi.height / 2;
  final labelCenterX = label.x + label.width / 2;
  final labelCenterY = label.y + label.height / 2;
  if ((labelCenterX - roiCenterX).abs() >= (labelCenterY - roiCenterY).abs()) {
    if (labelCenterX >= roiCenterX) {
      return ConnectorEnds(
        LayoutPoint(roi.x + roi.width, roiCenterY),
        LayoutPoint(label.x, labelCenterY),
      );
    }
    return ConnectorEnds(
      LayoutPoint(roi.x, roiCenterY),
      LayoutPoint(label.x + label.width, labelCenterY),
    );
  }
  if (labelCenterY >= roiCenterY) {
    return ConnectorEnds(
      LayoutPoint(roiCenterX, roi.y + roi.height),
      LayoutPoint(labelCenterX, label.y),
    );
  }
  return ConnectorEnds(
    LayoutPoint(roiCenterX, roi.y),
    LayoutPoint(labelCenterX, label.y + label.height),
  );
}

class ArrowPoint {
  const ArrowPoint(this.x, this.y);

  final double x;
  final double y;
}

const noteArrowLengthPt = 8.0;
const noteArrowWidthPt = 8.0;

/// 矢印の先端は ROI 側。底辺は注釈へ向かう。長さが足りない線には付けない。
List<ArrowPoint>? arrowHeadPoints(
  double tipX,
  double tipY,
  double awayX,
  double awayY,
) {
  final dx = awayX - tipX;
  final dy = awayY - tipY;
  final distance = math.sqrt(dx * dx + dy * dy);
  if (distance < 0.5) {
    return null;
  }
  final directionX = dx / distance;
  final directionY = dy / distance;
  final baseX = tipX + directionX * noteArrowLengthPt;
  final baseY = tipY + directionY * noteArrowLengthPt;
  final normalX = -directionY;
  final normalY = directionX;
  final half = noteArrowWidthPt / 2;
  return [
    ArrowPoint(tipX, tipY),
    ArrowPoint(baseX + normalX * half, baseY + normalY * half),
    ArrowPoint(baseX - normalX * half, baseY - normalY * half),
  ];
}

SlideRect connectorBounds(LayoutPoint start, LayoutPoint end) {
  return SlideRect(
    x: math.min(start.x, end.x),
    y: math.min(start.y, end.y),
    width: (end.x - start.x).abs(),
    height: (end.y - start.y).abs(),
  );
}
