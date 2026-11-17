import 'dart:math' as math;
import 'dart:ui';

import 'package:smart_report_preview/layout_result.dart';

const roiMinSizePt = 8.0;
const frameMinSizePt = 24.0;

/// 画像枠の辺か角。動かした辺だけが伸び、反対側は固定する。
enum FrameHandle {
  left,
  right,
  top,
  bottom,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

/// サイズ変更で動かす角。反対側の角は固定する。
enum RoiCorner { topLeft, topRight, bottomLeft, bottomRight }

/// ROI 枠を元画像の表示矩形の中に収める。画面上の移動であり、配置計算ではない。
SlideRect clampRoi(
  SlideRect roi,
  SlideRect bounds, {
  double minSize = roiMinSizePt,
}) {
  final minWidth = math.min(minSize, bounds.width);
  final minHeight = math.min(minSize, bounds.height);
  final width = roi.width.clamp(minWidth, bounds.width).toDouble();
  final height = roi.height.clamp(minHeight, bounds.height).toDouble();
  final x = roi.x.clamp(bounds.x, bounds.x + bounds.width - width).toDouble();
  final y = roi.y.clamp(bounds.y, bounds.y + bounds.height - height).toDouble();
  return SlideRect(x: x, y: y, width: width, height: height);
}

SlideRect moveRoi(SlideRect roi, SlideRect bounds, double dx, double dy) {
  return clampRoi(
    SlideRect(
      x: roi.x + dx,
      y: roi.y + dy,
      width: roi.width,
      height: roi.height,
    ),
    bounds,
  );
}

/// 右下を動かした分だけ幅と高さを変える。左上は固定する。
SlideRect resizeRoi(SlideRect roi, SlideRect bounds, double dx, double dy) {
  return resizeRoiFromCorner(roi, bounds, RoiCorner.bottomRight, dx, dy);
}

/// 指定した角を動かし、反対側の角は動かさない。元画像の表示範囲と最小サイズに収める。
SlideRect resizeRoiFromCorner(
  SlideRect roi,
  SlideRect bounds,
  RoiCorner corner,
  double dx,
  double dy,
) {
  final movesLeft =
      corner == RoiCorner.topLeft || corner == RoiCorner.bottomLeft;
  final movesTop = corner == RoiCorner.topLeft || corner == RoiCorner.topRight;
  final anchorX = movesLeft ? roi.x + roi.width : roi.x;
  final anchorY = movesTop ? roi.y + roi.height : roi.y;
  final roomWidth = movesLeft
      ? anchorX - bounds.x
      : bounds.x + bounds.width - anchorX;
  final roomHeight = movesTop
      ? anchorY - bounds.y
      : bounds.y + bounds.height - anchorY;
  final minWidth = math.min(roiMinSizePt, math.max(roomWidth, 0));
  final minHeight = math.min(roiMinSizePt, math.max(roomHeight, 0));
  final width = (roi.width + (movesLeft ? -dx : dx))
      .clamp(minWidth, math.max(minWidth, roomWidth))
      .toDouble();
  final height = (roi.height + (movesTop ? -dy : dy))
      .clamp(minHeight, math.max(minHeight, roomHeight))
      .toDouble();
  final x = (movesLeft ? anchorX - width : anchorX)
      .clamp(bounds.x, bounds.x + bounds.width - width)
      .toDouble();
  final y = (movesTop ? anchorY - height : anchorY)
      .clamp(bounds.y, bounds.y + bounds.height - height)
      .toDouble();
  return SlideRect(x: x, y: y, width: width, height: height);
}

/// ドラッグの始点と現在位置から、元画像の表示範囲に収まる矩形を作る。
SlideRect? rectInside(Offset start, Offset current, SlideRect bounds) {
  final left = math.max(math.min(start.dx, current.dx), bounds.x);
  final top = math.max(math.min(start.dy, current.dy), bounds.y);
  final right = math.min(
    math.max(start.dx, current.dx),
    bounds.x + bounds.width,
  );
  final bottom = math.min(
    math.max(start.dy, current.dy),
    bounds.y + bounds.height,
  );
  final width = right - left;
  final height = bottom - top;
  if (width <= 0 || height <= 0) {
    return null;
  }
  return SlideRect(x: left, y: top, width: width, height: height);
}

bool canCommitRoi(SlideRect roi) {
  return roi.width >= roiMinSizePt && roi.height >= roiMinSizePt;
}

/// 画像枠の一辺か一角を動かす。並びの矩形の中に収め、幅と高さを別々に変えられる。
SlideRect resizeFrame(
  SlideRect frame,
  SlideRect bounds,
  FrameHandle handle,
  double dx,
  double dy,
) {
  final minWidth = math.min(frameMinSizePt, math.max(bounds.width, 0));
  final minHeight = math.min(frameMinSizePt, math.max(bounds.height, 0));
  final movesLeft =
      handle == FrameHandle.left ||
      handle == FrameHandle.topLeft ||
      handle == FrameHandle.bottomLeft;
  final movesRight =
      handle == FrameHandle.right ||
      handle == FrameHandle.topRight ||
      handle == FrameHandle.bottomRight;
  final movesTop =
      handle == FrameHandle.top ||
      handle == FrameHandle.topLeft ||
      handle == FrameHandle.topRight;
  final movesBottom =
      handle == FrameHandle.bottom ||
      handle == FrameHandle.bottomLeft ||
      handle == FrameHandle.bottomRight;
  var left = frame.x;
  var top = frame.y;
  var right = frame.x + frame.width;
  var bottom = frame.y + frame.height;
  if (movesLeft) {
    left += dx;
  }
  if (movesRight) {
    right += dx;
  }
  if (movesTop) {
    top += dy;
  }
  if (movesBottom) {
    bottom += dy;
  }
  final limitRight = bounds.x + bounds.width;
  final limitBottom = bounds.y + bounds.height;
  if (movesLeft) {
    left = left.clamp(bounds.x, right - minWidth).toDouble();
  }
  if (movesRight) {
    right = right.clamp(left + minWidth, limitRight).toDouble();
  }
  if (movesTop) {
    top = top.clamp(bounds.y, bottom - minHeight).toDouble();
  }
  if (movesBottom) {
    bottom = bottom.clamp(top + minHeight, limitBottom).toDouble();
  }
  left = left.clamp(bounds.x, limitRight - minWidth).toDouble();
  top = top.clamp(bounds.y, limitBottom - minHeight).toDouble();
  right = right.clamp(left + minWidth, limitRight).toDouble();
  bottom = bottom.clamp(top + minHeight, limitBottom).toDouble();
  return SlideRect(x: left, y: top, width: right - left, height: bottom - top);
}

/// 画像枠を変形できる範囲。配置が渡した並びの矩形を優先し、無いときは同じ段の枠の外接矩形。
SlideRect imageFrameBounds(LayoutResult layout, PlacedElement frame) {
  final group = frame.groupFrame;
  if (group != null && group.width > 0 && group.height > 0) {
    return group;
  }
  var left = frame.frame.x;
  var top = frame.frame.y;
  var right = left + frame.frame.width;
  var bottom = top + frame.frame.height;
  final midY = top + frame.frame.height / 2;
  for (final element in layout.elements) {
    if (element.kind != 'image_frame') {
      continue;
    }
    final box = element.frame;
    final overlaps = midY >= box.y && midY <= box.y + box.height;
    if (!overlaps) {
      continue;
    }
    left = math.min(left, box.x);
    top = math.min(top, box.y);
    right = math.max(right, box.x + box.width);
    bottom = math.max(bottom, box.y + box.height);
  }
  return SlideRect(x: left, y: top, width: right - left, height: bottom - top);
}

/// 表示中の画像矩形に対する正規化座標（0〜1）。
SlideRect normalizedRoi(SlideRect roi, SlideRect image) {
  return SlideRect(
    x: (roi.x - image.x) / image.width,
    y: (roi.y - image.y) / image.height,
    width: roi.width / image.width,
    height: roi.height / image.height,
  );
}

String? projectPathForLayout(String layoutPath) {
  const suffix = '.layout.json';
  if (layoutPath.endsWith(suffix)) {
    return '${layoutPath.substring(0, layoutPath.length - suffix.length)}.project.json';
  }
  if (_layoutFileName(layoutPath) == 'layout.json') {
    return _siblingPath(layoutPath, 'project.json');
  }
  return null;
}

String? undoPathForProject(String? projectPath) {
  if (projectPath == null || projectPath.isEmpty) {
    return null;
  }
  return '$projectPath.undo';
}

String? redoPathForProject(String? projectPath) {
  if (projectPath == null || projectPath.isEmpty) {
    return null;
  }
  return '$projectPath.redo';
}

String? pptxPathForLayout(String layoutPath) {
  const suffix = '.layout.json';
  if (layoutPath.endsWith(suffix)) {
    return '${layoutPath.substring(0, layoutPath.length - suffix.length)}.pptx';
  }
  if (_layoutFileName(layoutPath) == 'layout.json') {
    return _siblingPath(layoutPath, 'report.pptx');
  }
  return null;
}

String _layoutFileName(String path) {
  final separator = _lastSeparator(path);
  return separator < 0 ? path : path.substring(separator + 1);
}

String _siblingPath(String path, String name) {
  final separator = _lastSeparator(path);
  if (separator < 0) {
    return name;
  }
  return '${path.substring(0, separator + 1)}$name';
}

int _lastSeparator(String path) {
  final slash = path.lastIndexOf('/');
  final backslash = path.lastIndexOf('\\');
  return slash > backslash ? slash : backslash;
}
